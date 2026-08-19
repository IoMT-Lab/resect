import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_config.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:test/test.dart';

Emulator _emulatorWith(Map<String, CommsAssignment> assignments) =>
    Emulator.create(name: 't', elfFilePath: '/dev/null', baseImagePath: '/dev/null')
        .copyWith(commsAssignments: assignments);

void main() {
  final catalog = HookCatalog.system();
  const i2cVirtualized = {
    CommsClass.i2c: CommsProtocolConfig(port: 1234, virtualized: true),
  };

  group('buildCommsHooks', () {
    test('virtualized symbol with a role gets the protocol hook', () {
      final hooks = buildCommsHooks(
        emulator: _emulatorWith({
          'HAL_I2C_Master_Receive': const CommsAssignment(
              protocol: CommsClass.i2c, role: CommsRole.read),
        }),
        configs: i2cVirtualized,
        catalog: catalog,
      );
      expect(hooks, contains('HAL_I2C_Master_Receive'));
      expect(hooks['HAL_I2C_Master_Receive']!.code, isNotEmpty);
    });

    test('unclassified symbols are skipped', () {
      final hooks = buildCommsHooks(
        emulator: _emulatorWith({
          'maybe_bus': const CommsAssignment(protocol: CommsClass.unclassified),
        }),
        configs: i2cVirtualized,
        catalog: catalog,
      );
      expect(hooks, isEmpty);
    });

    test('non-virtualized protocol is skipped', () {
      final hooks = buildCommsHooks(
        emulator: _emulatorWith({
          'HAL_I2C_Master_Receive': const CommsAssignment(
              protocol: CommsClass.i2c, role: CommsRole.read),
        }),
        configs: const {
          CommsClass.i2c: CommsProtocolConfig(port: 1234, virtualized: false),
        },
        catalog: catalog,
      );
      expect(hooks, isEmpty);
    });

    test('roleless symbol gets the return-0 fill by default', () {
      final hooks = buildCommsHooks(
        emulator: _emulatorWith({
          'HAL_I2C_GetState': const CommsAssignment(protocol: CommsClass.i2c),
        }),
        configs: i2cVirtualized,
        catalog: catalog,
      );
      expect(hooks, contains('HAL_I2C_GetState'));
      expect(hooks['HAL_I2C_GetState']!.scope, isNull);
    });

    test('roleless symbol is skipped when fill-unmapped is off', () {
      final hooks = buildCommsHooks(
        emulator: _emulatorWith({
          'HAL_I2C_GetState': const CommsAssignment(protocol: CommsClass.i2c),
        }),
        configs: const {
          CommsClass.i2c: CommsProtocolConfig(
              port: 1234, virtualized: true, fillUnmappedWithReturnZero: false),
        },
        catalog: catalog,
      );
      expect(hooks, isEmpty);
    });
  });
}
