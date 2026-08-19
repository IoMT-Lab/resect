// Grade auto-tune report directories for the wrapper-skip pathologies
// observed in the Aug 3 collaborator capture: killing previously-working
// parent functions, targeting entry points, coverage collapses, lost
// best-so-far peaks, ignored leaf-spin evidence, and repeated
// recommendations.
//
// Run with (from emulator_orchestrator/):
//   dart run tool/grade_autotune_reports.dart --elf <fw.elf> <reportDir> [<reportDir> ...]
//
// Each reportDir is one session's autotune_reports/<timestamp>/ directory
// containing round_NN.md, round_NN_manifest.json, round_NN_trace.txt.
// The ELF is used to extract the call graph (objdump, in-process) for the
// callee walks; it must be the same firmware the session ran.
//
// Strict flags (any occurrence = session FAIL for that metric):
//   M-parent   Return-0 forced override on a symbol that executed cleanly
//              in the evidence round AND has an executed direct callee or
//              a transitive callee carrying an active override.
//   M-entry    any recommendation targeting main / Reset_Handler / _start.
//   M-collapse a round whose executed count fell below 50% of the prior
//              round's.
//   M-leaf     evidence showed a (xN >= 4) spin on an UNHOOKED symbol and
//              the round answered with caller Return-0s instead of an
//              override on that symbol.
// Report-only:
//   M-anchor   peak executed minus final executed (best-so-far gap).
//   M-repeat   emitted recommendations that were already in effect
//              (skipped-as-no-op count / total emitted).

import 'dart:convert';
import 'dart:io';

import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_call_graph_source.dart';

const _entryPoints = {'main', 'Reset_Handler', '_start'};

class _Rec {
  _Rec({required this.kind, this.symbol, this.artifactId});
  final String kind;
  final String? symbol;
  final int? artifactId;

  String get key => '$kind:${symbol ?? ''}:${artifactId ?? ''}';

  @override
  String toString() =>
      '$kind${symbol != null ? ' `$symbol`' : ''}'
      '${artifactId != null ? ' <- #$artifactId' : ''}';
}

class _Round {
  _Round(this.n);
  final int n;
  SynthesisManifest? manifest;
  final emitted = <_Rec>[];
  final applied = <_Rec>[];
  final skippedNoOps = <_Rec>[];
  String? haltSymbol;
  // Spin symbols from the evidence trace line: symbol -> repeat count.
  final spins = <String, int>{};
}

// Accepts both report line shapes: the pre-labeled `` ← #3 `` and the
// label-first `` ← "Return 1" (#3) `` the writer emits now.
final _recRe = RegExp(
    r'(set_forced_override|clear_forced_override|set_preference|'
    r'generate_custom_hook|set_group_override|clear_group_override)'
    r'\s+`([^`]+)`(?:\s+←\s+(?:#(\d+)|"[^"]*"\s+\(#(\d+)\)))?');
final _capRe = RegExp(r'(adjust_iteration_cap)\s+→\s+(\d+)');
final _catalogRe = RegExp(r'- id=(\d+)\s+\S+\s+"([^"]+)"');
final _haltRe = RegExp(r'- Halt point: `([^`]+)`');
final _spinRe = RegExp(r'`([^`]+)` \(×(\d+)\)');

Future<void> main(List<String> args) async {
  String? elfPath;
  final reportDirs = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--elf') {
      elfPath = args[++i];
    } else {
      reportDirs.add(args[i]);
    }
  }
  if (elfPath == null || reportDirs.isEmpty) {
    stderr.writeln('Usage: dart run tool/grade_autotune_reports.dart '
        '--elf <fw.elf> <reportDir> [...]');
    exit(1);
  }

  stderr.writeln('Extracting call graph from $elfPath ...');
  final callGraph = await DartCallGraphSource().getCallGraph(elfPath);
  stderr.writeln('Call graph: ${callGraph.totalFunctions} symbols');

  for (final dir in reportDirs) {
    await _gradeSession(dir, callGraph);
  }
}

