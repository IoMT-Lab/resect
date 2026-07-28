// Diff the call graph extracted by callgraph-dart (objdump-based)
// against the one extracted by signatures-dart (Ghidra-based) for
// the same ELF.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_callgraph_diff.dart [<elf>]

import 'package:callgraph/callgraph.dart' as cg;
import 'package:emulator_orchestrator/services/external/ghidra_installer.dart';
import 'package:signatures/signatures.dart';

Future<void> main(List<String> args) async {
  final elf = args.isNotEmpty
      ? args.first
      : '/home/evan/Development/resect/emulation_engine/aya_ppg.elf';

  print('elf: $elf');
  print('');

  print('=== objdump (callgraph-dart) ===');
  final objStart = DateTime.now();
  final objgraph = await cg.extractCallgraph(elf);
  final objElapsed = DateTime.now().difference(objStart);
  print('elapsed: ${objElapsed.inSeconds}s');
  print('symbols: ${objgraph.symbols.length}');
  final objEdgeCount = objgraph.symbols.values
      .fold<int>(0, (n, s) => n + s.calledFunctions.length);
  print('edges (unique target per src): $objEdgeCount');
  print('');

  print('=== Ghidra (signatures-dart) ===');
  final installer = GhidraInstaller();
  final ghidraDir = installer.resolveInstallDir()!;
  final javaHome = await installer.resolveJavaHome();
  final ghidraStart = DateTime.now();
  final info = await extractProgramInfo(
      elfPath: elf, ghidraDir: ghidraDir, javaHome: javaHome);
  final ghidraElapsed = DateTime.now().difference(ghidraStart);
  print('elapsed: ${ghidraElapsed.inSeconds}s');
  print('symbols: ${info.callGraph.length}');
  final ghidraEdgeCount = info.callGraph.values
      .fold<int>(0, (n, n2) => n + n2.calls.length);
  print('edges (unique target per src): $ghidraEdgeCount');
  print('');

  // -------- symbol-set diff --------
  final objSyms = objgraph.symbols.keys.toSet();
  final ghidraSyms = info.callGraph.keys.toSet();
  final objOnly = objSyms.difference(ghidraSyms);
  final ghidraOnly = ghidraSyms.difference(objSyms);
  final common = objSyms.intersection(ghidraSyms);

  print('=== symbol-set diff ===');
  print('objdump only:    ${objOnly.length}');
  print('Ghidra only:     ${ghidraOnly.length}');
  print('common:          ${common.length}');
  print('');
  if (objOnly.isNotEmpty) {
    print('sample objdump-only symbols:');
    for (final s in objOnly.take(10)) {
      print('  $s');
    }
    print('');
  }
  if (ghidraOnly.isNotEmpty) {
    print('sample Ghidra-only symbols:');
    for (final s in ghidraOnly.take(10)) {
      print('  $s');
    }
    print('');
  }

  // -------- edge-set diff (only for symbols present in both) --------
  var perfectMatch = 0;
  var ghidraSuperset = 0;
  var objdumpSuperset = 0;
  var divergent = 0;
  final divergentSamples = <String>[];
  final ghidraIndirectCount = <String, int>{};

  for (final sym in common) {
    final objCalls =
        objgraph.symbols[sym]!.calledFunctions.keys.toSet();
    final ghidraCalls = info.callGraph[sym]!.calls.keys.toSet();

    // Indirect edges only Ghidra surfaces (synthesised <indirect:0x..>).
    final indirect =
        ghidraCalls.where((c) => c.startsWith('<indirect:')).length;
    if (indirect > 0) ghidraIndirectCount[sym] = indirect;
    final ghidraDirect =
        ghidraCalls.where((c) => !c.startsWith('<indirect:')).toSet();

    final inObjNotG = objCalls.difference(ghidraDirect);
    final inGNotObj = ghidraDirect.difference(objCalls);

    if (inObjNotG.isEmpty && inGNotObj.isEmpty) {
      perfectMatch++;
    } else if (inObjNotG.isEmpty && inGNotObj.isNotEmpty) {
      // Ghidra found everything objdump did + extras (direct edges).
      ghidraSuperset++;
    } else if (inGNotObj.isEmpty && inObjNotG.isNotEmpty) {
      objdumpSuperset++;
    } else {
      divergent++;
      if (divergentSamples.length < 10) {
        divergentSamples.add(
            '$sym: obj-only=${inObjNotG.take(3).toList()}, '
            'ghidra-only=${inGNotObj.take(3).toList()}');
      }
    }
  }

  print('=== edge-set parity (common ${common.length} symbols) ===');
  print('perfect match:        $perfectMatch');
  print('Ghidra found extras:  $ghidraSuperset   '
      '(direct edges objdump missed)');
  print('objdump found extras: $objdumpSuperset   '
      '(direct edges Ghidra missed)');
  print('divergent (both found different things): $divergent');
  print('');
  print('Ghidra indirect edges (computed-call resolutions): '
      '${ghidraIndirectCount.values.fold<int>(0, (a, b) => a + b)} '
      'across ${ghidraIndirectCount.length} symbols');
  if (divergentSamples.isNotEmpty) {
    print('');
    print('sample divergent symbols:');
    for (final s in divergentSamples) {
      print('  $s');
    }
  }
}
