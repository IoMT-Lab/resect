/// Static analysis pass over a candidate hook + the original
/// function's decompilation + the project's `.repl` map. Produces
/// two gate-level signals salvaged from the proposed equivalence
/// checker (see plan §"Static checks: mod-set containment and
/// unmapped-access count"):
///
/// 1. **Mod-set containment**: every memory address the candidate
///    writes must be an address the original also writes (or the
///    candidate writes nothing). Catches hallucinated writes —
///    e.g. an LLM-generated hook that pokes a register the
///    original function never touched.
///
/// 2. **Unmapped-access budget**: every literal memory address the
///    candidate reads/writes must be in a region mapped by the
///    user's project `.repl`. Catches hooks that would generate
///    unhandled access in the user's actual emulator.
///
/// Both checks operate on STATICALLY-RESOLVABLE addresses only.
/// Hex literals, parameter-pointer accesses (matched by arg index),
/// and writes through identified globals are covered. Computed
/// addresses (`base + offset` where either side isn't a literal)
/// fall through to runtime — that's the harness's job, not ours.
///
/// Implementation: Dart regex over the Ghidra decompilation +
/// `.repl`, Python AST shell-out for the hook body (same
/// `python3 -c` pattern the integration test already uses).
library;

import 'dart:convert';
import 'dart:io';

/// A single memory-write site, in a form that can be compared
/// across "the original wrote here" and "the candidate writes
/// here". The three variants are mutually exclusive; exactly one of
/// [exactAddress], [throughArgIndex], or [globalRegion] is set.
class WriteFootprint {
  const WriteFootprint.exact(int address)
      : exactAddress = address,
        throughArgIndex = null,
        globalRegion = null;

  const WriteFootprint.throughArg(int argIndex)
      : exactAddress = null,
        throughArgIndex = argIndex,
        globalRegion = null;

  const WriteFootprint.globalRegion(String name)
      : exactAddress = null,
        throughArgIndex = null,
        globalRegion = name;

  /// Literal address (e.g. `0x48400054`) when the write target is
  /// a hex constant. Set for both Ghidra's `_DAT_<hex> = ...` form
  /// and a Python hook's `cpu.Bus.WriteDoubleWord(0x48400054, ...)`.
  final int? exactAddress;

  /// Argument index (0-based; corresponds to R0/R1/R2/R3 under
  /// ARM AAPCS) when the write goes through a pointer parameter
  /// — e.g. `*<param> = ...` in the original, or
  /// `pointer.writeData(cpu, ptr, ...)` where `ptr` came from
  /// `cpu.GetRegister(N)` in the candidate.
  final int? throughArgIndex;

  /// Name of a global region — e.g. an array name in the original
  /// (`results[i] = ...`) or a fallback when the analyser
  /// recognised "writes-to-region" but couldn't pin a literal.
  final String? globalRegion;

  /// Two footprints match when they're the same kind and the
  /// kind's discriminator agrees. Used for `subset` checks.
  bool matches(WriteFootprint other) {
    if (exactAddress != null) return exactAddress == other.exactAddress;
    if (throughArgIndex != null) {
      return throughArgIndex == other.throughArgIndex;
    }
    if (globalRegion != null) return globalRegion == other.globalRegion;
    return false;
  }

  @override
  String toString() {
    if (exactAddress != null) {
      return '0x${exactAddress!.toRadixString(16)}';
    }
    if (throughArgIndex != null) return '*arg$throughArgIndex';
    if (globalRegion != null) return 'global:$globalRegion';
    return '<unknown>';
  }

  @override
  bool operator ==(Object other) =>
      other is WriteFootprint &&
      exactAddress == other.exactAddress &&
      throughArgIndex == other.throughArgIndex &&
      globalRegion == other.globalRegion;

  @override
  int get hashCode => Object.hash(exactAddress, throughArgIndex, globalRegion);
}

/// One `[start, end)` range from the project's `.repl`, plus the
/// peripheral name for the diagnostic.
class MappedRegion {
  const MappedRegion({
    required this.name,
    required this.start,
    required this.end,
  });

  final String name;
  final int start;
  final int end;

  bool contains(int address) => address >= start && address < end;
}

