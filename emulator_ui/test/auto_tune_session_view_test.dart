import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_ui/presentation/screens/synthesize/widgets/auto_tune_session_view.dart';
import 'package:emulator_ui/presentation/widgets/metric_trajectory_chart.dart';
import 'package:emulator_ui/providers/auto_tune_session_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

SynthesisManifest _manifest(
  String runId, {
  int executed = 50,
  bool withTelemetry = true,
}) =>
    SynthesisManifest(
      manifestVersion: 2,
      elfHash: 'a' * 64,
      elfFileName: 'test.elf',
      synthesizerRunId: runId,
      result: const ManifestRunResult(
          success: true, totalIterations: 4, durationSeconds: 45.6),
      decisions: const [],
      metrics: ManifestMetrics(
        overallFidelity: 0.826,
        coverageFidelity: 0.209,
        subgraphFidelity: null,
        intactCount: 1,
        degradedCount: 0,
        hookedCount: 1,
        executedCount: executed,
        totalSymbols: 945,
      ),
      executedSymbols: [for (var i = 0; i < executed; i++) 'sym$i'],
      stops: withTelemetry
          ? const [
              StopTiming(
                  elapsedSeconds: 0.9,
                  kind: 'unhandled_access',
                  symbol: 'SystemInit'),
              StopTiming(elapsedSeconds: 45.6, kind: 'clean_exit'),
            ]
          : null,
      phaseTimings: withTelemetry
          ? const PhaseTimings(
              selectionSeconds: 0.1,
              generationSeconds: 0.0,
              advisorSeconds: 343.0,
            )
          : null,
      census: withTelemetry
          ? const ArtifactCensus(
              hookArtifacts: 19,
              hookBindings: 0,
              forcedOverrides: 1,
              commsAssignments: 49,
              groupMembers: 171,
              ragChunksByKind: {},
              signatures: 0,
              decompilations: 0,
            )
          : null,
    );

RoundSnapshot _snapshot(
  int round,
  String runId, {
  bool reverted = false,
  List<Recommendation>? recs,
}) =>
    RoundSnapshot(
      snapshotVersion: RoundSnapshot.currentVersion,
      round: round,
      synthesizerRunId: runId,
      createdAt: DateTime.utc(2026),
      hookOverrides: const {},
      hookOverrideScopes: const {},
      hookPreferences: const {},
      hookBindings: const {},
      iterationCap: 500,
      metrics: const ManifestMetrics(
        overallFidelity: 0.8,
        coverageFidelity: null,
        subgraphFidelity: null,
        intactCount: 1,
        degradedCount: 0,
        hookedCount: 0,
      ),
      executedSymbols: const ['A'],
      manifestRef: SynthesisManifestRef(runId: runId),
      llmRecommendations: recs,
      reverted: reverted,
    );

AutoTuneSessionNotifier _sessionWith(List<AutoTuneSessionRoundRecord> rounds,
    {bool finished = true}) {
  final n = AutoTuneSessionNotifier()..beginLive('/tmp/reports');
  rounds.forEach(n.addRound);
  if (finished) n.finishLive('noCoverageProgress');
  return n;
}

Future<void> _pump(WidgetTester tester, AutoTuneSessionNotifier notifier) =>
    tester.pumpWidget(ProviderScope(
    overrides: [
      autoTuneSessionProvider.overrideWith((ref) => notifier),
      artifactLabelsProvider.overrideWith(
          (ref) async => const {18: 'Stateful increment (from 0)'}),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: AutoTuneSessionView()),
      ),
    ),
  ));

