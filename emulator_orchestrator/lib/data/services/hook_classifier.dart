/// Deterministic, no-LLM rule engine that maps a Ghidra-extracted
/// function (signature + decompilation + data symbols) to one of the
/// hooks-dart catalog templates (`returnHook`, `incrementHook`, etc.)
/// PLUS a runtime invariant that the candidate's harness output must
/// satisfy.
///
/// The rule set is documented in the plan
/// (`/home/evan/.claude/plans/radiant-inventing-dream.md` § Q3
/// answer). Each rule is implemented here as a [HookRule] entry in
/// the const [_kRules] list. Adding a rule is one list entry — the
/// engine in [HookClassifier.classify] is pure dispatch.
///
/// "No template fits" is the literal complement of all the rules:
/// when every rule's `match` returns false, `classify` returns null
/// and the caller (`LlmHookGenerator`) falls through to the LLM
/// path. That fall-through is the documented and only such path;
/// it's the definition the plan demands.
library;

import 'package:renode/renode.dart' show Hook;
import 'package:resect_hooks/resect_hooks.dart' show incrementHook, returnHook;
import 'package:signatures/signatures.dart'
    show DataSymbol, FunctionSignature;

/// Result of [HookClassifier.classify]: which template matched, the
/// materialised hook body, and the post-execution invariant the
/// scorer will evaluate against the harness's captured returns.
class ClassificationResult {
  const ClassificationResult({
    required this.ruleName,
    required this.templateName,
    required this.hook,
    required this.invariant,
    required this.params,
  });

  /// Short human-readable rule identifier, e.g. "rule-3-counter".
  /// Surfaced in the dialog so the user sees *why* a particular
  /// template was picked.
  final String ruleName;

  /// Name of the catalog helper invoked, e.g. "returnHook" or
  /// "incrementHook". The catalog template is in
  /// `hooks-dart/lib/src/simple_hooks.dart`.
  final String templateName;

  /// The materialised hook — `.code` is the Python body ready for
  /// installation via `client.addHook` or
  /// `HookTestHarness.runHook(hookCode: ...)`.
  final Hook hook;

  /// The named params the template was invoked with. Surfaced for
  /// telemetry and the dialog breakdown.
  final Map<String, Object> params;

  /// Post-execution invariant. The scorer calls
  /// `invariant.evaluate(returnValues)` after the harness completes;
  /// failure of the invariant gate-fails the candidate.
  final HookInvariant invariant;
}

/// A check that runs after the harness captures the 10 return values
/// produced by 10 successive `main()` calls in the bundled rig.
abstract class HookInvariant {
  const HookInvariant();

  /// One-line description for the dialog breakdown.
  String describe();

  /// Evaluate against the captured returns. The 10-entry list is the
  /// `HookTestResult.returnValues` field. A non-passing result
  /// gate-fails the candidate; the violation string is surfaced
  /// verbatim to the user.
  InvariantResult evaluate(List<int> returnValues);
}

class InvariantResult {
  const InvariantResult.pass()
      : passed = true,
        violation = null;
  const InvariantResult.fail(String reason)
      : passed = false,
        violation = reason;

  final bool passed;
  final String? violation;
}

// ---------------------------------------------------------------------------
// Concrete invariants
// ---------------------------------------------------------------------------

/// "All N return values equal a fixed constant K." The default
/// invariant for `returnHook(K)` outputs (Rules 1, 2, 6, 7).
class _AllReturnsEqualInvariant extends HookInvariant {
  const _AllReturnsEqualInvariant(this.expected);
  final int expected;

  @override
  String describe() => 'all 10 returns == $expected';

  @override
  InvariantResult evaluate(List<int> returnValues) {
    if (returnValues.isEmpty) {
      return const InvariantResult.fail(
          'No return values captured (bootstrap did not run main()).');
    }
    for (var i = 0; i < returnValues.length; i++) {
      if (returnValues[i] != expected) {
        return InvariantResult.fail(
          'Expected all returns == $expected; observed '
          'returnValues[$i] == ${returnValues[i]}. Full list: $returnValues',
        );
      }
    }
    return const InvariantResult.pass();
  }
}

