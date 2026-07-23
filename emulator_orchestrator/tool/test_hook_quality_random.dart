// Random-sample report of the hook scoring pipeline.
//
// Picks N (default 10) functions at random from the user's aya
// ghidra_decompilations table and runs each one through the full
// pipeline: classifier → materialise catalog hook OR LLM-generate
// → harness → static analyzer → scorer. Prints a per-function
// block + a summary table at the end.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_hook_quality_random.dart
//
// Flags:
//   --count=N         number of functions to sample (default 10)
//   --seed=N          PRNG seed (default: random; printed in the
//                     report so you can reproduce)
//   --with-judge      enable LLM-as-judge for LLM-path hooks
//                     (slow: ~60 s per fall-through function)
//   --with-progress   enable emulator-progress runner
//                     (slow + noisy on stm32wb05_empty.repl:
//                     ~30 s per function regardless of path)
//   --elf=NAME        firmware filename in artifacts DB to sample
//                     from (default: aya_ppg.elf)
//
// Default behavior runs gate-only: harness + invariant + mod-set +
// unmapped-access. ~5-15s per function depending on whether the
// LLM falls through.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/services/hook_classifier.dart';
import 'package:emulator_orchestrator/data/services/hook_progress_runner.dart';
import 'package:emulator_orchestrator/data/services/hook_scorer.dart';
import 'package:emulator_orchestrator/data/services/hook_static_analyzer.dart';
import 'package:emulator_orchestrator/data/services/hook_test_harness.dart';
import 'package:emulator_orchestrator/data/services/llm_client.dart';
import 'package:emulator_orchestrator/data/services/llm_hook_generator.dart';
import 'package:emulator_orchestrator/data/services/llm_judge.dart';
import 'package:emulator_orchestrator/data/services/rag_index.dart';
import 'package:path/path.dart' as p;
import 'package:resect_hooks/resect_hooks.dart' show includeSystemModules;
import 'package:signatures/signatures.dart';

class _Args {
  final int count;
  final int seed;
  final bool withJudge;
  final bool withProgress;
  final String elfName;
  final String? modelOverride;
  const _Args(this.count, this.seed, this.withJudge, this.withProgress,
      this.elfName, this.modelOverride);
}

_Args _parseArgs(List<String> argv) {
  var count = 10;
  var seed = DateTime.fromMillisecondsSinceEpoch(0)
      .millisecondsSinceEpoch; // placeholder; replaced if --seed not given
  var withJudge = false;
  var withProgress = false;
  var elfName = 'aya_ppg.elf';
  String? modelOverride;
  var sawSeedFlag = false;
  for (final raw in argv) {
    if (raw == '--with-judge') {
      withJudge = true;
    } else if (raw == '--with-progress') {
      withProgress = true;
    } else if (raw.startsWith('--count=')) {
      count = int.parse(raw.substring('--count='.length));
    } else if (raw.startsWith('--seed=')) {
      seed = int.parse(raw.substring('--seed='.length));
      sawSeedFlag = true;
    } else if (raw.startsWith('--elf=')) {
      elfName = raw.substring('--elf='.length);
    } else if (raw.startsWith('--model=')) {
      modelOverride = raw.substring('--model='.length);
    } else {
      stderr.writeln('Unknown arg: $raw');
      exit(2);
    }
  }
  if (!sawSeedFlag) {
    // Pick a deterministic-but-fresh seed from a 32-bit time slice
    // so it logs nicely.
    seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  }
  return _Args(count, seed, withJudge, withProgress, elfName, modelOverride);
}

