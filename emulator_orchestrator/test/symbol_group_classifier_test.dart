import 'package:emulator_orchestrator/data/models/symbol_group.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';
import 'package:test/test.dart';

void main() {
  final catalog = HookCatalog.system();
  final classifier = SymbolGroupClassifier(catalog: catalog);

  SymbolGroup? groupWithScope(List<SymbolGroup> groups, String scope) {
    for (final g in groups) {
      if (g.scope == scope) return g;
    }
    return null;
  }

  group('SymbolGroupClassifier — verb-anchored parse', () {
    test('groups the LSI clock trio with the shared prefix scope', () {
      final groups = classifier.classify([
        'LL_RCC_LSI_Enable',
        'LL_RCC_LSI_Disable',
        'LL_RCC_LSI_IsReady',
      ]);
      final lsi = groupWithScope(groups, 'LL_RCC_LSI');
      expect(lsi, isNotNull);
      expect(lsi!.members['LL_RCC_LSI_Enable']!.role, GroupMemberRole.enable);
      expect(lsi.members['LL_RCC_LSI_Disable']!.role, GroupMemberRole.disable);
      expect(lsi.members['LL_RCC_LSI_IsReady']!.role, GroupMemberRole.isReady);
      for (final m in lsi.hookableMembers) {
        expect(m.value.scope, 'LL_RCC_LSI');
      }
    });

    test('LSI and HSE are separate objects, not one RCC blob', () {
      final groups = classifier.classify([
        'LL_RCC_LSI_Enable',
        'LL_RCC_LSI_IsReady',
        'LL_RCC_HSE_Enable',
        'LL_RCC_HSE_IsReady',
      ]);
      expect(groupWithScope(groups, 'LL_RCC_LSI'), isNotNull);
      expect(groupWithScope(groups, 'LL_RCC_HSE'), isNotNull);
      expect(groupWithScope(groups, 'LL_RCC'), isNull);
    });

    test('a shallow object (only one non-framework token) is rejected', () {
      // subject would be [LL, RCC] -> one non-framework token -> "any old RCC".
      final groups = classifier.classify([
        'LL_RCC_Enable',
        'LL_RCC_Disable',
      ]);
      expect(groups, isEmpty);
    });

    test('a single-member object is not a group', () {
      final groups = classifier.classify([
        'LL_RCC_LSI_Enable',
        'LL_RCC_HSE_Enable',
      ]);
      expect(groups, isEmpty);
    });

    test('excluded (comms) symbols never appear in a group', () {
      final groups = classifier.classify(
        [
          'LL_RCC_LSI_Enable',
          'LL_RCC_LSI_IsReady',
          'HAL_I2C_Master_Transmit',
          'HAL_I2C_Master_Receive',
        ],
        exclude: {'HAL_I2C_Master_Transmit', 'HAL_I2C_Master_Receive'},
      );
      final allMembers = groups.expand((g) => g.members.keys).toSet();
      expect(allMembers, isNot(contains('HAL_I2C_Master_Transmit')));
      expect(groupWithScope(groups, 'LL_RCC_LSI'), isNotNull);
    });

    test('camelCase verbs are detected (IsEnabled reads as isReady)', () {
      final groups = classifier.classify([
        'LL_APB1_GRP1_EnableClock',
        'LL_APB1_GRP1_IsEnabledClock',
      ]);
      final g = groupWithScope(groups, 'LL_APB1_GRP1');
      expect(g, isNotNull);
      expect(g!.members['LL_APB1_GRP1_EnableClock']!.role,
          GroupMemberRole.enable);
      expect(g.members['LL_APB1_GRP1_IsEnabledClock']!.role,
          GroupMemberRole.isReady);
    });

    test('a mid-name camelCase verb splits a subsystem into sub-objects', () {
      final groups = classifier.classify([
        'BLEPLAT_CNTR_PacketSetDataPtr',
        'BLEPLAT_CNTR_PacketSetIntDone',
        'BLEPLAT_CNTR_SmSetTxPwr',
        'BLEPLAT_CNTR_SmSetRxMode',
        'BLEPLAT_CNTR_IntGetIntStatusRxOk',
        'BLEPLAT_CNTR_IntGetIntStatusTxDone',
      ]);
      // Not one 6-member BLEPLAT_CNTR blob — three coherent sub-objects.
      expect(groupWithScope(groups, 'BLEPLAT_CNTR'), isNull);
      expect(groupWithScope(groups, 'BLEPLAT_CNTR_Packet')?.members.length, 2);
      expect(groupWithScope(groups, 'BLEPLAT_CNTR_Sm')?.members.length, 2);
      final intg = groupWithScope(groups, 'BLEPLAT_CNTR_Int');
      expect(intg, isNotNull);
      expect(intg!.members.values.first.role, GroupMemberRole.get);
    });

    test('symbols with no recognized verb form no group', () {
      final groups = classifier.classify([
        'us_to_systime',
        'us_to_ticks',
        'sfp_lock_acquire',
        'sfp_lock_owner',
      ]);
      expect(groups, isEmpty);
    });

    test('numbered instances get distinct scopes; Enable/IsEnabled pair', () {
      final groups = classifier.classify([
        'LL_RADIO_TIMER_EnableTimer1',
        'LL_RADIO_TIMER_DisableTimer1',
        'LL_RADIO_TIMER_IsEnabledTimer1',
        'LL_RADIO_TIMER_EnableTimer2',
        'LL_RADIO_TIMER_DisableTimer2',
      ]);
      final t1 = groupWithScope(groups, 'LL_RADIO_TIMER_Timer1');
      final t2 = groupWithScope(groups, 'LL_RADIO_TIMER_Timer2');
      expect(t1, isNotNull);
      expect(t2, isNotNull);
      // Timer1's enable/disable/is-enabled all share the Timer1 scope, so the
      // is-enabled read sees the enable write.
      expect(t1!.members.length, 3);
      for (final m in t1.hookableMembers) {
        expect(m.value.scope, 'LL_RADIO_TIMER_Timer1');
      }
      // Timer2 is a distinct object — its writes never touch Timer1's state.
      expect(t2!.members.length, 2);
      expect(t1.members.containsKey('LL_RADIO_TIMER_EnableTimer2'), isFalse);
    });

    test('role templates match the catalog build shapes', () {
      final groups = classifier.classify([
        'LL_RCC_LSI_Enable',
        'LL_RCC_LSI_Disable',
        'LL_RCC_LSI_IsReady',
      ]);
      final g = groupWithScope(groups, 'LL_RCC_LSI')!;
      const scope = 'LL_RCC_LSI';
      expect(
          g.members['LL_RCC_LSI_Enable']!.code,
          catalog.build(
              'write', {'scope': scope, 'value': 1, 'returnValue': 0}).code);
      expect(
          g.members['LL_RCC_LSI_Disable']!.code,
          catalog.build(
              'write', {'scope': scope, 'value': 0, 'returnValue': 0}).code);
      expect(g.members['LL_RCC_LSI_IsReady']!.code,
          catalog.build('read', {'scope': scope, 'defaultValue': 0}).code);
    });

    test('Clear maps to write 0', () {
      final groups = classifier.classify([
        'BLEPLAT_CNTR_ClearInterrupt',
        'BLEPLAT_CNTR_ClearSemareq',
      ]);
      final g = groupWithScope(groups, 'BLEPLAT_CNTR');
      expect(g, isNotNull);
      expect(g!.members['BLEPLAT_CNTR_ClearInterrupt']!.role,
          GroupMemberRole.clear);
      expect(
          g.members['BLEPLAT_CNTR_ClearInterrupt']!.code,
          catalog.build('write',
              {'scope': 'BLEPLAT_CNTR', 'value': 0, 'returnValue': 0}).code);
    });
  });
}