/// Outcome of [HookStaticAnalyzer.evaluate]. Two boolean checks and
/// per-check diagnostic lists for surfacing in the dialog.
class StaticCheckResult {
  const StaticCheckResult({
    required this.modSetContained,
    required this.hallucinatedWrites,
    required this.unmappedAccesses,
    required this.candidateWrites,
    required this.candidateReads,
    required this.originalWrites,
  });

  final bool modSetContained;
  final List<WriteFootprint> hallucinatedWrites;
  final List<int> unmappedAccesses;

  // Surfaced for the diagnostic UI / telemetry, not used for gating.
  final Set<WriteFootprint> candidateWrites;
  final Set<int> candidateReads;
  final Set<WriteFootprint> originalWrites;

  bool get unmappedAccessOk => unmappedAccesses.isEmpty;

  /// One-line "what failed" string, or null if both checks passed.
  String? get violation {
    if (!modSetContained && hallucinatedWrites.isNotEmpty) {
      final addrs = hallucinatedWrites.map((w) => '$w').join(', ');
      return 'candidate writes $addrs which the original does not. '
          'original writes: '
          '${originalWrites.isEmpty ? "<none>" : originalWrites.join(", ")}';
    }
    if (!unmappedAccessOk) {
      final addrs = unmappedAccesses
          .map((a) => '0x${a.toRadixString(16)}')
          .join(', ');
      return 'candidate accesses $addrs which is/are outside any '
          '.repl-mapped region (would generate unhandled access in '
          'the user\'s emulator).';
    }
    return null;
  }
}

/// Always-mapped region for the Cortex-M Private Peripheral Bus —
/// the CPU handles this range directly regardless of `.repl`. Added
/// to the parsed regions so a hook that touches NVIC / SCB / SysTick
/// doesn't trip the unmapped-access check.
const _kCortexMPpb = MappedRegion(
  name: 'cortex-m-ppb',
  start: 0xE0000000,
  end: 0xE0100000,
);

/// The full static-analysis pass. Stateless; safe to share.
class HookStaticAnalyzer {
  const HookStaticAnalyzer();

  /// Run both checks. Inputs are the same data the dialog already
  /// has on hand: the candidate hook body, the function's
  /// decompilation (from `ghidra_decompilations`), the parameter
  /// list from the signature (used to match `<param>-> field`
  /// writes to arg indices), and the `.repl` content.
  Future<StaticCheckResult> evaluate({
    required String candidateCode,
    required String originalDecompilation,
    required List<String> parameterNames,
    required String replContent,
  }) async {
    final originalWrites =
        _parseOriginalWrites(originalDecompilation, parameterNames);
    final candidateAccesses = await _parseCandidateAccesses(candidateCode);
    final candidateWrites = candidateAccesses.writes;
    final candidateReads = candidateAccesses.reads;
    final regions = _parseRepl(replContent);

    // Mod-set containment: every candidate write must match some
    // original write. Empty candidate-set trivially passes.
    final hallucinated = <WriteFootprint>[];
    for (final w in candidateWrites) {
      if (!originalWrites.any((o) => o.matches(w))) {
        hallucinated.add(w);
      }
    }
    final modSetContained = hallucinated.isEmpty;

    // Unmapped-access budget: every literal address (read or
    // write) must fall inside some mapped region.
    final unmapped = <int>[];
    for (final addr in {
      ...candidateReads,
      for (final w in candidateWrites)
        if (w.exactAddress != null) w.exactAddress!,
    }) {
      final inRegion = regions.any((r) => r.contains(addr)) ||
          _kCortexMPpb.contains(addr);
      if (!inRegion) unmapped.add(addr);
    }
    unmapped.sort();

    return StaticCheckResult(
      modSetContained: modSetContained,
      hallucinatedWrites: hallucinated,
      unmappedAccesses: unmapped,
      candidateWrites: candidateWrites,
      candidateReads: candidateReads,
      originalWrites: originalWrites,
    );
  }
}

// ---------------------------------------------------------------------------
// Parse the original's writes from Ghidra decompilation text.
// ---------------------------------------------------------------------------

