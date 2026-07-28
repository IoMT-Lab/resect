// End-to-end integration test for the Ghidra → artifact-DB → RAG →
// LLM-prompt pipeline. Walks the SAME services the LLM dialog walks
// (SignaturesService, RagIndex, LlmHookGenerator, LlmClient) against
// the SAME databases the running app uses
// (~/.config/call_graph_viewer/...). No sandbox, no fixture, no
// mocks — if a wiring point breaks for the user, this test breaks
// the same way.
//
// Why this test exists: a prior version of the work in this area
// claimed "verified end-to-end" based on tool/test_ghidra_extract.dart,
// which only exercises the Ghidra subprocess in a temp dir. That
// test stayed green while the user's session produced useless stub
// output, because `_primeSignatureCache`'s gate (`hasSignaturesFor`)
// short-circuited extraction on a pre-v8 stale cache and the four
// new Ghidra tables never got populated. This test reproduces the
// user's exact failure path and asserts the recovery.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_rag_end_to_end.dart [<project.emu>]
//
// Default project: ~/.config/call_graph_viewer/projects/Aya.emu
//
// Side effects on success:
//   - Re-extracts Ghidra data into all six tables (idempotent —
//     transaction overwrite).
//   - Rebuilds the project's RAG index, embedding decompilation /
//     data_type / data_symbol / memory_section chunks.
//   - Runs one Ollama generation pass (~5 min on CPU).
//
// Exits 0 on every assertion passing. Exits non-zero with a clear
// failure message naming the step otherwise. NO silent skip paths.

import 'dart:convert';
import 'dart:io';

// Full drift import (no `show`) so Expression<bool>'s `&` operator
// is in scope at the where-clause call sites in step 9.
import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/services/external/ghidra_installer.dart';
import 'package:emulator_orchestrator/services/quality/hook_scorer.dart';
import 'package:emulator_orchestrator/services/quality/hook_static_analyzer.dart';
import 'package:emulator_orchestrator/services/quality/hook_test_harness.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:emulator_orchestrator/services/rag/rag_index.dart';
import 'package:emulator_orchestrator/services/external/signatures_service.dart';
import 'package:path/path.dart' as p;

const String _targetSymbol = 'LL_APB0_GRP1_EnableClock';

// Comment-line openers the stop-word list (LlmHookGenerator._kStopSequences)
// is supposed to halt at. Listed here too so the test can assert
// the rendered Ollama output doesn't contain them — if it does,
// the stop-words failed (or the prompt rewrite didn't take).
const List<String> _bannedOpeners = [
  '# Since',
  '# Based on',
  '# Typically',
  '# Standard',
  '# In STM',
  '# In ST',
  '# The function',
  '# This function',
  '# Note that',
  'Rule 1',
  'Rule 2',
  'Rule 3',
];

