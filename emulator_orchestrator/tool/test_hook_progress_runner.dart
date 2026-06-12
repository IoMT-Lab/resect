// Smoke test for HookProgressRunner. Boots the user's real project
// Renode twice — once with `returnHook(0)` installed at
// LL_APB0_GRP1_EnableClock, once without — and reports the
// instruction-count delta + normalised 0-1 score.
//
// Slow: ~15-30 s total (two Renode boots + run windows). Run when
// the runner or scoring weights change.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_hook_progress_runner.dart

import 'dart:io';

import 'package:emulator_orchestrator/data/services/hook_progress_runner.dart';

// User's real STM32WB05 project assets — same paths the dialog
// uses via Emulator.elfFilePath / baseImagePath.
const String _replPath = '/home/evan/Development/resect/emulation_engine/'
    'renode_1.16.0-dotnet_portable/platforms/cpus/stm32wb05_empty.repl';
const String _elfPath =
    '/home/evan/Development/resect/emulation_engine/aya_ppg.elf';

// The classifier's Rule-6 materialisation for
// LL_APB0_GRP1_EnableClock. This is what the dialog would install.
const String _hookCode = '''
import set_return_value
setReturnValue(cpu, 0)
''';

Future<void> main() async {
  stdout.writeln('=== test_hook_progress_runner ===');
  stdout.writeln('repl: $_replPath');
  stdout.writeln('elf:  $_elfPath');
  stdout.writeln('target symbol: LL_APB0_GRP1_EnableClock');
  stdout.writeln('hook: ${_hookCode.trim().replaceAll("\n", " ; ")}');
  stdout.writeln('');

  if (!File(_replPath).existsSync()) {
    stderr.writeln('!!! FAIL: .repl not found at $_replPath');
    exit(1);
  }
  if (!File(_elfPath).existsSync()) {
    stderr.writeln('!!! FAIL: ELF not found at $_elfPath');
    exit(1);
  }

  final runner = HookProgressRunner();
  final result = await runner.measure(
    replPath: _replPath,
    elfPath: _elfPath,
    targetSymbol: 'LL_APB0_GRP1_EnableClock',
    hookCode: _hookCode,
  );

  stdout.writeln('with-hook  instructions: ${result.withHookInstructions}');
  stdout.writeln('baseline   instructions: ${result.baselineInstructions}');
  final delta = result.withHookInstructions - result.baselineInstructions;
  stdout.writeln('delta:                   $delta');
  stdout.writeln('score:                   ${result.score.toStringAsFixed(3)}');
  stdout.writeln('elapsed:                 ${result.elapsed.inSeconds}s');
  if (result.errorMessage != null) {
    stdout.writeln('error: ${result.errorMessage}');
  }

  // Sanity check: both runs produced a count. Not asserting a
  // specific score because (a) the firmware may not reach
  // LL_APB0_GRP1_EnableClock in the bounded window, (b) wall-clock
  // variance affects instruction count, (c) the baseline run with
  // the same firmware may finish at the same point. The point of
  // this smoke test is to confirm the runner boots Renode twice,
  // reads the counter, and returns a usable result — not to
  // verify a specific delta.
  if (result.errorMessage != null) {
    stderr.writeln('!!! FAIL: ${result.errorMessage}');
    exit(1);
  }
  if (result.withHookInstructions == 0 || result.baselineInstructions == 0) {
    stderr.writeln('!!! FAIL: one of the runs reported 0 instructions. '
        'Renode either didn\'t start or the cpu ExecutedInstructions '
        'read failed.');
    exit(1);
  }
  stdout.writeln('');
  stdout.writeln('=== PASS: runner produced usable counts from both passes ===');
}