/// "Returns are strictly monotonically increasing across the 10
/// calls AND non-zero by the second call." The invariant for
/// `incrementHook(...)` outputs (Rule 3). This is what catches the
/// HAL_GetTick → `setReturnValue(cpu, 0)` failure mode: a constant-0
/// output violates both clauses.
class _StrictlyIncreasingInvariant extends HookInvariant {
  const _StrictlyIncreasingInvariant();

  @override
  String describe() =>
      'returns strictly monotonically increasing; non-zero by call 2';

  @override
  InvariantResult evaluate(List<int> returnValues) {
    if (returnValues.length < 2) {
      return InvariantResult.fail(
        'Expected at least 2 return values to verify monotonicity; '
        'observed ${returnValues.length}. Full list: $returnValues',
      );
    }
    for (var i = 1; i < returnValues.length; i++) {
      if (returnValues[i] <= returnValues[i - 1]) {
        return InvariantResult.fail(
          'Expected strictly increasing returns; observed '
          'returnValues[$i] == ${returnValues[i]} '
          '<= returnValues[${i - 1}] == ${returnValues[i - 1]}. '
          'Full list: $returnValues',
        );
      }
    }
    if (returnValues[1] == 0) {
      return InvariantResult.fail(
        'Expected non-zero return by call 2 (a counter-style hook '
        'should advance at least once across the first two calls); '
        'observed returnValues[1] == 0. Full list: $returnValues',
      );
    }
    return const InvariantResult.pass();
  }
}

/// "All 10 returns ∈ {0, 1} AND equal the busy/ready default."
/// Rule 5's invariant: a peripheral-status query returns a boolean
/// flag; the catalog substitute returns the "all clear" value (0
/// for *Busy*, 1 for *Ready*/Active*).
class _BinaryFlagInvariant extends HookInvariant {
  const _BinaryFlagInvariant(this.expected);
  final int expected; // 0 or 1

  @override
  String describe() =>
      'all 10 returns == $expected (status flag; busy→0, ready→1)';

  @override
  InvariantResult evaluate(List<int> returnValues) {
    if (returnValues.isEmpty) {
      return const InvariantResult.fail('No return values captured.');
    }
    for (var i = 0; i < returnValues.length; i++) {
      final v = returnValues[i];
      if (v != 0 && v != 1) {
        return InvariantResult.fail(
          'Expected returns ∈ {0, 1}; observed returnValues[$i] == $v. '
          'Full list: $returnValues',
        );
      }
      if (v != expected) {
        return InvariantResult.fail(
          'Expected all returns == $expected (status flag); '
          'observed returnValues[$i] == $v. Full list: $returnValues',
        );
      }
    }
    return const InvariantResult.pass();
  }
}

/// "All 10 returns equal a chip default for a clock/frequency
/// global, and that default falls in the [1 MHz, 200 MHz] plausible
/// MCU clock range." Rule 4's invariant.
class _ChipClockInvariant extends HookInvariant {
  const _ChipClockInvariant(this.expectedHz);
  final int expectedHz;

  @override
  String describe() => 'all 10 returns == $expectedHz Hz '
      '(value in plausible MCU clock range [1 MHz, 200 MHz])';

  @override
  InvariantResult evaluate(List<int> returnValues) {
    if (returnValues.isEmpty) {
      return const InvariantResult.fail('No return values captured.');
    }
    const minHz = 1000000;
    const maxHz = 200000000;
    for (var i = 0; i < returnValues.length; i++) {
      final v = returnValues[i];
      if (v != expectedHz) {
        return InvariantResult.fail(
          'Expected all returns == $expectedHz; observed '
          'returnValues[$i] == $v. Full list: $returnValues',
        );
      }
      if (v < minHz || v > maxHz) {
        return InvariantResult.fail(
          'Expected return in [1 MHz, 200 MHz]; observed $v Hz.',
        );
      }
    }
    return const InvariantResult.pass();
  }
}

