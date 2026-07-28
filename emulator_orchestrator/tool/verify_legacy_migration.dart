// Verifies that ArtifactLibraryService.migrateLegacyHookBodies correctly
// rewrites pre-fix artifact rows that carry raw `import set_return_value`
// (and friends) into substituted form.
//
// Reads the user's real artifact DB at
//   ~/.config/call_graph_viewer/artifact_library/artifacts.db
// counts legacy rows, runs the migration, counts again, dumps the body
// of a single representative row before/after.
//
//   dart run tool/verify_legacy_migration.dart

import 'dart:io';

import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/services/hooks/artifact_library_service.dart';

final _legacy = RegExp(
  r'^\s*(?:import|from)\s+'
  r'(set_return_value|variables|comms|i2c_local|i2c_remote|'
  r'uart_remote|pointer|stm32_glue)\b',
  multiLine: true,
);

Future<void> main() async {
  final db = ArtifactDatabase();
  final svc = ArtifactLibraryService(db);

  // Pre-scan: count legacy rows.
  final pre = await db.getAllArtifacts();
  final preLegacy = pre
      .where((a) => a.artifactType == 'renode_hook' &&
          _legacy.hasMatch(a.artifactData))
      .toList();
  stdout.writeln('=== pre-migration ===');
  stdout.writeln('total renode_hook rows:  ${pre.where((a) => a.artifactType == 'renode_hook').length}');
  stdout.writeln('legacy (raw-import) rows: ${preLegacy.length}');

  if (preLegacy.isEmpty) {
    stdout.writeln('\nnothing to migrate. exiting.');
    exit(0);
  }

  // Sample one row for before/after diff.
  final sample = preLegacy.first;
  stdout.writeln('\nsample row id=${sample.id} '
      '(origin=${sample.origin} target=${sample.targetSymbolName}):');
  stdout.writeln('--- BEFORE (first 8 lines) ---');
  sample.artifactData.split('\n').take(8).forEach(stdout.writeln);

  // Run migration.
  await svc.migrateLegacyHookBodies();

  // Post-scan.
  final post = await db.getAllArtifacts();
  final postLegacy = post
      .where((a) => a.artifactType == 'renode_hook' &&
          _legacy.hasMatch(a.artifactData))
      .toList();
  stdout.writeln('\n=== post-migration ===');
  stdout.writeln('legacy (raw-import) rows: ${postLegacy.length}');

  final after = post.firstWhere((a) => a.id == sample.id);
  stdout.writeln('\nsample row id=${sample.id} after migration:');
  stdout.writeln('--- AFTER (first 12 lines) ---');
  after.artifactData.split('\n').take(12).forEach(stdout.writeln);

  // Idempotency check.
  await svc.migrateLegacyHookBodies();
  final post2 = await db.getAllArtifacts();
  final post2Legacy = post2
      .where((a) => a.artifactType == 'renode_hook' &&
          _legacy.hasMatch(a.artifactData))
      .toList();
  stdout.writeln('\n=== idempotency check (second migration pass) ===');
  stdout.writeln('legacy rows after second pass: ${post2Legacy.length}');

  await db.close();
}
