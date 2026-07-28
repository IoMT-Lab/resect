// End-to-end check that a hook whose `import set_return_value` was
// inlined by the new DB write boundary actually executes in Renode
// without the IronPython `ImportException: No module named
// set_return_value` that previously killed the .NET process.
//
// Reads the artifact row whose body matches the canonical
// `setReturnValue(cpu, 0)` shape (catalog-built, fidelity floor) and
// runs it via HookProgressRunner against the same firmware the user
// hits in synthesis. Success = no crash + a usable instruction count.
//
//   dart run tool/verify_substituted_hook_in_renode.dart

import 'dart:io';

import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/services/quality/hook_progress_runner.dart';

const String _replPath =
    '/home/evan/Development/resect/emulation_engine/'
    'renode_1.16.0-dotnet_portable/platforms/cpus/stm32wb05_empty.repl';
const String _elfPath =
    '/home/evan/Development/resect/emulation_engine/aya_ppg.elf';
const String _targetSymbol = 'LL_APB0_GRP1_EnableClock';

Future<void> main() async {
  if (!File(_replPath).existsSync()) {
    stderr.writeln('!!! repl not found at $_replPath');
    exit(1);
  }
  if (!File(_elfPath).existsSync()) {
    stderr.writeln('!!! elf not found at $_elfPath');
    exit(1);
  }

  final db = ArtifactDatabase();
  final rows = await db.getAllArtifacts();
  // Pick the user-origin row for LL_APB0_GRP1_EnableClock — the one
  // that, before migration, carried `import set_return_value`.
  final row = rows.firstWhere(
    (a) =>
        a.artifactType == 'renode_hook' &&
        a.targetSymbolName == _targetSymbol,
    orElse: () => throw StateError(
        'no renode_hook row for $_targetSymbol; was the project opened?'),
  );

  stdout.writeln('=== verify_substituted_hook_in_renode ===');
  stdout.writeln('elf:    $_elfPath');
  stdout.writeln('target: $_targetSymbol');
  stdout.writeln('row id: ${row.id}  origin: ${row.origin}');
  stdout.writeln('--- hook body (first 10 lines) ---');
  row.artifactData.split('\n').take(10).forEach(stdout.writeln);
  stdout.writeln('--- end body ---\n');

  // If the body still carries `import set_return_value`, the DB
  // write boundary didn't substitute on the most recent insert, or
  // the migration hasn't run. Fail loudly — running this in Renode
  // would crash the engine.
  if (RegExp(r'^\s*import\s+set_return_value\b', multiLine: true)
      .hasMatch(row.artifactData)) {
    stderr.writeln('!!! row still has raw `import set_return_value` — '
        'migration not applied. open the project once to trigger it.');
    await db.close();
    exit(2);
  }

  final runner = HookProgressRunner();
  final result = await runner.measure(
    replPath: _replPath,
    elfPath: _elfPath,
    targetSymbol: _targetSymbol,
    hookCode: row.artifactData,
  );

  stdout.writeln('with-hook  instructions: ${result.withHookInstructions}');
  stdout.writeln('baseline   instructions: ${result.baselineInstructions}');
  stdout.writeln('score:                   ${result.score.toStringAsFixed(3)}');
  stdout.writeln('elapsed:                 ${result.elapsed.inSeconds}s');
  if (result.errorMessage != null) {
    stdout.writeln('error: ${result.errorMessage}');
  }

  await db.close();

  // The hook should run cleanly. A null errorMessage and any
  // non-error count is enough — the bug being verified is "Renode
  // doesn't crash with ImportException."
  if (result.errorMessage != null) {
    stderr.writeln('\n!!! FAIL: $result.errorMessage');
    exit(1);
  }
  stdout.writeln('\nOK — hook executed in Renode without ImportException.');
}
