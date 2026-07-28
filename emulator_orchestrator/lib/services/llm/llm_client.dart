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
  /// Response-only convenience wrapper around [generateEvents].
  ///
  /// Yields only `LlmResponseChunk.text` strings so existing
  /// callers (and JSON-buffering consumers like
  /// [RecommendationService]) don't see thinking tokens mixed
  /// into the response stream. Callers that want the
  /// reasoning trace (the auto-tune modal, the Last Run card,
  /// the Hook Database dialog) should call [generateEvents]
  /// directly and pattern-match on [LlmStreamEvent] subtypes.
  Stream<String> generate(
    String prompt, {
    String? system,
    String? modelOverride,
    double temperature = 1.0,
    double topP = 0.95,
    int topK = 64,
    bool think = true,
    int numCtx = 16384,
    int numPredict = 4000,
    List<String>? stop,
    Map<String, Object?>? format,
  }) async* {
    await for (final ev in generateEvents(
      prompt,
      system: system,
      modelOverride: modelOverride,
      temperature: temperature,
      topP: topP,
      topK: topK,
      think: think,
      numCtx: numCtx,
      numPredict: numPredict,
      stop: stop,
      format: format,
    )) {
      if (ev is LlmResponseChunk) yield ev.text;
    }
  }

  /// Discriminated stream yielding both thinking and response
  /// channels. Per-NDJSON-line order matches Ollama's wire order:
  /// thinking events arrive first while the model reasons, then
  /// response events as the final answer streams out.
  ///
  /// All other arguments match [generate]. Use this when the
  /// caller wants to drive a UI surface for the reasoning trace
  /// — the auto-tune modal's `_LlmStreamingBody` and the Last
  /// Run card's `_streamingBody` are the in-tree examples.
  Stream<LlmStreamEvent> generateEvents(
    String prompt, {
    String? system,
    String? modelOverride,
    double temperature = 1.0,
    double topP = 0.95,
    int topK = 64,
    bool think = true,
    int numCtx = 16384,
    int numPredict = 4000,
    List<String>? stop,
    Map<String, Object?>? format,
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
    // `format` is Ollama's constrained-decoding hook — a JSON schema
    // object that forces the response channel to conform. Only ever
    // passed with `think: false`: format+think interaction is
    // undocumented upstream, so callers that want structured output
    // disable thinking (see LlmProfiles). Omitted from the body when
    // null so unstructured calls are unchanged.
    final body = <String, Object?>{
      'model': modelOverride ?? model,
      'prompt': prompt,
      'stream': true,
      'think': think,
      'system': ?system,
      'format': ?format,
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
    yield* parseGenerateNdjson(
        resp.transform(utf8.decoder).transform(const LineSplitter()));
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

  /// Models installed on the Ollama server, smallest first (by
  /// on-disk byte size — a reliable proxy for params × quantization).
  /// Excludes the configured [embeddingModel] and anything whose name
  /// contains `embed` since those can't run `/api/generate`.
  ///
  /// Returns an empty list when `/api/tags` fails or returns
  /// nothing — callers should fall back to the constructor-configured
  /// [model] in that case.
  Future<List<({String name, int sizeBytes})>> listModels() async {
    try {
      final req = await _http.getUrl(Uri.parse('http://$host/api/tags'));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return const [];
      }
      final raw = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final list = (json['models'] as List?) ?? const [];
      final out = <({String name, int sizeBytes})>[];
      for (final entry in list) {
        if (entry is! Map<String, dynamic>) continue;
        final name = entry['name'] as String?;
        final size = entry['size'];
        if (name == null || size is! num) continue;
        if (name == embeddingModel) continue;
        if (name.toLowerCase().contains('embed')) continue;
        out.add((name: name, sizeBytes: size.toInt()));
      }
      out.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
      return out;
    } catch (_) {
      return const [];
    }
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

/// One chunk produced by [LlmClient.generateEvents] — either a
/// reasoning ("thinking") token or a final-response token.
///
/// Discriminated as a sealed hierarchy so callers can
/// pattern-match exhaustively: the auto-tune modal and the
/// Last Run card route thinking chunks to a dedicated UI pane
/// while routing response chunks to the buffer that JSON-parses
/// or commits the final advisory.
sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

/// A chunk of the model's reasoning trace, streamed before the
/// final answer. Surfaced live in the UI when the model has
/// `think=true` (the LlmClient default). Empty/whitespace-only
/// thinking chunks are filtered upstream — every event here
/// carries non-empty text.
class LlmThinkingChunk extends LlmStreamEvent {
  const LlmThinkingChunk(this.text);
  final String text;
}

/// A chunk of the model's final answer. Concatenating every
/// `LlmResponseChunk.text` in order reproduces the same string
/// that the legacy [LlmClient.generate] response-only stream
/// yields.
class LlmResponseChunk extends LlmStreamEvent {
  const LlmResponseChunk(this.text);
  final String text;
}

/// Terminal event yielded exactly once at the end of a successful
/// [LlmClient.generateEvents] stream. Carries the diagnostic
/// fields from Ollama's final NDJSON line — `done_reason`,
/// `eval_count` (response tokens emitted) — plus a local count
/// of how many [LlmThinkingChunk]s preceded it.
///
/// The recommendation-service flow uses this to distinguish
/// "model finished naturally with empty response" (a real
/// content failure) from "model hit `num_predict` budget mid-think"
/// (a configuration issue) — the two have identical raw output
/// but very different remediation.
///
/// `doneReason` is the verbatim Ollama string: `"stop"` for
/// natural completion, `"length"` when `num_predict` clamped
/// the stream, `"load"` when the model is still warming up.
class LlmStreamDone extends LlmStreamEvent {
  const LlmStreamDone({
    required this.doneReason,
    required this.responseTokens,
    required this.thinkingChunks,
  });

  final String doneReason;
  final int responseTokens;
  final int thinkingChunks;
}

/// Parse Ollama's `/api/generate` NDJSON line stream into
/// discriminated [LlmStreamEvent]s. One NDJSON line in →
/// zero, one, or two thinking/response events out (a single line
/// can carry both `thinking` and `response` text), followed by
/// a single terminal [LlmStreamDone] event when Ollama signals
/// `done: true`.
///
/// Pure function on top of an in-memory string stream — the
/// network is the caller's problem. Exposed as a top-level
/// function so the parsing contract can be unit-tested
/// without spinning up Ollama or mocking HttpClient.
Stream<LlmStreamEvent> parseGenerateNdjson(Stream<String> lines) async* {
  var thinkingChunks = 0;
  await for (final line in lines) {
    if (line.isEmpty) continue;
    final obj = jsonDecode(line) as Map<String, dynamic>;
    final err = obj['error'];
    if (err is String) {
      throw LlmClientException('Ollama generate error: $err');
    }
    // Thinking and response are separate fields on Ollama's
    // NDJSON line. A single line can carry either or both.
    // Emit them in field order — thinking first when present
    // since that matches how the model produces them
    // chronologically.
    final thinking = obj['thinking'];
    if (thinking is String && thinking.isNotEmpty) {
      thinkingChunks++;
      yield LlmThinkingChunk(thinking);
    }
    final chunk = obj['response'];
    if (chunk is String && chunk.isNotEmpty) {
      yield LlmResponseChunk(chunk);
    }
    if (obj['done'] == true) {
      final doneReason = obj['done_reason'];
      final evalCount = obj['eval_count'];
      yield LlmStreamDone(
        doneReason: doneReason is String ? doneReason : 'unknown',
        responseTokens: evalCount is num ? evalCount.toInt() : 0,
        thinkingChunks: thinkingChunks,
      );
      break;
    }
  }
}
