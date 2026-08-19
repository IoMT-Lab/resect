import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/orchestrator/recommendation_overlay_applier.dart';
import 'package:test/test.dart';

/// The one shared recommendation → overlay path (used by the engine on
/// both surfaces). Cases migrated from the UI's deleted
/// `RecommendationApplier` tests.
void main() {
  group('planRecommendationBatch', () {
    test('orders clears → sets → preferences → cap', () {
      final batch = <Recommendation>[
        const SetPreference(rationale: 'try first', symbol: 'p1', artifactId: 9),
        const SetForcedOverride(rationale: 'pin', symbol: 's1', artifactId: 4),
        const AdjustIterationCap(rationale: 'more iters', newValue: 25),
        const ClearForcedOverride(rationale: 'unpin', symbol: 'c1'),
      ];
      final ordered = planRecommendationBatch(batch);
      expect(ordered, hasLength(4));
      expect(ordered[0], isA<ClearForcedOverride>());
      expect(ordered[1], isA<SetForcedOverride>());
      expect(ordered[2], isA<SetPreference>());
      expect(ordered[3], isA<AdjustIterationCap>());
    });

    test('drops GenerateCustomHook entries (authored upstream)', () {
      final batch = <Recommendation>[
        const GenerateCustomHook(rationale: 'no match', symbol: 'mystery'),
        const SetPreference(rationale: 'try', symbol: 'p1', artifactId: 9),
      ];
      final ordered = planRecommendationBatch(batch);
      expect(ordered, hasLength(1));
      expect(ordered.first, isA<SetPreference>());
    });

    test('dedupes by symbol with last-write-wins', () {
      final batch = <Recommendation>[
        const ClearForcedOverride(rationale: 'r1', symbol: 's1'),
        const SetForcedOverride(rationale: 'r2', symbol: 's1', artifactId: 4),
        const SetForcedOverride(rationale: 'r3', symbol: 's1', artifactId: 7),
      ];
      final ordered = planRecommendationBatch(batch);
      expect(ordered, hasLength(1));
      final r = ordered.single as SetForcedOverride;
      expect(r.artifactId, 7); // last set wins
    });

    test('collapses multiple AdjustIterationCap to last one', () {
      final batch = <Recommendation>[
        const AdjustIterationCap(rationale: 'r1', newValue: 5),
        const AdjustIterationCap(rationale: 'r2', newValue: 15),
        const AdjustIterationCap(rationale: 'r3', newValue: 30),
      ];
      final ordered = planRecommendationBatch(batch);
      expect(ordered, hasLength(1));
      expect((ordered.single as AdjustIterationCap).newValue, 30);
    });

    test('empty batch returns empty list', () {
      expect(planRecommendationBatch(const []), isEmpty);
    });
  });

  group('applyRecommendationsToOverlays', () {
    test('SetForcedOverride writes both overrides and scopes maps', () {
      final overrides = <String, int>{};
      final scopes = <String, String>{};
      applyRecommendationsToOverlays(
        recommendations: [
          const SetForcedOverride(
            rationale: 'pin',
            symbol: 'LL_RCC_HSE_IsReady',
            artifactId: 4,
            scope: 'HSE',
          ),
        ],
        hookOverrides: overrides,
        hookOverrideScopes: scopes,
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(overrides, {'LL_RCC_HSE_IsReady': 4});
      expect(scopes, {'LL_RCC_HSE_IsReady': 'HSE'});
    });

    test('SetForcedOverride with null scope clears the scope entry', () {
      final overrides = <String, int>{};
      final scopes = <String, String>{'s1': 'OLD'};
      applyRecommendationsToOverlays(
        recommendations: [
          const SetForcedOverride(rationale: 'pin', symbol: 's1', artifactId: 4),
        ],
        hookOverrides: overrides,
        hookOverrideScopes: scopes,
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(overrides, {'s1': 4});
      expect(scopes, isNot(contains('s1')));
    });

    test('ClearForcedOverride removes from both maps', () {
      final overrides = <String, int>{'s1': 4, 's2': 9};
      final scopes = <String, String>{'s1': 'HSE'};
      applyRecommendationsToOverlays(
        recommendations: [
          const ClearForcedOverride(rationale: 'unpin', symbol: 's1'),
        ],
        hookOverrides: overrides,
        hookOverrideScopes: scopes,
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(overrides, {'s2': 9});
      expect(scopes, isEmpty);
    });

    test('SetPreference writes the preferences map', () {
      final prefs = <String, int>{};
      applyRecommendationsToOverlays(
        recommendations: [
          const SetPreference(rationale: 'try', symbol: 's1', artifactId: 12),
        ],
        hookOverrides: {},
        hookOverrideScopes: {},
        hookPreferences: prefs,
        iterationCap: 10,
      );
      expect(prefs, {'s1': 12});
    });

    test('AdjustIterationCap returns the new cap', () {
      final result = applyRecommendationsToOverlays(
        recommendations: [
          const AdjustIterationCap(rationale: 'more', newValue: 25),
        ],
        hookOverrides: {},
        hookOverrideScopes: {},
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(result.iterationCap, 25);
    });

    test('AdjustIterationCap with non-positive value is ignored', () {
      final result = applyRecommendationsToOverlays(
        recommendations: [
          const AdjustIterationCap(rationale: 'bad', newValue: 0),
          const AdjustIterationCap(rationale: 'worse', newValue: -5),
        ],
        hookOverrides: {},
        hookOverrideScopes: {},
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(result.iterationCap, 10);
    });

    test('GenerateCustomHook is silently dropped', () {
      final overrides = <String, int>{};
      final result = applyRecommendationsToOverlays(
        recommendations: [
          const GenerateCustomHook(rationale: 'no match', symbol: 'mystery'),
        ],
        hookOverrides: overrides,
        hookOverrideScopes: {},
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(result.applied, isEmpty);
      expect(overrides, isEmpty);
    });

    test('dedupe applies only the last rec per symbol', () {
      final overrides = <String, int>{};
      applyRecommendationsToOverlays(
        recommendations: [
          const SetForcedOverride(rationale: 'a', symbol: 's1', artifactId: 4),
          const SetForcedOverride(rationale: 'b', symbol: 's1', artifactId: 7),
        ],
        hookOverrides: overrides,
        hookOverrideScopes: {},
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(overrides, {'s1': 7});
    });

    test('full batch applies overrides, scopes, preferences, and cap', () {
      final overrides = <String, int>{};
      final scopes = <String, String>{};
      final prefs = <String, int>{};
      final result = applyRecommendationsToOverlays(
        recommendations: [
          const SetForcedOverride(
              rationale: 'pin', symbol: 's1', artifactId: 4, scope: 'HSE'),
          const ClearForcedOverride(rationale: 'unpin', symbol: 's2'),
          const SetPreference(rationale: 'try', symbol: 's3', artifactId: 12),
          const AdjustIterationCap(rationale: 'more', newValue: 25),
        ],
        hookOverrides: overrides,
        hookOverrideScopes: scopes,
        hookPreferences: prefs,
        iterationCap: 10,
      );
      expect(result.applied, hasLength(4));
      expect(overrides, {'s1': 4});
      expect(scopes, {'s1': 'HSE'});
      expect(prefs, {'s3': 12});
      expect(result.iterationCap, 25);
    });

    test('preserves existing overlay entries untouched by the batch', () {
      final overrides = <String, int>{'existing': 1, 's1': 2};
      applyRecommendationsToOverlays(
        recommendations: [
          const SetForcedOverride(rationale: 'pin', symbol: 's1', artifactId: 7),
        ],
        hookOverrides: overrides,
        hookOverrideScopes: {},
        hookPreferences: {},
        iterationCap: 10,
      );
      expect(overrides, {'existing': 1, 's1': 7});
    });
  });
}