Future<void> main(List<String> args) async {
  final projectPath = args.isNotEmpty
      ? args.first
      : p.join(
          Platform.environment['HOME']!,
          '.config/call_graph_viewer/projects/Aya.emu',
        );
  stdout.writeln('=== test_rag_end_to_end ===');
  stdout.writeln('project: $projectPath');

  // ---- preconditions ----

  final cfg = EnvConfig.load();
  final ghidraOn = (cfg.get('MODULE_GHIDRA') ?? '') == '1';
  if (!ghidraOn) {
    _fail(
      'precondition',
      'MODULE_GHIDRA != "1" in ${cfg.path}. '
          'Toggle it on in System Configuration → Modules first.',
    );
  }
  final ghidraDir = (cfg.get('GHIDRA_DIR') ?? '').trim();
  if (ghidraDir.isEmpty || !File(p.join(ghidraDir, 'support', 'analyzeHeadless')).existsSync()) {
    _fail(
      'precondition',
      'GHIDRA_DIR not set or analyzeHeadless missing: $ghidraDir. '
          'Run the Ghidra installer first.',
    );
  }
  if (!File(projectPath).existsSync()) {
    _fail('precondition', '.emu project not found: $projectPath');
  }

  // ---- load the emulator the same way the app does ----

  final emulator = await EmulatorRepository().loadEmulator(projectPath);
  final elfPath = emulator.elfFilePath;
  if (elfPath == null) {
    _fail('precondition', 'Emulator has no elfFilePath: $projectPath');
  }
  if (!File(elfPath).existsSync()) {
    _fail('precondition', 'ELF file missing: $elfPath');
  }
  stdout.writeln('elf:     $elfPath');

  // ---- open the SAME artifact DB the app uses ----

  final db = ArtifactDatabase();
  // Look up firmware row by file basename — same way the artifact
  // processing path matches.
  final firmwareRows = await db.select(db.firmwareImages).get();
  final firmware = firmwareRows.firstWhere(
    (f) => f.fileName == p.basename(elfPath),
    orElse: () => _fail<FirmwareImage>(
      'precondition',
      'No firmware row in artifacts DB matches ${p.basename(elfPath)}. '
          'Open the project in the app once to register it.',
    ),
  );
  final elfHash = firmware.elfHash;
  stdout.writeln('elfHash: ${elfHash.substring(0, 12)}…');

  // ---- step 1: print current state ----

  stdout.writeln('');
  stdout.writeln('=== step 1: current state (pre-test) ===');
  await _printGhidraTableCounts(db, elfHash);

  // ---- step 2: verify the gate decides the right way for this state ----

  stdout.writeln('');
  stdout.writeln('=== step 2: gate behaviour on current state ===');
  final sigService = SignaturesService(db: db, ghidraInstaller: GhidraInstaller());
  final hasSig = await sigService.hasSignaturesFor(elfHash);
  final hasFull =
      await sigService.hasCompleteGhidraExtractionFor(elfHash);
  final decompCount = await _rowCount(
      db, 'ghidra_decompilations', "elf_hash = '$elfHash'");
  stdout.writeln('hasSignaturesFor:                $hasSig');
  stdout.writeln('hasCompleteGhidraExtractionFor:  $hasFull');
  stdout.writeln('ghidra_decompilations rows:      $decompCount');
  // The gate must agree with the table state. If it lies in
  // either direction, that's the bug.
  if (hasFull != (decompCount > 0)) {
    _fail(
      'step 2',
      'hasCompleteGhidraExtractionFor returned $hasFull but '
          'ghidra_decompilations has $decompCount rows for this elf. '
          'The gate is broken — fix it before anything else matters.',
    );
  }

  // ---- step 3: run extractFor (the actual service the dialog uses) ----

  stdout.writeln('');
  stdout.writeln('=== step 3: SignaturesService.extractFor ===');
  if (hasFull) {
    stdout.writeln('skipped — cache complete. Re-running anyway to '
        'exercise the warm path…');
  }
  // Always run extractFor to test BOTH the cold path (stale cache
  // → re-extract → populate new tables) AND the warm path
  // (already populated → re-runs cleanly, idempotent overwrite
  // inside the transaction).
  final extractStart = DateTime.now();
  var lastPhase = '';
  await for (final ev in sigService.extractFor(elfPath)) {
    if (ev.message != lastPhase) {
      stdout.writeln('  [phase] ${ev.message}');
      lastPhase = ev.message;
    }
  }
  stdout.writeln('extractFor elapsed: '
      '${DateTime.now().difference(extractStart).inSeconds}s');

  // ---- step 4: assert all six Ghidra tables now have rows ----

  stdout.writeln('');
  stdout.writeln('=== step 4: post-extract table state ===');
  await _printGhidraTableCounts(db, elfHash);

  final sigCount =
      await _rowCount(db, 'signatures', "elf_hash = '$elfHash'");
  final cgCount =
      await _rowCount(db, 'ghidra_call_graphs', "elf_hash = '$elfHash'");
  final dCount = await _rowCount(
      db, 'ghidra_decompilations', "elf_hash = '$elfHash'");
  final dtCount = await _rowCount(
      db, 'ghidra_data_types', "elf_hash = '$elfHash'");
  final dsCount = await _rowCount(
      db, 'ghidra_data_symbols', "elf_hash = '$elfHash'");
  final mmCount = await _rowCount(
      db, 'ghidra_memory_map', "elf_hash = '$elfHash'");

  if (sigCount == 0) _fail('step 4', 'signatures has 0 rows post-extract.');
  if (cgCount == 0) _fail('step 4', 'ghidra_call_graphs has 0 rows post-extract.');
  if (dCount == 0) {
    _fail('step 4',
        'ghidra_decompilations has 0 rows post-extract. THIS IS THE USER\'S FAILURE.');
  }
  if (dtCount == 0) _fail('step 4', 'ghidra_data_types has 0 rows post-extract.');
  if (dsCount == 0) _fail('step 4', 'ghidra_data_symbols has 0 rows post-extract.');
  if (mmCount == 0) _fail('step 4', 'ghidra_memory_map has 0 rows post-extract.');

  // The single assertion that catches the user's failure mode:
  // is the target function's decompilation actually queryable?
  final targetSource = await db.decompilationFor(
    elfHash: elfHash,
    functionName: _targetSymbol,
  );
  if (targetSource == null || targetSource.isEmpty) {
    _fail(
      'step 4',
      'decompilationFor($_targetSymbol) returned null/empty after '
          'extraction. The pin path the LLM generator uses can\'t '
          'fire, and the user gets a stub.',
    );
  }
  stdout.writeln('');
  stdout.writeln('decompilationFor($_targetSymbol): '
      '${targetSource.length} chars, first line: '
      '${targetSource.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '<empty>').trim()}');

  // ---- step 5: verify the gate now returns true ----

  stdout.writeln('');
  stdout.writeln('=== step 5: gate behaviour after extract ===');
  final hasFullAfter =
      await sigService.hasCompleteGhidraExtractionFor(elfHash);
  stdout.writeln('hasCompleteGhidraExtractionFor:  $hasFullAfter');
  if (!hasFullAfter) {
    _fail(
      'step 5',
      'Gate returns false after a successful extraction. This means '
          'subsequent _primeSignatureCache calls would re-extract '
          'forever (no caching).',
    );
  }

  // ---- step 6: RagIndex.rebuildFor (the actual one the button calls) ----

  stdout.writeln('');
  stdout.writeln('=== step 6: RagIndex.rebuildFor ===');
  final projectDir = p.dirname(projectPath);
  final llmClient = _buildLlmClient(cfg);
  final ragIndex = RagIndex(
    projectDir: projectDir,
    client: llmClient,
    artifactDb: db,
  );
  try {
    final rebuildStart = DateTime.now();
    var lastRagPhase = '';
    await for (final ev in ragIndex.rebuildFor(emulator, elfHash: elfHash)) {
      if (ev.phase != lastRagPhase) {
        stdout.writeln('  [phase] ${ev.phase}  (${ev.done}/${ev.total})');
        lastRagPhase = ev.phase;
      }
    }
    stdout.writeln('rebuildFor elapsed: '
        '${DateTime.now().difference(rebuildStart).inSeconds}s');

    // ---- step 7: assert RAG has chunks of every kind ----

    stdout.writeln('');
    stdout.writeln('=== step 7: RAG chunk counts by kind ===');
    final ragDbPath = p.join(projectDir, 'rag_index.db');
    final byKind = _ragChunkCountsByKind(ragDbPath);
    for (final entry in byKind.entries) {
      stdout.writeln('  ${entry.key.padRight(20)} ${entry.value}');
    }
    void requireKind(String kind, int min) {
      final n = byKind[kind] ?? 0;
      if (n < min) {
        _fail(
          'step 7',
          'RAG chunk count for source_kind="$kind" is $n (expected >= $min). '
              'The rebuild did NOT pull this kind from the artifact DB.',
        );
      }
    }
    requireKind('decompilation', 200);
    requireKind('data_type', 1);
    requireKind('data_symbol', 1);
    requireKind('memory_section', 1);

    // ---- step 8: compose the prompt (no Ollama call) ----

    stdout.writeln('');
    stdout.writeln('=== step 8: prompt composition ===');
    final generator = LlmHookGenerator(
      index: ragIndex,
      client: llmClient,
      artifactDb: db,
    );

    // composePrompt() does exactly what generate() does up to (but
    // not including) the Ollama call. Same retrieval, same pin,
    // same ordering. Returns the prompt string deterministically
    // so the test can assert on its content without burning ~5 min
    // of generation time.
    //
    // Substitute-style user prompt — same shape the dialog's
    // `_defaultStubPrompt` produces. The model is supposed to
    // produce a no-op return for hardware-touching functions like
    // LL_APB0_GRP1_EnableClock.
    const userPrompt =
        'Substitute for $_targetSymbol in emulation. The goal is to '
        'let the caller continue without generating unhandled memory '
        'accesses — NOT to reproduce what the real hardware would do. '
        'Read the decompilation only to learn (a) what $_targetSymbol '
        'returns and (b) whether it writes to any caller-provided '
        "pointer buffers. If it's purely hardware-touching with no "
        'outputs, the hook is just setReturnValue(cpu, 0).';
    final composed = await generator.composePrompt(
      userPrompt: userPrompt,
      targetSymbol: _targetSymbol,
      elfHash: elfHash,
    );
    stdout.writeln('composed prompt: ${composed.length} chars');

    const pinHeader =
        '### Decompiled source (Ghidra) — $_targetSymbol';
    if (!composed.contains(pinHeader)) {
      _fail(
        'step 8',
        'Composed prompt does not contain pinned-decompilation header '
            '"$pinHeader". The pin lookup or prompt-composition is broken.',
      );
    }
    // Pin must come before any OTHER `### ` chunk header inside
    // `## Project context`. Find the project-context block and
    // ensure the pin is the first chunk there.
    final ctxIdx = composed.indexOf('## Project context');
    if (ctxIdx < 0) {
      _fail('step 8',
          'Composed prompt has no "## Project context" section.');
    }
    final ctxBlock = composed.substring(ctxIdx);
    final firstHeader =
        RegExp(r'^### ', multiLine: true).firstMatch(ctxBlock);
    if (firstHeader == null) {
      _fail('step 8',
          '"## Project context" block has no "### " chunk headers.');
    }
    final firstHeaderEnd =
        ctxBlock.indexOf('\n', firstHeader.start);
    final firstHeaderText =
        ctxBlock.substring(firstHeader.start, firstHeaderEnd);
    if (firstHeaderText != pinHeader) {
      _fail(
        'step 8',
        'First chunk header in "## Project context" is '
            '"$firstHeaderText", not "$pinHeader". Pin not at top.',
      );
    }
    stdout.writeln('pinned chunk header: $firstHeaderText (FIRST in context block)');

    // ---- step 9: actual generation. With Stage-1 classifier
    // wiring, LL_APB0_GRP1_EnableClock should match Rule 6 and
    // skip the LLM entirely — the catalog's `returnHook(0)` is
    // materialised directly. Generation should complete in
    // milliseconds, not the 60s+ the LLM path takes.

    stdout.writeln('');
    stdout.writeln('=== step 9: generation (classifier should fire; LLM bypassed) ===');
    // Pull the target's signature — required for the classifier
    // to evaluate Rule 6's `return type == void` precondition.
    final sigRow = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) &
              t.symbolName.equals(_targetSymbol)))
        .getSingleOrNull();
    if (sigRow == null) {
      _fail('step 9',
          'No signature row for $_targetSymbol — extraction failed?');
    }
    final signature = FunctionSignature.fromJson(
      _targetSymbol,
      jsonDecode(sigRow.signatureJson) as Map<String, dynamic>,
    );
    final genStart = DateTime.now();
    final buf = StringBuffer();
    await for (final tok in generator.generate(
      userPrompt: userPrompt,
      targetSymbol: _targetSymbol,
      elfHash: elfHash,
      signature: signature,
    )) {
      buf.write(tok);
      stdout.write(tok);
    }
    final genElapsed = DateTime.now().difference(genStart);

    // Assert the classifier fired. With Stage 1's Rule 6
    // (peripheral writes, void return), this should match for
    // LL_APB0_GRP1_EnableClock with zero LLM cost.
    final classification = generator.lastClassification;
    if (classification == null) {
      _fail('step 9',
          'Classifier did NOT fire for $_targetSymbol. Generation '
              'fell through to the LLM (${genElapsed.inSeconds}s).');
    }
    stdout.writeln('');
    stdout.writeln('classifier verdict: ${classification.ruleName} → '
        '${classification.templateName} ${classification.params}');
    stdout.writeln('invariant: ${classification.invariant.describe()}');
    if (genElapsed.inSeconds > 5) {
      _fail('step 9',
          'Classifier fired but generation took ${genElapsed.inSeconds}s; '
              'expected sub-second materialisation of the catalog hook.');
    }
    stdout.writeln('');
    stdout.writeln('generate elapsed: '
        '${DateTime.now().difference(genStart).inSeconds}s');

    final output = buf.toString();
    final lineCount = output.split('\n').where((l) => l.trim().isNotEmpty).length;
    stdout.writeln('output lines (non-blank): $lineCount');

    // Substitute-pattern output for a hardware-touching function
    // like LL_APB0_GRP1_EnableClock should be ~2–5 lines (the
    // canonical `import set_return_value` / `setReturnValue(cpu, 0)`).
    // 15 is a generous ceiling — anything above suggests the model
    // is still replicating instead of substituting.
    if (lineCount > 15) {
      _fail(
        'step 9',
        'Output is $lineCount non-blank lines (expected <= 15 for a '
            'substitute-pattern hook). Likely replication. First 10 lines:\n  '
            '${output.split('\n').take(10).join('\n  ')}',
      );
    }
    for (final banned in _bannedOpeners) {
      if (output.contains(banned)) {
        _fail(
          'step 9',
          'Output contains banned opener "$banned". '
              'Stop-words list failed to halt the model, OR the system '
              'prompt rewrite didn\'t take. Add "$banned" '
              '(prefixed with \\n where appropriate) to '
              'LlmHookGenerator._kStopSequences.',
        );
      }
    }

    // ---- step 10: run the generated hook through HookTestHarness ----
    //
    // The dialog now auto-runs this on every generation. The test
    // walks the SAME path: spawn Renode (bundled minimal-.repl rig),
    // install the hook at the bundled `main`, run, capture
    // unhandled-access events + Renode log.
    //
    // For a substitute-style hook (no peripheral I/O), this MUST
    // pass cleanly. Any hardware access from the hook hits the
    // bundled rig's unmapped memory → unhandled-access subscriber
    // fires → errorMessage non-null → fail. That's the contract.

    stdout.writeln('');
    stdout.writeln('=== step 10: HookTestHarness on generated hook ===');
    final harness = HookTestHarness();
    final harnessStart = DateTime.now();
    final harnessResult = await harness.runHook(hookCode: output);
    stdout.writeln('harness elapsed: '
        '${DateTime.now().difference(harnessStart).inSeconds}s');
    stdout.writeln('ranToCompletion: ${harnessResult.ranToCompletion}');
    stdout.writeln('errorMessage:    ${harnessResult.errorMessage ?? "<none>"}');
    stdout.writeln('return values:   ${harnessResult.returnValues}');
    if (!harnessResult.ranToCompletion) {
      _fail(
        'step 10',
        'HookTestHarness did NOT reach halt_loop. errorMessage: '
            '${harnessResult.errorMessage}\n'
            'Renode log tail:\n${harnessResult.renodeLogTail}',
      );
    }
    if (harnessResult.errorMessage != null) {
      _fail(
        'step 10',
        'Bootstrap completed but harness flagged: '
            '${harnessResult.errorMessage}\n'
            'This means the generated hook touched hardware (unhandled '
            'access). Substitute-style hooks should not — fix the '
            'system prompt or regenerate.\n'
            'Renode log tail:\n${harnessResult.renodeLogTail}',
      );
    }

    // ---- step 11: scorer + static-analyzer integration ----
    //
    // The dialog's path is: harness → static-analyzer → scorer →
    // 4 gate sub-checks (harness, invariant, mod-set,
    // unmapped-access). For a classifier-materialised `returnHook(0)`
    // hook against LL_APB0_GRP1_EnableClock all four MUST pass.

    stdout.writeln('');
    stdout.writeln('=== step 11: scorer + static-analyzer ===');
    final replPath = emulator.baseImagePath;
    if (replPath == null) {
      _fail('step 11', 'Emulator has no baseImagePath (.repl missing).');
    }
    final replContent = await File(replPath).readAsString();
    final paramNames =
        signature.parameters.map((p) => p.name).toList();
    final staticResult = await const HookStaticAnalyzer().evaluate(
      candidateCode: output,
      originalDecompilation: composed.contains(pinHeader)
          ? targetSource
          : '', // pinned chunk text is the decompilation
      parameterNames: paramNames,
      replContent: replContent,
    );
    stdout.writeln('static: modSetContained=${staticResult.modSetContained}, '
        'unmappedAccessOk=${staticResult.unmappedAccessOk}, '
        'candidateWrites=${staticResult.candidateWrites}, '
        'candidateReads=${staticResult.candidateReads}');

    final report = const HookScorer().score(
      harness: harnessResult,
      classification: classification,
      staticResult: staticResult,
    );
    stdout.writeln('gate sub-checks:');
    for (final c in report.gateChecks) {
      stdout.writeln('  - ${c.name.padRight(20)} ${c.passed ? "PASS" : "FAIL"}'
          '${c.violation == null ? "" : "  (${c.violation})"}');
    }
    stdout.writeln('score: ${report.score}');
    if (!report.gatePassed) {
      _fail(
        'step 11',
        'Scorer gate failed for the classifier-materialised hook. '
            'First violation: ${report.firstViolation}',
      );
    }
  } finally {
    ragIndex.close();
    llmClient.close();
  }
  await db.close();

  stdout.writeln('');
  stdout.writeln('=== ALL ASSERTIONS PASSED ===');
}

