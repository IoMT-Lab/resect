// Run HookStaticAnalyzer over 10 random real functions from the
// artifact DB. Candidate hook per function:
//   - classifier match → that template's materialized body
//   - no match        → setReturnValue(cpu, 0) (matches what the
//                       LLM has been emitting for fall-through)
//
//   dart run tool/test_static_analyzer_random.dart [--count=10] [--seed=N]

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/services/hooks/hook_classifier.dart';
import 'package:emulator_orchestrator/services/quality/hook_static_analyzer.dart';
import 'package:resect_signatures/resect_signatures.dart';

const String _replPath = '/home/evan/Development/resect/emulation_engine/'
    'renode_1.16.0-dotnet_portable/platforms/cpus/stm32wb05_empty.repl';
const String _llmFallbackHook = 'import set_return_value\n'
    'setReturnValue(cpu, 0)\n';

Future<void> main(List<String> argv) async {
  var count = 10;
  var seed = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  for (final a in argv) {
    if (a.startsWith('--count=')) count = int.parse(a.substring(8));
    if (a.startsWith('--seed=')) seed = int.parse(a.substring(7));
  }

  final db = ArtifactDatabase();
  final fw = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals('aya_ppg.elf')))
      .getSingleOrNull();
  if (fw == null) { stderr.writeln('no aya_ppg.elf in DB'); exit(1); }
  final elfHash = fw.elfHash;

  final decomps = await (db.select(db.ghidraDecompilations)
        ..where((t) => t.elfHash.equals(elfHash)))
      .get();
  final pool = <String>[];
  for (final d in decomps) {
    if (d.sourceText.trim().isEmpty) continue;
    final sigExists = (await (db.select(db.signatures)
              ..where((t) => t.elfHash.equals(elfHash) &
                  t.symbolName.equals(d.functionName)))
            .getSingleOrNull()) != null;
    if (sigExists) pool.add(d.functionName);
  }
  pool.shuffle(math.Random(seed));
  final chosen = pool.take(count).toList();

  final dsRows = await (db.select(db.ghidraDataSymbols)
        ..where((t) => t.elfHash.equals(elfHash)))
      .get();
  final dataSymbols = <String, DataSymbol>{
    for (final r in dsRows)
      r.symbolName: DataSymbol(
        name: r.symbolName, address: r.address,
        type: r.typeName, size: r.size),
  };

  final replContent = await File(_replPath).readAsString();
  const classifier = HookClassifier();
  const analyzer = HookStaticAnalyzer();

  stdout.writeln('seed=$seed  count=${chosen.length}');
  stdout.writeln('repl=$_replPath');
  stdout.writeln('');

  var modPasses = 0;
  var unmappedPasses = 0;
  for (var i = 0; i < chosen.length; i++) {
    final fn = chosen[i];
    final sigRow = await (db.select(db.signatures)
          ..where((t) =>
              t.elfHash.equals(elfHash) & t.symbolName.equals(fn)))
        .getSingleOrNull();
    final sig = FunctionSignature.fromJson(
        fn, jsonDecode(sigRow!.signatureJson) as Map<String, dynamic>);
    final decomp = await db.decompilationFor(
        elfHash: elfHash, functionName: fn);
    if (decomp == null) continue;

    final cls = classifier.classify(
      functionName: fn, signature: sig,
      decompilation: decomp, dataSymbols: dataSymbols,
    );
    final candidate = cls?.hook.code ?? _llmFallbackHook;
    final source = cls == null ? 'LLM-fallback' : cls.ruleName;

    final paramNames = sig.parameters.map((p) => p.name).toList();
    final result = await analyzer.evaluate(
      candidateCode: candidate,
      originalDecompilation: decomp,
      parameterNames: paramNames,
      replContent: replContent,
    );

    if (result.modSetContained) modPasses++;
    if (result.unmappedAccessOk) unmappedPasses++;

    stdout.writeln('--- [${i+1}/${chosen.length}] $fn  '
        '(source: $source) ---');
    stdout.writeln('  original writes:   '
        '${result.originalWrites.isEmpty ? "<none>" : result.originalWrites.join(", ")}');
    stdout.writeln('  candidate writes:  '
        '${result.candidateWrites.isEmpty ? "<none>" : result.candidateWrites.join(", ")}');
    stdout.writeln('  candidate reads:   '
        '${result.candidateReads.isEmpty ? "<none>" : result.candidateReads.map((a) => "0x${a.toRadixString(16)}").join(", ")}');
    stdout.writeln('  mod-set contained: ${result.modSetContained}');
    stdout.writeln('  unmapped-access OK: ${result.unmappedAccessOk}');
    if (result.violation != null) {
      stdout.writeln('  violation: ${result.violation}');
    }
    stdout.writeln('');
  }

  await db.close();
  stdout.writeln('=== summary ===');
  stdout.writeln('  mod-set passes:        $modPasses / ${chosen.length}');
  stdout.writeln('  unmapped-access passes: $unmappedPasses / ${chosen.length}');
}
