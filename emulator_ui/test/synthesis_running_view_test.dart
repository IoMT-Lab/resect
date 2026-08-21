import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_ui/presentation/screens/synthesize/widgets/synthesis_console.dart';
import 'package:emulator_ui/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The running view's ring must distinguish the two phases: the 30s
/// emulation observation window (countdown) vs the on-demand LLM hook
/// generation, during which emulation is paused and a countdown running
/// to zero is a lie — it shows an elapsed timer instead.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required SynthesisProgress progress,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        synthesisProgressProvider.overrideWith((ref) => progress),
        currentEmulatorProvider
            .overrideWith((ref) => Emulator.create(name: 'p')),
      ],
      child: const MaterialApp(home: Scaffold(body: SynthesisConsole())),
    ));
    // One frame only — the view holds spinners, so pumpAndSettle would
    // never settle.
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('emulating phase shows the 30s countdown', (tester) async {
    await pump(
      tester,
      progress: SynthesisProgress(
        countdownStart: DateTime.now(),
        status: 'Iteration 3',
        iteration: 3,
      ),
    );
    // A fresh countdownStart → the ring text is a near-30s value.
    expect(find.textContaining(RegExp(r'^(30|29)s$')), findsOneWidget);
    expect(find.text('LLM authoring hook — emulation paused'), findsNothing);
  });

  testWidgets('llmActive swaps the countdown for an elapsed timer',
      (tester) async {
    await pump(
      tester,
      progress: SynthesisProgress(
        // Started 95s ago — a countdown would have hit 0s long ago.
        countdownStart: DateTime.now().subtract(const Duration(seconds: 95)),
        status: 'LLM generating: uart_rx_getc (gemma4:e4b)',
        llmActive: true,
      ),
    );
    expect(find.text('LLM authoring hook — emulation paused'), findsOneWidget);
    // Elapsed, counting UP (1m 35s ±1s of test slop), not a dead 0s.
    expect(find.textContaining(RegExp(r'^1m 3[456]s$')), findsOneWidget);
    expect(find.text('0s'), findsNothing);
    expect(find.text('LLM generating: uart_rx_getc (gemma4:e4b)'),
        findsOneWidget);
  });
}