void main() {
  final rounds = [
    AutoTuneSessionRoundRecord(
      round: 0,
      manifest: _manifest('run-0', executed: 39),
      snapshot: _snapshot(0, 'run-0'),
    ),
    AutoTuneSessionRoundRecord(
      round: 1,
      manifest: _manifest('run-1'),
      snapshot: _snapshot(
        1,
        'run-1',
        recs: const [
          SetForcedOverride(
            rationale: 'spins in the trace',
            symbol: 'LL_RADIO_TIMER_GetAbsoluteTime',
            artifactId: 18,
          ),
        ],
      ),
    ),
    AutoTuneSessionRoundRecord(
      round: 2,
      manifest: _manifest('run-2', executed: 12),
      snapshot: _snapshot(2, 'run-2', reverted: true),
    ),
  ];

  testWidgets('renders chart, metric band, census, and status',
      (tester) async {
    await _pump(tester, _sessionWith(rounds));
    await tester.pumpAndSettle();

    expect(find.text('AUTO-TUNE SESSION'), findsOneWidget);
    expect(find.byType(MetricTrajectoryChart), findsOneWidget);
    // Session status: stop reason + best round (round 1: 50 executed;
    // round 2's 12 doesn't count — it was reverted).
    expect(find.textContaining('noCoverageProgress'), findsOneWidget);
    expect(find.textContaining('holding round 1 overlays'), findsOneWidget);
    // Metric band: cumulative synthesis (3 × 45.6s) and advisor time.
    expect(find.text('136.8s'), findsOneWidget);
    expect(find.text('1029.0s'), findsOneWidget);
    // Census line from the last round that carries one.
    expect(find.textContaining('Artifacts feeding synthesis: 240'),
        findsOneWidget);
    // Compact report: one tile per round, reverted badge on R2.
    expect(find.text('R0'), findsOneWidget);
    expect(find.text('R2'), findsOneWidget);
    expect(find.text('REVERTED'), findsOneWidget);
    expect(find.text('BEST'), findsOneWidget);
  });

  testWidgets('expanding a round tile shows labeled moves and stop log',
      (tester) async {
    await _pump(tester, _sessionWith(rounds));
    await tester.pumpAndSettle();

    await tester.tap(find.text('R1'));
    await tester.pumpAndSettle();

    expect(
        find.textContaining('set_forced_override '
            'LL_RADIO_TIMER_GetAbsoluteTime ← '
            '"Stateful increment (from 0)" (#18)'),
        findsOneWidget);
    expect(find.textContaining('0.9s → unhandled access at SystemInit'),
        findsWidgets);
  });

  testWidgets('renders nothing without a session', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        artifactLabelsProvider.overrideWith((ref) async => const {}),
      ],
      child: const MaterialApp(
        home: Scaffold(body: AutoTuneSessionView()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('AUTO-TUNE SESSION'), findsNothing);
  });

  test('trajectoryOffsets maps values onto the plot rect', () {
    const rounds = [
      TrajectoryRound(round: 0, fidelity: 0.0, coverage: 1.0),
      TrajectoryRound(round: 1, fidelity: 0.5, coverage: null),
      TrajectoryRound(round: 2, fidelity: 1.0, coverage: 0.5),
    ];
    const size = Size(100, 100);
    final fid = trajectoryOffsets(
        rounds: rounds, value: (r) => r.fidelity, size: size);
    expect(fid, const [
      Offset(0, 100), // 0.0 at round 0 → bottom-left
      Offset(50, 50), // 0.5 at round 1 → center
      Offset(100, 0), // 1.0 at round 2 → top-right
    ]);
    final cov = trajectoryOffsets(
        rounds: rounds, value: (r) => r.coverage, size: size);
    expect(cov[1], isNull); // null value → series gap
    expect(cov[2], const Offset(100, 50));

    // Fixed round budget: the axis spans 0..maxRound, so early rounds
    // sit at the left instead of stretching to fill the width.
    final fixed = trajectoryOffsets(
        rounds: rounds, value: (r) => r.fidelity, size: size, maxRound: 10);
    expect(fixed[1]!.dx, closeTo(10, 1e-9)); // round 1 of 10 → 10% across
    expect(fixed[2]!.dx, closeTo(20, 1e-9));
  });
}