/// "All 10 returns equal HAL_OK (0) AND none equal HAL_ERROR (1) /
/// HAL_BUSY (2) / HAL_TIMEOUT (3)." Rule 7's invariant for hooks
/// that substitute a HAL polling loop with a no-op success return.
class _HalOkInvariant extends HookInvariant {
  const _HalOkInvariant();

  @override
  String describe() => 'all 10 returns == 0 (HAL_OK); none ∈ '
      '{HAL_ERROR=1, HAL_BUSY=2, HAL_TIMEOUT=3}';

  @override
  InvariantResult evaluate(List<int> returnValues) {
    if (returnValues.isEmpty) {
      return const InvariantResult.fail('No return values captured.');
    }
    const halErrors = {1, 2, 3};
    for (var i = 0; i < returnValues.length; i++) {
      final v = returnValues[i];
      if (halErrors.contains(v)) {
        const names = {1: 'HAL_ERROR', 2: 'HAL_BUSY', 3: 'HAL_TIMEOUT'};
        return InvariantResult.fail(
          'Expected HAL_OK (0); observed returnValues[$i] == $v '
          '(${names[v]}). Full list: $returnValues',
        );
      }
      if (v != 0) {
        return InvariantResult.fail(
          'Expected all returns == 0 (HAL_OK); observed '
          'returnValues[$i] == $v. Full list: $returnValues',
        );
      }
    }
    return const InvariantResult.pass();
  }
}

// ---------------------------------------------------------------------------
// Rule data + matcher
// ---------------------------------------------------------------------------

/// One classifier rule. The engine evaluates these in order; first
/// `match` that returns a non-null [ClassificationResult] wins.
typedef _RuleMatcher = ClassificationResult? Function(
  String functionName,
  FunctionSignature signature,
  String decompilationBody,
  Map<String, DataSymbol> dataSymbols,
);

/// The full rule list. Order matters: more specific rules earlier.
/// Rules emit [ClassificationResult] on match, null on miss.
///
/// Ordering rationale:
///   1. Rule 1 — trivial empty/void body (catches the simplest case
///      before anything else evaluates patterns).
///   2. Rule 2 — `return <literal>;` is more specific than Rule 6's
///      "any peripheral-write body".
///   3. Rule 3 — `return <counter-named-global>;` must come BEFORE
///      Rule 4, which would also match `return <global>;` for any
///      clock-named global.
///   4. Rule 4 — chip-config global return.
///   5. Rule 5 — peripheral-status-flag pattern with parens/masking.
///   6. Rule 7 — HAL polling loop (multi-statement; needs to be
///      checked before Rule 6 which has weaker preconditions).
///   7. Rule 6 — catch-all for void-returning peripheral writers.
const List<({String name, _RuleMatcher match})> _kRules = [
  (name: 'rule-1-empty-or-void-return', match: _rule1EmptyOrVoidReturn),
  (name: 'rule-2-return-literal', match: _rule2ReturnLiteral),
  (name: 'rule-3-counter-global', match: _rule3CounterGlobal),
  (name: 'rule-4-chip-config-global', match: _rule4ChipConfigGlobal),
  (name: 'rule-5-busy-ready-flag', match: _rule5BusyReadyFlag),
  (name: 'rule-7-hal-polling-loop', match: _rule7HalPollingLoop),
  (name: 'rule-6-pure-peripheral-writes', match: _rule6PurePeripheralWrites),
];

/// Pure dispatch over the rule list. Returns null when no rule
/// matched ("no template fits") — caller (`LlmHookGenerator`) falls
/// through to the LLM path.
class HookClassifier {
  const HookClassifier();

