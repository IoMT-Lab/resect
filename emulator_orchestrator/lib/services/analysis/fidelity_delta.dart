import '../../data/models/synthesis_manifest.dart';

/// Pure-function delta between two [ManifestMetrics] snapshots.
///
/// The closed-loop LLM orchestrator passes a [FidelityDelta] to the
/// LLM each round so it can see what its prior recommendations
/// actually accomplished. Also surfaced in the per-round summary
/// card on the auto-tune modal.
///
/// Sign convention: positive = "current improved over prior".
/// `current.overallFidelity - prior.overallFidelity` for every metric
/// (and `current.executedSymbols.length - prior.executedSymbols.length`
/// for [executedSymbolsDelta]). When either side has a null coverage
/// or subgraph value (no traversal data / no start/end pair), the
/// corresponding delta is also null.
class FidelityDelta {
  const FidelityDelta({
    required this.overallFidelityDelta,
    required this.coverageFidelityDelta,
    required this.subgraphFidelityDelta,
    required this.executedSymbolsDelta,
  });

  /// `current.overallFidelity - prior.overallFidelity`. Always
  /// defined since both manifests are guaranteed to carry an overall
  /// score.
  final double overallFidelityDelta;

  /// `current.coverageFidelity - prior.coverageFidelity`. Null when
  /// either side didn't capture coverage fidelity (no traversed
  /// symbols).
  final double? coverageFidelityDelta;

  /// `current.subgraphFidelity - prior.subgraphFidelity`. Null when
  /// either side didn't have start/end symbols configured.
  final double? subgraphFidelityDelta;

  /// Net change in the count of distinct symbols the firmware
  /// reached during the run.
  final int executedSymbolsDelta;

  /// Compute the delta from [prior] to [current]. Both are required
  /// — the round-0 baseline produces the first metrics; subsequent
  /// rounds always have a prior to compare against.
  factory FidelityDelta.compute({
    required ManifestMetrics prior,
    required ManifestMetrics current,
    int priorExecutedCount = 0,
    int currentExecutedCount = 0,
  }) =>
      FidelityDelta(
        overallFidelityDelta:
            current.overallFidelity - prior.overallFidelity,
        coverageFidelityDelta:
            (current.coverageFidelity != null && prior.coverageFidelity != null)
                ? current.coverageFidelity! - prior.coverageFidelity!
                : null,
        subgraphFidelityDelta:
            (current.subgraphFidelity != null && prior.subgraphFidelity != null)
                ? current.subgraphFidelity! - prior.subgraphFidelity!
                : null,
        executedSymbolsDelta: currentExecutedCount - priorExecutedCount,
      );

  /// True when no monitored metric moved (overall stayed, coverage
  /// and subgraph either stayed or weren't comparable, executed-
  /// symbol count unchanged). Convenience predicate for the LLM
  /// prompt and the round summary card; not a termination signal on
  /// its own.
  bool get isFlat =>
      overallFidelityDelta == 0 &&
      (coverageFidelityDelta == null || coverageFidelityDelta == 0) &&
      (subgraphFidelityDelta == null || subgraphFidelityDelta == 0) &&
      executedSymbolsDelta == 0;

  Map<String, dynamic> toJson() => {
        'overall_fidelity_delta': overallFidelityDelta,
        if (coverageFidelityDelta != null)
          'coverage_fidelity_delta': coverageFidelityDelta,
        if (subgraphFidelityDelta != null)
          'subgraph_fidelity_delta': subgraphFidelityDelta,
        'executed_symbols_delta': executedSymbolsDelta,
      };
}
