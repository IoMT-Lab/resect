import '../../data/models/call_graph.dart';
import '../../data/models/comms_assignment.dart';

/// Merge fresh classifier suggestions into persisted assignments for a graph.
///
/// The one merge rule for comms classification, shared by the UI's
/// `CommsClassificationController` and the CLI:
/// - Symbols already in [existing] keep their entry (including
///   [CommsClass.unclassified], the user-dismissal marker).
/// - Symbols new to [graph] receive the classifier's suggestion, if any.
/// - Symbols absent from [graph] fall out of the merged map.
/// - Symbols in neither map stay out entirely.
///
/// Known debt: [CommsAssignment] records no provenance, so "existing wins"
/// cannot distinguish a deliberate user choice from a prior run's classifier
/// suggestion — once persisted, a stale suggestion outranks an improved
/// classifier forever.
Map<String, CommsAssignment> mergeCommsAssignments({
  required CallGraph graph,
  required Map<String, CommsAssignment> existing,
  required Map<String, CommsAssignment> suggestions,
}) {
  final merged = <String, CommsAssignment>{};
  for (final sym in graph.symbols.keys) {
    if (existing.containsKey(sym)) {
      merged[sym] = existing[sym]!;
    } else if (suggestions.containsKey(sym)) {
      merged[sym] = suggestions[sym]!;
    }
  }
  return merged;
}

/// Shallow equality over assignment maps, for change detection.
bool commsAssignmentsEqual(
  Map<String, CommsAssignment> a,
  Map<String, CommsAssignment> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
