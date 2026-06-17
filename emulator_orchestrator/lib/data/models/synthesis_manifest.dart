import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Per-run record of the synthesizer's per-symbol decisions, written
/// to disk alongside the project as `manifests/<run_id>.json` and
/// rendered visually in the post-synthesis report tab.
///
/// The manifest is the load-bearing artifact that lets a future
/// reader (LLM, CLI tool, the user opening a project months later)
/// reconstruct *why* synthesis settled where it did — not just which
/// hooks ended up applied, but the decision provenance (forced
/// override / comms / warm-start / binding / iteration fallback /
/// LLM on-demand) and any prior failed attempts.
///
/// **Schema versioning.** [manifestVersion] is bumped on additive
/// shape changes; the parser accepts every published version it
/// knows about. v1 (the original shipping shape) carried only
/// decisions + a run-outcome block. v2 adds run-level metrics
/// (`metrics`, `executedSymbols`, `timing`) alongside the existing
/// fields, and an optional `autoTuneRound` on each
/// [ManifestDecision]. v1 manifests load into the v2 reader with
/// all new fields null; v2 manifests carry the new fields populated.
class SynthesisManifest {
  const SynthesisManifest({
    required this.manifestVersion,
    required this.elfHash,
    required this.elfFileName,
    required this.synthesizerRunId,
    required this.result,
    required this.decisions,
    this.failedSymbol,
    this.metrics,
    this.executedSymbols,
    this.timing,
  });

  /// Schema version. Bump on shape changes; the parser accepts every
  /// version this build understands ([_supportedVersions]). Manifests
  /// written by this build use [_currentManifestVersion].
  final int manifestVersion;

  /// SHA-256 of the firmware ELF this run targeted. Lets a future
  /// manifest-diff view detect when the firmware changed under it.
  final String elfHash;

  /// Filename of the firmware ELF — for human-readable display.
  final String elfFileName;

  /// Unique run identifier — typically the run's start timestamp
  /// (ISO-8601) which doubles as both the manifest filename and a
  /// stable cross-reference for the synthesis-report UI.
  final String synthesizerRunId;

  /// Top-level run outcome: success/fail, iteration count, wall
  /// time. Subset of the data carried by the live [SynthesizerResult].
  final ManifestRunResult result;

  /// One [ManifestDecision] per symbol that received a hook during
  /// this run, in iteration-apply order. Symbols the synthesizer
  /// never touched (because emulation never paused at them) aren't
  /// included — the manifest records *decisions*, not the call graph.
  final List<ManifestDecision> decisions;

  /// The symbol whose hook candidates were exhausted (or whose
  /// forced override failed) — non-null iff `result.success == false`.
  final String? failedSymbol;

  /// Run-level aggregate fidelity metrics (v2+). Populated by the
  /// caller after the synthesizer returns, by running
  /// [FidelityCalculator] against the manifest's decisions + the
  /// run's executed symbols + the call graph. Null on v1 manifests
  /// loaded from disk.
  final ManifestMetrics? metrics;

  /// Symbols the firmware actually reached during this run (v2+).
  /// Subset of the call graph; used by the coverage-fidelity
  /// computation and by the closed-loop orchestrator's progress
  /// signal. Null on v1 manifests.
  final List<String>? executedSymbols;

  /// Optional per-iteration wall-clock timing (v2+). Each entry
  /// captures one iteration of the synthesizer's main loop. Null
  /// when not captured (cheap-build mode); populated when a richer
  /// timing breakdown is asked for.
  final List<IterationTiming>? timing;

  /// Manifest versions this build can parse. The most recent
  /// version in this set is what newly-built manifests are tagged
  /// with ([_currentManifestVersion]).
  static const _supportedVersions = {1, 2};
  static const _currentManifestVersion = 2;

  /// Version this build stamps onto new manifests. Exposed for the
  /// manifest builder and tests; consumers should generally read
  /// [manifestVersion] off a constructed manifest instead.
  static int get currentVersion => _currentManifestVersion;

  Map<String, dynamic> toJson() => {
        'manifest_version': manifestVersion,
        'elf_hash': elfHash,
        'elf_file_name': elfFileName,
        'synthesizer_run_id': synthesizerRunId,
        'result': result.toJson(),
        'decisions': decisions.map((d) => d.toJson()).toList(),
        if (failedSymbol != null) 'failed_symbol': failedSymbol,
        if (metrics != null) 'metrics': metrics!.toJson(),
        if (executedSymbols != null) 'executed_symbols': executedSymbols,
        if (timing != null)
          'timing': timing!.map((t) => t.toJson()).toList(),
      };