class _PerFunctionResult {
  final String functionName;
  final String? ruleName;
  final String? templateName;
  final String hookCode;
  final HookQualityReport? report;
  final String pathTaken; // 'classifier' | 'llm' | 'error'
  final String? error;
  final Duration totalElapsed;
  const _PerFunctionResult({
    required this.functionName,
    required this.ruleName,
    required this.templateName,
    required this.hookCode,
    required this.report,
    required this.pathTaken,
    required this.error,
    required this.totalElapsed,
  });
}

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);
  stdout.writeln('=== test_hook_quality_random ===');
  stdout.writeln('count:         ${args.count}');
  stdout.writeln('seed:          ${args.seed}');
  stdout.writeln('with-judge:    ${args.withJudge}');
  stdout.writeln('with-progress: ${args.withProgress}');
  stdout.writeln('elf:           ${args.elfName}');
  stdout.writeln('');

  final cfg = EnvConfig.load();
  final db = ArtifactDatabase();

  // Resolve firmware row.
  final firmware = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals(args.elfName)))
      .getSingleOrNull();
  if (firmware == null) {
    stderr.writeln('No firmware row for ${args.elfName}.');
    exit(1);
  }
  final elfHash = firmware.elfHash;

  // Pull the candidate pool: every decompiled function for this ELF
  // that has BOTH a non-empty decompilation AND a signature row.
  final decompRows = await (db.select(db.ghidraDecompilations)
        ..where((t) => t.elfHash.equals(elfHash)))
      .get();
  final candidates = <String>[];
  for (final d in decompRows) {
    if (d.sourceText.trim().isEmpty) continue;
    final sig = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) &
              t.symbolName.equals(d.functionName)))
        .getSingleOrNull();
    if (sig == null) continue;
    candidates.add(d.functionName);
  }
  stdout.writeln('candidate pool: ${candidates.length} functions '
      '(decompilation + signature both present)');

  // Pick N at random.
  final rng = math.Random(args.seed);
  candidates.shuffle(rng);
  final chosen = candidates.take(args.count).toList();
  stdout.writeln('selected:      ${chosen.length}');
  stdout.writeln('');

  // Bootstrap shared infra ONCE.
  includeSystemModules();
  final harness = HookTestHarness();
  const analyzer = HookStaticAnalyzer();
  const scorer = HookScorer();
  const classifier = HookClassifier();

  // Resolve .repl content for the static analyzer's unmapped check
  // + the progress runner. Default to the bundled empty repl when
  // no project-specific one is configured.
  final replPath = _resolveReplPath(cfg);
  final replContent = replPath != null
      ? await File(replPath).readAsString()
      : '';
  if (replPath == null) {
    stdout.writeln('warning: no .repl resolved; unmapped-access '
        'check will be permissive.');
  }

  // LLM client + RagIndex are required for the LLM-path fall-
  // through. Load them once; tear down at the end.
  final llmClient = _buildLlmClient(cfg, modelOverride: args.modelOverride);
  stdout.writeln('model:         ${llmClient.model}');
  final projectDir = _findProjectDir();
  RagIndex? ragIndex;
  LlmHookGenerator? generator;
  if (projectDir != null) {
    ragIndex = RagIndex(
      projectDir: projectDir,
      client: llmClient,
      artifactDb: db,
    );
    generator = LlmHookGenerator(
      index: ragIndex,
      client: llmClient,
      artifactDb: db,
      classifier: classifier,
    );
  }

  final results = <_PerFunctionResult>[];
  try {
    for (var i = 0; i < chosen.length; i++) {
      final name = chosen[i];
      stdout.writeln(
          '─── [${i + 1}/${chosen.length}] $name ───');
      final stopwatch = Stopwatch()..start();
      try {
        final r = await _runOneFunction(
          functionName: name,
          elfHash: elfHash,
          db: db,
          harness: harness,
          analyzer: analyzer,
          scorer: scorer,
          classifier: classifier,
          generator: generator,
          replContent: replContent,
          replPath: replPath,
          elfPath: firmware.fileName == args.elfName
              ? _resolveElfPath(firmware.fileName)
              : null,
          llmClient: llmClient,
          withJudge: args.withJudge,
          withProgress: args.withProgress,
        );
        stopwatch.stop();
        results.add(_PerFunctionResult(
          functionName: name,
          ruleName: r.ruleName,
          templateName: r.templateName,
          hookCode: r.hookCode,
          report: r.report,
          pathTaken: r.pathTaken,
          error: r.error,
          totalElapsed: stopwatch.elapsed,
        ));
      } catch (e, st) {
        stopwatch.stop();
        stderr.writeln('  ! exception: $e\n$st');
        results.add(_PerFunctionResult(
          functionName: name,
          ruleName: null,
          templateName: null,
          hookCode: '',
          report: null,
          pathTaken: 'error',
          error: '$e',
          totalElapsed: stopwatch.elapsed,
        ));
      }
      stdout.writeln('');
    }
  } finally {
    ragIndex?.close();
    llmClient.close();
    await db.close();
  }

  // Summary table.
  stdout.writeln('═══════════════════════════════════════════════');
  stdout.writeln('SUMMARY');
  stdout.writeln('═══════════════════════════════════════════════');
  stdout.writeln('');
  stdout.writeln(_formatSummaryTable(results));
  stdout.writeln('');

  final classifierHits = results.where((r) => r.ruleName != null).length;
  final llmFallThroughs =
      results.where((r) => r.pathTaken == 'llm').length;
  final errors = results.where((r) => r.pathTaken == 'error').length;
  final gatePasses = results
      .where((r) => r.report?.gatePassed ?? false)
      .length;
  final scores = results
      .where((r) => r.report != null)
      .map((r) => r.report!.score)
      .toList();
  final avgScore = scores.isEmpty
      ? 0.0
      : scores.reduce((a, b) => a + b) / scores.length;

  stdout.writeln('classifier matched: $classifierHits / ${results.length}');
  stdout.writeln('LLM fall-through:   $llmFallThroughs / ${results.length}');
  stdout.writeln('errors:             $errors / ${results.length}');
  stdout.writeln('gate passes:        $gatePasses / ${results.length}');
  stdout.writeln('average score:      ${avgScore.toStringAsFixed(3)}');
  if (classifierHits > 0) {
    final ruleBreakdown = <String, int>{};
    for (final r in results) {
      if (r.ruleName != null) {
        ruleBreakdown.update(r.ruleName!, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    stdout.writeln('rule breakdown:');
    final keys = ruleBreakdown.keys.toList()..sort();
    for (final k in keys) {
      stdout.writeln('  $k: ${ruleBreakdown[k]}');
    }
  }
  stdout.writeln('');
  stdout.writeln('seed for reproduction: --seed=${args.seed}');
}

class _RunResult {
  final String? ruleName;
  final String? templateName;
  final String hookCode;
  final HookQualityReport? report;
  final String pathTaken;
  final String? error;
  _RunResult({
    required this.ruleName,
    required this.templateName,
    required this.hookCode,
    required this.report,
    required this.pathTaken,
    required this.error,
  });
}

Future<_RunResult> _runOneFunction({
  required String functionName,
  required String elfHash,
  required ArtifactDatabase db,
  required HookTestHarness harness,
  required HookStaticAnalyzer analyzer,
  required HookScorer scorer,
  required HookClassifier classifier,
  required LlmHookGenerator? generator,
  required String replContent,
  required String? replPath,
  required String? elfPath,
  required LlmClient llmClient,
  required bool withJudge,
  required bool withProgress,
}) async {
  // Load signature + decompilation + data_symbols.
  final sigRow = await (db.select(db.signatures)
        ..where((t) =>
            t.elfHash.equals(elfHash) & t.symbolName.equals(functionName)))
      .getSingleOrNull();
  if (sigRow == null) {
    return _RunResult(
      ruleName: null,
      templateName: null,
      hookCode: '',
      report: null,
      pathTaken: 'error',
      error: 'no signature row',
    );
  }
  final signature = FunctionSignature.fromJson(
    functionName,
    jsonDecode(sigRow.signatureJson) as Map<String, dynamic>,
  );
  final decompilation = await db.decompilationFor(
    elfHash: elfHash,
    functionName: functionName,
  );
  if (decompilation == null || decompilation.isEmpty) {
    return _RunResult(
      ruleName: null,
      templateName: null,
      hookCode: '',
      report: null,
      pathTaken: 'error',
      error: 'no decompilation',
    );
  }
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

  stdout.writeln(
      '  signature: ${signature.summary()}');
  final firstLine = decompilation
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty &&
          !l.contains('WARNING') &&
          !l.contains('/*'),
          orElse: () => '');
  if (firstLine.isNotEmpty) {
    stdout.writeln('  decompilation: ${firstLine.trim()}');
  }

  // Try the classifier first.
  final classification = classifier.classify(
    functionName: functionName,
    signature: signature,
    decompilation: decompilation,
    dataSymbols: dataSymbols,
  );

  String hookCode;
  String? ruleName;
  String? templateName;
  String pathTaken;

  if (classification != null) {
    hookCode = classification.hook.code;
    ruleName = classification.ruleName;
    templateName = classification.templateName;
    pathTaken = 'classifier';
    stdout.writeln('  path: classifier → '
        '${classification.ruleName} '
        '(${classification.templateName} ${classification.params})');
  } else {
    // Fall through to LLM.
    if (generator == null) {
      return _RunResult(
        ruleName: null,
        templateName: null,
        hookCode: '',
        report: null,
        pathTaken: 'error',
        error: 'classifier no-match but LLM generator not available',
      );
    }
    pathTaken = 'llm';
    stdout.writeln('  path: classifier no-match → LLM generation '
        '(this takes ~60s)…');
    final start = DateTime.now();
    final buf = StringBuffer();
    await for (final tok in generator.generate(
      userPrompt: 'Substitute for $functionName in emulation. The goal '
          'is to let the caller continue without generating unhandled '
          'memory accesses — NOT to reproduce what the real hardware '
          'would do.',
      targetSymbol: functionName,
      elfHash: elfHash,
      signature: signature,
    )) {
      buf.write(tok);
    }
    hookCode = buf.toString();
    final dur = DateTime.now().difference(start);
    stdout.writeln('  LLM generation: ${dur.inSeconds}s, '
        '${hookCode.split('\n').where((l) => l.trim().isNotEmpty).length} '
        'non-blank lines');
  }

  // Compact hook display: just the first 4 non-blank lines.
  final hookLines = hookCode
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();
  stdout.writeln('  hook (${hookLines.length} lines):');
  for (final line in hookLines.take(4)) {
    stdout.writeln('    $line');
  }
  if (hookLines.length > 4) {
    stdout.writeln('    … (+${hookLines.length - 4} more)');
  }

  // Harness.
  HookTestResult harnessResult;
  try {
    harnessResult = await harness.runHook(hookCode: hookCode);
  } catch (e) {
    stdout.writeln('  harness: EXCEPTION $e');
    return _RunResult(
      ruleName: ruleName,
      templateName: templateName,
      hookCode: hookCode,
      report: null,
      pathTaken: pathTaken,
      error: 'harness exception: $e',
    );
  }
  stdout.writeln('  harness: ranToCompletion=${harnessResult.ranToCompletion} '
      'errorMessage=${harnessResult.errorMessage == null ? "none" : "\"${harnessResult.errorMessage}\""} '
      'returns=${harnessResult.returnValues}');

  // Static analysis.
  final paramNames = signature.parameters.map((p) => p.name).toList();
  final staticResult = await analyzer.evaluate(
    candidateCode: hookCode,
    originalDecompilation: decompilation,
    parameterNames: paramNames,
    replContent: replContent,
  );
  stdout.writeln('  static: modSet=${staticResult.modSetContained} '
      'unmappedOk=${staticResult.unmappedAccessOk} '
      'candidateWrites=${staticResult.candidateWrites} '
      'candidateReads=${staticResult.candidateReads}');

  // Optional Layer 3 (judge).
  LlmJudgeResult? judgeResult;
  if (withJudge && classification == null) {
    stdout.writeln('  judge: in flight (LLM, ~60s)…');
    final judgeStart = DateTime.now();
    try {
      judgeResult = await LlmJudge(client: llmClient).evaluate(
        candidateHook: hookCode,
        baselineHook: 'import set_return_value\nsetReturnValue(cpu, 0)\n',
        functionName: functionName,
        decompilation: decompilation,
      );
      stdout.writeln('  judge: score=${judgeResult.score.toStringAsFixed(3)} '
          '(${DateTime.now().difference(judgeStart).inSeconds}s)');
    } catch (e) {
      stdout.writeln('  judge: FAILED $e');
    }
  }

  // Optional Layer 2 (progress).
  HookProgressResult? progressResult;
  if (withProgress && replPath != null && elfPath != null) {
    stdout.writeln('  progress: in flight (two Renode boots, ~20s)…');
    try {
      progressResult = await HookProgressRunner().measure(
        replPath: replPath,
        elfPath: elfPath,
        targetSymbol: functionName,
        hookCode: hookCode,
      );
      stdout.writeln('  progress: score=${progressResult.score.toStringAsFixed(3)} '
          'withHook=${progressResult.withHookInstructions} '
          'baseline=${progressResult.baselineInstructions}');
    } catch (e) {
      stdout.writeln('  progress: FAILED $e');
    }
  }

  final report = scorer.score(
    harness: harnessResult,
    classification: classification,
    staticResult: staticResult,
    judgeResult: judgeResult,
    progressResult: progressResult,
  );
  stdout.writeln('  gate checks:');
  for (final c in report.gateChecks) {
    stdout.writeln('    - ${c.name.padRight(18)} ${c.passed ? "PASS" : "FAIL"}'
        '${c.violation == null ? "" : " (${c.violation})"}');
  }
  stdout.writeln('  score: ${report.score.toStringAsFixed(3)}'
      '${report.gatePassed ? "" : " (gate failed)"}');

  return _RunResult(
    ruleName: ruleName,
    templateName: templateName,
    hookCode: hookCode,
    report: report,
    pathTaken: pathTaken,
    error: null,
  );
}

String _formatSummaryTable(List<_PerFunctionResult> results) {
  final rows = <List<String>>[
    ['#', 'function', 'path', 'rule/template', 'score', 'gate'],
  ];
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    final ruleCell = r.pathTaken == 'classifier'
        ? '${r.ruleName} / ${r.templateName}'
        : (r.pathTaken == 'llm' ? 'LLM' : '(error)');
    final scoreCell = r.report == null
        ? '—'
        : r.report!.score.toStringAsFixed(2);
    final gateCell = r.report == null
        ? '—'
        : (r.report!.gatePassed ? '✓' : '✗');
    final fn = r.functionName.length > 40
        ? '${r.functionName.substring(0, 37)}...'
        : r.functionName;
    rows.add(['${i + 1}', fn, r.pathTaken, ruleCell, scoreCell, gateCell]);
  }
  // Column widths.
  final widths = List<int>.filled(rows[0].length, 0);
  for (final row in rows) {
    for (var c = 0; c < row.length; c++) {
      if (row[c].length > widths[c]) widths[c] = row[c].length;
    }
  }
  final buf = StringBuffer();
  for (var ri = 0; ri < rows.length; ri++) {
    for (var ci = 0; ci < rows[ri].length; ci++) {
      buf.write(rows[ri][ci].padRight(widths[ci] + 2));
    }
    buf.writeln();
    if (ri == 0) {
      for (var ci = 0; ci < widths.length; ci++) {
        buf.write('─' * (widths[ci] + 2));
      }
      buf.writeln();
    }
  }
  return buf.toString();
}

