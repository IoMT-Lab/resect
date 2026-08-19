import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart' as cg_sym;
import 'package:emulator_orchestrator/data/models/symbol_group.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_report_writer.dart';
import 'package:emulator_orchestrator/services/analysis/coverage_frontier.dart';
import 'package:emulator_orchestrator/services/llm/last_run_insight_service.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:emulator_ui/presentation/screens/synthesize/llm_synthesis_orchestrator.dart';
import 'package:emulator_ui/presentation/screens/synthesize/ui_auto_tune_sink.dart';
import 'package:emulator_ui/presentation/screens/synthesize/ui_review_policy.dart';
import 'package:emulator_ui/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parity proof for the UI-on-engine migration: the REAL AutoTuneEngine
/// driven through the UI's policy + sink classes (accept-all mode, like
/// a CLI session), with an AutoTuneReportSink writing the same files a
/// CLI run writes. Scripted synthesis + recommender — no Renode, no
/// Ollama.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
      'engine through UiAutoTuneSink + UiReviewPolicy: states, files, '
      'snapshots', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentEmulatorProvider.notifier).state =
        Emulator.create(name: 'parity');

    final tempDir =
        await Directory.systemTemp.createTemp('resect_parity_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    final states = <AutoTuneState>[];
    final lines = <AutoTuneRoundLine>[];
    final uiSink = UiAutoTuneSink(
      container: container,
      emitState: states.add,
      onRoundLine: lines.add,
    );
    final reportSink = AutoTuneReportSink(
      reportDir: tempDir,
      callGraph: _callGraph(['A', 'B']),
      startedAt: DateTime.utc(2026),
      color: false,
      log: (_) {},
    );
    final policy = UiReviewPolicy(emitState: states.add, interactive: false);

    final engine = AutoTuneEngine(
      runSynthesis: _ScriptedSynth([
        _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
        _result(runId: 'r1', success: true, executed: ['A', 'B']),
      ]).call,
      recommendationService: _scripted([
        _recs([
          const SetPreference(rationale: 'try', symbol: 'A', artifactId: 4),
        ]),
        _recs(const []), // round 2 → empty → llmEmpty
      ]),
      artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
      reviewPolicy: policy,
      sink: MultiSink([uiSink, reportSink]),
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: container.read(currentEmulatorProvider)!,
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B']),
      config: const AutoTuneConfig(maxRounds: 2),
    );

    // Same terminal reason a CLI session would report.
    expect(reason, AutoTuneStopReason.llmEmpty);
    final done = states.whereType<AutoTuneFinished>().single;
    expect(done.reason, AutoTuneFinishReason.llmEmpty);
    expect(done.finalRound, 1);

    // The modal's state sequence: baseline → llm → synthesizing → done,
    // with NO review state (accept-all mode).
    expect(states.first, isA<AutoTuneRunningBaseline>());
    expect(states.whereType<AutoTuneReviewing>(), isEmpty);
    expect(states.whereType<AutoTuneLlmGenerating>(), isNotEmpty);
    expect(states.whereType<AutoTuneSynthesizing>(), isNotEmpty);

    // Snapshots persisted onto the project: baseline + round 1.
    final emulator = container.read(currentEmulatorProvider)!;
    expect(emulator.roundSnapshots.map((s) => s.round), [0, 1]);
    expect(lines.map((l) => l.round), [0, 1]);

    // The report files a CLI session would leave behind.
    final names = tempDir
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toSet();
    expect(names, containsAll(<String>{
      'round_00.md',
      'round_00_manifest.json',
      'round_01.md',
      'round_01_manifest.json',
      'round_01_trace.txt',
      'summary.md',
    }));
  });
}

// -- Fakes (pattern from emulator_orchestrator/test/auto_tune_engine_test) --

class _ScriptedSynth {
  _ScriptedSynth(this._results);
  final List<SynthesizerResult?> _results;
  var _i = 0;

  Future<SynthesizerResult?> call(AutoTuneOverlays overlays, int round) async =>
      _results[_i++];
}

class _ScriptedRecommender extends RecommendationService {
  _ScriptedRecommender(
    this._results, {
    required super.llmClient,
    required super.insightService,
    required super.artifactDb,
  });

  final List<RecommendationResult> _results;
  var _i = 0;

  @override
  Future<RecommendationResult> recommend({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    List<RoundSnapshot> history = const [],
    OptimizationTarget? optimizationTarget,
    RecommendationMode mode = RecommendationMode.auto,
    List<FrontierEntry> frontier = const [],
    RoundFeedback? feedback,
    int maxRecommendations = RecommendationService.defaultMaxRecommendations,
    List<SymbolGroup> symbolGroups = const [],
    Map<String, GroupOverrideState> groupOverrides = const {},
    void Function(String token)? onToken,
    void Function(String chunk)? onThinking,
    void Function(String prompt)? onPromptComposed,
  }) async {
    final r = _results[_i++];
    onPromptComposed?.call('scripted prompt');
    if (r.prose.isNotEmpty) onToken?.call(r.prose);
    return r;
  }
}

RecommendationService _scripted(List<RecommendationResult> results) {
  final client = LlmClient(host: 'localhost:11435', model: 'gemma4:e4b');
  return _ScriptedRecommender(
    results,
    llmClient: client,
    insightService: LastRunInsightService(llmClient: client),
    artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
  );
}

CallGraph _callGraph(List<String> symbols) => CallGraph(
      elfPath: '/dev/null',
      symbols: {
        for (final s in symbols)
          s: cg_sym.Symbol(name: s, numInstructions: 1, calledSymbols: const {}),
      },
    );

RecommendationResult _recs(List<Recommendation> recs) =>
    RecommendationResult(prose: 'ok', recommendations: recs, parseFailure: false);

SynthesizerResult _result({
  required String runId,
  bool success = false,
  String? failedSymbol,
  int? triedArtifactId,
  List<String> executed = const ['A'],
}) {
  final manifest = SynthesisManifest(
    manifestVersion: 2,
    elfHash: 'a' * 64,
    elfFileName: 'test.elf',
    synthesizerRunId: runId,
    result: ManifestRunResult(
        success: success, totalIterations: 1, durationSeconds: 1),
    decisions: [
      if (failedSymbol != null)
        ManifestDecision(
          symbol: failedSymbol,
          appliedHook: AppliedHook(bodyHash: 'h', artifactId: triedArtifactId),
          decisionKind: ManifestDecisionKind.iterationFallback,
          decisionSource: 'iteration_fallback',
        ),
    ],
    failedSymbol: failedSymbol,
    metrics: const ManifestMetrics(
      overallFidelity: 0.5,
      coverageFidelity: 0.5,
      subgraphFidelity: null,
      intactCount: 1,
      degradedCount: 0,
      hookedCount: 1,
    ),
    executedSymbols: executed,
  );
  return SynthesizerResult(
    success: success,
    totalIterations: 1,
    resolvedHooks: const {},
    totalDuration: const Duration(seconds: 1),
    failedSymbol: failedSymbol,
    manifest: manifest,
  );
}
