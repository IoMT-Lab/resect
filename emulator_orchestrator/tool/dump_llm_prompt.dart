// Compose the LLM prompt for a given function exactly the way the
// dialog does — then print it. No LLM call, no generation. Just
// shows what the model is being asked.
//
//   dart run tool/dump_llm_prompt.dart <function-name>

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/services/hooks/hook_classifier.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:emulator_orchestrator/services/rag/rag_index.dart';
import 'package:resect_signatures/resect_signatures.dart';

Future<void> main(List<String> argv) async {
  if (argv.length != 1) {
    stderr.writeln('usage: dump_llm_prompt.dart <function-name>');
    exit(2);
  }
  final fn = argv[0];

  final cfg = EnvConfig.load();
  final db = ArtifactDatabase();
  final fw = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals('aya_ppg.elf')))
      .getSingleOrNull();
  if (fw == null) { stderr.writeln('no aya_ppg.elf'); exit(1); }
  final elfHash = fw.elfHash;

  final sigRow = await (db.select(db.signatures)
        ..where((t) =>
            t.elfHash.equals(elfHash) & t.symbolName.equals(fn)))
      .getSingleOrNull();
  if (sigRow == null) {
    stderr.writeln('no signature for $fn'); exit(1);
  }
  final signature = FunctionSignature.fromJson(
      fn, jsonDecode(sigRow.signatureJson) as Map<String, dynamic>);

  final host = (cfg.get('LLM_OLLAMA_HOST') ?? '').trim();
  final model = (cfg.get('LLM_MODEL') ?? '').trim();
  final client = LlmClient(
    host: host.isEmpty ? 'localhost:11434' : host,
    model: model.isEmpty ? 'gemma4:12b' : model,
  );
  final ragIndex = RagIndex(
    projectDir: '/home/evan/.config/call_graph_viewer/projects',
    client: client,
    artifactDb: db,
  );
  final generator = LlmHookGenerator(
    index: ragIndex,
    client: client,
    artifactDb: db,
    classifier: const HookClassifier(),
  );

  // Match what the dialog's _defaultStubPrompt produces.
  final userPrompt = 'Substitute for $fn in emulation. The goal is '
      'to let the caller continue without generating unhandled '
      'memory accesses — NOT to reproduce what the real hardware '
      'would do. Read the decompilation only to learn (a) what $fn '
      'returns and (b) whether it writes to any caller-provided '
      "pointer buffers. If it's purely hardware-touching with no "
      'outputs, the hook is just setReturnValue(cpu, 0).';

  final prompt = await generator.composePrompt(
    userPrompt: userPrompt,
    targetSymbol: fn,
    elfHash: elfHash,
    signature: signature,
  );

  stdout.writeln('================ SYSTEM PROMPT ================');
  stdout.writeln(LlmHookGenerator.systemPrompt);
  stdout.writeln('================ USER PROMPT ================');
  stdout.writeln(prompt);
  stdout.writeln('================ END ================');
  stdout.writeln('');
  stdout.writeln('classifier verdict: ${generator.lastClassification?.ruleName ?? "<no match>"}');

  ragIndex.close();
  client.close();
  await db.close();
}
