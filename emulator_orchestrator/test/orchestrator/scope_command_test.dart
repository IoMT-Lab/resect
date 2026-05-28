import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_emulation_controller.dart';
import 'package:test/test.dart';

/// Guards the `sysbus AddHookAtSymbol` command-string construction in
/// [DartEmulationController._applyHooks] (extracted as the public static
/// helper [DartEmulationController.addHookAtSymbolCommand] for testability).
/// The variable-reference form (`$hookName`) is kept intact; only the optional
/// `"scope"` suffix is the new behavior added in Workstream A.
void main() {
  test('no scope → variable-reference form unchanged from pre-A behavior', () {
    expect(
      DartEmulationController.addHookAtSymbolCommand(
        'HAL_I2C_Read',
        'HAL_I2C_Read_hook',
        null,
      ),
      'sysbus AddHookAtSymbol "HAL_I2C_Read" \$HAL_I2C_Read_hook',
    );
  });

  test('with scope → 3rd quoted arg appended', () {
    expect(
      DartEmulationController.addHookAtSymbolCommand(
        'HAL_I2C_Read',
        'HAL_I2C_Read_hook',
        'i2c',
      ),
      'sysbus AddHookAtSymbol "HAL_I2C_Read" \$HAL_I2C_Read_hook "i2c"',
    );
  });
}
