// Tier 1 enhancement check: confirm a hook that writes via
// pointer.writeData to a linker-relative address from the user's
// real firmware no longer faults in the bundled rig.
//
// Before Tier 1: the bundled rig's sram was 4 KB at 0x20000000.
// A pointer.writeData(cpu, 0x200005ec, ...) would hit unmapped
// memory at offset 0x5ec and trip onUnhandledAccess.
//
// After Tier 1: sram is 64 KB. The write lands inside the
// expanded region, succeeds silently, and the harness reports
// ranToCompletion=true with no errorMessage.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_harness_permissive_ram.dart

import 'dart:io';

import 'package:emulator_orchestrator/data/services/hook_test_harness.dart';

// Hook that writes 12 zero bytes to 0x200005ec (the linker
// address of DBInfo in aya_ppg.elf). On the old 4 KB rig this
// would unhandled-access; on the new 64 KB rig it succeeds.
const String _hookCode = '''
import set_return_value
import pointer
pointer.writeData(cpu, 0x200005ec, [0] * 12)
setReturnValue(cpu, 0)
''';

Future<void> main() async {
  stdout.writeln('=== test_harness_permissive_ram ===');
  stdout.writeln('hook writes 12 zeros to 0x200005ec (well above the old');
  stdout.writeln('4 KB SRAM ceiling at 0x20000FFF; inside the new 64 KB');
  stdout.writeln('region that ends at 0x2000FFFF).');
  stdout.writeln('');

  final harness = HookTestHarness();
  final result = await harness.runHook(hookCode: _hookCode);

  stdout.writeln('ranToCompletion: ${result.ranToCompletion}');
  stdout.writeln('errorMessage:    ${result.errorMessage ?? "<none>"}');
  stdout.writeln('returnValues:    ${result.returnValues}');
  stdout.writeln('runtime:         ${result.runtime.inMilliseconds}ms');
  if (result.errorMessage != null) {
    stderr.writeln('');
    stderr.writeln(
        '!!! FAIL: write to 0x200005ec triggered: ${result.errorMessage}');
    stderr.writeln('Renode log tail:\n${result.renodeLogTail}');
    exit(1);
  }
  if (!result.ranToCompletion) {
    stderr.writeln('!!! FAIL: bootstrap did not complete.');
    stderr.writeln('Renode log tail:\n${result.renodeLogTail}');
    exit(1);
  }
  stdout.writeln('');
  stdout.writeln('=== PASS: expanded-SRAM rig accepts the write '
      'without unhandled-access ===');
}
