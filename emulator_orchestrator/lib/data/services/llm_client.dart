import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Thin Dart HTTP wrapper around the local Ollama server's REST API.
///
/// Backs the two Ollama endpoints the rest of the LLM stack needs:
///   - `POST /api/generate` for streaming hook generation, and
///   - `POST /api/embeddings` for the RAG index's nomic-embed-text
///     query/document embeddings.
///
/// Construction parameters come from the user's resect.config:
///   - [host]  → `LLM_OLLAMA_HOST` (default `localhost:11434`)
///   - [model] → `LLM_MODEL`        (e.g. `gemma4:12b`)
///
/// All calls go to a local process. No outbound network traffic.
class LlmClient {
  LlmClient({
    required this.host,
    required this.model,
    this.embeddingModel = 'nomic-embed-text',
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  /// `host:port` of the Ollama server. Stored without scheme.
  final String host;

  /// Ollama tag of the inference model used by [generate].
  final String model;

  /// Ollama tag of the embedding model used by [embed].
  final String embeddingModel;

  final HttpClient _http;

  /// Stream response tokens as the inference model produces them.
  ///
  /// Yields the `response` field of each NDJSON line Ollama emits — so
  /// callers can append tokens to an editor as they arrive. Ends when
  /// Ollama signals `done: true`.
  ///
  /// Cancel by `.cancel()`'ing the subscription. The underlying request
  /// stays open server-side until Ollama finishes; v1 accepts that idle
  /// work in exchange for simpler client code. Thinking-channel tokens
  /// are emitted into Ollama's separate `thinking` JSON field and
  /// are NOT yielded by this stream — callers that want them have to
  /// hit `/api/generate` directly (see `tool/sweep_v2.dart`).
  ///
  /// ### Default sampling: the Gemma 4 model-card recipe
  ///
  /// `temperature=1.0`, `top_p=0.95`, `top_k=64` are the values
  /// Google publishes on the Gemma 4 model card. The three are
  /// **tuned together** — `top_p` and `top_k` cap the sampling
  /// pool, and `temperature` samples within that capped distribution.
  /// Twisting one knob in isolation (e.g. dropping T to 0.2) breaks
  /// the recipe. We override only when a specific caller has a
  /// reason — see `LlmJudge` below.
  ///
  /// ### Default generation budget: reasoning ON, 4000 tokens
  ///
  /// `think=true` and `numPredict=4000` are what passed end-to-end
  /// verification on both `gemma4:e4b` and `gemma4:12b` for the
  /// hook-gen task on 2026-06-11. The hook generator's canonical
  /// out-pointer shape (`pointer.writeData(cpu, ptr, [0] * N)`)
  /// requires the model to read the pinned `data_type` chunk,
  /// identify it as an out-pointer arg, look up the struct size,
  /// and combine that with the register-arg ABI — work that the
  /// non-thinking path on the smaller model cannot do. With
  /// `think=false`, `gemma4:e4b` deterministically pattern-matches
  /// the no-op (`setReturnValue(cpu, 0)`) for every non-trivial
  /// function regardless of context.
  ///
  /// 4000 tokens is a tested ceiling: `gemma4:e4b` typically closes
  /// its thought block in ~700 tokens and emits the response in
  /// another ~100; `gemma4:12b` uses ~3200 tokens for the same
  /// task. 4000 covers both with margin.
  ///
  /// ### Why these defaults aren't the LL_APB0 protection
  ///
  /// An earlier comment-block on this docstring claimed `numPredict=384`
  /// was the forcing function against the 2026-06 `LL_APB0_GRP1_EnableClock`
  /// fantasy-register-map failure mode. That regression is actually
  /// guarded by two other mechanisms: (a) the system-prompt
  /// grounding rules (commit-or-stub, comment-budget, quote-the-source —
  /// see `LlmHookGenerator.systemPrompt`), and (b) the `stop`
  /// sequences passed by `LlmHookGenerator` to halt the model at the
  /// first `\n# Since`, `\n# Based on`, `\n# Typically`, etc. — the
  /// literal opener of the failure mode's comment preamble. Those
  /// two together do the work; the 384-token cap turned out to make
  /// the smaller model unusable without contributing to safety.
  ///
  /// ### `numCtx` defaults to 16384
  ///
  /// Ollama's slot default is 4096 tokens, which truncates prompts
  /// with `## Platform` (.repl + symbols) + RAG context + system
  /// prompt + room to reply. Truncation chops the *end* of the
  /// prompt — including the `## Request` line — and the model emits
  /// a single-token reply before stopping. 16K covers our prompts
  /// with margin without ballooning KV-cache memory (~12 MB per 1K
  /// tokens on gemma4:12b at Q4).
  ///
  /// ### Per-caller overrides
  ///
  /// `LlmJudge` pins `think=false`, `numPredict=256`, and
  /// `temperature=0.0` explicitly because it's a short
  /// structured-output task (verdict JSON with winner + confidence +
  /// reason). Reasoning would consume the 256-token budget before
  /// any response bytes appear; that's why the override is required
  /// when the global default is `think=true`.
  ///
  /// Callers that want a different sampling profile pass these
  /// parameters explicitly — but think twice before raising
  /// `numPredict` without raising `numCtx`, and don't lower
  /// `temperature` without resampling `top_p` / `top_k` to keep the
  /// recipe coherent.
  Stream<String> generate(
    String prompt, {
    String? system,
    double temperature = 1.0,
    double topP = 0.95,
    int topK = 64,
    bool think = true,
    int numCtx = 16384,
    int numPredict = 4000,
    List<String>? stop,
  }) async* {
    // Defaults are the Gemma 4 model-card recommendation
    // (temperature=1.0, top_p=0.95, top_k=64). `think=true` and
    // `num_predict=4000` are what passed end-to-end verification on
    // both gemma4:e4b and gemma4:12b for the hook-gen task on
    // 2026-06-11. The earlier non-thinking / 384-token defaults
    // produced setReturnValue(cpu, 0) for every non-trivial function
    // on the smaller model — the canonical out-pointer shape
    // (pointer.writeData + return 0) requires reasoning the
    // non-thinking path cannot do.
    //
    // `options.stop` is Ollama's per-request list of literal byte
    // sequences that halt generation when the model emits them.
    // Used by `LlmHookGenerator` to cut off the comment-preamble
    // failure mode (`# Since`, `# Based on`, `# Typically`, …) the
    // moment the model starts narrating instead of coding. Omit
    // the key when no stops are passed — Ollama interprets an
    // empty list as "no constraint" but the omission is cleaner.
    final hasStops = stop != null && stop.isNotEmpty;
    final body = <String, Object?>{
      'model': model,
      'prompt': prompt,
      'stream': true,
      'think': think,
      'system': ?system,
      'options': <String, Object?>{
        'num_ctx': numCtx,
        'num_predict': numPredict,
        'temperature': temperature,
        'top_p': topP,
        'top_k': topK,
        if (hasStops) 'stop': stop,
      },
    };
    final req = await _http.postUrl(Uri.parse('http://$host/api/generate'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      final detail = await resp.transform(utf8.decoder).join();
      throw LlmClientException(
        'Ollama /api/generate returned ${resp.statusCode}: $detail',
      );
    }
    await for (final line
        in resp.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      final obj = jsonDecode(line) as Map<String, dynamic>;
      final err = obj['error'];
      if (err is String) {
        throw LlmClientException('Ollama generate error: $err');
      }
      final chunk = obj['response'];
      if (chunk is String && chunk.isNotEmpty) yield chunk;
      if (obj['done'] == true) break;
    }
  }

  /// Embed [text] with the configured [embeddingModel]. Used both for
  /// document chunks (during RAG index build) and for query text (at
  /// retrieve-time). Returns 768-dim float32 for nomic-embed-text.
  Future<Float32List> embed(String text) async {
    final body = jsonEncode({
      'model': embeddingModel,
      'prompt': text,
    });
    final req = await _http.postUrl(Uri.parse('http://$host/api/embeddings'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(body));
    final resp = await req.close();
    final raw = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw LlmClientException(
        'Ollama /api/embeddings returned ${resp.statusCode}: $raw',
      );
    }
    final obj = jsonDecode(raw) as Map<String, dynamic>;
    final list = obj['embedding'];
    if (list is! List) {
      throw LlmClientException(
        'Ollama /api/embeddings returned no embedding field: $raw',
      );
    }
    final out = Float32List(list.length);
    for (var i = 0; i < list.length; i++) {
      out[i] = (list[i] as num).toDouble();
    }
    return out;
  }

  /// Ping Ollama's `/api/tags` endpoint to confirm the server is up. Used
  /// by the UI to show a "warming up" hint before the first generate.
  Future<bool> ping() async {
    try {
      final req = await _http.getUrl(Uri.parse('http://$host/api/tags'));
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void close() => _http.close(force: true);
}

class LlmClientException implements Exception {
  LlmClientException(this.message);
  final String message;
  @override
  String toString() => 'LlmClientException: $message';
}