Future<void> _gradeSession(String dir, CallGraph callGraph) async {
  final d = Directory(dir);
  if (!d.existsSync()) {
    stderr.writeln('No such report dir: $dir');
    return;
  }

  // ---- Parse rounds -------------------------------------------------------
  final rounds = <int, _Round>{};
  final artifactLabels = <int, String>{};

  _Round roundFor(int n) => rounds.putIfAbsent(n, () => _Round(n));

  for (final f in d.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    final mManifest = RegExp(r'^round_(\d+)_manifest\.json$').firstMatch(name);
    final mMd = RegExp(r'^round_(\d+)\.md$').firstMatch(name);
    final mTrace = RegExp(r'^round_(\d+)_trace\.txt$').firstMatch(name);

    if (mManifest != null) {
      final n = int.parse(mManifest.group(1)!);
      roundFor(n).manifest = SynthesisManifest.fromJson(
          jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    } else if (mMd != null) {
      final n = int.parse(mMd.group(1)!);
      _parseMd(f.readAsStringSync(), roundFor(n));
    } else if (mTrace != null) {
      final n = int.parse(mTrace.group(1)!);
      _parseTrace(f.readAsStringSync(), roundFor(n), artifactLabels);
    }
  }

  final ns = rounds.keys.toList()..sort();
  if (ns.isEmpty) {
    stderr.writeln('No rounds found in $dir');
    return;
  }

  bool isReturnZero(int? id) =>
      id != null && (artifactLabels[id] ?? '') == 'Return 0';

  // ---- Walk rounds, folding overlay state ---------------------------------
  final overrides = <String, int>{}; // symbol -> artifactId, folded per round
  final seenRecKeys = <String>{};

  final parentKills = <String>[]; // "rN: sym (reason)"
  final entryHits = <String>[];
  final collapses = <String>[];
  final leafFails = <String>[];
  final leafPasses = <String>[];
  var emittedTotal = 0;
  var repeatCount = 0;
  final executedByRound = <int, int>{};

  for (final n in ns) {
    final r = rounds[n]!;
    final prev = n > 0 ? rounds[n - 1] : null;
    final prevExecuted = prev?.manifest?.executedSymbols?.toSet() ?? {};
    executedByRound[n] = r.manifest?.executedSymbols?.length ?? 0;

    // M-repeat: emitted recs already seen applied/skipped before, plus
    // the writer's own skipped-as-no-op list.
    emittedTotal += r.emitted.length;
    for (final rec in r.emitted) {
      if (seenRecKeys.contains(rec.key)) repeatCount++;
    }
    repeatCount += r.skippedNoOps.length;

    // M-entry.
    for (final rec in r.applied) {
      final sym = rec.symbol;
      if (sym != null && _entryPoints.contains(sym)) {
        entryHits.add('r$n: ${rec.toString()}');
      }
    }

    // M-parent: Return-0 forced override on a proven parent.
    for (final rec in r.applied) {
      if (rec.kind != 'set_forced_override' || !isReturnZero(rec.artifactId)) {
        continue;
      }
      final sym = rec.symbol!;
      if (!prevExecuted.contains(sym)) continue;
      final node = callGraph.symbols[sym];
      if (node == null) continue;
      final directCallees = node.calledSymbols.keys.toSet();
      final executedCallee =
          directCallees.where(prevExecuted.contains).toList();
      final overriddenBeneath =
          _transitiveOverridden(callGraph, sym, overrides.keys.toSet());
      if (executedCallee.isNotEmpty || overriddenBeneath.isNotEmpty) {
        final why = [
          if (executedCallee.isNotEmpty)
            'executed callees: ${executedCallee.take(3).join(', ')}',
          if (overriddenBeneath.isNotEmpty)
            'overrides beneath: ${overriddenBeneath.take(3).join(', ')}',
        ].join('; ');
        parentKills.add('r$n: `$sym` ($why)');
      }
    }

    // M-leaf: this round's evidence (trace prompt) described the PREVIOUS
    // round's run. Spin >= 4 on a symbol with no override going in.
    for (final e in r.spins.entries) {
      if (e.value < 4) continue;
      final sym = e.key;
      if (overrides.containsKey(sym)) continue; // already hooked going in
      final fixedIt = r.applied.any((rec) =>
          rec.symbol == sym &&
          (rec.kind == 'set_forced_override' ||
              rec.kind == 'generate_custom_hook'));
      final killedCallers = r.applied.any((rec) =>
          rec.kind == 'set_forced_override' &&
          isReturnZero(rec.artifactId) &&
          rec.symbol != sym);
      if (fixedIt) {
        // Right target — but check the VALUE: a time/tick/counter reader
        // forced to a CONSTANT freezes the clock (observed live:
        // GetAbsoluteTime <- Return 1 dropped coverage 39 -> 15).
        final timeLike = RegExp(
                r'GetTick|GetAbsoluteTime|GetCounter|GetTime|_Counter\b',
                caseSensitive: false)
            .hasMatch(sym);
        final appliedRec = r.applied.firstWhere((rec) => rec.symbol == sym);
        final label = artifactLabels[appliedRec.artifactId] ?? '';
        final constant = label == 'Return 0' || label == 'Return 1';
        if (timeLike && constant) {
          leafFails.add('r$n: `$sym` (×${e.value}) is a time/counter '
              'reader forced to a CONSTANT ("$label") — the clock is '
              'frozen; needs a Stateful increment artifact');
        } else {
          leafPasses.add('r$n: `$sym` (×${e.value}) → leaf forced '
              '("$label")');
        }
      } else if (killedCallers) {
        leafFails.add('r$n: `$sym` (×${e.value}) spinning, answered with '
            'caller Return-0s instead');
      }
    }

    // Fold this round's applied recs into the running overlay state, and
    // remember them for repeat detection.
    for (final rec in r.applied) {
      seenRecKeys.add(rec.key);
      if (rec.kind == 'set_forced_override' &&
          rec.symbol != null &&
          rec.artifactId != null) {
        overrides[rec.symbol!] = rec.artifactId!;
      } else if (rec.kind == 'clear_forced_override' && rec.symbol != null) {
        overrides.remove(rec.symbol!);
      }
    }
    for (final rec in r.skippedNoOps) {
      seenRecKeys.add(rec.key);
    }

    // M-collapse.
    if (n > 0) {
      final prevCount = executedByRound[n - 1] ?? 0;
      final nowCount = executedByRound[n] ?? 0;
      if (prevCount > 0 && nowCount < prevCount * 0.5) {
        collapses.add('r${n - 1}→r$n: $prevCount → $nowCount executed '
            '(applied: ${rounds[n]!.applied.map((x) => x.toString()).join('; ')})');
      }
    }
  }

  final peak = executedByRound.values.fold(0, (a, b) => a > b ? a : b);
  final last = executedByRound[ns.last] ?? 0;

  // ---- Scorecard -----------------------------------------------------------
  final out = StringBuffer()
    ..writeln('## Session: $dir')
    ..writeln()
    ..writeln('Rounds: ${ns.length} (${ns.first}..${ns.last}) | '
        'executed per round: '
        '${[for (final n in ns) executedByRound[n]].join(' → ')}')
    ..writeln();

  void metric(String name, bool fail, List<String> items,
      {String? extra}) {
    out.writeln('- **$name**: ${fail ? 'FAIL' : 'pass'}'
        '${extra != null ? ' — $extra' : ''}');
    for (final i in items) {
      out.writeln('    - $i');
    }
  }

  metric('M-parent (Return-0 on proven parent)', parentKills.isNotEmpty,
      parentKills, extra: '${parentKills.length} occurrence(s)');
  metric('M-entry (entry-point targeting)', entryHits.isNotEmpty, entryHits);
  metric('M-collapse (>50% executed drop)', collapses.isNotEmpty, collapses);
  metric('M-leaf (spin evidence ignored)', leafFails.isNotEmpty, leafFails,
      extra: '${leafFails.length} fail / ${leafPasses.length} correctly '
          'leaf-forced');
  for (final p in leafPasses) {
    out.writeln('    - (pass) $p');
  }
  out
    ..writeln('- **M-anchor (best-so-far gap)**: peak $peak → final $last '
        '(gap ${peak - last})')
    ..writeln('- **M-repeat**: $repeatCount repeated of $emittedTotal '
        'emitted (${emittedTotal == 0 ? '0' : (repeatCount / emittedTotal * 100).toStringAsFixed(0)}%)')
    ..writeln();

  stdout.write(out.toString());
}

/// Transitive callees of [root] (BFS over direct-call edges) that carry an
/// active forced override. Bounded by the visited set.
List<String> _transitiveOverridden(
    CallGraph g, String root, Set<String> overridden) {
  final hits = <String>[];
  final visited = <String>{root};
  final queue = [root];
  while (queue.isNotEmpty) {
    final cur = queue.removeLast();
    final node = g.symbols[cur];
    if (node == null) continue;
    for (final callee in node.calledSymbols.keys) {
      if (!visited.add(callee)) continue;
      if (overridden.contains(callee)) hits.add(callee);
      queue.add(callee);
    }
  }
  return hits;
}

void _parseMd(String md, _Round r) {
  // Old layout: numbered "## LLM recommendations" list = emitted;
  // "**Applied this round" block = applied; "**Skipped as no-ops" = no-ops.
  // New layout: one numbered list under "## What changed going in", each
  // entry annotated with its fate (`— **applied**`, `— skipped as a
  // no-op`, `— REFUSED …`).
  var section = '';
  for (final line in md.split('\n')) {
    if (line.startsWith('**Applied this round')) {
      section = 'applied';
      continue;
    }
    if (line.startsWith('**Skipped as no-ops')) {
      section = 'skipped';
      continue;
    }
    if (line.startsWith('## LLM recommendations')) {
      section = 'emitted';
      continue;
    }
    if (line.startsWith('## What changed going in')) {
      section = 'changed';
      continue;
    }
    if (line.startsWith('## ') || line.startsWith('# ')) {
      section = '';
      continue;
    }

    final rec = _parseRecLine(line);
    if (rec == null) continue;
    switch (section) {
      case 'emitted':
        // Only the numbered list entries (rationales are indented `- _..._`).
        if (RegExp(r'^\d+\. ').hasMatch(line)) r.emitted.add(rec);
      case 'applied':
        if (line.startsWith('- ')) r.applied.add(rec);
      case 'skipped':
        if (line.startsWith('- ')) r.skippedNoOps.add(rec);
      case 'changed':
        if (RegExp(r'^\d+\. ').hasMatch(line)) {
          r.emitted.add(rec);
          if (line.contains('— **applied**')) r.applied.add(rec);
          if (line.contains('— skipped as a no-op')) r.skippedNoOps.add(rec);
        } else if (line.startsWith('- ')) {
          // "Also applied (edited during review)" bullets.
          r.applied.add(rec);
        }
    }
  }
}

_Rec? _parseRecLine(String line) {
  final m = _recRe.firstMatch(line);
  if (m != null) {
    return _Rec(
      kind: m.group(1)!,
      symbol: m.group(2),
      artifactId: (m.group(3) ?? m.group(4)) != null
          ? int.parse((m.group(3) ?? m.group(4))!)
          : null,
    );
  }
  final c = _capRe.firstMatch(line);
  if (c != null) return _Rec(kind: c.group(1)!);
  return null;
}

void _parseTrace(String trace, _Round r, Map<int, String> artifactLabels) {
  // Evidence lines live in the prompt section; the catalog block gives the
  // id -> label map.
  for (final m in _catalogRe.allMatches(trace)) {
    artifactLabels[int.parse(m.group(1)!)] = m.group(2)!;
  }
  final halt = _haltRe.firstMatch(trace);
  if (halt != null) r.haltSymbol = halt.group(1);
  // Spin counts only from the "Recent call sequence" line.
  for (final line in trace.split('\n')) {
    if (!line.contains('Recent call sequence')) continue;
    for (final m in _spinRe.allMatches(line)) {
      r.spins[m.group(1)!] = int.parse(m.group(2)!);
    }
    break;
  }
}
