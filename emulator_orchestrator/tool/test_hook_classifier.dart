// Regression test for HookClassifier. Runs against the user's real
// artifact DB (the same one the app uses) so the assertions are
// grounded in actual Ghidra-extracted decompilations + data_symbols.
// No mocks, no fixtures — this is the contract the rule list makes
// with the user's project.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_hook_classifier.dart
//
// Exits 0 when every per-function expectation matches. Exits non-zero
// on the first mismatch, naming which function + which expectation
// failed.

import 'dart:convert';
import 'dart:io';

// Full drift import (no `show`) so Expression<bool>'s `&` operator
// is in scope at the where-clause call sites below.
import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/services/hook_classifier.dart';
import 'package:resect_signatures/resect_signatures.dart';

class _Expectation {
  const _Expectation({
    required this.functionName,
    required this.expectedRule, // null = expect classifier to return null
    required this.expectedTemplate, // null when no match expected
    required this.invariantOnReturns,
    required this.invariantShouldPass,
  });

  final String functionName;
  final String? expectedRule;
  final String? expectedTemplate;

  /// Sample return values to feed the invariant. Only used when the
  /// rule fires; the test asserts the invariant evaluates to the
  /// expected pass/fail outcome on this input.
  final List<int> invariantOnReturns;
  final bool invariantShouldPass;
}

// The regression cases. Covers Stage 3's full rule set (Rules 1, 2,
// 3, 4, 5, 6, 7 — Rules 8 and 9 are explicit fall-throughs to the
// LLM path and don't produce a classifier verdict).
const _expectations = <_Expectation>[
  // Rule 6: pure peripheral writes, void return.
  _Expectation(
    functionName: 'LL_APB0_GRP1_EnableClock',
    expectedRule: 'rule-6-pure-peripheral-writes',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    invariantShouldPass: true,
  ),

  // Rule 3: counter / tick global. The headline regression — under
  // the previous architecture the LLM produced `setReturnValue(cpu, 0)`
  // and the harness green-checked it. Now the classifier picks
  // incrementHook deterministically, and the invariant rejects the
  // constant-zero input it would have accepted before.
  _Expectation(
    functionName: 'HAL_GetTick',
    expectedRule: 'rule-3-counter-global',
    expectedTemplate: 'incrementHook',
    invariantOnReturns: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
    invariantShouldPass: true,
  ),
  // The same function, but with the failing input. Invariant must
  // reject [0,0,...,0] — this is the test that the new gate catches
  // what the old gate missed.
  _Expectation(
    functionName: 'HAL_GetTick',
    expectedRule: 'rule-3-counter-global',
    expectedTemplate: 'incrementHook',
    invariantOnReturns: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    invariantShouldPass: false,
  ),

  // Rule 4: chip-config global (SystemCoreClock). Classifier picks
  // returnHook(64_000_000) — the STM32WB05 typical clock default.
  // Invariant: all 10 returns equal the default AND in plausible
  // MCU clock range.
  _Expectation(
    functionName: 'HAL_RCC_GetSysClockFreq',
    expectedRule: 'rule-4-chip-config-global',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [
      64000000, 64000000, 64000000, 64000000, 64000000,
      64000000, 64000000, 64000000, 64000000, 64000000,
    ],
    invariantShouldPass: true,
  ),
  // A "returns are 0" anti-pattern (callers would divide by 0 in
  // baud-rate math). Invariant must reject.
  _Expectation(
    functionName: 'HAL_RCC_GetSysClockFreq',
    expectedRule: 'rule-4-chip-config-global',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    invariantShouldPass: false,
  ),

  // Rule 5 (busy variant): LL_AES_IsBusy. Classifier picks
  // returnHook(0). Invariant: all returns ∈ {0, 1} AND equal 0.
  _Expectation(
    functionName: 'LL_AES_IsBusy',
    expectedRule: 'rule-5-busy-ready-flag',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    invariantShouldPass: true,
  ),
  // Same function, but the substitute returned 1 (busy forever).
  // Invariant must reject — for *Busy* the all-clear value is 0.
  _Expectation(
    functionName: 'LL_AES_IsBusy',
    expectedRule: 'rule-5-busy-ready-flag',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    invariantShouldPass: false,
  ),

  // Rule 5 (ready variant): LL_RNG_IsActiveFlag_RNGRDY. Classifier
  // picks returnHook(1) — the "ready" all-clear. Returns of 0
  // would cause callers' polling loops to hang.
  _Expectation(
    functionName: 'LL_RNG_IsActiveFlag_RNGRDY',
    expectedRule: 'rule-5-busy-ready-flag',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    invariantShouldPass: true,
  ),
  // The "always reports not-ready" trap. Invariant must reject.
  _Expectation(
    functionName: 'LL_RNG_IsActiveFlag_RNGRDY',
    expectedRule: 'rule-5-busy-ready-flag',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    invariantShouldPass: false,
  ),

  // Rule 7: HAL polling loop returning HAL_StatusTypeDef.
  // Classifier picks returnHook(0) (HAL_OK). Invariant must reject
  // HAL_ERROR (1) / HAL_BUSY (2) / HAL_TIMEOUT (3) anywhere in the
  // 10 returns.
  _Expectation(
    functionName: 'FLASH_WaitForLastOperation',
    expectedRule: 'rule-7-hal-polling-loop',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    invariantShouldPass: true,
  ),
  // Reports HAL_TIMEOUT (=3) on the last call. Invariant must
  // reject — substitute should always succeed.
  _Expectation(
    functionName: 'FLASH_WaitForLastOperation',
    expectedRule: 'rule-7-hal-polling-loop',
    expectedTemplate: 'returnHook',
    invariantOnReturns: [0, 0, 0, 0, 0, 0, 0, 0, 0, 3],
    invariantShouldPass: false,
  ),
];