final _kDatWrite = RegExp(r'_DAT_([0-9a-fA-F]+)\s*=');
final _kPtrFieldWrite = RegExp(r'([A-Za-z_]\w*)\s*->\s*\w+\s*=');
final _kPtrDerefWrite = RegExp(r'\*\s*([A-Za-z_]\w*)\s*=');
final _kIndexWrite = RegExp(r'\b([A-Za-z_]\w*)\s*\[[^\]]+\]\s*=');

Set<WriteFootprint> _parseOriginalWrites(
  String decompilation,
  List<String> parameterNames,
) {
  final paramIndex = <String, int>{
    for (var i = 0; i < parameterNames.length; i++) parameterNames[i]: i,
  };
  // Some Ghidra decompilations also expose a `<param>_local` synthetic
  // copy of the parameter. Treat it the same as the param for
  // through-arg matching.
  for (final p in parameterNames.toList()) {
    paramIndex.putIfAbsent('${p}_local', () => paramIndex[p]!);
  }

  final out = <WriteFootprint>{};
  // `_DAT_<hex> = ...;` — exact address.
  for (final m in _kDatWrite.allMatches(decompilation)) {
    out.add(WriteFootprint.exact(int.parse(m.group(1)!, radix: 16)));
  }
  // `<ptr>-><field> = ...;` — through-arg if <ptr> is a param.
  for (final m in _kPtrFieldWrite.allMatches(decompilation)) {
    final ptr = m.group(1)!;
    final idx = paramIndex[ptr];
    if (idx != null) {
      out.add(WriteFootprint.throughArg(idx));
    } else {
      out.add(WriteFootprint.globalRegion(ptr));
    }
  }
  // `*<ptr> = ...;` — same logic.
  for (final m in _kPtrDerefWrite.allMatches(decompilation)) {
    final ptr = m.group(1)!;
    final idx = paramIndex[ptr];
    if (idx != null) {
      out.add(WriteFootprint.throughArg(idx));
    } else {
      out.add(WriteFootprint.globalRegion(ptr));
    }
  }
  // `<global>[<expr>] = ...;` — region.
  for (final m in _kIndexWrite.allMatches(decompilation)) {
    final name = m.group(1)!;
    if (!paramIndex.containsKey(name)) {
      out.add(WriteFootprint.globalRegion(name));
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Parse candidate's writes + reads via python3 AST shell-out.
// ---------------------------------------------------------------------------

class _CandidateAccesses {
  const _CandidateAccesses({required this.writes, required this.reads});
  final Set<WriteFootprint> writes;
  final Set<int> reads;
}

/// Python helper: parses the hook body's AST and emits JSON listing
/// every `cpu.Bus.*` / `pointer.*` call along with the address
/// argument's static form (literal int, GetRegister arg index, or
/// "unknown").
///
/// Kept here as a const string for the same reason
/// `dumpProgramInfoScript` is: bundling the helper into the dart
/// binary avoids package-resource resolution at runtime.
const String _kAstWalker = r'''
import ast, json, sys

WRITE_FUNCS = {
  ('cpu.Bus.WriteByte', 'cpu.Bus.WriteWord', 'cpu.Bus.WriteDoubleWord',
   'cpu.Bus.WriteQuadWord', 'cpu.Bus.WriteBytes', 'pointer.writeData')
}
READ_FUNCS = {
  ('cpu.Bus.ReadByte', 'cpu.Bus.ReadWord', 'cpu.Bus.ReadDoubleWord',
   'cpu.Bus.ReadQuadWord', 'cpu.Bus.ReadBytes', 'pointer.readData')
}

def dotted_name(node):
    """Returns the dotted call target ('cpu.Bus.WriteBytes') or None."""
    parts = []
    cur = node
    while isinstance(cur, ast.Attribute):
        parts.append(cur.attr)
        cur = cur.value
    if isinstance(cur, ast.Name):
        parts.append(cur.id)
        return '.'.join(reversed(parts))
    return None

def get_register_arg(node):
    """If node is `cpu.GetRegister(N).RawValue` or
    `int(cpu.GetRegister(N).RawValue)`, return N. Otherwise None."""
    # Unwrap int(...) wrapping
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'int':
        if node.args:
            node = node.args[0]
    # Now expect Attribute(Call(Attribute), 'RawValue')
    if isinstance(node, ast.Attribute) and node.attr == 'RawValue':
        inner = node.value
        if isinstance(inner, ast.Call):
            tgt = dotted_name(inner.func)
            if tgt == 'cpu.GetRegister' and inner.args:
                a = inner.args[0]
                if isinstance(a, ast.Constant) and isinstance(a.value, int):
                    return a.value
    return None

def literal_int(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    # Unwrap int(literal)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'int':
        if node.args:
            return literal_int(node.args[0])
    return None

# Map variable assignments so `addr = 0x48400054; Write(addr, ...)` resolves.
class VarMap(ast.NodeVisitor):
    def __init__(self):
        self.vars = {}
    def visit_Assign(self, node):
        if len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            v = literal_int(node.value)
            if v is not None:
                self.vars[node.targets[0].id] = ('int', v)
            else:
                reg = get_register_arg(node.value)
                if reg is not None:
                    self.vars[node.targets[0].id] = ('reg', reg)

def resolve(node, varmap):
    """Returns ('int', N) or ('reg', N) or None."""
    v = literal_int(node)
    if v is not None: return ('int', v)
    reg = get_register_arg(node)
    if reg is not None: return ('reg', reg)
    if isinstance(node, ast.Name) and node.id in varmap.vars:
        return varmap.vars[node.id]
    return None

src = sys.stdin.read()
try:
    tree = ast.parse(src)
except SyntaxError as e:
    print(json.dumps({'error': f'SyntaxError: {e}'}))
    sys.exit(0)

varmap = VarMap()
varmap.visit(tree)

writes = []
reads = []

# Address-arg positions per function family. Verified against
# Renode's IBusController .NET interface — the typed writes have
# offset at arg[0], not arg[1]:
#   cpu.Bus.WriteByte/Word/DoubleWord/QuadWord(addr, value) → arg[0]
#   cpu.Bus.WriteBytes(bytes, addr)        → arg[1] (signature is
#                                             WriteBytes(byte[], long))
#   cpu.Bus.ReadX(addr) / ReadBytes(addr, size) → arg[0]
#   pointer.writeData(cpu, ptr, data)      → ptr at arg[1]
#   pointer.readData(cpu, ptr, size)       → ptr at arg[1]
ADDR_ARG_INDEX = {
    'cpu.Bus.WriteByte': 0, 'cpu.Bus.WriteWord': 0,
    'cpu.Bus.WriteDoubleWord': 0, 'cpu.Bus.WriteQuadWord': 0,
    'cpu.Bus.WriteBytes': 1,
    'cpu.Bus.ReadByte': 0, 'cpu.Bus.ReadWord': 0,
    'cpu.Bus.ReadDoubleWord': 0, 'cpu.Bus.ReadQuadWord': 0,
    'cpu.Bus.ReadBytes': 0,
    'pointer.writeData': 1,
    'pointer.readData': 1,
}

WRITE_NAMES = {'cpu.Bus.WriteByte','cpu.Bus.WriteWord','cpu.Bus.WriteDoubleWord',
               'cpu.Bus.WriteQuadWord','cpu.Bus.WriteBytes','pointer.writeData'}
READ_NAMES  = {'cpu.Bus.ReadByte','cpu.Bus.ReadWord','cpu.Bus.ReadDoubleWord',
               'cpu.Bus.ReadQuadWord','cpu.Bus.ReadBytes','pointer.readData'}

for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    name = dotted_name(node.func)
    if name is None:
        continue
    if name not in ADDR_ARG_INDEX:
        continue
    idx = ADDR_ARG_INDEX[name]
    if idx >= len(node.args):
        continue
    resolved = resolve(node.args[idx], varmap)
    is_write = name in WRITE_NAMES
    rec = {'call': name, 'line': node.lineno}
    if resolved is None:
        rec['address'] = None
    elif resolved[0] == 'int':
        rec['address'] = resolved[1]
    else:
        rec['arg_index'] = resolved[1]
    if is_write:
        writes.append(rec)
    else:
        reads.append(rec)

print(json.dumps({'writes': writes, 'reads': reads}))
''';

Future<_CandidateAccesses> _parseCandidateAccesses(String hookCode) async {
  final proc = await Process.start(
    'python3',
    ['-c', _kAstWalker],
    runInShell: false,
  );
  proc.stdin.add(utf8.encode(hookCode));
  await proc.stdin.close();
  final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
  final stderrFuture = proc.stderr.transform(utf8.decoder).join();
  final exitCode = await proc.exitCode;
  final stdoutBody = await stdoutFuture;
  final stderrBody = await stderrFuture;
  if (exitCode != 0) {
    throw StateError(
      'python3 AST walker exited $exitCode. stderr: $stderrBody',
    );
  }
  final parsed = jsonDecode(stdoutBody.trim()) as Map<String, dynamic>;
  if (parsed['error'] != null) {
    // Treat unparseable hooks as "no writes / no reads" — the
    // harness will gate-fail them on a Python syntax error
    // anyway; we don't double-flag.
    return const _CandidateAccesses(writes: {}, reads: {});
  }
  final writes = <WriteFootprint>{};
  final reads = <int>{};
  for (final raw in (parsed['writes'] as List).cast<Map<String, dynamic>>()) {
    final addr = raw['address'];
    final argIdx = raw['arg_index'];
    if (addr is int) {
      writes.add(WriteFootprint.exact(addr));
    } else if (argIdx is int) {
      writes.add(WriteFootprint.throughArg(argIdx));
    }
    // address == null && arg_index == null → computed; skip.
  }
  for (final raw in (parsed['reads'] as List).cast<Map<String, dynamic>>()) {
    final addr = raw['address'];
    if (addr is int) reads.add(addr);
  }
  return _CandidateAccesses(writes: writes, reads: reads);
}

// ---------------------------------------------------------------------------
// Parse the project's `.repl` for mapped regions.
// ---------------------------------------------------------------------------
//
// Match patterns we care about:
//   <name>: <type> @ sysbus <hex>
//   <name>: <type> @ sysbus <hex> { size: <hex> }
//
// The Renode .repl grammar is richer than this; we cover the
// straight-line declarations that produce a single address range.
// Anything more exotic (multi-region peripherals, inheritance) gets
// approximated — false negatives here just mean we flag an access
// as unmapped that the real emulator might actually handle. The
// dialog shows the offending address so the user can override.

final _kReplBaseOnly = RegExp(
  r'^\s*[A-Za-z_]\w*\s*:\s*[A-Za-z_][\w.]*\s+@\s+sysbus\s+0x([0-9a-fA-F]+)\s*$',
  multiLine: true,
);
final _kReplBaseWithSize = RegExp(
  r'^\s*([A-Za-z_]\w*)\s*:\s*[A-Za-z_][\w.]*\s+@\s+sysbus\s+0x([0-9a-fA-F]+)[\s\S]*?\bsize\s*:\s*0x([0-9a-fA-F]+)',
  multiLine: true,
);

List<MappedRegion> _parseRepl(String replContent) {
  final out = <MappedRegion>[_kCortexMPpb];
  // Pass 1 — base+size declarations (peripherals, memory blocks).
  for (final m in _kReplBaseWithSize.allMatches(replContent)) {
    final name = m.group(1)!;
    final base = int.parse(m.group(2)!, radix: 16);
    final size = int.parse(m.group(3)!, radix: 16);
    out.add(MappedRegion(name: name, start: base, end: base + size));
  }
  // Pass 2 — base-only declarations get a 4 KB default range so the
  // diagnostic still catches "way outside any peripheral" addresses.
  // Tight peripherals (e.g. UART at 0x40004400) usually have a
  // ~256-byte register map; 4 KB is generous in the right direction.
  final seenBases = {for (final r in out) r.start};
  for (final m in _kReplBaseOnly.allMatches(replContent)) {
    final base = int.parse(m.group(1)!, radix: 16);
    if (!seenBases.contains(base)) {
      out.add(MappedRegion(
        name: '<base-only>',
        start: base,
        end: base + 0x1000,
      ));
    }
  }
  return out;
}