LlmClient _buildLlmClient(EnvConfig cfg) {
  final host = (cfg.get('LLM_OLLAMA_HOST') ?? '').trim();
  final model = (cfg.get('LLM_MODEL') ?? '').trim();
  return LlmClient(
    host: host.isEmpty ? 'localhost:11434' : host,
    model: model.isEmpty ? 'gemma4:12b' : model,
  );
}

Future<void> _printGhidraTableCounts(
    ArtifactDatabase db, String elfHash) async {
  for (final t in const [
    'signatures',
    'ghidra_call_graphs',
    'ghidra_decompilations',
    'ghidra_data_types',
    'ghidra_data_symbols',
    'ghidra_memory_map',
  ]) {
    final n = await _rowCount(db, t, "elf_hash = '$elfHash'");
    stdout.writeln('  ${t.padRight(24)} $n');
  }
}

Future<int> _rowCount(ArtifactDatabase db, String table, String where) async {
  // Use Drift's raw SQL — saves a bunch of switch/case for one
  // simple count per table.
  final row = await db
      .customSelect('SELECT COUNT(*) AS n FROM $table WHERE $where')
      .getSingle();
  return row.data['n'] as int;
}

Map<String, int> _ragChunkCountsByKind(String dbPath) {
  // Spawn `python3 -c '...'` to avoid pulling in another Dart
  // SQLite dependency in this test-only tool — `python3 -c` is
  // present on every dev machine the rest of the test relies on.
  if (!File(dbPath).existsSync()) {
    _fail('step 7', 'RAG DB does not exist at $dbPath. rebuildFor never wrote one.');
  }
  final r = Process.runSync('python3', [
    '-c',
    'import sqlite3,json; '
        'c=sqlite3.connect(${jsonEncode(dbPath)}); '
        'print(json.dumps({k:v for k,v in c.execute("SELECT source_kind, COUNT(*) FROM chunks GROUP BY source_kind")}))'
  ]);
  if (r.exitCode != 0) {
    _fail('step 7', 'python3 sqlite probe failed: ${r.stderr}');
  }
  final raw = (r.stdout as String).trim();
  if (raw.isEmpty || raw == '{}') return {};
  final m = jsonDecode(raw) as Map<String, dynamic>;
  return {for (final e in m.entries) e.key: e.value as int};
}

Never _fail<T>(String step, String message) {
  stderr.writeln('');
  stderr.writeln('!!! FAIL at $step:');
  stderr.writeln('!!! $message');
  exit(1);
}
