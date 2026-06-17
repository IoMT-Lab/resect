import 'hook_binding.dart';
import 'recommendation.dart';
import 'synthesis_manifest.dart';

/// Durable per-round record of one iteration of the closed-loop
/// LLM-orchestrated synthesizer.
///
/// One [RoundSnapshot] is appended to `Emulator.roundSnapshots`
/// at the end of every round of the auto-tune loop. The snapshot
/// captures:
///
/// - The overlay state going INTO this round (so the snapshot is
///   self-contained — a future reader can reconstruct what synthesis
///   ran with).
/// - The outcome (metrics, manifest reference, executed-symbol set).
/// - The LLM's recommendations and the user's per-recommendation
///   decisions (Accept / Reject / Edit), if this round had a review
///   step (round 0 baseline has neither).
///
/// **Forward-compatibility slots.** [memoryMapCheckpointPath],
/// [resumePointSymbol], and [deviceProfileSnapshot] are reserved
/// for future infrastructure (memory-map checkpointing,
/// resume-from-instruction synthesis, device-class metadata). All
/// null on day-one snapshots; populated as those features land
/// without a schema break.
///
/// **Persistence.** Snapshots are serialized as part of the `.emu`
/// project file under the `round_snapshots` key. Pruning policy:
/// when the list exceeds the project's configured cap, oldest
/// snapshots are dropped FIFO at the next append.
class RoundSnapshot {
  const RoundSnapshot({
    required this.snapshotVersion,
    required this.round,
    required this.synthesizerRunId,
    required this.createdAt,
    required this.hookOverrides,
    required this.hookOverrideScopes,
    required this.hookPreferences,
    required this.hookBindings,
    required this.iterationCap,
    required this.metrics,
    required this.executedSymbols,
    required this.manifestRef,
    this.llmRecommendations,
    this.userDecisions,
    this.llmProse,
    this.memoryMapCheckpointPath,
    this.resumePointSymbol,
    this.deviceProfileSnapshot,
  });

  /// Schema version this snapshot was written with. Bump on shape
  /// changes; the reader accepts known versions.
  final int snapshotVersion;

  /// 0-indexed round number. Round 0 is the baseline synthesis run
  /// before any LLM recommendations; rounds 1..N each carry the
  /// LLM's recommendations + the user's review decisions.
  final int round;

  /// ISO-8601 timestamp identifying the synthesizer run that
  /// produced [metrics] / [executedSymbols] / [manifestRef]. Same
  /// value as `SynthesisManifest.synthesizerRunId`.
  final String synthesizerRunId;

  /// When this snapshot was appended.
  final DateTime createdAt;

  /// Forced override map (symbol → artifact ID) at the start of
  /// this round.
  final Map<String, int> hookOverrides;

  /// Per-symbol Renode scope strings at the start of this round.
  final Map<String, String> hookOverrideScopes;

  /// Hook preference map (symbol → preferred artifact ID) at the
  /// start of this round.
  final Map<String, int> hookPreferences;

  /// Fidelity-scored hook bindings at the start of this round.
  final Map<String, HookBinding> hookBindings;

  /// Synthesizer iteration cap configured for this round's run.
  final int iterationCap;

  /// Run-level aggregate fidelity metrics produced by the run.
  /// Always populated on a successfully-appended snapshot — copied
  /// directly from `SynthesisManifest.metrics` (manifest v2+) or
  /// recomputed via `FidelityCalculator` for legacy v1 manifests.
  final ManifestMetrics metrics;

  /// Symbols the firmware actually reached during this round's run.
  final List<String> executedSymbols;

  /// Reference to the [SynthesisManifest] this round produced. The
  /// manifest itself lives next to the project on disk; the
  /// snapshot carries only the lookup key.
  final SynthesisManifestRef manifestRef;

  /// Recommendations the LLM emitted at the start of this round.
  /// Null on round 0 (baseline has no LLM call).
  final List<Recommendation>? llmRecommendations;