  factory SynthesisManifest.fromJson(Map<String, dynamic> json) {
    final version = json['manifest_version'] as int;
    if (!_supportedVersions.contains(version)) {
      throw FormatException(
        'Unsupported synthesis-manifest version: $version '
        '(this build understands versions ${_supportedVersions.join(", ")}).',
      );
    }
    return SynthesisManifest(
      manifestVersion: version,
      elfHash: json['elf_hash'] as String,
      elfFileName: json['elf_file_name'] as String,
      synthesizerRunId: json['synthesizer_run_id'] as String,
      result:
          ManifestRunResult.fromJson(json['result'] as Map<String, dynamic>),
      decisions: (json['decisions'] as List<dynamic>)
          .map((e) =>
              ManifestDecision.fromJson(e as Map<String, dynamic>))
          .toList(),
      failedSymbol: json['failed_symbol'] as String?,
      metrics: json['metrics'] == null
          ? null
          : ManifestMetrics.fromJson(json['metrics'] as Map<String, dynamic>),
      executedSymbols: (json['executed_symbols'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      timing: (json['timing'] as List<dynamic>?)
          ?.map((e) => IterationTiming.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Return a copy of this manifest with the v2 enrichment fields
  /// (`metrics`, `executedSymbols`, `timing`) populated. Used by the
  /// synthesis caller after the workflow returns to fold in
  /// [FidelityCalculator] output without re-building the rest of
  /// the manifest.
  SynthesisManifest withMetrics({
    required ManifestMetrics metrics,
    required List<String> executedSymbols,
    List<IterationTiming>? timing,
  }) =>
      SynthesisManifest(
        manifestVersion: manifestVersion,
        elfHash: elfHash,
        elfFileName: elfFileName,
        synthesizerRunId: synthesizerRunId,
        result: result,
        decisions: decisions,
        failedSymbol: failedSymbol,
        metrics: metrics,
        executedSymbols: executedSymbols,
        timing: timing ?? this.timing,
      );

  /// Format the manifest as pretty-printed JSON ready to write to
  /// disk. Uses a 2-space indent to keep diffs readable.
  String toPrettyJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Top-level outcome embedded in the manifest. Distinct from the
/// in-memory [SynthesizerResult] because the manifest stays serialized
/// for the long haul and shouldn't carry references to ephemeral
/// per-run code-state maps.
class ManifestRunResult {
  const ManifestRunResult({
    required this.success,
    required this.totalIterations,
    required this.durationSeconds,
  });

  final bool success;
  final int totalIterations;
  final double durationSeconds;

  Map<String, dynamic> toJson() => {
        'success': success,
        'total_iterations': totalIterations,
        'duration_seconds': durationSeconds,
      };

  factory ManifestRunResult.fromJson(Map<String, dynamic> json) =>
      ManifestRunResult(
        success: json['success'] as bool,
        totalIterations: json['total_iterations'] as int,
        durationSeconds: (json['duration_seconds'] as num).toDouble(),
      );
}

/// Run-level aggregate fidelity metrics (manifest v2+).
///
/// Produced by [FidelityCalculator] over the manifest's hooked symbols
/// + the run's executed symbols + the project call graph, then folded
/// into the manifest via [SynthesisManifest.withMetrics] before
/// persistence. The closed-loop LLM orchestrator reads these directly
/// instead of recomputing each round.
class ManifestMetrics {
  const ManifestMetrics({
    required this.overallFidelity,
    required this.coverageFidelity,
    required this.subgraphFidelity,
    required this.intactCount,
    required this.degradedCount,
    required this.hookedCount,
  });

  /// Overall weighted fidelity across the whole call graph. 0–1.
  final double overallFidelity;

  /// Fidelity averaged over only the functions traversed during this
  /// run. Null if no traversal data was captured.
  final double? coverageFidelity;

  /// Fidelity averaged over only functions on paths between the
  /// project's configured start/stop symbols. Null if start/stop are
  /// not set on the project.
  final double? subgraphFidelity;

  /// Functions whose fidelity stayed at 1.0 after propagation.
  final int intactCount;

  /// Functions transitively affected (0.0 < fidelity < 1.0).
  final int degradedCount;

  /// Functions directly hooked (fidelity forced to efficacy, default 0.0).
  final int hookedCount;

  Map<String, dynamic> toJson() => {
        'overall_fidelity': overallFidelity,
        if (coverageFidelity != null) 'coverage_fidelity': coverageFidelity,
        if (subgraphFidelity != null) 'subgraph_fidelity': subgraphFidelity,
        'intact_count': intactCount,
        'degraded_count': degradedCount,
        'hooked_count': hookedCount,
      };

  factory ManifestMetrics.fromJson(Map<String, dynamic> json) =>
      ManifestMetrics(
        overallFidelity: (json['overall_fidelity'] as num).toDouble(),
        coverageFidelity: (json['coverage_fidelity'] as num?)?.toDouble(),
        subgraphFidelity: (json['subgraph_fidelity'] as num?)?.toDouble(),
        intactCount: json['intact_count'] as int,
        degradedCount: json['degraded_count'] as int,
        hookedCount: json['hooked_count'] as int,
      );
}

/// Per-iteration wall-clock timing (manifest v2+). Optional; null
/// list means the caller chose not to capture per-iteration timing
/// for this run.
class IterationTiming {
  const IterationTiming({
    required this.iterationIndex,
    required this.wallClockSeconds,
  });

  final int iterationIndex;
  final double wallClockSeconds;

  Map<String, dynamic> toJson() => {
        'iteration_index': iterationIndex,
        'wall_clock_seconds': wallClockSeconds,
      };

  factory IterationTiming.fromJson(Map<String, dynamic> json) =>
      IterationTiming(
        iterationIndex: json['iteration_index'] as int,
        wallClockSeconds:
            (json['wall_clock_seconds'] as num).toDouble(),
      );
}

/// One decision made by the synthesizer for one symbol during one run.
///
/// The fields shadow [HookDecision] plus runtime-only data
/// (iteration index, prior failed attempts, LLM telemetry). The
/// pre-synthesis report shows what *will* happen; this records what
/// *did* happen.
class ManifestDecision {
  const ManifestDecision({
    required this.symbol,
    required this.appliedHook,
    required this.decisionKind,
    required this.decisionSource,
    this.fidelityAtDecision,
    this.iterationIndex,
    this.previousAttempts,
    this.llmInvocation,
    this.autoTuneRound,
  });

  final String symbol;
  final AppliedHook appliedHook;
  final ManifestDecisionKind decisionKind;

  /// Provenance string capturing *why* this decision was made.
  /// Examples: `user.hookOverrides`, `comms:i2c_read`,
  /// `warm_start`, `classifier:rule-3-counter-global`,
  /// `llm:gemma4:e4b`, `default_template:return_0`.
  final String decisionSource;

  /// The fidelity value used at the moment of selection. Set for
  /// binding-driven decisions (where the binding's fidelity is the
  /// sort key) and for iteration-fallback decisions (where the
  /// artifact's intrinsic score is the sort key). Null for
  /// override / comms / warm-start where fidelity doesn't apply.
  final double? fidelityAtDecision;

  /// 0-based iteration loop index for iteration-fallback and
  /// llm-on-demand decisions. Null for pre-seeded decisions
  /// (override / comms / warm-start) — those happen before the
  /// loop starts.
  final int? iterationIndex;

  /// Earlier artifacts tried for this symbol before the applied
  /// hook stuck. Empty/null when the first try worked.
  final List<PreviousAttempt>? previousAttempts;

  /// LLM telemetry for `llm_on_demand` decisions; null otherwise.
  final LlmInvocation? llmInvocation;

  /// When this decision was driven by an overlay change the
  /// closed-loop LLM orchestrator wrote during a specific auto-tune
  /// round, the round index lands here. Null for decisions outside
  /// auto-tune sessions or for the baseline (round 0) run.
  final int? autoTuneRound;

  Map<String, dynamic> toJson() => {
        'symbol': symbol,
        'applied_hook': appliedHook.toJson(),
        'decision_kind': decisionKind.jsonName,
        'decision_source': decisionSource,
        if (fidelityAtDecision != null)
          'fidelity_at_decision': fidelityAtDecision,
        if (iterationIndex != null) 'iteration_index': iterationIndex,
        if (previousAttempts != null && previousAttempts!.isNotEmpty)
          'previous_attempts':
              previousAttempts!.map((p) => p.toJson()).toList(),
        if (llmInvocation != null) 'llm_invocation': llmInvocation!.toJson(),
        if (autoTuneRound != null) 'auto_tune_round': autoTuneRound,
      };

  factory ManifestDecision.fromJson(Map<String, dynamic> json) =>
      ManifestDecision(
        symbol: json['symbol'] as String,
        appliedHook: AppliedHook.fromJson(
            json['applied_hook'] as Map<String, dynamic>),
        decisionKind: ManifestDecisionKind.fromJson(
            json['decision_kind'] as String),
        decisionSource: json['decision_source'] as String,
        fidelityAtDecision:
            (json['fidelity_at_decision'] as num?)?.toDouble(),
        iterationIndex: json['iteration_index'] as int?,
        previousAttempts: (json['previous_attempts'] as List<dynamic>?)
            ?.map((e) => PreviousAttempt.fromJson(e as Map<String, dynamic>))
            .toList(),
        llmInvocation: json['llm_invocation'] == null
            ? null
            : LlmInvocation.fromJson(
                json['llm_invocation'] as Map<String, dynamic>),
        autoTuneRound: json['auto_tune_round'] as int?,
      );
}

/// The hook that was actually applied to a symbol, identified by a
/// SHA-256 of the code body so a future manifest reader can verify
/// the body hasn't drifted, plus the [artifactId] when the hook
/// came from a DB row.
///
/// [artifactId] is nullable because comms hooks are catalog-built
/// at synthesis time (no DB row), and warm-start hooks carry just
/// the code without a back-reference to the artifact the prior run
/// used. The [bodyHash] is the content-addressed identifier that
/// always works.
class AppliedHook {
  const AppliedHook({
    required this.bodyHash,
    this.artifactId,
    this.scope,
  });

  final int? artifactId;
  final String bodyHash;
  final String? scope;

  /// Compute the SHA-256 of [body] as a hex string. Same hash used
  /// by [ArtifactLibraryService.hashElfFile] for ELF files — the
  /// manifest stays consistent with the rest of the project's
  /// content-addressed identifiers.
  static String hashBody(String body) =>
      sha256.convert(utf8.encode(body)).toString();

  Map<String, dynamic> toJson() => {
        if (artifactId != null) 'artifact_id': artifactId,
        'body_hash': bodyHash,
        if (scope != null) 'scope': scope,
      };

  factory AppliedHook.fromJson(Map<String, dynamic> json) => AppliedHook(
        artifactId: json['artifact_id'] as int?,
        bodyHash: json['body_hash'] as String,
        scope: json['scope'] as String?,
      );
}

/// One artifact that was tried for a symbol and rejected before the
/// applied hook stuck. Useful for "why did we end up with the no-op"
/// post-mortems on iteration-fallback decisions.
class PreviousAttempt {
  const PreviousAttempt({
    required this.artifactId,
    required this.outcome,
  });

  final int artifactId;

  /// Free-form short label for why this artifact didn't survive.
  /// Today's values: `unhandled_access_repeat`. Stays open-ended so
  /// new failure modes (timeout, crash, gate-fail) can be added
  /// without a schema bump.
  final String outcome;

  Map<String, dynamic> toJson() => {
        'artifact_id': artifactId,
        'outcome': outcome,
      };

  factory PreviousAttempt.fromJson(Map<String, dynamic> json) =>
      PreviousAttempt(
        artifactId: json['artifact_id'] as int,
        outcome: json['outcome'] as String,
      );
}

/// LLM telemetry attached to `llm_on_demand` decisions — captures
/// which model produced the hook plus token counts so a future
/// audit can sanity-check generation budgets.
class LlmInvocation {
  const LlmInvocation({
    required this.model,
    this.promptTokens,
    this.completionTokens,
    this.thinkingTokens,
  });

  final String model;
  final int? promptTokens;
  final int? completionTokens;
  final int? thinkingTokens;

  Map<String, dynamic> toJson() => {
        'model': model,
        if (promptTokens != null) 'prompt_tokens': promptTokens,
        if (completionTokens != null) 'completion_tokens': completionTokens,
        if (thinkingTokens != null) 'thinking_tokens': thinkingTokens,
      };

  factory LlmInvocation.fromJson(Map<String, dynamic> json) => LlmInvocation(
        model: json['model'] as String,
        promptTokens: json['prompt_tokens'] as int?,
        completionTokens: json['completion_tokens'] as int?,
        thinkingTokens: json['thinking_tokens'] as int?,
      );
}

/// How the synthesizer arrived at the applied hook for a symbol —
/// mirrors the project-level overlay priority order plus the two
/// runtime-only kinds (iteration fallback and on-demand LLM).
enum ManifestDecisionKind {
  /// User's forced override (`Emulator.hookOverrides`); pre-seeded.
  forcedOverride('forced_override'),

  /// Comms-bus hook from `Emulator.commsAssignments` +
  /// `CommsProtocolConfig.virtualized`; pre-seeded.
  comms('comms'),

  /// Warm-start body from `Emulator.hooks` (previous run's result);
  /// pre-seeded.
  warmStart('warm_start'),

  /// Per-symbol [HookBinding] drove the iteration sort and the first
  /// candidate it picked survived.
  binding('binding'),

  /// No binding (or the binding failed); the synthesizer's
  /// iteration loop fell through to an artifact selected by
  /// intrinsic-score sort.
  iterationFallback('iteration_fallback'),

  /// All DB candidates exhausted; the LLM generated a fresh hook
  /// at synthesis time. See [LlmInvocation] on the same decision
  /// for token telemetry.
  llmOnDemand('llm_on_demand');

  const ManifestDecisionKind(this.jsonName);

  /// Stable wire-format identifier — the value that round-trips
  /// through the JSON `decision_kind` field. Decoupled from the
  /// Dart enum's `name` so renaming the Dart identifier doesn't
  /// silently break existing manifest files.
  final String jsonName;

  static ManifestDecisionKind fromJson(String name) {
    for (final v in ManifestDecisionKind.values) {
      if (v.jsonName == name) return v;
    }
    throw FormatException('Unknown ManifestDecisionKind: $name');
  }
}
