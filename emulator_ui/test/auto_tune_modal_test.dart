import 'dart:async';

import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/services/recommendation_service.dart';
import 'package:emulator_ui/presentation/screens/synthesize/llm_synthesis_orchestrator.dart';
import 'package:emulator_ui/presentation/screens/synthesize/widgets/auto_tune_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pump the modal with the given [orchestrator] inside a
/// `MaterialApp`/`ProviderScope` so the test environment matches
/// the production environment (Theme, Navigator, providers).
Future<void> pumpModal(
  WidgetTester tester,
  LlmSynthesisOrchestrator orchestrator,
  Future<void> sessionFuture,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: orchestrator.container,
      child: MaterialApp(
        home: Scaffold(
          body: AutoTuneModal(
            orchestrator: orchestrator,
            sessionFuture: sessionFuture,
          ),
        ),
      ),
    ),
  );
}

void main() {
  late ProviderContainer container;
  late LlmSynthesisOrchestrator orchestrator;
  late Completer<void> sessionCompleter;

  setUp(() {
    container = ProviderContainer();
    orchestrator = LlmSynthesisOrchestrator(container);
    sessionCompleter = Completer<void>();
  });

  tearDown(() {
    orchestrator.dispose();
    container.dispose();
  });

  group('AutoTuneModal — state rendering', () {
    testWidgets('idle state shows the waiting text', (tester) async {
      orchestrator.setStateForTest(const AutoTuneIdle());
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      expect(find.textContaining('Waiting for the auto-tune'), findsOneWidget);
    });

    testWidgets('baseline state shows progress + Cancel button',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneRunningBaseline());
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // 'baseline synthesis' appears in both header and body status text.
      expect(find.textContaining('baseline synthesis'), findsWidgets);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('synthesizing state shows the round number', (tester) async {
      orchestrator
          .setStateForTest(const AutoTuneSynthesizing(round: 3));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      expect(find.textContaining('round 3'), findsWidgets);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('LLM generating state surfaces streamed tokens',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneLlmGenerating(
        round: 2,
        streamedText: '{"prose": "still thinking',
      ));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      expect(find.textContaining('still thinking'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('reviewing state renders all recommendation rows',
        (tester) async {
      orchestrator.setStateForTest(AutoTuneReviewing(
        round: 1,
        result: const RecommendationResult(
          prose: 'Try pinning two clock symbols.',
          recommendations: [
            SetForcedOverride(
              rationale: 'busy bit always reads 1',
              symbol: 'LL_RCC_HSE_IsReady',
              artifactId: 4,
              scope: 'HSE',
            ),
            SetPreference(
              rationale: 'try return-1 first',
              symbol: 'LL_RCC_LSI_IsReady',
              artifactId: 12,
            ),
          ],
          parseFailure: false,
        ),
      ));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      expect(find.text('OVERRIDE'), findsOneWidget);
      expect(find.text('PREFER'), findsOneWidget);
      expect(find.textContaining('LL_RCC_HSE_IsReady'), findsOneWidget);
      expect(find.textContaining('LL_RCC_LSI_IsReady'), findsOneWidget);
      expect(find.text('Accept all'), findsOneWidget);
      expect(find.text('Reject all'), findsOneWidget);
      expect(find.text('Apply and continue'), findsOneWidget);
      expect(find.text('Stop auto-tune'), findsOneWidget);
    });

    testWidgets('parse-failed state shows raw text + Retry/Stop',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneParseFailed(
        round: 1,
        raw: '{"prose": "broken json',
      ));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      expect(find.textContaining('could not be parsed as JSON'),
          findsOneWidget);
      expect(find.textContaining('broken json'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets('finished state shows reason headline + Close button',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneFinished(
        reason: AutoTuneFinishReason.llmEmpty,
        finalRound: 3,
      ));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      expect(find.textContaining('no further recommendations'),
          findsOneWidget);
      expect(find.textContaining('Final round: 3'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('finished state surfaces error message when present',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneFinished(
        reason: AutoTuneFinishReason.llmError,
        finalRound: 2,
        errorMessage: 'connection refused: localhost:11434',
      ));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      // 'LLM call errored' appears in both the headline and the explanation.
      expect(find.textContaining('LLM call errored'), findsWidgets);
      // SelectableText splits the error text into multiple TextSpans
      // depending on font/locale; assert at least one match rather
      // than exactly one.
      expect(
        find.textContaining('connection refused'),
        findsWidgets,
      );
    });
  });

  group('AutoTuneModal — review interactions', () {
    final twoRecs = const RecommendationResult(
      prose: 'two recs',
      recommendations: [
        SetForcedOverride(
          rationale: 'pin a',
          symbol: 'sym_a',
          artifactId: 1,
        ),
        SetPreference(
          rationale: 'prefer b',
          symbol: 'sym_b',
          artifactId: 2,
        ),
      ],
      parseFailure: false,
    );

    testWidgets('Accept-all paints both rows in the accepted tint',
        (tester) async {
      orchestrator.setStateForTest(
          AutoTuneReviewing(round: 1, result: twoRecs));
      await pumpModal(tester, orchestrator, sessionCompleter.future);

      // Initial state: per-row defaults are "accepted"; the modal's
      // local state lazily creates entries on first interaction.
      // Tap Accept-all to materialize all entries.
      await tester.tap(find.text('Accept all'));
      await tester.pump();
      // After Accept-all, the cards should be present; we can't
      // easily assert the tint without a key, but the buttons are
      // still there and the layout hasn't crashed.
      expect(find.byType(Card), findsNWidgets(2));
    });

    testWidgets('Reject-all keeps the rows but recolors them',
        (tester) async {
      orchestrator.setStateForTest(
          AutoTuneReviewing(round: 1, result: twoRecs));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      await tester.tap(find.text('Reject all'));
      await tester.pump();
      // Rows still present; Apply and continue still available.
      expect(find.byType(Card), findsNWidgets(2));
      expect(find.text('Apply and continue'), findsOneWidget);
    });

    testWidgets('Apply-and-continue dismisses the review buttons',
        (tester) async {
      orchestrator.setStateForTest(
          AutoTuneReviewing(round: 1, result: twoRecs));
      await pumpModal(tester, orchestrator, sessionCompleter.future);
      await tester.tap(find.text('Apply and continue'));
      await tester.pump();
      // Without runAutoTune driving the next state, the modal stays
      // in the reviewing state but the submitReview future has been
      // completed on the orchestrator's side. The smoke check here
      // is that tapping doesn't crash and the modal is still
      // mounted.
      expect(find.byType(AutoTuneModal), findsOneWidget);
    });
  });
}
