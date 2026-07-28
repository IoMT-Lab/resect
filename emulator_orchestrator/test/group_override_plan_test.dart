import 'package:emulator_orchestrator/data/models/symbol_group.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';
import 'package:emulator_orchestrator/orchestrator/workflows/synthesizer_workflow.dart';
import 'package:test/test.dart';

void main() {
  final catalog = HookCatalog.system();
  final classifier = SymbolGroupClassifier(catalog: catalog);

  // A realistic LSI clock object.
  final groups = classifier.classify([
    'LL_RCC_LSI_Enable',
    'LL_RCC_LSI_Disable',
    'LL_RCC_LSI_IsReady',
  ]);
  final groupOf = <String, SymbolGroup>{
    for (final g in groups)
      for (final m in g.members.keys) m: g,
  };

  group('planGroupOverride', () {
    test('a member fault installs the whole group with the shared scope', () {
      final plan = planGroupOverride(
        faultSymbol: 'LL_RCC_LSI_IsReady',
        groupOf: groupOf,
        appliedScopes: <String>{},
        overriddenSymbols: <String>{},
      );
      expect(plan, isNotNull);
      expect(plan!.scope, 'LL_RCC_LSI');
      expect(plan.members.map((m) => m.symbol),
          containsAll(['LL_RCC_LSI_Enable', 'LL_RCC_LSI_Disable', 'LL_RCC_LSI_IsReady']));
      for (final m in plan.members) {
        expect(m.scope, 'LL_RCC_LSI');
        expect(m.code, isNotEmpty);
      }
    });

    test('returns null once the group has already been applied', () {
      final plan = planGroupOverride(
        faultSymbol: 'LL_RCC_LSI_Enable',
        groupOf: groupOf,
        appliedScopes: {'LL_RCC_LSI'},
        overriddenSymbols: <String>{},
      );
      expect(plan, isNull);
    });

    test('returns null for a symbol that is not in any group', () {
      final plan = planGroupOverride(
        faultSymbol: 'main',
        groupOf: groupOf,
        appliedScopes: <String>{},
        overriddenSymbols: <String>{},
      );
      expect(plan, isNull);
    });

    test('a user-overridden or comms member is excluded from the plan', () {
      final plan = planGroupOverride(
        faultSymbol: 'LL_RCC_LSI_IsReady',
        groupOf: groupOf,
        appliedScopes: <String>{},
        overriddenSymbols: {'LL_RCC_LSI_Disable'},
      );
      expect(plan, isNotNull);
      final syms = plan!.members.map((m) => m.symbol);
      expect(syms, isNot(contains('LL_RCC_LSI_Disable')));
      expect(syms, containsAll(['LL_RCC_LSI_Enable', 'LL_RCC_LSI_IsReady']));
    });

    test('returns null when every member is excluded', () {
      final plan = planGroupOverride(
        faultSymbol: 'LL_RCC_LSI_Enable',
        groupOf: groupOf,
        appliedScopes: <String>{},
        overriddenSymbols: {
          'LL_RCC_LSI_Enable',
          'LL_RCC_LSI_Disable',
          'LL_RCC_LSI_IsReady',
        },
      );
      expect(plan, isNull);
    });
  });

  group('ManifestDecisionKind.groupOverride', () {
    test('round-trips through its json name', () {
      expect(ManifestDecisionKind.groupOverride.jsonName, 'group_override');
      expect(ManifestDecisionKind.fromJson('group_override'),
          ManifestDecisionKind.groupOverride);
    });
  });
}
