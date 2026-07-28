import 'dart:convert';

import 'package:resect_signatures/resect_signatures.dart';

import '../../data/database/artifact_database.dart';

/// Cache-aware reader for the Ghidra-extracted call graph.
///
/// Populated as a side effect of [SignaturesService.extractFor]:
/// each extraction pass writes both tables together, so anywhere the
/// signatures cache has rows for an ELF, the call-graph cache will
/// too. Reads are point-lookups against `ghidra_call_graphs.elfHash`
/// (single row per ELF, full payload as JSON).
///
/// Gated on `MODULE_GHIDRA` via [SignaturesService]; this service
/// itself just does the read.
class CallGraphService {
  CallGraphService({required this.db});

  final ArtifactDatabase db;

  /// Delete the cached call-graph row for [elfHash]. Used by the UI's
  /// "Regenerate Call Graph" path (shift-click) to force the next read
  /// to miss and re-run `SignaturesService.extractFor` from scratch.
  /// Side note: `extractFor` itself delete-then-inserts all six Ghidra
  /// tables atomically, so removing only this row is enough to trigger
  /// a clean re-extract of everything — the rest of the rows get
  /// overwritten by the next extraction pass.
  Future<int> invalidateFor(String elfHash) =>
      (db.delete(db.ghidraCallGraphs)
            ..where((t) => t.elfHash.equals(elfHash)))
          .go();

  /// True iff a row exists in `ghidra_call_graphs` for [elfHash].
  Future<bool> hasCallGraphFor(String elfHash) async {
    final row = await (db.selectOnly(db.ghidraCallGraphs)
          ..addColumns([db.ghidraCallGraphs.elfHash])
          ..where(db.ghidraCallGraphs.elfHash.equals(elfHash))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// Read the cached call graph for [elfHash]. Returns null when no
  /// row exists (the caller should kick off extraction via
  /// `SignaturesService.extractFor`) or when the cached payload is
  /// corrupt (treated as cache miss; caller can re-extract).
  Future<Map<String, CallGraphNode>?> callGraphFor(String elfHash) async {
    final row = await (db.select(db.ghidraCallGraphs)
          ..where((t) => t.elfHash.equals(elfHash)))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      final json = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      return {
        for (final entry in json.entries)
          entry.key:
              CallGraphNode.fromJson(entry.value as Map<String, dynamic>),
      };
    } catch (_) {
      // Corrupt cache — treat as a miss so the caller can re-extract.
      return null;
    }
  }
}
