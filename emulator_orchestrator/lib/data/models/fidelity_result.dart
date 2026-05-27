/// Result of fidelity analysis on a call graph after synthesis.
///
/// Fidelity measures how much of the emulated system's behavior is "real"
/// firmware vs. stubbed by hook bypasses. Degradation propagates upward
/// through the call graph — parent functions that depend on hooked children
/// receive proportional fidelity reduction.
class FidelityResult {
  /// Overall weighted fidelity score (0.0 = fully degraded, 1.0 = fully intact).
  final double overallFidelity;

  /// Fidelity averaged over only the functions that were actually traversed
  /// during emulation/synthesis. Null if no traversal data is available.
  final double? coverageFidelity;

  /// Number of traversed functions used to compute [coverageFidelity].
  final int traversedFunctions;

  /// Per-function fidelity scores (function name → 0.0–1.0).
  final Map<String, double> perFunction;

  /// Total number of functions in the analyzed scope.
  final int totalFunctions;

  /// Functions directly hooked (fidelity forced to 0.0 or near-zero).
  final int hookedFunctions;

  /// Functions transitively affected (0.0 < fidelity < 1.0).
  final int degradedFunctions;

  /// Functions completely unaffected (fidelity == 1.0).
  final int intactFunctions;

  /// Number of iterations the solver ran before converging.
  final int solverIterations;

  /// Fidelity averaged over only the functions on paths between the
  /// configured start and stop symbols. Null if start/stop are not set.
  final double? subgraphFidelity;

  /// Number of functions in the start→stop subgraph.
  final int subgraphFunctions;

  /// Fraction of all call-graph functions that were traversed during
  /// emulation/synthesis (0.0–1.0). Null if no traversal data is available.
  final double? coverage;

  const FidelityResult({
    required this.overallFidelity,
    required this.perFunction, required this.totalFunctions, required this.hookedFunctions, required this.degradedFunctions, required this.intactFunctions, required this.solverIterations, this.coverageFidelity,
    this.traversedFunctions = 0,
    this.subgraphFidelity,
    this.subgraphFunctions = 0,
    this.coverage,
  });

  Map<String, dynamic> toJson() => {
      'overallFidelity': overallFidelity,
      if (coverageFidelity != null) 'coverageFidelity': coverageFidelity,
      if (coverage != null) 'coverage': coverage,
      if (traversedFunctions > 0) 'traversedFunctions': traversedFunctions,
      'totalFunctions': totalFunctions,
      'hookedFunctions': hookedFunctions,
      'degradedFunctions': degradedFunctions,
      'intactFunctions': intactFunctions,
      'solverIterations': solverIterations,
      if (subgraphFidelity != null) 'subgraphFidelity': subgraphFidelity,
      if (subgraphFunctions > 0) 'subgraphFunctions': subgraphFunctions,
      'perFunction': perFunction,
    };

  @override
  String toString() {
    final pct = (overallFidelity * 100).toStringAsFixed(1);
    final cov = coverage != null
        ? ', coverage: ${(coverage! * 100).toStringAsFixed(1)}%'
        : '';
    final covFid = coverageFidelity != null
        ? ', coverage fidelity: ${(coverageFidelity! * 100).toStringAsFixed(1)}%'
        : '';
    final sub = subgraphFidelity != null
        ? ', subgraph: ${(subgraphFidelity! * 100).toStringAsFixed(1)}%'
        : '';
    return 'FidelityResult($pct%$cov$covFid$sub — $intactFunctions intact, '
        '$degradedFunctions degraded, $hookedFunctions hooked)';
  }
}
