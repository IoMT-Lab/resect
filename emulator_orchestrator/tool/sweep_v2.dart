// sweep_v2 — runs the random-10 sample (same seed as the saved baseline)
// through the FIXED prompt composer + Gemma4 at the docs-recommended
// settings (think=true, num_predict=4000, T=1.0, top_p=0.95, top_k=64).
//
// Outputs per-function: classifier verdict, response code, eval_count,
// total wall time, thinking length. Streams tokens to stdout so progress
// is visible — the operation is ~20 min per LLM-fallback function.
//
//   dart run tool/sweep_v2.dart [--seed=N] [--count=10]
//
// Writes a final table to /tmp/sweep_v2_<seed>.txt and an NDJSON
// records file at /tmp/sweep_v2_<seed>.ndjson for the user to diff
// against random10_report_seed745444944.txt.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/services/hooks/hook_classifier.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:emulator_orchestrator/services/rag/rag_index.dart';
import 'package:signatures/signatures.dart';

const _kElfName = 'aya_ppg.elf';
const _kProjectDir = '/home/evan/.config/call_graph_viewer/projects';

Future<void> main(List<String> argv) async {
  var seed = 745444944;
  var count = 10;
  String? modelOverride;
  for (final a in argv) {
    if (a.startsWith('--seed=')) seed = int.parse(a.substring(7));
    if (a.startsWith('--count=')) count = int.parse(a.substring(8));
    if (a.startsWith('--model=')) modelOverride = a.substring(8);
  }

  final cfg = EnvConfig.load();
  final db = ArtifactDatabase();
  final fw = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals(_kElfName)))
      .getSingleOrNull();
  if (fw == null) {
    stderr.writeln('no $_kElfName in artifact DB');
    exit(1);
  }
  final elfHash = fw.elfHash;

  // Same selection as test_hook_quality_random: shuffle all functions
  // with both signature and non-empty decompilation by `seed`, take
  // first `count`.
  final decomps = await (db.select(db.ghidraDecompilations)
        ..where((t) => t.elfHash.equals(elfHash)))
      .get();
  final pool = <String>[];
  for (final d in decomps) {
    if (d.sourceText.trim().isEmpty) continue;
    final sigExists = (await (db.select(db.signatures)
              ..where((t) =>
                  t.elfHash.equals(elfHash) &
                  t.symbolName.equals(d.functionName)))
            .getSingleOrNull()) !=
        null;
    if (sigExists) pool.add(d.functionName);
  }
  pool.shuffle(math.Random(seed));
  final chosen = pool.take(count).toList();

  final host = (cfg.get('LLM_OLLAMA_HOST') ?? 'localhost:11434').trim();
  final model = (modelOverride?.trim().isNotEmpty ?? false)
      ? modelOverride!.trim()
      : (cfg.get('LLM_MODEL') ?? 'gemma4:12b').trim();
  final client = LlmClient(host: host, model: model);
  final ragIndex = RagIndex(
    projectDir: _kProjectDir,
    client: client,
    artifactDb: db,
  );
  final generator = LlmHookGenerator(
    index: ragIndex,
    client: client,
    artifactDb: db,
    classifier: const HookClassifier(),
  );

  stdout.writeln('=== sweep_v2 ===');
  stdout.writeln('seed=$seed  count=${chosen.length}  model=$model');
  stdout.writeln('functions:');
  for (var i = 0; i < chosen.length; i++) {
    stdout.writeln('  [${i + 1}/${chosen.length}] ${chosen[i]}');
  }
  stdout.writeln('');

  final outTxt = '/tmp/sweep_v2_$seed.txt';
  final outNdjson = '/tmp/sweep_v2_$seed.ndjson';
  final tableSink = File(outTxt).openWrite();
  final jsonSink = File(outNdjson).openWrite();
  tableSink.writeln('seed=$seed  count=${chosen.length}  model=$model');
  tableSink.writeln(
      '${'function'.padRight(40)}  ${'source'.padRight(18)}  ${'eval'.padLeft(6)}  ${'sec'.padLeft(6)}  hook (first line)');

  for (var i = 0; i < chosen.length; i++) {
    final fn = chosen[i];
    stdout.writeln('');
    stdout.writeln('===== [${i + 1}/${chosen.length}] $fn =====');

    final sigRow = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) & t.symbolName.equals(fn)))
        .getSingleOrNull();
    if (sigRow == null) {
      stdout.writeln('  SKIP: no signature');
      continue;
    }
    final signature = FunctionSignature.fromJson(
        fn, jsonDecode(sigRow.signatureJson) as Map<String, dynamic>);

    final userPrompt = 'Substitute for $fn in emulation. The goal is '
        'to let the caller continue without generating unhandled '
        'memory accesses — NOT to reproduce what the real hardware '
        'would do. Read the decompilation only to learn (a) what $fn '
        'returns and (b) whether it writes to any caller-provided '
        "pointer buffers. If it's purely hardware-touching with no "
        'outputs, the hook is just setReturnValue(cpu, 0).';

    // Compose the prompt — exercises pin + dedup automatically.
    final composedPrompt = await generator.composePrompt(
      userPrompt: userPrompt,
      targetSymbol: fn,
      elfHash: elfHash,
      signature: signature,
    );

    // Run the classifier separately so we can record which rule (if
    // any) fires. `composePrompt` doesn't run it.
    final decomp = await db.decompilationFor(
        elfHash: elfHash, functionName: fn);
    final dsRows = await db.dataSymbolsFor(elfHash);
    final dataSymbols = <String, DataSymbol>{
      for (final r in dsRows)
        r.symbolName: DataSymbol(
          name: r.symbolName,
          address: r.address,
          type: r.typeName,
          size: r.size,
        ),
    };
    final cls = decomp == null
        ? null
        : const HookClassifier().classify(
            functionName: fn,
            signature: signature,
            decompilation: decomp,
            dataSymbols: dataSymbols,
          );

    String source;
    String responseText;
    int evalCount = 0;
    double secs = 0.0;
    int thinkingLen = 0;

    if (cls != null) {
      source = 'classifier:${cls.ruleName}';
      responseText = cls.hook.code;
      stdout.writeln('  classifier matched: ${cls.ruleName}');
      stdout.writeln('  hook:');
      for (final line in responseText.split('\n')) {
        stdout.writeln('    $line');
      }
    } else {
      source = 'llm ($model docs-recommended)';
      stdout.writeln('  classifier: <no match> → LLM');
      stdout.writeln('  streaming Ollama with think=true, '
          'num_predict=4000, T=1.0, top_p=0.95, top_k=64…');

      final result = await _callOllamaStreaming(
        host: host,
        model: model,
        systemPrompt: LlmHookGenerator.systemPrompt,
        userPrompt: composedPrompt,
        onTokenThink: (chunk) => stdout.write(chunk),
        onTokenResp: (chunk) => stdout.write(chunk),
      );
      responseText = result.response.trim();
      evalCount = result.evalCount;
      secs = result.totalSeconds;
      thinkingLen = result.thinking.length;
      stdout.writeln('');
      stdout.writeln('  eval_count=$evalCount  total=${secs.toStringAsFixed(1)}s'
          '  thinking_chars=$thinkingLen');
      stdout.writeln('  --- response ---');
      for (final line in responseText.split('\n')) {
        stdout.writeln('    $line');
      }
    }

    final firstLine = responseText.split('\n').firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '<empty>',
        );
    tableSink.writeln(
      '${fn.padRight(40)}  ${source.padRight(18)}  '
      '${evalCount.toString().padLeft(6)}  '
      '${secs.toStringAsFixed(0).padLeft(6)}  $firstLine',
    );
    jsonSink.writeln(jsonEncode({
      'function': fn,
      'source': source,
      'classifier_rule': cls?.ruleName,
      'eval_count': evalCount,
      'seconds': secs,
      'thinking_chars': thinkingLen,
      'response': responseText,
    }));
  }

  await tableSink.flush();
  await tableSink.close();
  await jsonSink.flush();
  await jsonSink.close();
  stdout.writeln('');
  stdout.writeln('=== done. results: $outTxt + $outNdjson ===');

  ragIndex.close();
  client.close();
  await db.close();
}

