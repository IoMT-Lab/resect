import '../../data/database/artifact_database.dart';
import '../../data/models/rag_index_status.dart';
import '../../data/models/symbol_group.dart';
import '../../data/models/synthesis_manifest.dart';

/// Count the artifacts feeding a synthesis run — the knowledge the loop
/// has to work with. One implementation shared by the CLI, the auto-tune
/// engine (per round), and the UI adapter.
///
/// [hookOverrides]/[hookBindings]/[commsAssignments] are the maps in
/// effect for the run (only their sizes are read). [ragStatus] comes
/// from `RagIndex.statusSnapshot` when a RAG index exists; null yields
/// empty chunk counts.
Future<ArtifactCensus> computeArtifactCensus({
  required ArtifactDatabase db,
  required String elfHash,
  required Map<String, dynamic> hookOverrides,
  required Map<String, dynamic> hookBindings,
  required Map<String, dynamic> commsAssignments,
  required List<SymbolGroup> symbolGroups,
  RagIndexStatus? ragStatus,
}) async =>
    ArtifactCensus(
      // The whole catalog — the firmware-scoped query ignores elfHash
      // today (known debt); reports label the number accordingly.
      hookArtifacts: (await db.getAllArtifacts()).length,
      hookBindings: hookBindings.length,
      forcedOverrides: hookOverrides.length,
      commsAssignments: commsAssignments.length,
      groupMembers: symbolGroups.fold(0, (a, g) => a + g.members.length),
      ragChunksByKind: ragStatus?.chunkCountsByKind ?? const {},
      signatures: await db.countSignaturesFor(elfHash),
      decompilations: (await db.decompilationsFor(elfHash)).length,
    );
