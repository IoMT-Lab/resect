// Regenerates lib/services/quality/test_harness_assets.dart from the
// contents of test_harness/.
//
// Reads:
//   - test_harness/minimal_firmware.elf  (binary, base64-encoded into Dart)
//   - test_harness/minimal_cortex_m.repl (text, base64-encoded into Dart)
//   - Symbol addresses from the ELF via arm-none-eabi-objdump -t
//
// Writes:
//   - lib/services/quality/test_harness_assets.dart
//
// Invoked from test_harness/Makefile via `make regen-dart`.
//
// `--check` mode exits non-zero if the on-disk file would change, for
// CI parity checks. Same shape as hooks-dart's gen_system_modules.dart.

import 'dart:convert';
import 'dart:io';

const _objdumpExe = 'arm-none-eabi-objdump';

const _symbolsOfInterest = ['main', 'halt_loop', 'results', 'done_flag'];

Future<void> main(List<String> args) async {
  final check = args.contains('--check');

  final scriptUri = Platform.script;
  // tool/gen_test_harness_assets.dart → package root is two levels up.
  final pkgRoot = File.fromUri(scriptUri).parent.parent;
  final harnessDir = Directory('${pkgRoot.path}/test_harness');
  final outPath =
      '${pkgRoot.path}/lib/services/quality/test_harness_assets.dart';

  final elfFile = File('${harnessDir.path}/minimal_firmware.elf');
  final replFile = File('${harnessDir.path}/minimal_cortex_m.repl');

  if (!await elfFile.exists()) {
    stderr.writeln('error: ${elfFile.path} not found. Run `make` first.');
    exit(2);
  }
  if (!await replFile.exists()) {
    stderr.writeln('error: ${replFile.path} not found.');
    exit(2);
  }

  final elfBytes = await elfFile.readAsBytes();
  final replText = await replFile.readAsString();
  final symbols = await _extractSymbols(elfFile.path);

  for (final name in _symbolsOfInterest) {
    if (!symbols.containsKey(name)) {
      stderr.writeln(
          'error: symbol `$name` not found in ${elfFile.path}.');
      exit(3);
    }
  }

  final content = _renderDart(
    elfBytes: elfBytes,
    replText: replText,
    symbols: symbols,
  );

  final outFile = File(outPath);
  if (check) {
    final existing = await outFile.exists() ? await outFile.readAsString() : '';
    if (existing == content) {
      stdout.writeln('OK: $outPath is up to date.');
      return;
    }
    stderr.writeln('error: $outPath is out of date with test_harness/. '
        'Run `make regen-dart` in test_harness/.');
    exit(1);
  }

  await outFile.writeAsString(content);
  stdout.writeln(
      'wrote $outPath (elf=${elfBytes.length}B repl=${replText.length}B)');
}

/// Run `arm-none-eabi-objdump -t` on [elfPath] and parse the symbol
/// table. Returns a map of symbol name → address (Thumb bit stripped).
Future<Map<String, int>> _extractSymbols(String elfPath) async {
  final result = await Process.run(_objdumpExe, ['-t', elfPath]);
  if (result.exitCode != 0) {
    stderr.writeln('$_objdumpExe exited ${result.exitCode}:');
    stderr.writeln(result.stderr);
    exit(4);
  }
  final out = <String, int>{};
  // Lines look like:
  //   20000000 g     O .bss	00000028 results
  //   00000020 g     F .text	00000004 halt_loop
  final lineRe = RegExp(r'^([0-9a-f]{8})\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)$');
  for (final line in const LineSplitter().convert(result.stdout as String)) {
    final m = lineRe.firstMatch(line);
    if (m == null) continue;
    final addr = int.parse(m.group(1)!, radix: 16);
    final name = m.group(2)!;
    out[name] = addr & ~1; // strip Thumb bit (LSB) just in case
  }
  return out;
}

String _renderDart({
  required List<int> elfBytes,
  required String replText,
  required Map<String, int> symbols,
}) {
  final elfB64 = base64Encode(elfBytes);
  final replB64 = base64Encode(utf8.encode(replText));

  String hex(int v) =>
      '0x${v.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  final buf = StringBuffer();
  buf.writeln('// GENERATED FILE — DO NOT EDIT BY HAND.');
  buf.writeln('//');
  buf.writeln('// Source files under test_harness/. Regenerate via:');
  buf.writeln('//   cd test_harness && make regen-dart');
  buf.writeln('//');
  buf.writeln('// Both the firmware ELF and the Renode platform .repl are');
  buf.writeln('// embedded as base64 string constants so the harness has no');
  buf.writeln('// filesystem dependency at runtime (matters for AOT Flutter).');
  buf.writeln();
  buf.writeln('/// Base64-encoded contents of test_harness/minimal_cortex_m.repl.');
  buf.writeln("const String testHarnessReplBase64 = '$replB64';");
  buf.writeln();
  buf.writeln('/// Base64-encoded contents of test_harness/minimal_firmware.elf.');
  buf.writeln('const String testHarnessElfBase64 =');
  // Chunk the ELF base64 across multiple lines so the generated file is
  // readable in diffs. 76 chars per line — matches MIME base64.
  for (var i = 0; i < elfB64.length; i += 76) {
    final end = (i + 76 < elfB64.length) ? i + 76 : elfB64.length;
    final chunk = elfB64.substring(i, end);
    final terminator = (end == elfB64.length) ? ';' : '';
    buf.writeln("    '$chunk'$terminator");
  }
  buf.writeln();
  buf.writeln('/// Symbol in the bundled firmware that the harness rewires');
  buf.writeln('/// to point at the hook under test.');
  buf.writeln("const String testHarnessMainSymbol = 'main';");
  buf.writeln();
  buf.writeln('/// Symbol the bootstrap spins in after calling main() the');
  buf.writeln('/// configured number of times. The harness installs a pause');
  buf.writeln('/// hook here to detect "bootstrap complete."');
  buf.writeln("const String testHarnessHaltSymbol = 'halt_loop';");
  buf.writeln();
  buf.writeln('/// PC value of `halt_loop` (Thumb bit stripped). Available');
  buf.writeln('/// for direct PC comparison if the symbol-hook path fails.');
  buf.writeln('const int testHarnessHaltLoopAddr = ${hex(symbols['halt_loop']!)};');
  buf.writeln();
  buf.writeln('/// Base address of the 10-entry uint32 results array.');
  buf.writeln('/// Bootstrap writes `results[i] = main()` for i in [0, 10).');
  buf.writeln('const int testHarnessResultsAddr = ${hex(symbols['results']!)};');
  buf.writeln();
  buf.writeln('/// Number of times the bootstrap calls main().');
  buf.writeln('const int testHarnessResultsCount = 10;');
  buf.writeln();
  buf.writeln('/// uint32 set to 1 by the bootstrap after the last main() call.');
  buf.writeln('const int testHarnessDoneFlagAddr = ${hex(symbols['done_flag']!)};');
  return buf.toString();
}
