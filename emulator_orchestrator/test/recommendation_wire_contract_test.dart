import 'dart:convert';

import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/orchestrator/recommendation_overlay_applier.dart';
import 'package:test/test.dart';

/// Locks the wire contract between the LLM's literal JSON output and
/// the overlay maps the next synthesis run reads. The LLM-emitted
/// shape was captured verbatim from a real `gemma4:e4b` response;
/// the test asserts that string parses → applies → produces the
/// expected overlay state.
///
/// If the LLM's contract changes shape (e.g. someone renames
/// `artifact_id` → `artifactId`) this test catches the regression at
/// the seam — before auto-tune silently no-ops on every round.
void main() {
  group('Recommendation wire contract (LLM JSON → applier → overlays)', () {
    List<Recommendation> parse(String json) {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return (decoded['recommendations'] as List<dynamic>)
          .map((e) => Recommendation.fromJson(e as Map<String, dynamic>))
          .whereType<Recommendation>()
          .toList();
    }

    test(
        'literal LLM JSON for set_forced_override lands in overrides '
        '+ scopes', () {
      // Verbatim shape from a real gemma4:e4b run. Snake_case
      // `artifact_id` is the contract — the Recommendation.fromJson
      // dispatch table expects it.
      const llmEmittedJson =
          '{"prose":"summary","recommendations":[{"kind":"set_forced_override","rationale":"Forcing LL_RCC_HSE_IsReady to always report success simulates a stable external oscillator.","symbol":"LL_RCC_HSE_IsReady","artifact_id":4,"scope":"HSE"}]}';

      final recs = parse(llmEmittedJson);
      expect(recs, hasLength(1));
      final sfo = recs.single as SetForcedOverride;
      expect(sfo.symbol, 'LL_RCC_HSE_IsReady');
      expect(sfo.artifactId, 4);
      expect(sfo.scope, 'HSE');

      final overrides = <String, int>{};
      final scopes = <String, String>{};
      applyRecommendationsToOverlays(
        recommendations: recs,
        hookOverrides: overrides,
        hookOverrideScopes: scopes,
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(overrides, {'LL_RCC_HSE_IsReady': 4});
      expect(scopes, {'LL_RCC_HSE_IsReady': 'HSE'});
    });

    test(
        'set_forced_override without scope clears the scope map slot '
        '(no orphan scope from a prior round)', () {
      const llmEmittedJson =
          '{"recommendations":[{"kind":"set_forced_override","rationale":"r","symbol":"sym","artifact_id":7}]}';
      final overrides = <String, int>{};
      final scopes = <String, String>{'sym': 'STALE_SCOPE'};
      applyRecommendationsToOverlays(
        recommendations: parse(llmEmittedJson),
        hookOverrides: overrides,
        hookOverrideScopes: scopes,
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(overrides, {'sym': 7});
      expect(scopes.containsKey('sym'), isFalse);
    });

    test(
        'multiple recommendations in one batch all land on their '
        'respective symbols', () {
      const llmEmittedJson = '''
{
  "prose": "stabilize the clock init path",
  "recommendations": [
    {"kind":"set_forced_override","rationale":"return 1 for HSE","symbol":"LL_RCC_HSE_IsReady","artifact_id":4,"scope":"HSE"},
    {"kind":"set_forced_override","rationale":"return 1 for LSI","symbol":"LL_RCC_LSI_IsReady","artifact_id":4,"scope":"LSI"},
    {"kind":"set_preference","rationale":"prefer this binding","symbol":"LL_RCC_HSE_Enable","artifact_id":9}
  ]
}''';
      final recs = parse(llmEmittedJson);
      expect(recs, hasLength(3));

      final overrides = <String, int>{};
      final scopes = <String, String>{};
      final prefs = <String, int>{};
      applyRecommendationsToOverlays(
        recommendations: recs,
        hookOverrides: overrides,
        hookOverrideScopes: scopes,
        hookPreferences: prefs,
        iterationCap: 10,
      );
      expect(overrides,
          {'LL_RCC_HSE_IsReady': 4, 'LL_RCC_LSI_IsReady': 4});
      expect(scopes,
          {'LL_RCC_HSE_IsReady': 'HSE', 'LL_RCC_LSI_IsReady': 'LSI'});
      expect(prefs, {'LL_RCC_HSE_Enable': 9});
    });
  });
}
