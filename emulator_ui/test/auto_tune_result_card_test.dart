import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_ui/presentation/screens/synthesize/widgets/synthesis_console.dart';
import 'package:emulator_ui/providers/app_providers.dart';
import 'package:emulator_ui/providers/auto_tune_session_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The auto-tune result card: replaces the misleading "SYNTHESIS
/// COMPLETE" banner with "ROUND N OF M — …" during a session.
void main() {
  AutoTuneSessionNotifier session({int rounds = 1, int? maxRounds}) {
    final n = AutoTuneSessionNotifier()
      ..beginLive('/tmp/reports', maxRounds: maxRounds);
    for (var r = 0; r < rounds; r++) {
      n.addRound(AutoTuneSessionRoundRecord(
        round: r,
        manifest: SynthesisManifest(
          manifestVersion: 2,
          elfHash: 'a' * 64,
          elfFileName: 'f.elf',
          synthesizerRunId: 'run-$r',
          result: const ManifestRunResult(
              success: true, totalIterations: 1, durationSeconds: 1),
          decisions: const [],
        ),
        snapshot: null,
      ));
    }
    return n;
  }

  Future<void> pump(
    WidgetTester tester, {
    required SynthesisProgress progress,
    required AutoTuneSessionNotifier notifier,
  }) =>
      tester.pumpWidget(ProviderScope(
        overrides: [
          autoTuneSessionProvider.overrideWith((ref) => notifier),
          synthesisProgressProvider.overrideWith((ref) => progress),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AutoTuneResultCard()),
          ),
        ),
      ));

  testWidgets('complete round is titled ROUND N OF M', (tester) async {
    await pump(
      tester,
      progress: SynthesisProgress(
        countdownStart: DateTime(2026),
        complete: true,
        success: true,
        status: 'Complete — 6 hooks',
      ),
      notifier: session(rounds: 2, maxRounds: 5),
    );
    expect(find.text('ROUND 1 OF 5 — COMPLETE'), findsOneWidget);
    expect(find.textContaining('SYNTHESIS COMPLETE'), findsNothing);
  });

  testWidgets('running round is titled SYNTHESIZING with the next round',
      (tester) async {
    await pump(
      tester,
      progress: SynthesisProgress(
        countdownStart: DateTime(2026),
        iteration: 4,
        hooksApplied: 2,
        currentSymbol: 'uart_rx_getc',
      ),
      notifier: session(rounds: 1, maxRounds: 5),
    );
    expect(find.text('ROUND 1 OF 5 — SYNTHESIZING…'), findsOneWidget);
    expect(find.textContaining('iteration 4'), findsOneWidget);
    expect(find.textContaining('uart_rx_getc'), findsOneWidget);
  });

  testWidgets('no round budget drops the OF M suffix', (tester) async {
    await pump(
      tester,
      progress: SynthesisProgress(
        countdownStart: DateTime(2026),
        complete: true,
        success: false,
        status: 'Failed at HAL_Init',
      ),
      notifier: session(rounds: 1),
    );
    expect(find.text('ROUND 0 — FAILED'), findsOneWidget);
  });
}