LlmClient _buildLlmClient(EnvConfig cfg, {String? modelOverride}) {
  final host = (cfg.get('LLM_OLLAMA_HOST') ?? '').trim();
  final model = (modelOverride?.trim().isNotEmpty ?? false)
      ? modelOverride!.trim()
      : (cfg.get('LLM_MODEL') ?? '').trim();
  return LlmClient(
    host: host.isEmpty ? 'localhost:11434' : host,
    model: model.isEmpty ? 'gemma4:12b' : model,
  );
}

String? _resolveReplPath(EnvConfig cfg) {
  // Same lookup the dialog uses via Emulator.baseImagePath. For
  // this script we read a hardcoded default (the stm32wb05_empty
  // .repl shipped with the engine); the user can edit if needed.
  const candidates = [
    '/home/evan/Development/resect/emulation_engine/'
        'renode_1.16.0-dotnet_portable/platforms/cpus/stm32wb05_empty.repl',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

String? _resolveElfPath(String fileName) {
  // Best-effort: aya_ppg.elf lives in emulation_engine.
  final candidates = [
    '/home/evan/Development/resect/emulation_engine/$fileName',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

String? _findProjectDir() {
  // The dialog resolves this from the open Emulator; for this
  // script we use the projects directory where the shared
  // rag_index.db lives.
  const dir = '/home/evan/.config/call_graph_viewer/projects';
  if (Directory(dir).existsSync() &&
      File(p.join(dir, 'rag_index.db')).existsSync()) {
    return dir;
  }
  return null;
}
