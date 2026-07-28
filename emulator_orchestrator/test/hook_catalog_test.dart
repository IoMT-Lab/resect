import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:test/test.dart';

/// Catalog tests: structural checks on the generated hook code. We can't assert
/// byte-equivalence with the legacy `return0HookCode`/`return1HookCode`
/// constants because hooks-dart's `returnHook` composes via
/// `import set_return_value` (inlined), producing a `def setReturnValue(...)`
/// helper plus a call with the constant — functionally equivalent to the legacy
/// inline form, but textually different. End-to-end synthesis regression is the
/// operational parity check; these tests just guard the structural contract.
void main() {
  final catalog = HookCatalog.system();

  group('return hook', () {
    test('builds a Hook with the correct value substituted into the call', () {
      final hook = catalog.build('return', {'value': 7});
      expect(hook.scope, isNull);
      expect(
        hook.code,
        contains('setReturnValue(cpu, 7)'),
        reason: 'call line should reference the requested value',
      );
      expect(
        hook.code,
        contains('cpu.SetRegister(0, RegisterValue.Create(value, 64))'),
        reason: 'helper definition should set R0 (ARM ABI return register)',
      );
      expect(
        hook.code,
        contains('cpu.PC = cpu.LR'),
        reason: 'helper definition should jump to LR (return to caller)',
      );
    });

    test('preset 0 — default artifact for new firmware', () {
      final hook = catalog.build('return', {'value': 0});
      expect(hook.code, contains('setReturnValue(cpu, 0)'));
    });

    test('preset 1 — default artifact for new firmware', () {
      final hook = catalog.build('return', {'value': 1});
      expect(hook.code, contains('setReturnValue(cpu, 1)'));
    });

    test('defaults value to 0 when omitted', () {
      final hook = catalog.build('return');
      expect(hook.code, contains('setReturnValue(cpu, 0)'));
    });
  });

  group('catalog shape', () {
    test('exposes all seeded kinds', () {
      final kinds = catalog.all.map((d) => d.kindId).toSet();
      expect(kinds, containsAll(<String>[
        'return',
        'read',
        'write',
        'increment',
        'i2c_read',
        'i2c_write',
      ]));
    });

    test('unknown kind throws ArgumentError', () {
      expect(() => catalog.build('nonexistent'), throwsArgumentError);
    });

    test('stateful and i2c builders attach the expected scope', () {
      expect(catalog.build('read', {'scope': 'reg'}).scope, 'reg');
      expect(catalog.build('write', {'scope': 'reg', 'value': 1}).scope, 'reg');
      expect(catalog.build('increment', {'scope': 'reg'}).scope, 'reg');
      expect(catalog.build('i2c_read', {'port': 1234}).scope, 'i2c');
      expect(catalog.build('i2c_write', {'port': 1234}).scope, 'i2c');
    });
  });
}
