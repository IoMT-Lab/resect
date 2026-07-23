// Run HookClassifier over N random functions from the artifact DB
// and report which rule each one matched (or no-match). No LLM,
// no harness, no Renode. Pure classifier dispatch.
//
//   dart run tool/test_classifier_breadth.dart [--count=100] [--seed=N]

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/services/hook_classifier.dart';
import 'package:resect_signatures/resect_signatures.dart';

Future<void> main(List<String> argv) async {
  var count = 100;
  var seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  for (final a in argv) {
    if (a.startsWith('--count=')) count = int.parse(a.substring(8));
    if (a.startsWith('--seed=')) seed = int.parse(a.substring(7));
  }

  final db = ArtifactDatabase();
  final firmware = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals('aya_ppg.elf')))
      .getSingleOrNull();
  if (firmware == null) {
    stderr.writeln('no aya_ppg.elf in DB');
    exit(1);
  }
  final elfHash = firmware.elfHash;

  // Pool: every function with both decompilation and signature.
  final decomps = await (db.select(db.ghidraDecompilations)
        ..where((t) => t.elfHash.equals(elfHash)))
      .get();
  final pool = <String>[];
  for (final d in decomps) {
    if (d.sourceText.trim().isEmpty) continue;
    final sig = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) &
              t.symbolName.equals(d.functionName)))
        .getSingleOrNull();
    if (sig != null) pool.add(d.functionName);
  }

  final rng = math.Random(seed);
  pool.shuffle(rng);
  final chosen = pool.take(count).toList();

  final dataSymbolRows = await (db.select(db.ghidraDataSymbols)
        ..where((t) => t.elfHash.equals(elfHash)))
      .get();
  final dataSymbols = <String, DataSymbol>{
    for (final r in dataSymbolRows)
      r.symbolName: DataSymbol(
          name: r.symbolName,
          address: r.address,
          type: r.typeName,
          size: r.size),
  };

  const classifier = HookClassifier();
  final ruleCounts = <String, int>{};
  final noMatch = <String>[];
  final perRule = <String, List<String>>{};

  stdout.writeln('seed=$seed  count=${chosen.length}  pool=${pool.length}');
  stdout.writeln('');

  for (final name in chosen) {
    final sigRow = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) & t.symbolName.equals(name)))
        .getSingleOrNull();
    if (sigRow == null) continue;
    final sig = FunctionSignature.fromJson(
        name, jsonDecode(sigRow.signatureJson) as Map<String, dynamic>);
    final decomp = await db.decompilationFor(
        elfHash: elfHash, functionName: name);
    if (decomp == null) continue;
    final result = classifier.classify(
      functionName: name,
      signature: sig,
      decompilation: decomp,
      dataSymbols: dataSymbols,
    );
    if (result == null) {
      ruleCounts.update('(no match)', (v) => v + 1, ifAbsent: () => 1);
      noMatch.add(name);
      perRule.putIfAbsent('(no match)', () => []).add(name);
    } else {
      ruleCounts.update(result.ruleName, (v) => v + 1, ifAbsent: () => 1);
      perRule.putIfAbsent(result.ruleName, () => []).add(name);
    }
  }

  await db.close();

  // Summary.
  stdout.writeln('=== rule counts ===');
  final sorted = ruleCounts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in sorted) {
    stdout.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }

  stdout.writeln('');
  stdout.writeln('=== sample function names per rule (first 5) ===');
  for (final e in sorted) {
    stdout.writeln('--- ${e.key} (${e.value}) ---');
    for (final fn in (perRule[e.key] ?? []).take(5)) {
      stdout.writeln('  $fn');
    }
  }
}
