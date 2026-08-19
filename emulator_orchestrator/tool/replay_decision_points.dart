// Replay the Aug 3 capture's disaster decision points through TODAY's
// recommendation pipeline (prompt + schema + history-window fix) and
// measure how often the model still makes the destructive move.
//
// Each decision point is one LLM call in a captured auto-tune session
// where the Aug 3 build recommended killing previously-working parent
// functions (or `main`). The evidence is rebuilt from the captured
// round manifests/reports/traces; TODAY's RecommendationService then
// composes the prompt and schema, and the same model (gemma4:e4b) is
// sampled N times. Every sampled recommendation set is graded:
//
//   leaf-fix      an override on the evidence's spinning leaf symbol
//   parent-kill   Return-0 forced override on a symbol that executed
//                 cleanly in the evidence round and has an executed
//                 callee or an override beneath it
//   entry-point   any rec targeting main / Reset_Handler / _start
//
// Escalation points parse their stalled-caller feedback verbatim from
// the captured trace prompt, so the candidate set matches what the
// Aug 3 engine computed. Comms is left OFF (the capture had none), so
// the replay isolates prompt/schema behavior, not the comms change.
//
// Run with (from emulator_orchestrator/):
//   dart run tool/replay_decision_points.dart \
//       --capture /home/evan/Downloads/workdir/workdir \
//       --host <ollama-host:port> [--model gemma4:e4b] [--samples 10]

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_call_graph_source.dart';
import 'package:emulator_orchestrator/services/analysis/coverage_frontier.dart';
import 'package:emulator_orchestrator/services/hooks/artifact_library_service.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';
import 'package:emulator_orchestrator/services/llm/last_run_insight_service.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';

const _entryPoints = {'main', 'Reset_Handler', '_start'};

/// The captured decision points. `round` is the round whose LLM call we
/// replay; its evidence is round-1's manifest and the round's own trace
/// prompt (halt/spin lines + feedback section).
const _points = [
  (session: 'example_run_2', reports: '2026-08-03T16-33-46.695294', round: 3,
   label: 'run_2 r3 — killed 4 clock-init callers (escalation)'),
  (session: 'example_run_2', reports: '2026-08-03T16-33-46.695294', round: 4,
   label: 'run_2 r4 — forced main <- Return 0 (normal round)'),
  (session: 'example', reports: '2026-08-03T18-23-40.681114', round: 3,
   label: 'example r3 — right leaf fix + clock-Enable kills (normal)'),
  (session: 'example', reports: '2026-08-03T18-23-40.681114', round: 5,
   label: 'example r5 — repeated 4-caller kill (escalation)'),
  (session: 'example_run_1', reports: '2026-08-03T15-33-49.541620', round: 7,
   label: 'run_1 r7 — killed BLE-init subtree at peak (escalation)'),
];

final _recRe = RegExp(
    r'(set_forced_override|clear_forced_override|set_preference|'
    r'generate_custom_hook|set_group_override|clear_group_override)'
    r'\s+`([^`]+)`(?:\s+←\s+#(\d+))?');
final _spinRe = RegExp(r'`([^`]+)` \(×(\d+)\)');
final _stalledRe = RegExp(r'`([^`]+)` \(\d+ unreached callees\)');
final _coverageRe = RegExp(r'Coverage did NOT move: (\d+) → (\d+)');

Future<void> main(List<String> args) async {
  var capture = '/home/evan/Downloads/workdir/workdir';
  var host = 'localhost:11434';
  var model = 'gemma4:e4b';
  var samples = 10;
  Set<int>? only;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--capture':
        capture = args[++i];
      case '--host':
        host = args[++i];
      case '--model':
        model = args[++i];
      case '--samples':
        samples = int.parse(args[++i]);
      case '--only':
        // Comma-separated indices into the decision-point list (0-based).
        only = args[++i].split(',').map(int.parse).toSet();
    }
  }

  final results = StringBuffer()
    ..writeln('# Decision-point replay — today\'s pipeline, model $model, '
        '$samples samples/point')
    ..writeln();

  for (var pi = 0; pi < _points.length; pi++) {
    if (only != null && !only.contains(pi)) continue;
    final p = _points[pi];
    final sessionDir = '$capture/${p.session}';
    final reportDir = '$sessionDir/autotune_reports/${p.reports}';
    stderr.writeln('=== ${p.label}');
    final table = await _replayPoint(
      sessionDir: sessionDir,
      reportDir: reportDir,
      round: p.round,
      host: host,
      model: model,
      samples: samples,
    );
    results
      ..writeln('## ${p.label}')
      ..writeln(table)
      ..writeln();
    stdout.writeln('## ${p.label}\n$table\n');
  }

  final outFile = File('replay_results.md');
  outFile.writeAsStringSync(results.toString());
  stderr.writeln('Written: ${outFile.absolute.path}');
}

