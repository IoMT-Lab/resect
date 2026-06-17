import '../services/recommendation_service.dart';

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
    this.maxWallClock = defaultMaxWallClock,
    this.snapshotCap = defaultSnapshotCap,
    this.snapshotWindowSize = defaultSnapshotWindowSize,
    this.optimizationTarget,
  });

  /// Hard cap on the number of LLM rounds (excluding the round-0
  /// baseline) the orchestrator will run before terminating.
  final int maxRounds;

  /// Hard cap on the total wall-clock elapsed across the session.
  /// Counts from `AutoTuneStarted` through the final `RoundCompleted`
  /// or `AutoTuneFinished`. The orchestrator checks this before
  /// each round and exits with reason `budget-exhausted` when the
  /// cap is hit.
  final Duration maxWallClock;

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

  /// Optional bias signal the LLM's recommendations should target.
  /// Surfaced as a dropdown in the config dialog; null means "no
  /// explicit target — improve everything you can."
  final OptimizationTarget? optimizationTarget;

  static const defaultMaxRounds = 5;
  static const defaultMaxWallClock = Duration(minutes: 30);
  static const defaultSnapshotCap = 100;
  static const defaultSnapshotWindowSize = 3;

  AutoTuneConfig copyWith({
    int? maxRounds,
    Duration? maxWallClock,
    int? snapshotCap,
    int? snapshotWindowSize,
    OptimizationTarget? optimizationTarget,
    bool clearOptimizationTarget = false,
  }) =>
      AutoTuneConfig(
        maxRounds: maxRounds ?? this.maxRounds,
        maxWallClock: maxWallClock ?? this.maxWallClock,
        snapshotCap: snapshotCap ?? this.snapshotCap,
        snapshotWindowSize: snapshotWindowSize ?? this.snapshotWindowSize,
        optimizationTarget: clearOptimizationTarget
            ? null
            : (optimizationTarget ?? this.optimizationTarget),
      );
}