Future<void> main() async {
  stdout.writeln('=== test_hook_classifier ===');
  final db = ArtifactDatabase();
  final classifier = const HookClassifier();

  // Resolve the firmware row. Same lookup the LLM dialog and
  // test_rag_end_to_end.dart use.
  final firmware = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals('aya_ppg.elf')))
      .getSingleOrNull();
  if (firmware == null) {
    _fail('precondition',
        'No firmware row in artifact DB for aya_ppg.elf. Open the project once.');
  }
  final elfHash = firmware.elfHash;
  stdout.writeln('elfHash: ${elfHash.substring(0, 12)}…');

  // Load the data_symbols once (the classifier needs them for Rule 3).
  final dataSymbolRows =
      await (db.select(db.ghidraDataSymbols)
            ..where((t) => t.elfHash.equals(elfHash)))
          .get();
  if (dataSymbolRows.isEmpty) {
    _fail('precondition',
        'ghidra_data_symbols has no rows for $elfHash. Run extraction first.');
  }
  final dataSymbols = <String, DataSymbol>{
    for (final r in dataSymbolRows)
      r.symbolName: DataSymbol(
        name: r.symbolName,
        address: r.address,
        type: r.typeName,
        size: r.size,
      ),
  };
  stdout.writeln('data_symbols: ${dataSymbols.length}');

  var passed = 0;
  var failed = 0;
  for (var i = 0; i < _expectations.length; i++) {
    final e = _expectations[i];
    stdout.writeln('');
    stdout.writeln('--- [${i + 1}/${_expectations.length}] ${e.functionName}'
        '${e.invariantOnReturns.isEmpty ? "" : " · returns=${e.invariantOnReturns}"} ---');

    // Pull the signature + decompilation for this function.
    final sigRow = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) &
              t.symbolName.equals(e.functionName)))
        .getSingleOrNull();
    if (sigRow == null) {
      _fail('expectation ${i + 1}',
          'No signature row for ${e.functionName} — function not in ELF?');
    }
    final signature =
        FunctionSignature.fromJson(e.functionName,
            jsonDecode(sigRow.signatureJson) as Map<String, dynamic>);

    final decompilation = await db.decompilationFor(
      elfHash: elfHash,
      functionName: e.functionName,
    );
    if (decompilation == null || decompilation.isEmpty) {
      _fail('expectation ${i + 1}',
          'No decompilation for ${e.functionName}.');
    }

    final result = classifier.classify(
      functionName: e.functionName,
      signature: signature,
      decompilation: decompilation,
      dataSymbols: dataSymbols,
    );

    // Check rule match.
    if (e.expectedRule == null) {
      if (result != null) {
        _failExpectation(
          i + 1,
          e,
          'Expected no rule match; got rule "${result.ruleName}" '
              '(template "${result.templateName}") instead.',
        );
        failed++;
        continue;
      }
      stdout.writeln('  ✓ no rule matched (as expected)');
      passed++;
      continue;
    }
    if (result == null) {
      _failExpectation(
        i + 1,
        e,
        'Expected rule "${e.expectedRule}"; classifier returned null '
            '(no match). Decompilation:\n  '
            '${decompilation.replaceAll("\n", "\n  ")}',
      );
      failed++;
      continue;
    }
    if (result.ruleName != e.expectedRule) {
      _failExpectation(
        i + 1,
        e,
        'Expected rule "${e.expectedRule}"; got "${result.ruleName}".',
      );
      failed++;
      continue;
    }
    if (e.expectedTemplate != null &&
        result.templateName != e.expectedTemplate) {
      _failExpectation(
        i + 1,
        e,
        'Expected template "${e.expectedTemplate}"; got '
            '"${result.templateName}".',
      );
      failed++;
      continue;
    }
    stdout.writeln('  ✓ rule=${result.ruleName} template=${result.templateName} '
        'params=${result.params}');
    stdout.writeln('    invariant: ${result.invariant.describe()}');

    // Check invariant against the sample returns.
    final invResult = result.invariant.evaluate(e.invariantOnReturns);
    if (invResult.passed != e.invariantShouldPass) {
      _failExpectation(
        i + 1,
        e,
        'Expected invariant ${e.invariantShouldPass ? "pass" : "fail"} '
            'on input ${e.invariantOnReturns}; observed '
            '${invResult.passed ? "pass" : "fail"} '
            '(violation: ${invResult.violation ?? "<none>"}).',
      );
      failed++;
      continue;
    }
    stdout.writeln('  ✓ invariant ${invResult.passed ? "passed" : "failed (as expected)"}'
        '${invResult.violation == null ? "" : "\n    violation: ${invResult.violation}"}');
    passed++;
  }

  await db.close();
  stdout.writeln('');
  stdout.writeln('=== summary: $passed passed, $failed failed '
      '(of ${_expectations.length} total) ===');
  if (failed > 0) {
    exit(1);
  }
}

void _failExpectation(int idx, _Expectation e, String message) {
  stderr.writeln('  ✗ FAIL: $message');
}

Never _fail(String step, String message) {
  stderr.writeln('');
  stderr.writeln('!!! FAIL at $step:');
  stderr.writeln('!!! $message');
  exit(1);
}