Future<String> _replayPoint({
  required String sessionDir,
  required String reportDir,
  required int round,
  required String host,
  required String model,
  required int samples,
}) async {
  String two(int n) => n.toString().padLeft(2, '0');

  // ---- Evidence: previous round's manifest --------------------------------
  final manifest = SynthesisManifest.fromJson(jsonDecode(
          File('$reportDir/round_${two(round - 1)}_manifest.json')
              .readAsStringSync())
      as Map<String, dynamic>);

  // ---- Call graph from the captured ELF ------------------------------------
  final callGraph =
      await DartCallGraphSource().getCallGraph('$sessionDir/aya_ppg.elf');

  // ---- Fold overlays + collect history from rounds 0..round-1 --------------
  final overrides = <String, int>{};
  final scopes = <String, String>{};
  final history = <RoundSnapshot>[];
  final artifactLabels = <int, String>{};
  for (var n = 0; n < round; n++) {
    final mdFile = File('$reportDir/round_${two(n)}.md');
    final applied = <Recommendation>[];
    if (mdFile.existsSync()) {
      var inApplied = false;
      for (final line in mdFile.readAsLinesSync()) {
        if (line.startsWith('**Applied this round')) {
          inApplied = true;
          continue;
        }
        if (line.startsWith('**') || line.startsWith('## ')) inApplied = false;
        if (!inApplied || !line.startsWith('- ')) continue;
        final m = _recRe.firstMatch(line);
        if (m == null) continue;
        final kind = m.group(1)!;
        final sym = m.group(2)!;
        final id = m.group(3) != null ? int.parse(m.group(3)!) : null;
        if (kind == 'set_forced_override' && id != null) {
          overrides[sym] = id;
          final scopeM = RegExp('scope=(\\S+)').firstMatch(line);
          if (scopeM != null) scopes[sym] = scopeM.group(1)!;
          applied.add(SetForcedOverride(
              rationale: '', symbol: sym, artifactId: id));
        } else if (kind == 'clear_forced_override') {
          overrides.remove(sym);
          scopes.remove(sym);
          applied.add(ClearForcedOverride(rationale: '', symbol: sym));
        }
      }
    }
    final mFile = File('$reportDir/round_${two(n)}_manifest.json');
    if (mFile.existsSync()) {
      final m = SynthesisManifest.fromJson(
          jsonDecode(mFile.readAsStringSync()) as Map<String, dynamic>);
      history.add(RoundSnapshot(
        snapshotVersion: RoundSnapshot.currentVersion,
        round: n,
        synthesizerRunId: m.synthesizerRunId,
        createdAt: DateTime.now(),
        hookOverrides: Map<String, int>.from(overrides),
        hookOverrideScopes: Map<String, String>.from(scopes),
        hookPreferences: const {},
        hookBindings: const {},
        iterationCap: 10,
        metrics: m.metrics ??
            const ManifestMetrics(
                overallFidelity: 0,
                coverageFidelity: null,
                subgraphFidelity: null,
                intactCount: 0,
                degradedCount: 0,
                hookedCount: 0),
        executedSymbols: m.executedSymbols ?? const [],
        manifestRef: SynthesisManifestRef(runId: m.synthesizerRunId),
        llmRecommendations: applied.isEmpty ? null : applied,
      ));
    }
  }
  // Today's window semantics: the engine passes the MOST RECENT N.
  final windowed =
      history.length <= 3 ? history : history.sublist(history.length - 3);

  // ---- Evidence details + feedback from the CAPTURED trace prompt ----------
  final trace = File('$reportDir/round_${two(round)}_trace.txt')
      .readAsStringSync();
  final spins = <String, int>{};
  for (final line in trace.split('\n')) {
    if (!line.contains('Recent call sequence')) continue;
    for (final m in _spinRe.allMatches(line)) {
      spins[m.group(1)!] = int.parse(m.group(2)!);
    }
    break;
  }
  for (final m in RegExp(r'- id=(\d+)\s+\S+\s+"([^"]+)"').allMatches(trace)) {
    artifactLabels[int.parse(m.group(1)!)] = m.group(2)!;
  }
  RoundFeedback? feedback;
  if (trace.contains('ESCALATION ROUND')) {
    final stalledLine = trace
        .split('\n')
        .firstWhere((l) => l.contains('INLINED busy-wait inside one of these'),
            orElse: () => '');
    final stalled = [
      for (final m in _stalledRe.allMatches(stalledLine)) m.group(1)!,
    ];
    final cov = _coverageRe.firstMatch(trace);
    feedback = RoundFeedback(
      coveragePrev: cov != null ? int.parse(cov.group(1)!) : 0,
      coverageNow: cov != null ? int.parse(cov.group(2)!) : 0,
      stalledCallers: stalled,
    );
    stderr.writeln('  escalation: ${stalled.length} stalled callers '
        '(${stalled.take(4).join(', ')}…)');
  }

  // ---- Mirror the captured artifact catalog into an in-memory DB -----------
  final artifactDb = ArtifactDatabase.forTesting(NativeDatabase.memory());
  await ArtifactLibraryService(artifactDb).ensureDefaultTemplates();
  // User rows the capture had beyond the 8 defaults (#9, #10, ...), in id
  // order so AUTOINCREMENT lines up.
  final userIds = artifactLabels.keys.where((id) => id > 8).toList()..sort();
  for (final id in userIds) {
    final label = artifactLabels[id]!;
    final body = label == 'Return 0'
        ? HookCatalog.system().build('return', const {'value': 0}).code
        : '# replay stand-in for "$label"\nreturn Create(1, cpu.GetRegister(0).RawValue)';
    await artifactDb.addArtifact(
      artifactType: 'renode_hook',
      artifactData: body,
      origin: 'user',
      name: label,
      architecture: 'ARM',
      intrinsicScore: 0.5,
    );
  }

  // ---- Decision state, frontier, symbol groups -----------------------------
  final emulator = Emulator.create(name: 'replay').copyWith(
    hookOverrides: Map<String, int>.from(overrides),
    hookOverrideScopes: Map<String, String>.from(scopes),
  );
  final state = buildHookDecisionState(
    emulator: emulator,
    elfHash: manifest.elfHash,
    commsConfigs: const {},
  );
  final executed = manifest.executedSymbols?.toSet() ?? <String>{};
  final frontier =
      computeFrontier(executedSymbols: executed, callGraph: callGraph);
  final symbolGroups = SymbolGroupClassifier(catalog: HookCatalog.system())
      .classify(callGraph.symbols.keys);

  // ---- Sample ---------------------------------------------------------------
  final client = LlmClient(host: host, model: model);
  final insight = LastRunInsightService(llmClient: client);
  final service = RecommendationService(
    llmClient: client,
    insightService: insight,
    artifactDb: artifactDb,
  );

  bool isReturnZero(int? id) =>
      id != null && (artifactLabels[id] ?? '') == 'Return 0';
  final prevExecuted = executed;

  var leafFix = 0, parentKill = 0, entryHit = 0, parseFail = 0;
  final sampleLines = <String>[];
  for (var s = 0; s < samples; s++) {
    RecommendationResult result;
    try {
      result = await service.recommend(
        currentManifest: manifest,
        currentState: state,
        callGraph: callGraph,
        history: windowed,
        frontier: frontier,
        feedback: feedback,
        maxRecommendations: 10,
        symbolGroups: symbolGroups,
      );
    } catch (e) {
      parseFail++;
      sampleLines.add('- s$s: ERROR $e');
      continue;
    }
    if (result.parseFailure) {
      parseFail++;
      sampleLines.add('- s$s: parse failure');
      continue;
    }
    var sLeaf = false, sParent = false, sEntry = false;
    final parts = <String>[];
    for (final rec in result.recommendations) {
      if (rec is SetForcedOverride) {
        parts.add('`${rec.symbol}`←#${rec.artifactId}');
        if (_entryPoints.contains(rec.symbol)) sEntry = true;
        if (spins.containsKey(rec.symbol)) sLeaf = true;
        if (isReturnZero(rec.artifactId) &&
            prevExecuted.contains(rec.symbol)) {
          final node = callGraph.symbols[rec.symbol];
          final execCallee = node?.calledSymbols.keys
                  .any(prevExecuted.contains) ??
              false;
          final ovrBeneath = _hasOverriddenDescendant(
              callGraph, rec.symbol, overrides.keys.toSet());
          if (execCallee || ovrBeneath) sParent = true;
        }
      } else if (rec is GenerateCustomHook) {
        parts.add('gen `${rec.symbol}`');
        if (spins.containsKey(rec.symbol)) sLeaf = true;
        if (_entryPoints.contains(rec.symbol)) sEntry = true;
      }
    }
    if (sLeaf) leafFix++;
    if (sParent) parentKill++;
    if (sEntry) entryHit++;
    sampleLines.add('- s$s: ${[
      if (sLeaf) 'LEAF-FIX',
      if (sParent) 'PARENT-KILL',
      if (sEntry) 'ENTRY',
    ].join(' ')} ${parts.join(', ')}');
    stderr.writeln('  sample $s: ${sampleLines.last}');
  }
  client.close();
  await artifactDb.close();

  final n = samples - parseFail;
  return [
    '| outcome | count / $samples |',
    '|---|---|',
    '| leaf-fix (forced the spinning leaf) | $leafFix |',
    '| PARENT-KILL (Return-0 on proven parent) | $parentKill |',
    '| ENTRY-POINT targeting | $entryHit |',
    '| parse failures | $parseFail |',
    '',
    'Valid samples: $n. Spin evidence: '
        '${spins.entries.map((e) => '`${e.key}`(×${e.value})').join(', ')}',
    '',
    ...sampleLines,
  ].join('\n');
}

bool _hasOverriddenDescendant(CallGraph g, String root, Set<String> overridden) {
  final visited = <String>{root};
  final queue = [root];
  while (queue.isNotEmpty) {
    final node = g.symbols[queue.removeLast()];
    if (node == null) continue;
    for (final callee in node.calledSymbols.keys) {
      if (!visited.add(callee)) continue;
      if (overridden.contains(callee)) return true;
      queue.add(callee);
    }
  }
  return false;
}
