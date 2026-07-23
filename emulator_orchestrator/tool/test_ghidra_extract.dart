// End-to-end exercise of the signature + call-graph extraction —
// invokes `signatures-dart`'s `extractProgramInfo` against a real
// ELF using the Temurin JRE and Ghidra install the previous test
// script just put on disk.
//
// Same code path as `SignaturesService.extractFor` (minus the DB
// write), so success here proves the Jython script parses + emits
// the expected JSON shape and that `analyzeHeadless` picks up our
// managed `JAVA_HOME`.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_ghidra_extract.dart [<elf>]
//
// Default ELF: emulation_engine/aya_ppg.elf

import 'dart:io';

import 'package:emulator_orchestrator/data/services/ghidra_installer.dart';
import 'package:resect_signatures/resect_signatures.dart';

Future<void> main(List<String> args) async {
  final elf = args.isNotEmpty
      ? args.first
      : '/home/evan/Development/resect/emulation_engine/aya_ppg.elf';
  if (!File(elf).existsSync()) {
    throw StateError('ELF not found: $elf');
  }
  final installer = GhidraInstaller();
  final ghidraDir = installer.resolveInstallDir();
  if (ghidraDir == null) {
    throw StateError('Ghidra not installed. Run test_ghidra_install.dart.');
  }
  final javaHome = await installer.resolveJavaHome();
  stdout.writeln('elf:       $elf');
  stdout.writeln('ghidraDir: $ghidraDir');
  stdout.writeln('javaHome:  $javaHome');
  stdout.writeln('');
  stdout.writeln('=== extractProgramInfo (this takes 30 s-2 min) ===');
  final start = DateTime.now();
  final info = await extractProgramInfo(
    elfPath: elf,
    ghidraDir: ghidraDir,
    javaHome: javaHome,
  );
  final elapsed = DateTime.now().difference(start);
  final decompWithSource = info.decompilation.values
      .where((d) => d.source != null && d.source!.isNotEmpty)
      .length;
  stdout.writeln('elapsed:                       ${elapsed.inSeconds}s');
  stdout.writeln('signatures.length:             ${info.signatures.length}');
  stdout.writeln('callGraph.length:              ${info.callGraph.length}');
  stdout.writeln('decompilation.length:          ${info.decompilation.length} '
      '($decompWithSource with non-empty source)');
  stdout.writeln('dataTypes.length:              ${info.dataTypes.length}');
  stdout.writeln('dataSymbols.length:            ${info.dataSymbols.length}');
  stdout.writeln('memoryMap.length:              ${info.memoryMap.length}');
  stdout.writeln('');
  stdout.writeln('=== sample signatures ===');
  for (final entry in info.signatures.entries.take(5)) {
    final sig = entry.value;
    stdout.writeln('  ${sig.summary()}');
    for (final p in sig.parameters) {
      stdout.writeln('    arg: ${p.name}: ${p.type} → ${p.storage}');
    }
  }
  stdout.writeln('');
  stdout.writeln('=== sample call-graph edges ===');
  for (final entry in info.callGraph.entries.take(5)) {
    final node = entry.value;
    final out = node.calls.entries.take(3).map((e) => '${e.key}×${e.value}');
    stdout.writeln(
        '  ${entry.key} @ 0x${node.address.toRadixString(16)}: '
        '${node.numInstructions} instr → ${out.join(', ')}'
        '${node.calls.length > 3 ? " (+${node.calls.length - 3} more)" : ""}');
  }
  stdout.writeln('');
  stdout.writeln('=== sample decompilations (first non-empty) ===');
  var shown = 0;
  for (final entry in info.decompilation.entries) {
    final src = entry.value.source;
    if (src == null || src.isEmpty) continue;
    stdout.writeln('--- ${entry.key} ---');
    final lines = src.split('\n');
    for (final line in lines.take(15)) {
      stdout.writeln('  $line');
    }
    if (lines.length > 15) {
      stdout.writeln('  ... (${lines.length - 15} more lines)');
    }
    if (++shown >= 2) break;
  }
  stdout.writeln('');
  stdout.writeln('=== sample data types ===');
  for (final entry in info.dataTypes.entries.take(3)) {
    stdout.writeln('--- ${entry.key} ---');
    final lines = entry.value.definition.split('\n');
    for (final line in lines.take(10)) {
      stdout.writeln('  $line');
    }
    if (lines.length > 10) {
      stdout.writeln('  ... (${lines.length - 10} more lines)');
    }
  }
  stdout.writeln('');
  stdout.writeln('=== sample data symbols ===');
  for (final entry in info.dataSymbols.entries.take(8)) {
    final s = entry.value;
    stdout.writeln('  ${s.name} @ 0x${s.address.toRadixString(16)} '
        '(${s.type}, ${s.size} bytes)');
  }
  stdout.writeln('');
  stdout.writeln('=== memory map ===');
  for (final m in info.memoryMap) {
    stdout.writeln('  ${m.name.padRight(16)}  '
        '0x${m.start.toRadixString(16).padLeft(8, '0')}-'
        '0x${m.end.toRadixString(16).padLeft(8, '0')}  '
        '[${m.permissions}]');
  }
}
