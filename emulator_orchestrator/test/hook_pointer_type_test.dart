import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:test/test.dart';

// Pins the behavior of `basePointerTypeName` — the function that
// turns a Ghidra-reported parameter type string into a name we can
// look up in the `ghidra_data_types` table. Most variants come from
// real signatures seen in aya_ppg.elf; the unusual ones (function
// pointers, nested cvr-qualifiers) come from hand inspection of the
// Ghidra DataType lexicon. If Ghidra changes how it stringifies
// types in a future release, the failures here will say so.
void main() {
  String? p(String s) => LlmHookGenerator.basePointerTypeName(s);

  group('named pointer to user type', () {
    test('plain pointer', () {
      expect(p('NVMDB_info *'), 'NVMDB_info');
      expect(p('VTIMER_HandleType *'), 'VTIMER_HandleType');
    });

    test('no space before asterisk', () {
      expect(p('NVMDB_info*'), 'NVMDB_info');
    });

    test('leading const', () {
      expect(p('const NVMDB_info *'), 'NVMDB_info');
    });

    test('leading volatile', () {
      expect(p('volatile foo *'), 'foo');
    });

    test('trailing const (pointer-itself const)', () {
      expect(p('NVMDB_info * const'), 'NVMDB_info');
    });

    test('double pointer keeps the base name', () {
      // Both stars are stripped; current behavior is to return the
      // raw base. Documented here so it doesn't drift silently.
      expect(p('NVMDB_info **'), 'NVMDB_info');
    });
  });

  group('primitives are dropped', () {
    test('void pointer', () {
      expect(p('void *'), isNull);
    });

    test('common stdint primitives', () {
      expect(p('uint8_t *'), isNull);
      expect(p('uint16_t *'), isNull);
      expect(p('uint32_t *'), isNull);
      expect(p('int32_t *'), isNull);
    });

    test('C primitives', () {
      expect(p('char *'), isNull);
      expect(p('int *'), isNull);
      expect(p('long *'), isNull);
      expect(p('float *'), isNull);
    });

    test('bool variants', () {
      expect(p('bool *'), isNull);
      expect(p('_Bool *'), isNull);
    });

    test('volatile primitive', () {
      expect(p('volatile uint32_t *'), isNull);
    });
  });

  group('non-pointer types are dropped', () {
    test('value type', () {
      expect(p('NVMDB_info'), isNull);
      expect(p('uint32_t'), isNull);
    });

    test('empty / whitespace', () {
      expect(p(''), isNull);
      expect(p('   '), isNull);
    });

    test('Ghidra "unknown" stripped-binary marker', () {
      // Decompilation for stripped binaries shows params as
      // `unknown` / `undefined4`. They have no pointer star, so we
      // skip — there's nothing to look up.
      expect(p('unknown'), isNull);
      expect(p('undefined4'), isNull);
    });
  });

  group('function pointers are dropped', () {
    test('parens trigger the function-pointer filter', () {
      expect(p('int (*)(int)'), isNull);
      expect(p('void (*)(void *)'), isNull);
    });
  });
}
