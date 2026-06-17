import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_ui/presentation/screens/synthesize/recommendation_applier.dart';
import 'package:emulator_ui/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RecommendationApplier.planBatch', () {
    test('orders clears → sets → preferences → cap', () {
      final batch = <Recommendation>[
        const SetPreference(
            rationale: 'try first', symbol: 'p1', artifactId: 9),
        const SetForcedOverride(
            rationale: 'pin', symbol: 's1', artifactId: 4),
        const AdjustIterationCap(rationale: 'more iters', newValue: 25),
        const ClearForcedOverride(rationale: 'unpin', symbol: 'c1'),
      ];
      final ordered = RecommendationApplier.planBatch(batch);
      expect(ordered, hasLength(4));
      expect(ordered[0], isA<ClearForcedOverride>());
      expect(ordered[1], isA<SetForcedOverride>());
      expect(ordered[2], isA<SetPreference>());
      expect(ordered[3], isA<AdjustIterationCap>());
    });

    test('drops GenerateCustomHook entries (orchestrator handles them)', () {
      final batch = <Recommendation>[
        const GenerateCustomHook(rationale: 'no match', symbol: 'mystery'),
        const SetPreference(
            rationale: 'try', symbol: 'p1', artifactId: 9),
      ];
      final ordered = RecommendationApplier.planBatch(batch);
      expect(ordered, hasLength(1));
      expect(ordered.first, isA<SetPreference>());
    });

    test('dedupes by symbol with last-write-wins', () {
      final batch = <Recommendation>[
        const ClearForcedOverride(rationale: 'r1', symbol: 's1'),
        const SetForcedOverride(
            rationale: 'r2', symbol: 's1', artifactId: 4),
        const SetForcedOverride(
            rationale: 'r3', symbol: 's1', artifactId: 7),
      ];
      final ordered = RecommendationApplier.planBatch(batch);
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
      final ordered = RecommendationApplier.planBatch(batch);
      expect(ordered, hasLength(1));
      expect((ordered.single as AdjustIterationCap).newValue, 30);
    });

    test('empty batch returns empty list', () {
      expect(RecommendationApplier.planBatch(const []), isEmpty);
    });
  });

  group('RecommendationApplier.apply', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });
    tearDown(() {
      container.dispose();
    });

    test('SetForcedOverride writes both overrides and scopes maps', () {
      const applier = RecommendationApplier();
      applier.apply(container, [
        const SetForcedOverride(
          rationale: 'pin',
          symbol: 'LL_RCC_HSE_IsReady',
          artifactId: 4,
          scope: 'HSE',
        ),
      ]);
      expect(container.read(hookOverridesProvider),
          equals({'LL_RCC_HSE_IsReady': 4}));
      expect(container.read(hookOverrideScopesProvider),
          equals({'LL_RCC_HSE_IsReady': 'HSE'}));
      expect(container.read(emulatorDirtyProvider), isTrue);
    });

    test('SetForcedOverride with null scope clears the scope entry', () {
      const applier = RecommendationApplier();
      // Seed an existing scope so we can verify it gets cleared.
      container.read(hookOverrideScopesProvider.notifier).state = {'s1': 'OLD'};
      applier.apply(container, [
        const SetForcedOverride(
          rationale: 'pin',
          symbol: 's1',
          artifactId: 4,
        ),
      ]);
      expect(container.read(hookOverridesProvider), equals({'s1': 4}));
      expect(container.read(hookOverrideScopesProvider),
          isNot(contains('s1')));
    });

    test('ClearForcedOverride removes from both maps', () {
      const applier = RecommendationApplier();
      container.read(hookOverridesProvider.notifier).state = {'s1': 4, 's2': 9};
      container.read(hookOverrideScopesProvider.notifier).state = {'s1': 'HSE'};
      applier.apply(container, [
        const ClearForcedOverride(rationale: 'unpin', symbol: 's1'),
      ]);
      expect(container.read(hookOverridesProvider), equals({'s2': 9}));
      expect(container.read(hookOverrideScopesProvider), isEmpty);
    });

    test('SetPreference writes hookPreferencesProvider', () {
      const applier = RecommendationApplier();
      applier.apply(container, [
        const SetPreference(rationale: 'try', symbol: 's1', artifactId: 12),
      ]);
      expect(container.read(hookPreferencesProvider), equals({'s1': 12}));
    });

    test('AdjustIterationCap writes synthesisMaxIterationsProvider', () {
      const applier = RecommendationApplier();
      expect(container.read(synthesisMaxIterationsProvider), 10);
      applier.apply(container, [
        const AdjustIterationCap(rationale: 'more', newValue: 25),
      ]);
      expect(container.read(synthesisMaxIterationsProvider), 25);
    });

    test('AdjustIterationCap with non-positive value is ignored', () {
      const applier = RecommendationApplier();
      container.read(synthesisMaxIterationsProvider.notifier).state = 10;
      applier.apply(container, [
        const AdjustIterationCap(rationale: 'bad', newValue: 0),
        const AdjustIterationCap(rationale: 'worse', newValue: -5),
      ]);
      expect(container.read(synthesisMaxIterationsProvider), 10);
    });

    test('GenerateCustomHook is silently dropped by apply', () {
      const applier = RecommendationApplier();
      final applied = applier.apply(container, [
        const GenerateCustomHook(rationale: 'no match', symbol: 'mystery'),
      ]);
      expect(applied, isEmpty);
      expect(container.read(hookOverridesProvider), isEmpty);
      expect(container.read(hookBindingsProvider), isEmpty);
    });

    test('dedupe applies only the last rec per symbol', () {
      const applier = RecommendationApplier();
      applier.apply(container, [
        const SetForcedOverride(rationale: 'a', symbol: 's1', artifactId: 4),
        const SetForcedOverride(rationale: 'b', symbol: 's1', artifactId: 7),
      ]);
      expect(container.read(hookOverridesProvider), equals({'s1': 7}));
    });

    test('full batch applies overrides, scopes, preferences, and cap', () {
      const applier = RecommendationApplier(roundNumber: 1);
      final applied = applier.apply(container, [
        const SetForcedOverride(
          rationale: 'pin',
          symbol: 's1',
          artifactId: 4,
          scope: 'HSE',
        ),
        const ClearForcedOverride(rationale: 'unpin', symbol: 's2'),
        const SetPreference(rationale: 'try', symbol: 's3', artifactId: 12),
        const AdjustIterationCap(rationale: 'more', newValue: 25),
      ]);
      expect(applied, hasLength(4));
      expect(container.read(hookOverridesProvider), equals({'s1': 4}));
      expect(container.read(hookOverrideScopesProvider), equals({'s1': 'HSE'}));
      expect(container.read(hookPreferencesProvider), equals({'s3': 12}));
      expect(container.read(synthesisMaxIterationsProvider), 25);
      expect(container.read(emulatorDirtyProvider), isTrue);
    });

    test('preserves existing overlay entries untouched by the batch', () {
      const applier = RecommendationApplier();
      container.read(hookOverridesProvider.notifier).state = {
        'existing': 1,
        's1': 2,
      };
      applier.apply(container, [
        const SetForcedOverride(
            rationale: 'pin', symbol: 's1', artifactId: 7),
      ]);
      // 'existing' survives; 's1' updated.
      expect(container.read(hookOverridesProvider),
          equals({'existing': 1, 's1': 7}));
    });
  });
}
