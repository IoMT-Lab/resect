import '../../services/llm/recommendation_service.dart';

/// Per-session configuration the user provides before kicking off
/// the closed-loop LLM-orchestrated synthesizer.
///
/// Collected by the auto-tune config dialog on the Synthesize tab
/// and handed to [LlmSynthesisOrchestrator.runAutoTune] verbatim.
/// All fields have safe defaults so a one-click start with no
/// adjustments runs a reasonable session.
class AutoTuneConfig {
  const AutoTuneConfig({
    this.maxRounds = defaultMaxRounds,
    this.snapshotCap = defaultSnapshotCap,
    this.snapshotWindowSize = defaultSnapshotWindowSize,
    this.maxRecommendationsPerRound = defaultMaxRecommendationsPerRound,
    this.stagnantRoundLimit = defaultStagnantRoundLimit,
    this.warmStart = defaultWarmStart,
    this.optimizationTarget,
  });

  /// Hard cap on the number of LLM rounds (excluding the round-0
  /// baseline) the orchestrator will run before terminating.
  final int maxRounds;

  /// FIFO cap on the project's `roundSnapshots` list. When the
  /// orchestrator's appendRoundSnapshot call would push the list
  /// past this value, the oldest snapshots are dropped. Stored on
  /// the [Emulator] alongside the snapshots themselves; this config
  /// field overrides the project's current value at session start.
  final int snapshotCap;

  /// How many recent snapshots the orchestrator passes to the LLM
  /// each round as context. 3 is the default — enough trajectory
  /// for the model to reason about prior recommendations without
  /// bloating the prompt.
  final int snapshotWindowSize;

  /// Cap on the number of recommendations the LLM may emit per round
  /// (the schema's `maxItems`). Raised from the historical 3 so the
  /// model can batch related fixes (e.g. classify every ready-flag on
  /// the frontier in one round) the way a human reading symbol names
  /// does.
  final int maxRecommendationsPerRound;

  /// Number of consecutive successful-but-coverage-stagnant rounds
  /// tolerated before the session stops with `noCoverageProgress`.
  /// The first stagnant round triggers a feedback-escalated LLM round
  /// (wrapper-skip framing); reaching this limit means escalation was
  /// tried and didn't move coverage either.
  final int stagnantRoundLimit;

  /// When true, each round's synthesis is seeded with the previous
  /// round's resolved hook code (warm start): rounds accumulate, and
  /// sessions converge faster at the cost of path-dependent results.
  /// Default false: every round re-synthesizes from the overlay set on
  /// a clean machine, so rounds are independent, comparable experiments.
  /// The engine never reads this — each surface's `runSynthesis`
  /// adapter closes over it.
  final bool warmStart;

  /// Optional bias signal the LLM's recommendations should target.
  /// Surfaced as a dropdown in the config dialog; null means "no
  /// explicit target — improve everything you can."
  final OptimizationTarget? optimizationTarget;

  static const defaultMaxRounds = 5;
  static const defaultSnapshotCap = 100;
  static const defaultSnapshotWindowSize = 3;
  static const defaultMaxRecommendationsPerRound = 10;
  static const defaultStagnantRoundLimit = 2;
  static const defaultWarmStart = false;

  AutoTuneConfig copyWith({
    int? maxRounds,
    int? snapshotCap,
    int? snapshotWindowSize,
    int? maxRecommendationsPerRound,
    int? stagnantRoundLimit,
    bool? warmStart,
    OptimizationTarget? optimizationTarget,
    bool clearOptimizationTarget = false,
  }) =>
      AutoTuneConfig(
        maxRounds: maxRounds ?? this.maxRounds,
        snapshotCap: snapshotCap ?? this.snapshotCap,
        snapshotWindowSize: snapshotWindowSize ?? this.snapshotWindowSize,
        maxRecommendationsPerRound:
            maxRecommendationsPerRound ?? this.maxRecommendationsPerRound,
        stagnantRoundLimit: stagnantRoundLimit ?? this.stagnantRoundLimit,
        warmStart: warmStart ?? this.warmStart,
        optimizationTarget: clearOptimizationTarget
            ? null
            : (optimizationTarget ?? this.optimizationTarget),
      );
}