  /// User's per-recommendation decisions (Accept / Reject / Edit).
  /// Null on round 0; length matches [llmRecommendations] on other
  /// rounds.
  final List<RecommendationDecision>? userDecisions;

  /// LLM's prose summary for this round, if any. Optional even on
  /// non-baseline rounds.
  final String? llmProse;

  /// Forward-compat: path to a memory-map checkpoint snapshot
  /// associated with this round. Populated once the BINDING
  /// FOUNDATION memory-map-checkpointing work lands.
  final String? memoryMapCheckpointPath;

  /// Forward-compat: symbol from which the next round's synthesis
  /// could resume (instead of restarting from boot). Populated once
  /// resume-from-instruction synthesis lands.
  final String? resumePointSymbol;

  /// Forward-compat: serialized device-class metadata at the
  /// moment this round ran. Populated once the device-class context
  /// work lands.
  final String? deviceProfileSnapshot;

  static const _currentSnapshotVersion = 1;

  /// Version this build stamps onto new snapshots. Exposed for
  /// builders and tests.
  static int get currentVersion => _currentSnapshotVersion;

  Map<String, dynamic> toJson() => {
        'snapshot_version': snapshotVersion,
        'round': round,
        'synthesizer_run_id': synthesizerRunId,
        'created_at': createdAt.toIso8601String(),
        'hook_overrides': hookOverrides,
        if (hookOverrideScopes.isNotEmpty)
          'hook_override_scopes': hookOverrideScopes,
        'hook_preferences': hookPreferences,
        'hook_bindings': hookBindings.map(
          (symbol, binding) => MapEntry(symbol, binding.toJson()),
        ),
        'iteration_cap': iterationCap,
        'metrics': metrics.toJson(),
        'executed_symbols': executedSymbols,
        'manifest_ref': manifestRef.toJson(),
        if (llmRecommendations != null)
          'llm_recommendations':
              llmRecommendations!.map((r) => r.toJson()).toList(),
        if (userDecisions != null)
          'user_decisions':
              userDecisions!.map((d) => d.toJson()).toList(),
        if (llmProse != null) 'llm_prose': llmProse,
        if (memoryMapCheckpointPath != null)
          'memory_map_checkpoint_path': memoryMapCheckpointPath,
        if (resumePointSymbol != null)
          'resume_point_symbol': resumePointSymbol,
        if (deviceProfileSnapshot != null)
          'device_profile_snapshot': deviceProfileSnapshot,
      };