  ClassificationResult? classify({
    required String functionName,
    required FunctionSignature signature,
    required String decompilation,
    required Map<String, DataSymbol> dataSymbols,
  }) {
    final body = _extractFunctionBody(decompilation);
    for (final rule in _kRules) {
      final result = rule.match(
        functionName,
        signature,
        body,
        dataSymbols,
      );
      if (result != null) return result;
    }
    return null;
  }
}

/// Strip Ghidra's `/* WARNING ... */` comments + the function-header
/// declaration, leaving just the `{ ... }` body's statements as plain
/// text. The match-rules operate on this normalised body.
///
/// Returns the empty string when the decompilation didn't include a
/// `{`/`}` block (e.g. extracted-but-failed decompilations).
String _extractFunctionBody(String decompilation) {
  final stripped = decompilation
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'//[^\n]*'), '');
  final openBrace = stripped.indexOf('{');
  final closeBrace = stripped.lastIndexOf('}');
  if (openBrace < 0 || closeBrace < 0 || closeBrace <= openBrace) {
    return '';
  }
  final inner = stripped.substring(openBrace + 1, closeBrace);
  // Drop local variable declarations of the form `type name;` at the
  // top of the body — Ghidra emits these for every `_local` synthetic
  // and they're noise for the pattern-matchers. Crucially we must
  // NOT drop `return <ident>;` — that's a statement, not a decl, and
  // its presence is what Rules 3/4 match on. We discriminate by
  // requiring the leading token to NOT be a C statement keyword.
  const statementKeywords = {
    'return', 'if', 'else', 'while', 'do', 'for', 'switch', 'case',
    'default', 'break', 'continue', 'goto', 'sizeof',
  };
  final declRegex = RegExp(
    r'^([A-Za-z_]\w*)[\s*]+[A-Za-z_]\w*(\s*,\s*[A-Za-z_]\w*)*\s*;$',
  );
  final lines = inner.split('\n');
  final kept = <String>[];
  var seenStatement = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final m = declRegex.firstMatch(line);
    final looksLikeDecl =
        m != null && !statementKeywords.contains(m.group(1));
    if (looksLikeDecl && !seenStatement) {
      continue;
    }
    seenStatement = true;
    kept.add(line);
  }
  return kept.join('\n').trim();
}

// ---------------------------------------------------------------------------
// Rule 1 — empty body / void return
// ---------------------------------------------------------------------------

ClassificationResult? _rule1EmptyOrVoidReturn(
  String functionName,
  FunctionSignature signature,
  String body,
  Map<String, DataSymbol> dataSymbols,
) {
  final isEmptyBody = body.isEmpty;
  final isBareReturn = body == 'return;';
  if (!(isEmptyBody || isBareReturn)) return null;
  return ClassificationResult(
    ruleName: 'rule-1-empty-or-void-return',
    templateName: 'returnHook',
    hook: returnHook(0),
    params: const {'returnValue': 0},
    invariant: const _AllReturnsEqualInvariant(0),
  );
}

// ---------------------------------------------------------------------------
// Rule 3 — counter / tick global
// ---------------------------------------------------------------------------
//
// Match shape: the body is a single `return <ident>;` AND <ident> is
// a known data_symbol AND the name suggests a counter / tick / event
// counter.

final _kReturnIdentifier = RegExp(r'^return\s+([A-Za-z_]\w*)\s*;$');
final _kCounterName =
    RegExp('tick|counter|cnt|ms_count|systicks', caseSensitive: false);

ClassificationResult? _rule3CounterGlobal(
  String functionName,
  FunctionSignature signature,
  String body,
  Map<String, DataSymbol> dataSymbols,
) {
  final match = _kReturnIdentifier.firstMatch(body);
  if (match == null) return null;
  final ident = match.group(1)!;
  if (!dataSymbols.containsKey(ident)) return null;
  if (!_kCounterName.hasMatch(ident)) return null;
  return ClassificationResult(
    ruleName: 'rule-3-counter-global',
    templateName: 'incrementHook',
    hook: incrementHook(functionName, defaultValue: 0),
    params: {'scope': functionName, 'defaultValue': 0},
    invariant: const _StrictlyIncreasingInvariant(),
  );
}

