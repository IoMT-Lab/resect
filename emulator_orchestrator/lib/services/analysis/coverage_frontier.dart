import '../../data/models/call_graph.dart';

/// One function on the coverage frontier: it executed, but at least
/// one of the functions it calls never did. These are the boundary
/// points where forward progress stopped expanding — the concrete
/// candidates for "something here silently blocks the firmware."
class FrontierEntry {
  const FrontierEntry({
    required this.symbol,
    required this.unexecutedCallees,
  });

  /// The executed function sitting on the boundary.
  final String symbol;

  /// The callees of [symbol] that were never entered during the run,
  /// in call-graph order. Non-empty by construction.
  final List<String> unexecutedCallees;

  int get unexecutedCalleeCount => unexecutedCallees.length;
}

/// Compute the coverage frontier for a run: executed functions that
/// have at least one never-executed callee, ranked by how many of
/// their callees went unreached (desc), tie-broken by symbol name
/// for determinism. Returns at most [topK] entries.
///
/// This is the signal Job 2 (proactive coverage) needs and which the
/// engine does not otherwise produce — Resect records only a flat
/// set of entered functions, with no notion of where execution
/// stopped branching outward. Deriving it here is pure: no I/O, no
/// engine changes.
///
/// [executedSymbols] is the set of functions entered at least once
/// (order/counts are irrelevant here). [callGraph] supplies the
/// caller→callee edges via each `Symbol.calledSymbols`. A callee
/// name that isn't itself a node in the graph (e.g. a PLT stub or an
/// unresolved import) still counts as unexecuted if it's not in the
/// executed set — it's a real place execution didn't go.
List<FrontierEntry> computeFrontier({
  required Set<String> executedSymbols,
  required CallGraph callGraph,
  int topK = 12,
}) {
  final entries = <FrontierEntry>[];
  for (final symbol in executedSymbols) {
    final node = callGraph.symbols[symbol];
    if (node == null) continue; // executed but not in the graph — skip.
    final unreached = <String>[];
    for (final callee in node.calledSymbols.keys) {
      if (!executedSymbols.contains(callee)) {
        unreached.add(callee);
      }
    }
    if (unreached.isNotEmpty) {
      entries.add(FrontierEntry(symbol: symbol, unexecutedCallees: unreached));
    }
  }
  entries.sort((a, b) {
    final byCount =
        b.unexecutedCalleeCount.compareTo(a.unexecutedCalleeCount);
    if (byCount != 0) return byCount;
    return a.symbol.compareTo(b.symbol);
  });
  if (entries.length > topK) {
    return entries.sublist(0, topK);
  }
  return entries;
}
