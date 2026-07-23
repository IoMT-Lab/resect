// Regression test for HookStaticAnalyzer. Uses the user's real
// project decompilation (LL_APB0_GRP1_EnableClock from
// ghidra_decompilations) and the real STM32WB05 .repl to exercise
// mod-set containment and unmapped-access budget checks.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_hook_static_analyzer.dart

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/services/hook_static_analyzer.dart';
import 'package:resect_signatures/resect_signatures.dart';

const String _replPath =
    '/home/evan/Development/resect/emulation_engine/'
    'renode_1.16.0-dotnet_portable/platforms/cpus/stm32wb05_empty.repl';

class _Case {
  const _Case({
    required this.name,
    required this.candidateCode,
    required this.expectModSetContained,
    required this.expectUnmappedOk,
  });
  final String name;
  final String candidateCode;
  final bool expectModSetContained;
  final bool expectUnmappedOk;
}

const _cases = <_Case>[
  // Pure no-op return — the canonical substitute. Empty mod-set;
  // no memory accesses at all. Both checks must pass.
  _Case(
    name: 'returnHook(0) form',
    candidateCode: '''
import set_return_value
setReturnValue(cpu, 0)
''',
    expectModSetContained: true,
    expectUnmappedOk: true,
  ),

  // Hallucinated write: hook writes to 0x40023800 (a plausible-
  // looking STM32F4 RCC address) but the original
  // LL_APB0_GRP1_EnableClock writes only to 0x48400054. Mod-set
  // containment must FAIL with that address surfaced. Also, the
  // 0x40023800 region isn't mapped in stm32wb05_empty.repl, so
  // unmapped-access budget must FAIL too.
  _Case(
    name: 'hallucinated write to unrelated MMIO',
    candidateCode: '''
import set_return_value
cpu.Bus.WriteDoubleWord(0x40023800, 0)
setReturnValue(cpu, 0)
''',
    expectModSetContained: false,
    expectUnmappedOk: false,
  ),

  // Unmapped-access pattern: hook reads from 0xDEADBEEF (not in
  // any mapped region). No write to original-untouched memory
  // (so mod-set containment still holds — empty write set).
  // Unmapped-access budget must FAIL on the read.
  _Case(
    name: 'read from unmapped 0xDEADBEEF',
    candidateCode: '''
import set_return_value
v = int(cpu.Bus.ReadDoubleWord(0xDEADBEEF))
setReturnValue(cpu, v)
''',
    expectModSetContained: true,  // no writes
    expectUnmappedOk: false,
  ),

  // Write to mapped SRAM region (sram0 @ 0x20000000 size 0x3000).
  // Mod-set containment: the original LL_APB0_GRP1_EnableClock
  // writes 0x48400054, so 0x20000100 is NOT in the original's
  // mod-set → mod-set containment FAILS. Unmapped-access budget
  // PASSES (0x20000100 is inside sram0).
  _Case(
    name: 'write to mapped SRAM not in original mod-set',
    candidateCode: '''
import set_return_value
from System import Array, Byte
cpu.Bus.WriteBytes(Array[Byte]([0,0,0,0]), 0x20000100)
setReturnValue(cpu, 0)
''',
    expectModSetContained: false,
    expectUnmappedOk: true,
  ),
];

Future<void> main() async {
  stdout.writeln('=== test_hook_static_analyzer ===');

  // Pull the original decompilation + parameter names for
  // LL_APB0_GRP1_EnableClock from the real DB.
  final db = ArtifactDatabase();
  final firmware = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals('aya_ppg.elf')))
      .getSingleOrNull();
  if (firmware == null) {
    _fail('precondition',
        'No firmware row for aya_ppg.elf. Open the project once.');
  }
  final elfHash = firmware.elfHash;

  final decompilation = await db.decompilationFor(
    elfHash: elfHash,
    functionName: 'LL_APB0_GRP1_EnableClock',
  );
  if (decompilation == null) {
    _fail('precondition',
        'No decompilation for LL_APB0_GRP1_EnableClock — run extraction first.');
  }
  final sigRow = await (db.select(db.signatures)
        ..where((t) =>
            t.elfHash.equals(elfHash) &
            t.symbolName.equals('LL_APB0_GRP1_EnableClock')))
      .getSingleOrNull();
  final sig = FunctionSignature.fromJson(
    'LL_APB0_GRP1_EnableClock',
    jsonDecode(sigRow!.signatureJson) as Map<String, dynamic>,
  );
  final paramNames = sig.parameters.map((p) => p.name).toList();

  // Load the real .repl.
  final replContent = await File(_replPath).readAsString();

  stdout.writeln('decompilation (first 200 chars):');
  stdout.writeln('  ${decompilation.substring(0, decompilation.length.clamp(0, 200)).replaceAll("\n", "\n  ")}');
  stdout.writeln('parameters: $paramNames');
  stdout.writeln('.repl: $_replPath (${replContent.length} chars)');
  stdout.writeln('');

  const analyzer = HookStaticAnalyzer();
  var passed = 0;
  var failed = 0;
  for (var i = 0; i < _cases.length; i++) {
    final c = _cases[i];
    stdout.writeln('--- [${i + 1}/${_cases.length}] ${c.name} ---');
    final result = await analyzer.evaluate(
      candidateCode: c.candidateCode,
      originalDecompilation: decompilation,
      parameterNames: paramNames,
      replContent: replContent,
    );
    stdout.writeln('  original writes:   ${result.originalWrites.isEmpty ? "<none>" : result.originalWrites.join(", ")}');
    stdout.writeln('  candidate writes:  ${result.candidateWrites.isEmpty ? "<none>" : result.candidateWrites.join(", ")}');
    stdout.writeln('  candidate reads:   ${result.candidateReads.isEmpty ? "<none>" : result.candidateReads.map((a) => "0x${a.toRadixString(16)}").join(", ")}');
    stdout.writeln('  mod-set contained: ${result.modSetContained}'
        '${result.hallucinatedWrites.isEmpty ? "" : "  (hallucinated: ${result.hallucinatedWrites.join(", ")})"}');
    stdout.writeln('  unmapped accesses: ${result.unmappedAccesses.isEmpty ? "<none>" : result.unmappedAccesses.map((a) => "0x${a.toRadixString(16)}").join(", ")}');
    if (result.violation != null) {
      stdout.writeln('  violation: ${result.violation}');
    }

    final modOk = result.modSetContained == c.expectModSetContained;
    final unmappedOk = result.unmappedAccessOk == c.expectUnmappedOk;
    if (modOk && unmappedOk) {
      stdout.writeln('  ✓ matches expectation '
          '(modSet=${c.expectModSetContained}, unmappedOk=${c.expectUnmappedOk})');
      passed++;
    } else {
      stdout.writeln('  ✗ FAIL: expected modSet=${c.expectModSetContained} '
          'unmappedOk=${c.expectUnmappedOk}; '
          'got modSet=${result.modSetContained} '
          'unmappedOk=${result.unmappedAccessOk}');
      failed++;
    }
    stdout.writeln('');
  }

  await db.close();
  stdout.writeln('=== summary: $passed passed, $failed failed '
      '(of ${_cases.length} total) ===');
  if (failed > 0) exit(1);
}

Never _fail(String step, String message) {
  stderr.writeln('!!! FAIL at $step: $message');
  exit(1);
}