// ---------------------------------------------------------------------------
// Rule 2 — return literal constant
// ---------------------------------------------------------------------------
//
// Match shape: body is exactly `return <integer-literal>;` (decimal
// or 0xHEX). The constant is the value the original always
// returned, and the substitute reproduces it verbatim.

final _kReturnLiteral =
    RegExp(r'^return\s+(0x[0-9a-fA-F]+|-?\d+)\s*;$');

ClassificationResult? _rule2ReturnLiteral(
  String functionName,
  FunctionSignature signature,
  String body,
  Map<String, DataSymbol> dataSymbols,
) {
  final match = _kReturnLiteral.firstMatch(body);
  if (match == null) return null;
  final raw = match.group(1)!;
  // `int.parse(raw, radix: 16)` does NOT accept the `0x` prefix; the
  // prefix is only auto-detected when radix is null (and even then
  // negative-hex isn't handled). Strip the prefix explicitly and use
  // tryParse so a malformed literal returns null instead of throwing
  // — one bad function shouldn't crash the whole seed pass.
  final int? value;
  if (raw.startsWith('-0x')) {
    final unsigned = int.tryParse(raw.substring(3), radix: 16);
    value = unsigned == null ? null : -unsigned;
  } else if (raw.startsWith('0x')) {
    value = int.tryParse(raw.substring(2), radix: 16);
  } else {
    value = int.tryParse(raw);
  }
  if (value == null) return null;
  return ClassificationResult(
    ruleName: 'rule-2-return-literal',
    templateName: 'returnHook',
    hook: returnHook(value),
    params: {'returnValue': value},
    invariant: _AllReturnsEqualInvariant(value),
  );
}

// ---------------------------------------------------------------------------
// Rule 4 — chip-config global (clock / frequency)
// ---------------------------------------------------------------------------
//
// Match shape: `return <identifier>;` where <identifier> matches a
// clock/frequency name pattern (SystemCoreClock, HCLK, etc.). The
// substitute returns a plausible MCU clock default — currently
// 64 MHz (the STM32WB05 typical core clock). Future work: derive
// the default from chip ID / .repl peripherals.

final _kClockName = RegExp(
  '(SystemCoreClock|SystemClock|HCLK|PCLK|AHB.*Clock|APB.*Clock)',
  caseSensitive: false,
);
const _kDefaultChipClockHz = 64000000;

ClassificationResult? _rule4ChipConfigGlobal(
  String functionName,
  FunctionSignature signature,
  String body,
  Map<String, DataSymbol> dataSymbols,
) {
  final match = _kReturnIdentifier.firstMatch(body);
  if (match == null) return null;
  final ident = match.group(1)!;
  if (!_kClockName.hasMatch(ident)) return null;
  return ClassificationResult(
    ruleName: 'rule-4-chip-config-global',
    templateName: 'returnHook',
    hook: returnHook(_kDefaultChipClockHz),
    params: {'returnValue': _kDefaultChipClockHz, 'identifier': ident},
    invariant: const _ChipClockInvariant(_kDefaultChipClockHz),
  );
}

// ---------------------------------------------------------------------------
// Rule 5 — busy / ready flag from a peripheral status read
// ---------------------------------------------------------------------------
//
// Match shape: body is `return (<cast>)(<expr> & <mask> [== <const>]);`
// or `return (<expr> & <mask>) != 0;` — the canonical
// peripheral-status-bit return.
//
// Classification by function name:
//   /busy/i              → returnHook(0)  (not busy)
//   /ready|active|isset|valid|present/i → returnHook(1)  (ready)
//   else                 → no match (LLM path)

final _kFlagMaskReturn =
    RegExp(r'^return\s+.*?\([^)]*?&[^)]*?\)[^;]*;$');
final _kBusyName = RegExp('busy', caseSensitive: false);
final _kReadyName =
    RegExp('ready|active|isset|valid|present', caseSensitive: false);

