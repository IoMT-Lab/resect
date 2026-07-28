import 'dart:collection';

import '../../data/models/call_graph.dart';
import '../../data/models/fidelity_result.dart';

/// Computes emulation fidelity by propagating degradation from hooked
/// functions upward through the call graph.
///
/// Each hooked function is assigned fidelity 0.0 (or `1 - efficacy`).
/// Parent functions are degraded in proportion to how many of their
/// outgoing edges lead to degraded children. The computation iterates
/// until convergence, handling cycles via fixed-point iteration.
class FidelityCalculator {
  static const _convergenceThreshold = 0.0001;
  static const _maxIterations = 100;

  /// Forward-BFS from each of [entries] over `calledSymbols` edges and
  /// return the set of reachable symbols (including the entries
  /// themselves). Used by the pre-synthesis report to distinguish
  /// "uncovered AND reachable" from "uncovered AND dead code" — the
  /// latter doesn't affect synthesis outcomes because the firmware
  /// never executes it.
  ///
  /// Entries that don't exist in [callGraph] are skipped. If none of
  /// [entries] match, returns an empty set (caller can fall back to
  /// "all symbols" semantics).
  static Set<String> reachableFromEntries(
    CallGraph callGraph,
    List<String> entries,
  ) {
    final symbols = callGraph.symbols;
    final reachable = <String>{};
    final queue = Queue<String>();
    for (final entry in entries) {
      if (symbols.containsKey(entry) && reachable.add(entry)) {
        queue.add(entry);
      }
    }
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      final sym = symbols[current];
      if (sym == null) continue;
      for (final child in sym.calledSymbols.keys) {
        if (symbols.containsKey(child) && reachable.add(child)) {
          queue.add(child);
        }
      }
    }
    return reachable;
  }

  /// Find all symbols on any path from [start] to [stop] in [callGraph].
  ///
  /// BFS forward from start, BFS backward from stop (using callers),
  /// then intersect to get only nodes that lie on some path between them.
  static Set<String> subgraphBetween(
    CallGraph callGraph,
    String start,
    String stop,
  ) {
    final symbols = callGraph.symbols;
    if (!symbols.containsKey(start) || !symbols.containsKey(stop)) {
      return {};
    }

    // Forward BFS from start.
    final forwardReachable = <String>{};
    final forwardQueue = Queue<String>()..add(start);
    forwardReachable.add(start);
    while (forwardQueue.isNotEmpty) {
      final current = forwardQueue.removeFirst();
      final sym = symbols[current];
      if (sym == null) continue;
      for (final child in sym.calledSymbols.keys) {
        if (symbols.containsKey(child) && forwardReachable.add(child)) {
          forwardQueue.add(child);
        }
      }
    }

    // Backward BFS from stop (follow caller edges).
    final backwardReachable = <String>{};
    final backwardQueue = Queue<String>()..add(stop);
    backwardReachable.add(stop);
    while (backwardQueue.isNotEmpty) {
      final current = backwardQueue.removeFirst();
      for (final caller in callGraph.getCallers(current)) {
        if (symbols.containsKey(caller) && backwardReachable.add(caller)) {
          backwardQueue.add(caller);
        }
      }
    }

    return forwardReachable.intersection(backwardReachable);
  }

  /// Compute fidelity for [callGraph] given [hookedSymbols].
  ///
  /// [traversedSymbols] — symbols actually executed during the run. If
  ///   provided, a separate `coverageFidelity` is computed over only these.
  /// [subgraphSymbols] — symbols on paths between start/stop. If provided,
  ///   a separate `subgraphFidelity` is computed over only these.
  /// [weights] — per-function importance weights for the overall score.
  ///   Functions not in the map default to 1.0.
  /// [hookEfficacy] — per-symbol efficacy (0.0–1.0). A hook with 80%
  ///   efficacy contributes only 20% degradation. Defaults to 0.0 (no value).
  static FidelityResult compute({
    required CallGraph callGraph,
    required Set<String> hookedSymbols,
    Set<String> traversedSymbols = const {},
    Set<String> subgraphSymbols = const {},
    Map<String, double> weights = const {},
    Map<String, double> hookEfficacy = const {},
  }) {
    final symbols = callGraph.symbols;
    if (symbols.isEmpty) {
      return const FidelityResult(
        overallFidelity: 1.0,
        perFunction: {},
        totalFunctions: 0,
        hookedFunctions: 0,
        degradedFunctions: 0,
        intactFunctions: 0,
        solverIterations: 0,
      );
    }

    // Initialize fidelity values.
    // Hooked symbols: fidelity = efficacy (default 0.0).
    // All others: fidelity = 1.0.
    final fidelity = <String, double>{};
    for (final name in symbols.keys) {
      if (hookedSymbols.contains(name)) {
        fidelity[name] = hookEfficacy[name] ?? 0.0;
      } else {
        fidelity[name] = 1.0;
      }
    }

    // Iterative convergence: recompute non-hooked functions until stable.
    var iterations = 0;
    for (var i = 0; i < _maxIterations; i++) {
      iterations++;
      var maxDelta = 0.0;

      for (final entry in symbols.entries) {
        final name = entry.key;

        // Hooked symbols have fixed fidelity — skip.
        if (hookedSymbols.contains(name)) continue;

        final calledSymbols = entry.value.calledSymbols;

        // Leaf functions with no outgoing edges stay at 1.0.
        if (calledSymbols.isEmpty) continue;

        // Compute degradation as average of children's degradation.
        // Only count children that exist in the call graph.
        var degradationSum = 0.0;
        var edgeCount = 0;

        for (final childName in calledSymbols.keys) {
          if (fidelity.containsKey(childName)) {
            degradationSum += 1.0 - fidelity[childName]!;
            edgeCount++;
          }
        }

        if (edgeCount == 0) continue;

        final newFidelity = 1.0 - (degradationSum / edgeCount);
        final delta = (newFidelity - fidelity[name]!).abs();
        if (delta > maxDelta) maxDelta = delta;
        fidelity[name] = newFidelity;
      }

      if (maxDelta < _convergenceThreshold) break;
    }

    // Compute summary counts.
    var hooked = 0;
    var degraded = 0;
    var intact = 0;

    for (final entry in fidelity.entries) {
      if (hookedSymbols.contains(entry.key)) {
        hooked++;
      } else if (entry.value >= 1.0 - _convergenceThreshold) {
        intact++;
      } else {
        degraded++;
      }
    }

    // Compute weighted overall fidelity.
    var weightedSum = 0.0;
    var totalWeight = 0.0;

    for (final entry in fidelity.entries) {
      final w = weights[entry.key] ?? 1.0;
      weightedSum += w * entry.value;
      totalWeight += w;
    }

    final overall = totalWeight > 0 ? weightedSum / totalWeight : 1.0;

    // Compute coverage: fraction of all call-graph functions that were traversed.
    double? coverageRatio;
    // Compute coverage fidelity: average fidelity over only traversed symbols.
    double? covFidelity;
    var travCount = 0;
    if (traversedSymbols.isNotEmpty) {
      var travSum = 0.0;
      for (final name in traversedSymbols) {
        if (fidelity.containsKey(name)) {
          travSum += fidelity[name]!;
          travCount++;
        }
      }
      covFidelity = travCount > 0 ? travSum / travCount : null;
      coverageRatio = fidelity.isNotEmpty ? travCount / fidelity.length : null;
    }

    // Compute subgraph fidelity: average over start→stop path symbols.
    double? subFidelity;
    var subCount = 0;
    if (subgraphSymbols.isNotEmpty) {
      var subSum = 0.0;
      for (final name in subgraphSymbols) {
        if (fidelity.containsKey(name)) {
          subSum += fidelity[name]!;
          subCount++;
        }
      }
      subFidelity = subCount > 0 ? subSum / subCount : null;
    }

    return FidelityResult(
      overallFidelity: overall,
      coverageFidelity: covFidelity,
      traversedFunctions: travCount,
      coverage: coverageRatio,
      perFunction: fidelity,
      totalFunctions: fidelity.length,
      hookedFunctions: hooked,
      degradedFunctions: degraded,
      intactFunctions: intact,
      solverIterations: iterations,
      subgraphFidelity: subFidelity,
      subgraphFunctions: subCount,
    );
  }
}
