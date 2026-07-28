// One-off script — exercises [GhidraInstaller.install] end-to-end
// against a real network + filesystem, the SAME code path the
// Modules-tab Install button drives. No mocks, no detached helpers.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_ghidra_install.dart
//
// Drains the install stream, prints progress, then verifies the
// resolved paths (Java + analyzeHeadless) are usable. Exits 0 on
// success; throws on any failure so the shell sees a non-zero code.

import 'dart:io';

import 'package:emulator_orchestrator/services/external/ghidra_installer.dart';

Future<void> main() async {
  final installer = GhidraInstaller();
  stdout.writeln('=== GhidraInstaller.install() ===');
  var bytesAt = 0;
  await for (final ev in installer.install()) {
    final total = ev.total;
    final done = ev.done;
    if (total != null && done != null && total > 0) {
      // Per-MB summary line so we don't flood with every chunk.
      if (done - bytesAt >= 10 * 1024 * 1024 || done == total) {
        bytesAt = done;
        final mb = (done / 1024 / 1024).toStringAsFixed(1);
        final totMb = (total / 1024 / 1024).toStringAsFixed(1);
        stdout.writeln('  [progress] $mb / $totMb MB');
      }
    } else {
      stdout.writeln('  [phase] ${ev.message}');
    }
  }

  stdout.writeln('');
  stdout.writeln('=== Post-install verification ===');
  final java = await installer.resolveJavaBinary();
  stdout.writeln('java binary:   $java');
  final javaHome = await installer.resolveJavaHome();
  stdout.writeln('JAVA_HOME:     $javaHome');
  final ghidraDir = installer.resolveInstallDir();
  stdout.writeln('GHIDRA_DIR:    $ghidraDir');
  stdout.writeln('isInstalled:   ${installer.isInstalled}');

  if (java == null) {
    throw StateError('Java is unresolved after install — failure.');
  }
  if (ghidraDir == null) {
    throw StateError('Ghidra dir is unresolved after install — failure.');
  }
  // Probe the actual files we'd hand to analyzeHeadless.
  final ah = File('$ghidraDir/support/analyzeHeadless');
  stdout.writeln(
      'analyzeHeadless exists: ${ah.existsSync()}  (${ah.path})');
  if (!ah.existsSync()) {
    throw StateError('analyzeHeadless missing post-install — failure.');
  }
  // And run java -version one more time on the resolved binary as a
  // smoke test — this is the binary analyzeHeadless will invoke.
  stdout.writeln('');
  stdout.writeln('=== resolved java -version ===');
  final v = await Process.run(java, ['-version']);
  stdout.writeln(v.stdout);
  stdout.writeln(v.stderr);
}