ClassificationResult? _rule5BusyReadyFlag(
  String functionName,
  FunctionSignature signature,
  String body,
  Map<String, DataSymbol> dataSymbols,
) {
  if (!_kFlagMaskReturn.hasMatch(body)) return null;
  final int expected;
  if (_kBusyName.hasMatch(functionName)) {
    expected = 0;
  } else if (_kReadyName.hasMatch(functionName)) {
    expected = 1;
  } else {
    return null; // ambiguous name; fall through to LLM
  }
  return ClassificationResult(
    ruleName: 'rule-5-busy-ready-flag',
    templateName: 'returnHook',
    hook: returnHook(expected),
    params: {'returnValue': expected, 'classification': expected == 0 ? 'busy' : 'ready'},
    invariant: _BinaryFlagInvariant(expected),
  );
}

// ---------------------------------------------------------------------------
// Rule 7 — HAL polling loop returning HAL_StatusTypeDef
// ---------------------------------------------------------------------------
//
// Match shape: body contains a call to `HAL_GetTick()` AND a
// `do { ... } while (...)` loop AND the signature's return type
// is `HAL_StatusTypeDef` (or any *Status* typedef). The polling
// pattern is "wait for hardware to be ready or time out"; the
// substitute just reports HAL_OK (= 0) immediately.

final _kHalGetTickCall = RegExp(r'\bHAL_GetTick\s*\(');
final _kDoWhileLoop = RegExp(r'\bdo\s*\{[\s\S]*?\}\s*while\b');

ClassificationResult? _rule7HalPollingLoop(
  String functionName,
  FunctionSignature signature,
  String body,
  Map<String, DataSymbol> dataSymbols,
) {
  final retType = signature.returnType;
  if (!retType.contains('HAL_StatusTypeDef') && !retType.contains('Status')) {
    return null;
  }
  if (!_kHalGetTickCall.hasMatch(body)) return null;
  if (!_kDoWhileLoop.hasMatch(body)) return null;
  return ClassificationResult(
    ruleName: 'rule-7-hal-polling-loop',
    templateName: 'returnHook',
    hook: returnHook(0),
    params: const {'returnValue': 0, 'meaning': 'HAL_OK'},
    invariant: const _HalOkInvariant(),
  );
}

// ---------------------------------------------------------------------------
// Rule 6 — pure peripheral writes, void return
// ---------------------------------------------------------------------------
//
// Match shape: the body contains only statements of the form
//   `_DAT_<hex> = <expr>;`              (Ghidra global-via-address)
//   `<ident>-><field> = <expr>;`        (peripheral struct field
//                                         assignment)
//   `<ident>.<field> = <expr>;`         (peripheral struct field
//                                         assignment, dot form)
//   `return;`                           (terminal)
// AND the return type is `void`. No reads, no branches, no calls.
// Empty body matches Rule 1 instead.

final _kPeripheralWriteStmt = RegExp(
  '^('
  r'_DAT_[0-9a-fA-F]+\s*=\s*[^;]+;'
  r'|[A-Za-z_]\w*\s*->\s*\w+\s*=\s*[^;]+;'
  r'|[A-Za-z_]\w*\s*\.\s*\w+\s*=\s*[^;]+;'
  r'|return\s*;'
  r')$',
);

ClassificationResult? _rule6PurePeripheralWrites(
  String functionName,
  FunctionSignature signature,
  String body,
  Map<String, DataSymbol> dataSymbols,
) {
  if (body.isEmpty) return null;
  if (signature.returnType != 'void') return null;
  final lines = body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
  for (final line in lines) {
    if (!_kPeripheralWriteStmt.hasMatch(line)) return null;
  }
  return ClassificationResult(
    ruleName: 'rule-6-pure-peripheral-writes',
    templateName: 'returnHook',
    hook: returnHook(0),
    params: const {'returnValue': 0},
    invariant: const _AllReturnsEqualInvariant(0),
  );
}