class _OllamaResult {
  _OllamaResult(this.thinking, this.response, this.evalCount,
      this.totalSeconds);
  final String thinking;
  final String response;
  final int evalCount;
  final double totalSeconds;
}

Future<_OllamaResult> _callOllamaStreaming({
  required String host,
  required String model,
  required String systemPrompt,
  required String userPrompt,
  required void Function(String) onTokenThink,
  required void Function(String) onTokenResp,
}) async {
  final body = jsonEncode({
    'model': model,
    'system': systemPrompt,
    'prompt': userPrompt,
    'stream': true,
    'think': true,
    'options': {
      'temperature': 1.0,
      'top_p': 0.95,
      'top_k': 64,
      'num_predict': 4000,
      'num_ctx': 16384,
    },
  });
  final http = HttpClient();
  try {
    final req = await http.postUrl(Uri.parse('http://$host/api/generate'));
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(body));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      final err = await resp.transform(utf8.decoder).join();
      throw StateError('Ollama HTTP ${resp.statusCode}: $err');
    }
    final thinkBuf = StringBuffer();
    final respBuf = StringBuffer();
    var currentChannel = 'none';
    var evalCount = 0;
    var totalNanos = 0;
    await for (final line in resp
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      final obj = jsonDecode(line) as Map<String, dynamic>;
      final err = obj['error'];
      if (err is String) {
        throw StateError('Ollama generate error: $err');
      }
      final thinkChunk = obj['thinking'] as String?;
      final respChunk = obj['response'] as String?;
      if (thinkChunk != null && thinkChunk.isNotEmpty) {
        if (currentChannel != 'think') {
          stdout.writeln('');
          stdout.writeln('  ----- [THINKING] -----');
          currentChannel = 'think';
        }
        thinkBuf.write(thinkChunk);
        onTokenThink(thinkChunk);
      }
      if (respChunk != null && respChunk.isNotEmpty) {
        if (currentChannel != 'resp') {
          stdout.writeln('');
          stdout.writeln('  ----- [RESPONSE] -----');
          currentChannel = 'resp';
        }
        respBuf.write(respChunk);
        onTokenResp(respChunk);
      }
      if (obj['done'] == true) {
        evalCount = (obj['eval_count'] as int?) ?? 0;
        totalNanos = (obj['total_duration'] as int?) ?? 0;
        break;
      }
    }
    return _OllamaResult(
        thinkBuf.toString(), respBuf.toString(), evalCount, totalNanos / 1e9);
  } finally {
    http.close(force: true);
  }
}
