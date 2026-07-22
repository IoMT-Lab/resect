import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/services/hook_catalog.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_config.dart';
import 'package:test/test.dart';

/// The comms read/write forwarding hook runs the `stm32_glue` extractor, which
/// reads the I2C `Size` argument from `[SP+4]` (the 6th arg). Attaching it to a
/// function that doesn't take those arguments — e.g. `get_i2c`, a zero-arg
/// accessor that just returns the bus handle — makes the extractor read stack
/// leftovers and forward a bogus, out-of-spec read. `buildCommsHooks` gates
/// attachment on the symbol's real argument count to prevent that.
void main() {
  Emulator emu(Map<String, CommsAssignment> commsAssignments) {
    final now = DateTime.fromMillisecondsSinceEpoch(0);
    return Emulator(
      id: 'test',
      name: 'test',
      createdAt: now,
      modifiedAt: now,
      emulationConfig: EmulationConfig.defaults(),
      uiState: UiState.defaults(),
      commsAssignments: commsAssignments,
    );
  }

  group('buildCommsHooks arg-count gate', () {
    final catalog = HookCatalog.system();
    final configs = {
      CommsClass.i2c: const CommsProtocolConfig(port: 1234, virtualized: true),
    };
    final assignments = {
      'get_i2c': const CommsAssignment(
          protocol: CommsClass.i2c, role: CommsRole.read),
      'HAL_I2C_Mem_Read': const CommsAssignment(
          protocol: CommsClass.i2c, role: CommsRole.read),
    };

    test('skips a 0-arg accessor and keeps a real 7-arg transfer', () {
      final hooks = buildCommsHooks(
        emulator: emu(assignments),
        configs: configs,
        catalog: catalog,
        argCounts: const {'get_i2c': 0, 'HAL_I2C_Mem_Read': 7},
      );
      // get_i2c (0 args) is left native — no forwarding hook.
      expect(hooks.containsKey('get_i2c'), isFalse);
      // HAL_I2C_Mem_Read (7 args) is a real transfer — still hooked.
      expect(hooks.containsKey('HAL_I2C_Mem_Read'), isTrue);
    });

    test('fail-open: unknown arg count still attaches (current behavior)', () {
      final hooks = buildCommsHooks(
        emulator: emu(assignments),
        configs: configs,
        catalog: catalog,
        argCounts: const {}, // no signatures cached
      );
      expect(hooks.containsKey('get_i2c'), isTrue);
      expect(hooks.containsKey('HAL_I2C_Mem_Read'), isTrue);
    });

    test('i2c threshold is 6 args (5 → skipped, 6 → attached)', () {
      final hooks = buildCommsHooks(
        emulator: emu({
          'read5': const CommsAssignment(
              protocol: CommsClass.i2c, role: CommsRole.read),
          'read6': const CommsAssignment(
              protocol: CommsClass.i2c, role: CommsRole.read),
        }),
        configs: configs,
        catalog: catalog,
        argCounts: const {'read5': 5, 'read6': 6},
      );
      expect(hooks.containsKey('read5'), isFalse);
      expect(hooks.containsKey('read6'), isTrue);
    });
  });
}
