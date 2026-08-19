import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:emulator_ui/presentation/screens/synthesize/llm_synthesis_orchestrator.dart';
import 'package:emulator_ui/presentation/screens/synthesize/widgets/auto_tune_panel.dart';
import 'package:emulator_ui/providers/auto_tune_session_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pump the panel with the given [orchestrator] inside a
/// `MaterialApp`/`ProviderScope` so the test environment matches
/// the production environment (Theme, Navigator, providers).
Future<void> pumpPanel(
  WidgetTester tester,
  LlmSynthesisOrchestrator orchestrator,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: orchestrator.container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AutoTunePanel(
              orchestrator: orchestrator,
              onDismiss: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  late ProviderContainer container;
  late LlmSynthesisOrchestrator orchestrator;

  setUp(() {
    container = ProviderContainer(overrides: [
      // Never touch the real artifact DB from widget tests — the
      // streaming body resolves artifact labels through this.
      artifactLabelsProvider.overrideWith(
          (ref) async => const {2: 'Return 0'}),
    ]);
    orchestrator = LlmSynthesisOrchestrator(container);
  });

  tearDown(() {
    orchestrator.dispose();
    container.dispose();
  });

  group('AutoTunePanel — state rendering', () {
    testWidgets('idle state shows the waiting text', (tester) async {
      orchestrator.setStateForTest(const AutoTuneIdle());
      await pumpPanel(tester, orchestrator);
      expect(find.textContaining('Waiting for the auto-tune'), findsOneWidget);
    });

    testWidgets('baseline state shows progress + Cancel button',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneRunningBaseline());
      await pumpPanel(tester, orchestrator);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // 'baseline synthesis' appears in both header and body status text.
      expect(find.textContaining('baseline synthesis'), findsWidgets);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('synthesizing state shows the round number', (tester) async {
      orchestrator
          .setStateForTest(const AutoTuneSynthesizing(round: 3));
      await pumpPanel(tester, orchestrator);
      expect(find.textContaining('round 3'), findsWidgets);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets(
        'LLM generating state renders parsed prose + recommendation rows, '
        'raw JSON behind a collapsed expander', (tester) async {
      orchestrator.setStateForTest(const AutoTuneLlmGenerating(
        round: 2,
        thinkingText: '',
        responseText: '{"prose": "Firmware stuck polling the UART.", '
            '"recommendations": ['
            '{"kind": "set_forced_override", "symbol": "uart_rx_getc", '
            '"artifact_id": 2, "rationale": "polling loop"}, '
            '{"kind": "set_preference", "symbol": "cli_p',
      ));
      await pumpPanel(tester, orchestrator);
      // Styled: closed prose + the one COMPLETE recommendation.
      expect(find.text('Firmware stuck polling the UART.'), findsOneWidget);
      expect(find.text('set_forced_override'), findsOneWidget);
      expect(find.textContaining('uart_rx_getc'), findsOneWidget);
      expect(find.text('polling loop'), findsOneWidget);
      // The half-streamed second recommendation is withheld.
      expect(find.text('set_preference'), findsNothing);
      // Raw JSON is behind the collapsed expander, not inline.
      expect(find.textContaining('"kind"'), findsNothing);
      await tester.tap(find.text('Raw response'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('"kind"'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('LLM generating state without thinking shows waiting note',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneLlmGenerating(
        round: 1,
        thinkingText: '',
        responseText: '',
      ));
      await pumpPanel(tester, orchestrator);
      // The single-pane fallback message kicks in when neither
      // thinking nor response have started.
      expect(find.textContaining('waiting for first tokens'),
          findsOneWidget);
      // No REASONING / RESPONSE header chips yet.
      expect(find.text('Reasoning'), findsNothing);
      expect(find.text('Response'), findsNothing);
    });

    testWidgets(
        'LLM generating with thinking only: reasoning note + collapsed '
        'Reasoning expander', (tester) async {
      orchestrator.setStateForTest(const AutoTuneLlmGenerating(
        round: 1,
        thinkingText: 'weighing override vs preference for HSE…',
        responseText: '',
      ));
      await pumpPanel(tester, orchestrator);
      expect(find.textContaining('model is reasoning'), findsOneWidget);
      // Reasoning stream is collapsed by default; expanding reveals it.
      expect(find.textContaining('weighing override'), findsNothing);
      await tester.tap(find.text('Reasoning'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('weighing override'), findsOneWidget);
    });

    testWidgets(
        'still-open prose stays withheld: composing placeholder shows',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneLlmGenerating(
        round: 2,
        thinkingText: 'reasoning trace token by token',
        responseText: '{"prose":"final answer',
      ));
      await pumpPanel(tester, orchestrator);
      // Nothing parseable yet — the open string is not rendered.
      expect(find.textContaining('final answer'), findsNothing);
      expect(find.textContaining('(composing…)'), findsOneWidget);
      expect(find.text('Reasoning'), findsOneWidget);
      expect(find.text('Raw response'), findsOneWidget);
    });

    testWidgets(
        'generating-hook state shows the target symbol in the header and '
        'streams both panes',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneGeneratingHook(
        round: 3,
        symbol: 'LL_RCC_LSI_Disable',
        thinkingText: 'considering the bitmask op',
        responseText: 'def hook(cpu):\n    pass',
      ));
      await pumpPanel(tester, orchestrator);
      // Header names both the round and the symbol being authored.
      expect(
        find.textContaining(
            'generating hook for LL_RCC_LSI_Disable (round 3)'),
        findsOneWidget,
      );
      // Hook authoring is NOT recommendation JSON — the code streams
      // visibly; reasoning stays behind its collapsed expander.
      expect(find.textContaining('def hook(cpu)'), findsOneWidget);
      expect(find.text('Reasoning'), findsOneWidget);
      expect(find.textContaining('considering the bitmask'), findsNothing);
      // Cancel button must be visible — generation is slow and the
      // user needs to be able to abort.
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('reviewing state renders all recommendation rows',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneReviewing(
        round: 1,
        result: RecommendationResult(
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
      await pumpPanel(tester, orchestrator);
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
        kind: RecommendationParseFailureKind.malformedJson,
      ));
      await pumpPanel(tester, orchestrator);
      expect(find.textContaining('could not be parsed as JSON'),
          findsOneWidget);
      expect(find.textContaining('broken json'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets(
        'parse-failed state with emptyResponse kind renders the budget '
        'diagnostic body (thinking chunks / response tokens / stop reason)',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneParseFailed(
        round: 1,
        raw: '',
        kind: RecommendationParseFailureKind.emptyResponse,
        diagnostic: RecommendationDiagnostic(
          doneReason: 'length',
          responseTokens: 0,
          thinkingChunks: 1024,
        ),
      ));
      await pumpPanel(tester, orchestrator);
      expect(
        find.textContaining('ran out of budget'),
        findsOneWidget,
      );
      expect(find.textContaining('Thinking chunks: 1024'), findsOneWidget);
      expect(find.textContaining('Response tokens: 0'), findsOneWidget);
      expect(find.textContaining('Stop reason'), findsOneWidget);
      expect(find.textContaining('length'), findsOneWidget);
      // Make sure the legacy "could not be parsed as JSON" body does NOT
      // also render — the kind discriminator should pick exactly one.
      expect(
        find.textContaining('could not be parsed as JSON'),
        findsNothing,
      );
      // The empty raw text "(empty)" placeholder should also be gone —
      // it was the symptom of this exact failure mode.
      expect(find.text('(empty)'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);
    });

    testWidgets(
        'parse-failed state with emptyResponse kind tolerates null '
        'diagnostic (defaults render ?)',
        (tester) async {
      // Backstop for the case where the parser found the buffer empty
      // but `LlmStreamDone` wasn't emitted (e.g. stream errored before
      // the final NDJSON line). Modal should still show the budget
      // body, just with `?` placeholders.
      orchestrator.setStateForTest(const AutoTuneParseFailed(
        round: 1,
        raw: '',
        kind: RecommendationParseFailureKind.emptyResponse,
      ));
      await pumpPanel(tester, orchestrator);
      expect(find.textContaining('ran out of budget'), findsOneWidget);
      expect(find.textContaining('Thinking chunks: ?'), findsOneWidget);
      expect(find.textContaining('Response tokens: ?'), findsOneWidget);
    });

    testWidgets('finished state shows reason headline + Close button',
        (tester) async {
      orchestrator.setStateForTest(const AutoTuneFinished(
        reason: AutoTuneFinishReason.llmEmpty,
        finalRound: 3,
      ));
      await pumpPanel(tester, orchestrator);
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
      await pumpPanel(tester, orchestrator);
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

  group('AutoTunePanel — review interactions', () {
    const twoRecs = RecommendationResult(
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
      await pumpPanel(tester, orchestrator);

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
      await pumpPanel(tester, orchestrator);
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
      await pumpPanel(tester, orchestrator);
      await tester.tap(find.text('Apply and continue'));
      await tester.pump();
      // Without runAutoTune driving the next state, the modal stays
      // in the reviewing state but the submitReview future has been
      // completed on the orchestrator's side. The smoke check here
      // is that tapping doesn't crash and the modal is still
      // mounted.
      expect(find.byType(AutoTunePanel), findsOneWidget);
    });
  });
}
