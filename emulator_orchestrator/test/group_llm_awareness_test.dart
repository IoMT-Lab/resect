import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/symbol_group.dart';
import 'package:emulator_orchestrator/orchestrator/recommendation_overlay_applier.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';
import 'package:emulator_orchestrator/orchestrator/workflows/synthesizer_workflow.dart';
import 'package:test/test.dart';

void main() {
  final catalog = HookCatalog.system();
  final classifier = SymbolGroupClassifier(catalog: catalog);
  final lsi = classifier.classify([
    'LL_RCC_LSI_Enable',
    'LL_RCC_LSI_Disable',
    'LL_RCC_LSI_IsReady',
  ]);
  final groupOf = <String, SymbolGroup>{
    for (final g in lsi)
      for (final m in g.members.keys) m: g,
  };

  group('group recommendation JSON round-trip', () {
    test('set_group_override', () {
      final r = SetGroupOverride(rationale: 'force the clock', scope: 'LL_RCC_LSI');
      final back = Recommendation.fromJson(r.toJson());
      expect(back, isA<SetGroupOverride>());
      expect((back as SetGroupOverride).scope, 'LL_RCC_LSI');
      expect(r.kind, 'set_group_override');
    });

    test('clear_group_override', () {
      final r = ClearGroupOverride(rationale: 'wrong for this object', scope: 'LL_RCC_LSI');
      final back = Recommendation.fromJson(r.toJson());
      expect(back, isA<ClearGroupOverride>());
      expect((back as ClearGroupOverride).scope, 'LL_RCC_LSI');
    });
  });

  group('applier maps group actions to groupOverrides', () {
    test('force and suppress, deduped by scope (last wins)', () {
      final groupOverrides = <String, GroupOverrideState>{};
      applyRecommendationsToOverlays(
        recommendations: [
          SetGroupOverride(rationale: '', scope: 'LL_RCC_LSI'),
          SetGroupOverride(rationale: '', scope: 'LL_RCC_HSE'),
          ClearGroupOverride(rationale: '', scope: 'LL_RCC_LSI'), // overrides LSI
        ],
        hookOverrides: {},
        hookOverrideScopes: {},
        hookPreferences: {},
        iterationCap: 10,
        groupOverrides: groupOverrides,
      );
      expect(groupOverrides['LL_RCC_LSI'], GroupOverrideState.suppressed);
      expect(groupOverrides['LL_RCC_HSE'], GroupOverrideState.forced);
    });
  });

  group('Emulator.groupOverrides round-trip', () {
    test('survives toJson/fromJson', () {
      final now = DateTime.fromMillisecondsSinceEpoch(0);
      final e = Emulator(
        id: 'x',
        name: 'x',
        createdAt: now,
        modifiedAt: now,
        emulationConfig: EmulationConfig.defaults(),
        uiState: UiState.defaults(),
        groupOverrides: const {
          'LL_RCC_LSI': GroupOverrideState.forced,
          'LL_RCC_HSE': GroupOverrideState.suppressed,
        },
      );
      final back = Emulator.fromJson(e.toJson());
      expect(back.groupOverrides['LL_RCC_LSI'], GroupOverrideState.forced);
      expect(back.groupOverrides['LL_RCC_HSE'], GroupOverrideState.suppressed);
    });
  });

  group('synthesizer group-install helpers', () {
    test('forcedGroupPlans installs only forced, unapplied groups', () {
      final plans = forcedGroupPlans(
        symbolGroups: lsi,
        groupOverrides: const {'LL_RCC_LSI': GroupOverrideState.forced},
        appliedScopes: <String>{},
        overriddenSymbols: <String>{},
      );
      expect(plans.length, 1);
      expect(plans.single.scope, 'LL_RCC_LSI');
      expect(plans.single.members.length, 3);
    });

    test('forcedGroupPlans skips suppressed and already-applied groups', () {
      expect(
        forcedGroupPlans(
          symbolGroups: lsi,
          groupOverrides: const {'LL_RCC_LSI': GroupOverrideState.suppressed},
          appliedScopes: <String>{},
          overriddenSymbols: <String>{},
        ),
        isEmpty,
      );
      expect(
        forcedGroupPlans(
          symbolGroups: lsi,
          groupOverrides: const {'LL_RCC_LSI': GroupOverrideState.forced},
          appliedScopes: {'LL_RCC_LSI'}, // already applied
          overriddenSymbols: <String>{},
        ),
        isEmpty,
      );
    });

    test('planGroupOverride returns null for a suppressed group on fault', () {
      final plan = planGroupOverride(
        faultSymbol: 'LL_RCC_LSI_IsReady',
        groupOf: groupOf,
        appliedScopes: <String>{},
        overriddenSymbols: <String>{},
        suppressedScopes: {'LL_RCC_LSI'},
      );
      expect(plan, isNull);
    });

    test('planGroupOverride still fires when not suppressed', () {
      final plan = planGroupOverride(
        faultSymbol: 'LL_RCC_LSI_IsReady',
        groupOf: groupOf,
        appliedScopes: <String>{},
        overriddenSymbols: <String>{},
      );
      expect(plan, isNotNull);
      expect(plan!.scope, 'LL_RCC_LSI');
    });
  });
}
