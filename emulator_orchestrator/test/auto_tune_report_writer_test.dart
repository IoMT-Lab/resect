import 'dart:io';

import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart' as cg;
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_report_writer.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:test/test.dart';

/// Round-page rendering: label-first hook references, the story-ordered
/// sections, the stop log / time split, and the census — the report
/// reorg's contract. Renders a fabricated round through the real sink
/// and asserts on the markdown it writes.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('report_writer_test');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  CallGraph graph(List<String> symbols) => CallGraph(
        elfPath: '/dev/null',
        symbols: {
          for (final s in symbols)
            s: cg.Symbol(name: s, numInstructions: 1, calledSymbols: const {}),
        },
      );

  SynthesisManifest manifest() => SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'a' * 64,
        elfFileName: 'test.elf',
        synthesizerRunId: 'run-1',
        result: const ManifestRunResult(
            success: false, totalIterations: 4, durationSeconds: 12.5),
        decisions: const [
          ManifestDecision(
            symbol: 'HAL_GPIO_Init',
            appliedHook: AppliedHook(bodyHash: 'h1', artifactId: 2),
            decisionKind: ManifestDecisionKind.iterationFallback,
            decisionSource: 'iteration_fallback',
          ),
          ManifestDecision(
            symbol: 'SystemClock_Config',
            appliedHook: AppliedHook(bodyHash: 'h2', artifactId: 7),
            decisionKind: ManifestDecisionKind.forcedOverride,
            decisionSource: 'user',
          ),
        ],
        failedSymbol: 'HAL_GPIO_Init',
        finalExecutionSymbol: 'HAL_GPIO_Init',
        recentExecutionTrace: const [
          'main',
          'HAL_GPIO_Init',
          'HAL_GPIO_Init',
          'HAL_GPIO_Init',
        ],
        metrics: const ManifestMetrics(
          overallFidelity: 0.82,
          coverageFidelity: 0.4,
          subgraphFidelity: null,
          intactCount: 2,
          degradedCount: 1,
          hookedCount: 2,
        ),
        executedSymbols: const ['main', 'HAL_GPIO_Init'],
        stops: const [
          StopTiming(
              elapsedSeconds: 0.8,
              kind: 'unhandled_access',
              symbol: 'HAL_GPIO_Init'),
          StopTiming(elapsedSeconds: 4.2, kind: 'pause'),
        ],
        phaseTimings:
            const PhaseTimings(selectionSeconds: 1.5, generationSeconds: 30.0),
      );

  AutoTuneRoundReport report({SynthesisManifest? m}) {
    final man = m ?? manifest();
    final result = SynthesizerResult(
      success: false,
      totalIterations: 4,
      resolvedHooks: const {},
      totalDuration: const Duration(milliseconds: 12500),
      failedSymbol: man.failedSymbol,
      manifest: man,
    );
    return AutoTuneRoundReport(
      round: 1,
      result: result,
      metrics: man.metrics!,
      snapshot: RoundSnapshot(
        snapshotVersion: RoundSnapshot.currentVersion,
        round: 1,
        synthesizerRunId: man.synthesizerRunId,
        createdAt: DateTime(2026),
        hookOverrides: const {},
        hookOverrideScopes: const {},
        hookPreferences: const {},
        hookBindings: const {},
        iterationCap: 500,
        metrics: man.metrics!,
        executedSymbols: man.executedSymbols!,
        manifestRef: SynthesisManifestRef(runId: man.synthesizerRunId),
      ),
      recommendation: const RecommendationResult(
        prose: 'Force the spinning leaf.',
        recommendations: [
          SetForcedOverride(
              rationale: 'It spins ×16 in the trace.',
              symbol: 'LL_TIM_GetCounter',
              artifactId: 7),
          SetPreference(
              rationale: 'Already in effect.',
              symbol: 'SystemClock_Config',
              artifactId: 7),
        ],
        parseFailure: false,
      ),
      appliedRecommendations: const [
        SetForcedOverride(
            rationale: 'It spins ×16 in the trace.',
            symbol: 'LL_TIM_GetCounter',
            artifactId: 7),
      ],
      skippedNoOps: const [
        SetPreference(
            rationale: 'Already in effect.',
            symbol: 'SystemClock_Config',
            artifactId: 7),
      ],
      advisorSeconds: 42.0,
      hookGenSeconds: 5.0,
      census: const ArtifactCensus(
        hookArtifacts: 40,
        hookBindings: 3,
        forcedOverrides: 2,
        commsAssignments: 5,
        groupMembers: 12,
        ragChunksByKind: {'docs': 100},
        signatures: 900,
        decompilations: 7,
      ),
    );
  }

  AutoTuneReportSink sink() => AutoTuneReportSink(
        reportDir: dir,
        callGraph: graph(['main', 'HAL_GPIO_Init', 'SystemClock_Config',
            'LL_TIM_GetCounter']),
        startedAt: DateTime(2026),
        artifactLabels: const {
          2: 'Return 1',
          7: 'Stateful increment (from 0)',
        },
        color: false,
        log: (_) {},
      );

  String renderRound() {
    sink().round(report());
    return File('${dir.path}/round_01.md').readAsStringSync();
  }

  test('hook references render label-first with the id retained', () {
    final md = renderRound();
    expect(
        md,
        contains('set_forced_override `LL_TIM_GetCounter` ← '
            '"Stateful increment (from 0)" (#7)'));
    expect(md, contains('`HAL_GPIO_Init` ← "Return 1" (#2)'));
    // No bare-id renders for known artifacts.
    expect(md, isNot(contains('← #7')));
  });

  test('sections appear in story order', () {
    final md = renderRound();
    final order = [
      '## What changed going in',
      '## What happened',
      '## Results',
      '## Why it stopped where it did',
      '## Hooks in effect',
      '## Coverage frontier',
      '## Artifact census',
    ];
    var last = -1;
    for (final h in order) {
      final at = md.indexOf(h);
      expect(at, greaterThan(last), reason: '$h out of order or missing');
      last = at;
    }
  });

  test('proposals carry their fate and rationale', () {
    final md = renderRound();
    expect(md, contains('— **applied**'));
    expect(md, contains('— skipped as a no-op (already in effect)'));
    expect(md, contains('_why:_ It spins ×16 in the trace.'));
  });

  test('stop log, first stop, and three-way time split are rendered', () {
    final md = renderRound();
    expect(md, contains('- Synthesis time: 12.5s'));
    expect(md,
        contains('- Time to first stop: 0.8s (unhandled access at '
            '`HAL_GPIO_Init`)'));
    expect(md, contains('- 0.8s → unhandled access at `HAL_GPIO_Init`'));
    expect(md, contains('- 4.2s → pause'));
    // Generation combines the workflow's 30.0s with the round's 5.0s
    // custom-hook pass; advisor comes from the round report.
    expect(
        md,
        contains('hook selection 1.5s · hook generation 35.0s · '
            'advisor 42.0s'));
  });

  test('why-it-stopped names the halt and collapses the spin trace', () {
    final md = renderRound();
    expect(md, contains('Halted at `HAL_GPIO_Init`'));
    expect(md, contains('`main` → `HAL_GPIO_Init ×3`'));
  });

  test('census section carries the full breakdown and total', () {
    final md = renderRound();
    expect(md, contains('- Hook artifacts in the catalog: 40'));
    expect(md, contains('- RAG chunks: 100 (docs 100)'));
    expect(md,
        contains('- Total artifacts feeding synthesis: ${40 + 3 + 2 + 5 + 12 + 100 + 900 + 7}'));
  });

  test('summary gains time and first-stop columns and cumulative times', () {
    sink()
      ..round(report())
      ..finished(AutoTuneStopReason.maxRounds, finalRound: 1);
    final md = File('${dir.path}/summary.md').readAsStringSync();
    expect(md, contains('| Time | First stop |'));
    expect(md, contains('| 12.5s | 0.8s unhandled access at `HAL_GPIO_Init` |'));
    expect(md, contains('- Total synthesis (emulation) time: 12.5s'));
    expect(md, contains('- Hook selection: 1.5s'));
    expect(md, contains('- Hook generation (LLM authoring): 35.0s'));
    expect(md, contains('- Advisor (recommendation) calls: 42.0s'));
    expect(md, contains('## Artifact census'));
  });
}
