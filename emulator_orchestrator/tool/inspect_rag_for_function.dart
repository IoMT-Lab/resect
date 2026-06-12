// Dump everything in the artifact DB + project's rag_index.db for
// a given function name. Used to verify that the RAG entries for a
// function exist, are well-formed, and match what's in the
// artifact tables they were derived from.
//
//   dart run tool/inspect_rag_for_function.dart <function-name>

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> main(List<String> argv) async {
  if (argv.length != 1) {
    stderr.writeln('usage: inspect_rag_for_function.dart <function-name>');
    exit(2);
  }
  final fn = argv[0];
  stdout.writeln('=== inspecting "$fn" ===');
  stdout.writeln('');

  // ---- artifact DB ----
  final db = ArtifactDatabase();
  final firmware = await (db.select(db.firmwareImages)
        ..where((t) => t.fileName.equals('aya_ppg.elf')))
      .getSingleOrNull();
  if (firmware == null) {
    stderr.writeln('no aya_ppg.elf in DB');
    exit(1);
  }
  final elfHash = firmware.elfHash;
  stdout.writeln('artifact DB → ELF hash: ${elfHash.substring(0, 16)}…');

  final sig = await (db.select(db.signatures)
        ..where((t) =>
            t.elfHash.equals(elfHash) & t.symbolName.equals(fn)))
      .getSingleOrNull();
  stdout.writeln('  signatures row:        '
      '${sig == null ? "MISSING" : "present"}');
  if (sig != null) {
    stdout.writeln('    signature: ${sig.signatureJson}');
  }

  final decomp = await db.decompilationFor(
    elfHash: elfHash,
    functionName: fn,
  );
  stdout.writeln('  ghidra_decompilations: '
      '${decomp == null ? "MISSING" : "${decomp.length} chars"}');
  if (decomp != null) {
    stdout.writeln('    --- decompilation ---');
    for (final line in decomp.split('\n')) {
      stdout.writeln('    $line');
    }
    stdout.writeln('    ---');
  }

  // ghidra_call_graphs is a single JSON row; pluck the function's entry.
  final cgPayload = await (db.select(db.ghidraCallGraphs)
        ..where((t) => t.elfHash.equals(elfHash)))
      .getSingleOrNull();
  if (cgPayload != null) {
    final hasEntry = cgPayload.payloadJson.contains('"$fn"');
    stdout.writeln('  ghidra_call_graphs:    '
        '${hasEntry ? "function present in payload" : "function NOT in payload"}');
  }

  await db.close();
  stdout.writeln('');

  // ---- project rag_index.db ----
  const ragPath = '/home/evan/.config/call_graph_viewer/projects/rag_index.db';
  if (!File(ragPath).existsSync()) {
    stdout.writeln('rag_index.db NOT FOUND at $ragPath');
    return;
  }
  stdout.writeln('rag_index.db → $ragPath');
  final ragDb = sqlite3.open(ragPath);
  try {
    // Count chunks per source_kind for THIS function.
    final byKind = ragDb.select(
        "SELECT source_kind, COUNT(*) AS n FROM chunks "
        "WHERE source_id = ? GROUP BY source_kind ORDER BY source_kind",
        [fn]);
    stdout.writeln('  chunks where source_id == "$fn":');
    if (byKind.isEmpty) {
      stdout.writeln('    (none)');
    } else {
      for (final r in byKind) {
        stdout.writeln('    ${r['source_kind']}  ×${r['n']}');
      }
    }
    // Show the actual text of each chunk (up to 4).
    final rows = ragDb.select(
        "SELECT source_kind, position, length(text) AS len, "
        "substr(text, 1, 400) AS preview "
        "FROM chunks WHERE source_id = ? "
        "ORDER BY source_kind, position",
        [fn]);
    if (rows.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln('  --- chunk previews (first 400 chars each) ---');
      for (final r in rows) {
        stdout.writeln('  [${r['source_kind']} pos=${r['position']} '
            'len=${r['len']}]');
        for (final line in (r['preview'] as String).split('\n')) {
          stdout.writeln('    $line');
        }
        stdout.writeln('');
      }
    }
    // Also: is this function mentioned in OTHER kinds where it's
    // not the source_id (e.g. mentioned in a doc chunk).
    final mentions = ragDb.select(
        "SELECT source_kind, source_id, position FROM chunks "
        "WHERE source_id != ? AND text LIKE ? "
        "LIMIT 5",
        [fn, '%$fn%']);
    if (mentions.isNotEmpty) {
      stdout.writeln('  also mentioned in (up to 5):');
      for (final r in mentions) {
        stdout.writeln('    ${r['source_kind']} / ${r['source_id']} '
            '(pos ${r['position']})');
      }
    }
  } finally {
    ragDb.dispose();
  }
}