  factory RoundSnapshot.fromJson(Map<String, dynamic> json) {
    final version = json['snapshot_version'] as int;
    if (version > _currentSnapshotVersion) {
      throw FormatException(
        'RoundSnapshot version $version is newer than this build '
        '(latest supported: $_currentSnapshotVersion).',
      );
    }
    final llmRaw = json['llm_recommendations'] as List<dynamic>?;
    final llmRecs = llmRaw
        ?.map((e) =>
            Recommendation.fromJson(e as Map<String, dynamic>))
        .whereType<Recommendation>()
        .toList();
    final userRaw = json['user_decisions'] as List<dynamic>?;
    final userDecs = userRaw
        ?.map((e) =>
            RecommendationDecision.fromJson(e as Map<String, dynamic>))
        .toList();
    return RoundSnapshot(
      snapshotVersion: version,
      round: json['round'] as int,
      synthesizerRunId: json['synthesizer_run_id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      hookOverrides: (json['hook_overrides'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as int)),
      hookOverrideScopes:
          (json['hook_override_scopes'] as Map<String, dynamic>?)
                  ?.map((k, v) => MapEntry(k, v as String)) ??
              const <String, String>{},
      hookPreferences: (json['hook_preferences'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as int)),
      hookBindings: (json['hook_bindings'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(
            k, HookBinding.fromJson(v as Map<String, dynamic>)),
      ),
      iterationCap: json['iteration_cap'] as int,
      metrics: ManifestMetrics.fromJson(
          json['metrics'] as Map<String, dynamic>),
      executedSymbols: (json['executed_symbols'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      manifestRef: SynthesisManifestRef.fromJson(
          json['manifest_ref'] as Map<String, dynamic>),
      llmRecommendations: llmRecs,
      userDecisions: userDecs,
      llmProse: json['llm_prose'] as String?,
      memoryMapCheckpointPath:
          json['memory_map_checkpoint_path'] as String?,
      resumePointSymbol: json['resume_point_symbol'] as String?,
      deviceProfileSnapshot: json['device_profile_snapshot'] as String?,
    );
  }
}

/// Lookup key for a [SynthesisManifest] referenced by a [RoundSnapshot].
///
/// The manifest itself lives next to the project on disk
/// (`<project>/manifests/<run_id>.json`). The snapshot carries
/// only the key so a future reader can locate it without the
/// snapshot duplicating the manifest's contents.
class SynthesisManifestRef {
  const SynthesisManifestRef({
    required this.runId,
    this.path,
  });

  /// Synthesizer run ID — matches `SynthesisManifest.synthesizerRunId`.
  final String runId;

  /// Optional filesystem path to the manifest JSON. Populated when
  /// the snapshot was created on a saved project; null otherwise.
  final String? path;

  Map<String, dynamic> toJson() => {
        'run_id': runId,
        if (path != null) 'path': path,
      };

  factory SynthesisManifestRef.fromJson(Map<String, dynamic> json) =>
      SynthesisManifestRef(
        runId: json['run_id'] as String,
        path: json['path'] as String?,
      );
}

/// What the user chose for one of the LLM's recommendations during
/// the review step.
class RecommendationDecision {
  const RecommendationDecision({
    required this.original,
    required this.action,
    this.edited,
    this.userNote,
  });

  /// The recommendation as the LLM emitted it.
  final Recommendation original;

  /// The user's action — Accept, Reject, or Edit.
  final UserAction action;

  /// If [action] is [UserAction.edited], the modified recommendation
  /// the user produced. Null otherwise. Equal-shape to [original]
  /// (same `kind`).
  final Recommendation? edited;

  /// Optional free-text reason. Surfaced in the snapshot history
  /// for audit; not required.
  final String? userNote;

  /// The recommendation the orchestrator would actually apply for
  /// this decision: [edited] if the user edited it, [original]
  /// otherwise. Null when [action] is [UserAction.rejected].
  Recommendation? get applied {
    switch (action) {
      case UserAction.accepted:
        return original;
      case UserAction.edited:
        return edited ?? original;
      case UserAction.rejected:
        return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'original': original.toJson(),
        'action': action.name,
        if (edited != null) 'edited': edited!.toJson(),
        if (userNote != null) 'user_note': userNote,
      };

  factory RecommendationDecision.fromJson(Map<String, dynamic> json) {
    final original = Recommendation.fromJson(
        json['original'] as Map<String, dynamic>);
    if (original == null) {
      throw FormatException(
        'RecommendationDecision.original has unknown kind: '
        '${(json['original'] as Map<String, dynamic>)['kind']}',
      );
    }
    final editedJson = json['edited'] as Map<String, dynamic>?;
    final edited = editedJson == null
        ? null
        : Recommendation.fromJson(editedJson);
    return RecommendationDecision(
      original: original,
      action: UserAction.values
          .firstWhere((a) => a.name == json['action'] as String),
      edited: edited,
      userNote: json['user_note'] as String?,
    );
  }
}

/// User action on a single recommendation row in the review UI.
enum UserAction {
  /// Apply the recommendation as the LLM emitted it.
  accepted,

  /// Drop this recommendation; the next synthesis round runs with
  /// the overlay unchanged for this symbol.
  rejected,

  /// Apply a user-modified variant of the recommendation. See
  /// [RecommendationDecision.edited].
  edited,
}
