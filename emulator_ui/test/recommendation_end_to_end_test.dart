import 'dart:convert';

import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_ui/presentation/screens/synthesize/recommendation_applier.dart';
import 'package:emulator_ui/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Locks the wire contract between the LLM's literal JSON output
/// and the providers that the next synthesis run reads from. The
/// LLM-emitted shape was captured verbatim from a real
/// `gemma4:e4b` response (see prior runtime test transcript in
/// session notes); the test asserts that string parses → applies
/// → produces the expected provider state.
///
/// If the LLM's contract changes shape (e.g. someone renames
/// `artifact_id` → `artifactId`) this test catches the regression
/// at the seam — before the auto-tune flow silently no-ops on
/// every round.
void main() {
  group('Recommendation end-to-end (LLM JSON → applier → providers)',
      () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test(
        'literal LLM JSON for set_forced_override lands in hookOverrides '
        '+ hookOverrideScopes', () {
      // Verbatim shape from a real gemma4:e4b run (see prior session
      // logs). Snake_case `artifact_id` is the contract — the
      // Recommendation.fromJson dispatch table expects it.
      const llmEmittedJson =
          '{"prose":"summary","recommendations":[{"kind":"set_forced_override","rationale":"Forcing LL_RCC_HSE_IsReady to always report success simulates a stable external oscillator.","symbol":"LL_RCC_HSE_IsReady","artifact_id":4,"scope":"HSE"}]}';

      final decoded = jsonDecode(llmEmittedJson) as Map<String, dynamic>;
      final recs = (decoded['recommendations'] as List<dynamic>)
          .map((e) => Recommendation.fromJson(e as Map<String, dynamic>))
          .whereType<Recommendation>()
          .toList();

      expect(recs, hasLength(1));
      final rec = recs.single;
      expect(rec, isA<SetForcedOverride>());
      final sfo = rec as SetForcedOverride;
      expect(sfo.symbol, 'LL_RCC_HSE_IsReady');
      expect(sfo.artifactId, 4);
      expect(sfo.scope, 'HSE');

      const applier = RecommendationApplier();
      applier.apply(container, recs);

      expect(container.read(hookOverridesProvider),
          equals({'LL_RCC_HSE_IsReady': 4}));
      expect(container.read(hookOverrideScopesProvider),
          equals({'LL_RCC_HSE_IsReady': 'HSE'}));
    });

    test(
        'set_forced_override without scope clears the scope map slot '
        '(no orphan scope from a prior round)', () {
      // Pre-populate a stale scope so we can verify the apply
      // clears it when the new recommendation omits scope.
      container.read(hookOverrideScopesProvider.notifier).state = {
        'sym': 'STALE_SCOPE',
      };
      const llmEmittedJson =
          '{"recommendations":[{"kind":"set_forced_override","rationale":"r","symbol":"sym","artifact_id":7}]}';
      final decoded = jsonDecode(llmEmittedJson) as Map<String, dynamic>;
      final recs = (decoded['recommendations'] as List<dynamic>)
          .map((e) => Recommendation.fromJson(e as Map<String, dynamic>))
          .whereType<Recommendation>()
          .toList();

      const applier = RecommendationApplier();
      applier.apply(container, recs);

      expect(container.read(hookOverridesProvider), equals({'sym': 7}));
      // No scope key for sym — the applier removed the stale entry.
      expect(container.read(hookOverrideScopesProvider).containsKey('sym'),
          isFalse);
    });

    test(
        'multiple recommendations in one batch all land on their respective '
        'symbols', () {
      const llmEmittedJson = '''
{
  "prose": "stabilize the clock init path",
  "recommendations": [
    {"kind":"set_forced_override","rationale":"return 1 for HSE","symbol":"LL_RCC_HSE_IsReady","artifact_id":4,"scope":"HSE"},
    {"kind":"set_forced_override","rationale":"return 1 for LSI","symbol":"LL_RCC_LSI_IsReady","artifact_id":4,"scope":"LSI"},
    {"kind":"set_preference","rationale":"prefer this binding","symbol":"LL_RCC_HSE_Enable","artifact_id":9}
  ]
}''';
      final decoded = jsonDecode(llmEmittedJson) as Map<String, dynamic>;
      final recs = (decoded['recommendations'] as List<dynamic>)
          .map((e) => Recommendation.fromJson(e as Map<String, dynamic>))
          .whereType<Recommendation>()
          .toList();
      expect(recs, hasLength(3));

      const applier = RecommendationApplier();
      applier.apply(container, recs);

      expect(
          container.read(hookOverridesProvider),
          equals({
            'LL_RCC_HSE_IsReady': 4,
            'LL_RCC_LSI_IsReady': 4,
          }));
      expect(
          container.read(hookOverrideScopesProvider),
          equals({
            'LL_RCC_HSE_IsReady': 'HSE',
            'LL_RCC_LSI_IsReady': 'LSI',
          }));
      expect(
          container.read(hookPreferencesProvider),
          equals({'LL_RCC_HSE_Enable': 9}));
    });
  });
}
