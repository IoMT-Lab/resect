import 'dart:async';
import 'dart:io';

import '../data/database/artifact_database.dart';
import '../data/models/auto_tune_config.dart';
import '../data/models/call_graph.dart';
import '../data/models/comms_assignment.dart';
import '../data/models/emulator.dart';
import '../data/models/hook_binding.dart';
import '../data/models/hook_decision_state.dart';
import '../data/models/recommendation.dart';
import '../data/models/round_snapshot.dart';
import '../data/models/symbol_group.dart';
import '../data/models/synthesis_manifest.dart';
import '../data/models/synthesizer_result.dart';
import '../services/analysis/coverage_frontier.dart';
import '../services/analysis/fidelity_calculator.dart';
import '../services/llm/llm_client.dart';
import '../services/llm/llm_hook_generator.dart';
import '../services/llm/recommendation_service.dart';
import 'auto_tune_progress.dart';
import 'recommendation_overlay_applier.dart';

/// UI-agnostic driver for the closed-loop auto-tune process.
///
/// This is the single implementation of the loop `runAutoTune` used
/// to own inside the Flutter UI: baseline synthesis → per round
/// { recommend → review → apply (overlays + authored hooks) →
/// re-synthesize → snapshot → termination checks }. Both the UI
/// orchestrator and the headless CLI drive this same engine; they
/// differ only in the three things injected here — how synthesis is
/// invoked ([RunSynthesis]), how recommendations are reviewed
/// ([AutoTuneReviewPolicy]), and where progress/results go
/// ([AutoTuneSink]). Nothing UI-specific (Riverpod, ChangeNotifier,
/// Completers) lives in here, so the CLI is a faithful validation of
/// the exact process the UI runs.
///
/// The engine owns the mutable overlay maps ([AutoTuneOverlays]), the
/// round counter, the prior-round failure (for the no-progress guard),
/// and the in-memory snapshot history it feeds back to the
/// recommendation model. It never reads a provider or touches disk;
/// persistence is the sink's job.
class AutoTuneEngine {
  AutoTuneEngine({
    required this.runSynthesis,
    required this.recommendationService,
    required this.artifactDb,
    required this.reviewPolicy,
    required this.sink,
    this.hookGenerator,
    this.symbolGroups = const [],
    this.now = DateTime.now,
  });

  /// Runs one synthesis with the engine's current overlays and returns
  /// the result. The returned [SynthesizerResult] MUST carry an
  /// enriched manifest (metrics + executedSymbols folded in via
  /// [enrichSynthesizerResult] / [SynthesisManifest.withMetrics]) —
  /// the engine reads `manifest.metrics` and `manifest.executedSymbols`
  /// directly rather than recomputing. Returns null on a synthesis
  /// error (the engine finishes with `synthesisError` /
  /// `baselineFailed`). The `round` argument is the loop round the run
  /// belongs to (0 = baseline), for adapter-side labelling/logging.
  final RunSynthesis runSynthesis;

  final RecommendationService recommendationService;
  final ArtifactDatabase artifactDb;

  /// Decides what to do with each round's recommendations (accept all
  /// for the CLI; pause for user Accept/Reject/Edit in the UI) and
  /// whether to retry after a parse failure.
  final AutoTuneReviewPolicy reviewPolicy;

  /// Receives every progress transition, the per-round LLM exchange
  /// (for trace files), the structured per-round report, and the
  /// terminal reason. The UI maps these to modal state + snapshot
  /// persistence; the CLI writes report files.
  final AutoTuneSink sink;

  /// Authors bodies for accepted `generate_custom_hook` recommendations.
  /// Required only if a session might accept one; when null and such a
  /// recommendation is accepted, the round finishes with `llmError`.
  final LlmHookGenerator? hookGenerator;

  /// Recognized object groups for this firmware (from `SymbolGroupClassifier`).
  /// Surfaced to the recommendation LLM so it can act on a whole peripheral,
  /// and passed to synthesis via the `runSynthesis` closure by the caller.
  final List<SymbolGroup> symbolGroups;

  /// Clock seam. Real `DateTime.now` in production; a fixed stamp in
  /// tests so snapshots are deterministic.
  final DateTime Function() now;

  var _cancelled = false;

  /// Request cancellation. The loop drops out at its next checkpoint
  /// with an `AutoTuneStopReason.cancelled` finish. The review policy
  /// is responsible for unblocking any pending review it is awaiting.
  void cancel() => _cancelled = true;

  /// Run a complete auto-tune session against [project].
  ///
  /// [elfHash] and [callGraph] describe the firmware under test.
  /// [commsConfigs] mirrors the UI's comms-protocol configuration so
  /// the recommendation prompt's decision projection matches
  /// (defaults to empty — headless runs without comms virtualization).
  /// [seedBaseline], when non-null, is an already-computed baseline
  /// result used in place of a round-0 synthesis (the UI passes the
  /// project's fresh synthesis result to avoid re-running it; the CLI
  /// passes null to always synthesize a clean baseline).
  ///
  /// Returns the terminal [AutoTuneStopReason]; [sink.finished] is
  /// also invoked with it.
  Future<AutoTuneStopReason> run({
    required Emulator project,
    required String elfHash,
    required CallGraph callGraph,
    AutoTuneConfig config = const AutoTuneConfig(),
    Map<CommsClass, CommsProtocolStatus> commsConfigs = const {},
    SynthesizerResult? seedBaseline,
    int iterationCap = 10,
  }) async {
    _cancelled = false;
    final overlays =
        AutoTuneOverlays.fromEmulator(project, iterationCap: iterationCap);
    final history = <RoundSnapshot>[];

    ({String symbol, Set<int> tried})? failureOf(SynthesizerResult? r) {
      final m = r?.manifest;
      final failed = m?.failedSymbol;
      if (m == null || failed == null) return null;
      return (symbol: failed, tried: triedArtifactsForFailedSymbol(m));
    }

    // The PREVIOUS round's failure (symbol + artifact ids tried for it).
    // Threaded across iterations so the no-progress guard distinguishes
    // a true repeat from legitimate exploration. Carried from each
    // round's own result — never from a live shared value (the original
    // self-comparison bug).
    ({String symbol, Set<int> tried})? prevFailure;

    // Coverage-stagnation state. `prevExecuted` is the last completed
    // run's executed-symbol set; a successful round that reproduces it
    // exactly is stagnant — the loop escalates via [RoundFeedback]
    // (wrapper-skip framing) once, then stops at
    // `config.stagnantRoundLimit` consecutive stagnant rounds with
    // `noCoverageProgress` instead of churning identical evidence to
    // maxRounds.
    Set<String>? prevExecuted;
    var stagnantRounds = 0;
    RoundFeedback? pendingFeedback;

    // Build the escalation feedback for the next round: coverage
    // freeze + the executed frontier callers (where an inlined spin is
    // likely) + whatever was skipped as a no-op this round. Excluded
    // from the wrapper-skip candidates:
    //   - entry points ("force main to return 0" ends the firmware);
    //   - symbols ALREADY forced (a skipped body cannot spin — without
    //     this, the frontier's callee-count ordering kept nominating
    //     the big wrappers we had already skipped while the real
    //     suspect sat lower in the list);
    //   - comms-virtualized symbols (already covered as a bus).
    const entryPoints = {'main', 'Reset_Handler', '_start'};
    final commsCovered = <String>{
      for (final e in project.commsAssignments.entries)
        if (e.value.protocol != CommsClass.unclassified &&
            (commsConfigs[e.value.protocol]?.virtualized ?? false))
          e.key,
    };
    RoundFeedback buildFeedback({
      required SynthesisManifest manifest,
      required List<Recommendation> noOpSkipped,
    }) {
      final executed = manifest.executedSymbols?.toSet() ?? const <String>{};
      final frontier = computeFrontier(
        executedSymbols: executed,
        callGraph: callGraph,
      );
      return RoundFeedback(
        coveragePrev: prevExecuted?.length ?? executed.length,
        coverageNow: executed.length,
        stalledCallers: [
          for (final e in frontier)
            if (!entryPoints.contains(e.symbol) &&
                !overlays.hookOverrides.containsKey(e.symbol) &&
                !commsCovered.contains(e.symbol))
              e.symbol,
        ].take(8).toList(),
        noOpSkipped: noOpSkipped,
      );
    }

    // Round 0: baseline.
    if (seedBaseline != null) {
      prevFailure = failureOf(seedBaseline);
      prevExecuted = seedBaseline.manifest?.executedSymbols?.toSet();
    } else {
      sink.phase(AutoTunePhase.baseline);
      final baseline = await runSynthesis(overlays, 0);
      if (_cancelled) return _finish(AutoTuneStopReason.cancelled, 0);
      if (baseline == null || baseline.manifest == null) {
        return _finish(AutoTuneStopReason.baselineFailed, 0,
            errorMessage: 'Synthesis returned no manifest.');
      }
      _emitRound(
        round: 0,
        result: baseline,
        overlays: overlays,
        history: history,
      );
      prevFailure = failureOf(baseline);
      prevExecuted = baseline.manifest!.executedSymbols?.toSet();
    }

    // Rounds 1..maxRounds.
    var round = 1;
    while (round <= config.maxRounds) {
      if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round - 1);

      // The manifest to reason about is the most recent round's.
      final lastManifest = history.isEmpty
          ? seedBaseline?.manifest
          : _lastResult?.manifest;
      if (lastManifest == null) {
        return _finish(AutoTuneStopReason.llmError, round - 1,
            errorMessage: 'No manifest available to recommend against.');
      }

      // Ask the LLM for recommendations.
      final llmResult = await _askLlm(
        round: round,
        project: project,
        elfHash: elfHash,
        callGraph: callGraph,
        commsConfigs: commsConfigs,
        overlays: overlays,
        manifest: lastManifest,
        history: history,
        config: config,
        feedback: pendingFeedback,
      );
      pendingFeedback = null;
      if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round - 1);
      if (llmResult == null) {
        // _askLlm already emitted the exchange + finished(llmError).
        return AutoTuneStopReason.llmError;
      }

      // Parse failure → policy decides retry vs stop.
      if (llmResult.parseFailure) {
        final retry = await reviewPolicy.onParseFailure(llmResult, round);
        if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round - 1);
        if (retry) continue;
        return _finish(AutoTuneStopReason.parseFailed, round);
      }

      // Empty recommendations → success termination.
      if (llmResult.recommendations.isEmpty) {
        return _finish(AutoTuneStopReason.llmEmpty, round - 1);
      }

      // Review.
      final review = await reviewPolicy.review(llmResult, round);
      if (_cancelled || review.cancelled) {
        return _finish(AutoTuneStopReason.cancelled, round - 1);
      }
      if (review.userStopped) {
        return _finish(AutoTuneStopReason.userStopped, round - 1);
      }
      final acceptedOrEdited = review.decisions
          .where((d) => d.action != UserAction.rejected)
          .map((d) => d.applied!)
          .toList();
      if (acceptedOrEdited.isEmpty) {
        return _finish(AutoTuneStopReason.userRejectedAll, round - 1);
      }

      // Drop recommendations already in effect (same override/
      // preference, or the same artifact the last run applied
      // reactively). Re-applying one burns a full synthesis round on
      // an identical run — the observed 6-round flatline was exactly
      // this. Skipped entries surface in the round report and in the
      // next round's feedback so the model is told not to repeat them.
      final filtered = filterNoOpRecommendations(
        recommendations: acceptedOrEdited,
        hookOverrides: overlays.hookOverrides,
        hookOverrideScopes: overlays.hookOverrideScopes,
        hookPreferences: overlays.hookPreferences,
        lastManifest: lastManifest,
      );
      final effective = filtered.kept;
      final skippedNoOps = filtered.skipped;

      if (effective.isEmpty) {
        // Nothing would change — re-synthesizing produces an
        // identical run, so don't. Count the round as stagnant,
        // escalate via feedback, and let the limit stop a session
        // that only re-recommends what's already in place. No round
        // report is emitted (there's no new manifest/runId to report).
        stagnantRounds++;
        if (stagnantRounds >= config.stagnantRoundLimit) {
          return _finish(AutoTuneStopReason.noCoverageProgress, round,
              errorMessage:
                  'Round $round: every recommendation was already in '
                  'effect and coverage is frozen.');
        }
        pendingFeedback = buildFeedback(
          manifest: lastManifest,
          noOpSkipped: skippedNoOps,
        );
        round++;
        continue;
      }

      // Author + seed any accepted generate_custom_hook recs BEFORE the
      // overlay applier runs (the applier drops that kind by design).
      // Defense-in-depth: only author for a real call-graph symbol — a
      // rec naming a non-symbol (e.g. a leaked sentinel) is dropped here
      // rather than seeding a bogus artifact + binding.
      final generateRecs = <GenerateCustomHook>[];
      for (final r in effective.whereType<GenerateCustomHook>()) {
        if (callGraph.symbols.containsKey(r.symbol)) {
          generateRecs.add(r);
        } else {
          stderr.writeln('[auto-tune] dropping generate_custom_hook for '
              'non-call-graph symbol "${r.symbol}"');
        }
      }
      if (generateRecs.isNotEmpty) {
        final err = await _generateAndSeedCustomHooks(
          generateRecs,
          round: round,
          elfHash: elfHash,
          overlays: overlays,
        );
        if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round - 1);
        if (err != null) {
          return _finish(AutoTuneStopReason.llmError, round,
              errorMessage: err);
        }
      }

      // Apply the reviewed overlay edits into the engine's overlays.
      overlays.apply(effective);

      // Re-synthesize with the new overlays. Display round+1 — the user
      // just applied round N's recs, so the run now starting is round
      // N+1's input.
      sink.phase(AutoTunePhase.synthesizing, round: round + 1);
      final runResult = await runSynthesis(overlays, round);
      if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round);
      if (runResult == null || runResult.manifest == null) {
        return _finish(AutoTuneStopReason.synthesisError, round,
            errorMessage: 'Synthesis returned no manifest.');
      }

      // Emit this round's report (+ append to history for the next
      // recommend call).
      _emitRound(
        round: round,
        result: runResult,
        overlays: overlays,
        history: history,
        recommendation: llmResult,
        decisions: review.decisions,
        applied: effective,
        skippedNoOps: skippedNoOps,
      );

      // No-progress guard: stop only on a TRUE repeat — same failing
      // symbol as the prior round AND no new hook tried for it.
      final currentFailed = runResult.manifest!.failedSymbol;
      final currentTried = triedArtifactsForFailedSymbol(runResult.manifest!);
      if (isNoProgress(
        currentFailed: currentFailed,
        prevFailed: prevFailure?.symbol,
        currentTried: currentTried,
        prevTried: prevFailure?.tried ?? const {},
      )) {
        return _finish(AutoTuneStopReason.noProgressOnSymbol, round);
      }
      prevFailure = currentFailed == null
          ? null
          : (symbol: currentFailed, tried: currentTried);

      // Coverage-stagnation guard: a successful round that reproduced
      // the previous executed set exactly means the applied changes did
      // nothing observable. Escalate once (wrapper-skip feedback), stop
      // at the configured limit; any coverage movement resets the
      // counter.
      final currentExecuted = runResult.manifest!.executedSymbols?.toSet();
      if (isCoverageStagnant(
        prevExecuted: prevExecuted,
        currentExecuted: currentExecuted,
        currentFailedSymbol: currentFailed,
      )) {
        stagnantRounds++;
        if (stagnantRounds >= config.stagnantRoundLimit) {
          return _finish(AutoTuneStopReason.noCoverageProgress, round,
              errorMessage:
                  'Coverage frozen at ${currentExecuted?.length ?? 0} '
                  'executed symbols for $stagnantRounds rounds '
                  '(escalation tried).');
        }
        pendingFeedback = buildFeedback(
          manifest: runResult.manifest!,
          noOpSkipped: skippedNoOps,
        );
      } else {
        stagnantRounds = 0;
      }
      prevExecuted = currentExecuted ?? prevExecuted;

      round++;
    }
    return _finish(AutoTuneStopReason.maxRounds, config.maxRounds);
  }

  // -- Internals -------------------------------------------------------------

  /// The most recent synthesis result emitted to a round report. Used
  /// as the manifest source for the next round's recommend call.
  SynthesizerResult? _lastResult;

  AutoTuneStopReason _finish(
    AutoTuneStopReason reason,
    int finalRound, {
    String? errorMessage,
  }) {
    sink.finished(reason, finalRound: finalRound, errorMessage: errorMessage);
    return reason;
  }

  /// Ask the recommendation model for the round's edits, streaming
  /// thinking/response tokens to the sink and emitting the full LLM
  /// exchange (for trace files) whether it succeeds or throws.
  Future<RecommendationResult?> _askLlm({
    required int round,
    required Emulator project,
    required String elfHash,
    required CallGraph callGraph,
    required Map<CommsClass, CommsProtocolStatus> commsConfigs,
    required AutoTuneOverlays overlays,
    required SynthesisManifest manifest,
    required List<RoundSnapshot> history,
    required AutoTuneConfig config,
    RoundFeedback? feedback,
  }) async {
    sink.phase(AutoTunePhase.llmGenerating, round: round);
    final state = buildHookDecisionState(
      emulator: overlays.applyTo(project),
      elfHash: elfHash,
      commsConfigs: commsConfigs,
    );
    final executed = manifest.executedSymbols?.toSet() ?? <String>{};
    final frontier =
        computeFrontier(executedSymbols: executed, callGraph: callGraph);
    final windowed = history
        .take(config.snapshotWindowSize.clamp(1, 100))
        .toList(growable: false);

    final thinkingBuf = StringBuffer();
    final responseBuf = StringBuffer();
    String? composedPrompt;
    try {
      final result = await recommendationService.recommend(
        currentManifest: manifest,
        currentState: state,
        callGraph: callGraph,
        history: windowed,
        optimizationTarget: config.optimizationTarget,
        frontier: frontier,
        feedback: feedback,
        maxRecommendations: config.maxRecommendationsPerRound,
        symbolGroups: symbolGroups,
        groupOverrides: overlays.groupOverrides,
        onPromptComposed: (p) => composedPrompt = p,
        onToken: (tok) {
          responseBuf.write(tok);
          sink.token(tok);
        },
        onThinking: (chunk) {
          thinkingBuf.write(chunk);
          sink.thinking(chunk);
        },
      );
      sink.llmExchange(AutoTuneLlmExchange(
        round: round,
        model: result.model,
        prompt: composedPrompt ?? '(prompt not captured)',
        thinking: thinkingBuf.toString(),
        response: responseBuf.toString(),
        result: result,
      ));
      return result;
    } catch (e) {
      sink.llmExchange(AutoTuneLlmExchange(
        round: round,
        model: null,
        prompt: composedPrompt ?? '(prompt not captured)',
        thinking: thinkingBuf.toString(),
        response: responseBuf.toString(),
        result: null,
        errorMessage: e.toString(),
      ));
      _finish(AutoTuneStopReason.llmError, round - 1,
          errorMessage: e.toString());
      return null;
    }
  }

  /// Author each accepted [GenerateCustomHook] via [hookGenerator],
  /// persist the body as a user-origin artifact, and seed a binding
  /// into [overlays] so the next synthesis picks it up. Returns null on
  /// success or an error message string on failure (missing generator,
  /// generation error, empty body).
  Future<String?> _generateAndSeedCustomHooks(
    List<GenerateCustomHook> recs, {
    required int round,
    required String elfHash,
    required AutoTuneOverlays overlays,
  }) async {
    final generator = hookGenerator;
    if (generator == null) {
      return 'LlmHookGenerator unavailable; cannot author custom hooks.';
    }
    for (final rec in recs) {
      if (_cancelled) return null;
      sink.phase(AutoTunePhase.generatingHook,
          round: round + 1, symbol: rec.symbol);
      final responseBuf = StringBuffer();
      try {
        await for (final ev in generator.generateEvents(
          userPrompt: rec.intent ?? _defaultHookIntent(rec.symbol),
          targetSymbol: rec.symbol,
          elfHash: elfHash,
        )) {
          switch (ev) {
            case LlmThinkingChunk(:final text):
              sink.thinking(text);
            case LlmResponseChunk(:final text):
              responseBuf.write(text);
              sink.token(text);
            case LlmStreamDone():
              break;
          }
        }
      } catch (e) {
        return 'Hook generation failed for ${rec.symbol}: $e';
      }
      final body = responseBuf.toString().trim();
      if (body.isEmpty) {
        return 'Hook generation produced no output for ${rec.symbol}.';
      }
      final newId = await artifactDb.addArtifact(
        artifactType: 'renode_hook',
        artifactData: body,
        origin: 'user',
        name: 'llm:auto-tune-r$round:${rec.symbol}',
        architecture: 'ARM',
        targetSymbolName: rec.symbol,
        intrinsicScore: 0.5,
      );
      overlays.hookBindings[rec.symbol] = HookBinding(
        artifactId: newId,
        fidelity: 0.5,
        provenance: 'llm:auto-tune-r$round',
        createdAt: now(),
      );
    }
    return null;
  }

  /// Build the round's [RoundSnapshot] + [AutoTuneRoundReport], append
  /// the snapshot to [history], remember the result for the next
  /// recommend, and hand the report to the sink.
  void _emitRound({
    required int round,
    required SynthesizerResult result,
    required AutoTuneOverlays overlays,
    required List<RoundSnapshot> history,
    RecommendationResult? recommendation,
    List<RecommendationDecision> decisions = const [],
    List<Recommendation> applied = const [],
    List<Recommendation> skippedNoOps = const [],
  }) {
    final manifest = result.manifest!;
    final metrics = manifest.metrics ?? _fallbackMetrics(manifest);
    final executed = manifest.executedSymbols ?? const <String>[];
    final snapshot = RoundSnapshot(
      snapshotVersion: RoundSnapshot.currentVersion,
      round: round,
      synthesizerRunId: manifest.synthesizerRunId,
      createdAt: now(),
      hookOverrides: Map<String, int>.from(overlays.hookOverrides),
      hookOverrideScopes: Map<String, String>.from(overlays.hookOverrideScopes),
      hookPreferences: Map<String, int>.from(overlays.hookPreferences),
      hookBindings: Map<String, HookBinding>.from(overlays.hookBindings),
      groupOverrides:
          Map<String, GroupOverrideState>.from(overlays.groupOverrides),
      iterationCap: overlays.iterationCap,
      metrics: metrics,
      executedSymbols: executed,
      manifestRef: SynthesisManifestRef(runId: manifest.synthesizerRunId),
      llmRecommendations: recommendation?.recommendations,
      userDecisions: decisions.isEmpty ? null : decisions,
      llmProse: recommendation?.prose,
    );
    history.add(snapshot);
    _lastResult = result;
    sink.round(AutoTuneRoundReport(
      round: round,
      result: result,
      metrics: metrics,
      snapshot: snapshot,
      recommendation: recommendation,
      decisions: decisions,
      appliedRecommendations: applied,
      skippedNoOps: skippedNoOps,
    ));
  }

  /// Metrics fallback when an adapter returned an un-enriched manifest.
  /// Both production adapters enrich before returning, so this is
  /// belt-and-suspenders; without a call graph here we can only report
  /// hooked counts from the decisions.
  ManifestMetrics _fallbackMetrics(SynthesisManifest manifest) => ManifestMetrics(
        overallFidelity: 0,
        coverageFidelity: null,
        subgraphFidelity: null,
        intactCount: 0,
        degradedCount: 0,
        hookedCount: manifest.decisions.map((d) => d.symbol).toSet().length,
      );

  static String _defaultHookIntent(String symbol) =>
      'Author a Renode hook for the firmware function `$symbol`. '
      "Its existing template-based hook didn't progress the "
      'firmware past this symbol; design a behavior (returning a '
      'sentinel value, toggling a status bit, etc.) that lets '
      'execution continue.';
}

/// Runs a synthesis with the engine's current [overlays] for loop
/// [round] (0 = baseline). See [AutoTuneEngine.runSynthesis].
typedef RunSynthesis = Future<SynthesizerResult?> Function(
    AutoTuneOverlays overlays, int round);

/// Mutable overlay set the engine threads through a session: forced
/// overrides + their scopes, soft preferences, fidelity-scored
/// bindings, and the synthesizer iteration cap. Seeded from the
/// project's persisted overlays; mutated in place as recommendations
/// are applied and custom hooks authored.
class AutoTuneOverlays {
  AutoTuneOverlays({
    required this.hookOverrides,
    required this.hookOverrideScopes,
    required this.hookPreferences,
    required this.hookBindings,
    required this.groupOverrides,
    required this.iterationCap,
  });

  factory AutoTuneOverlays.fromEmulator(Emulator e, {int iterationCap = 10}) =>
      AutoTuneOverlays(
        hookOverrides: Map<String, int>.from(e.hookOverrides),
        hookOverrideScopes: Map<String, String>.from(e.hookOverrideScopes),
        hookPreferences: Map<String, int>.from(e.hookPreferences),
        hookBindings: Map<String, HookBinding>.from(e.hookBindings),
        groupOverrides:
            Map<String, GroupOverrideState>.from(e.groupOverrides),
        iterationCap: iterationCap,
      );

  final Map<String, int> hookOverrides;
  final Map<String, String> hookOverrideScopes;
  final Map<String, int> hookPreferences;
  final Map<String, HookBinding> hookBindings;
  final Map<String, GroupOverrideState> groupOverrides;
  int iterationCap;

  /// Apply a reviewed batch of recommendations to these maps in place,
  /// via the shared applier core (same source of truth as the UI's
  /// `RecommendationApplier`). `generate_custom_hook` entries are
  /// assumed already authored + seeded into [hookBindings]; the applier
  /// drops them.
  void apply(List<Recommendation> recommendations) {
    final result = applyRecommendationsToOverlays(
      recommendations: recommendations,
      hookOverrides: hookOverrides,
      hookOverrideScopes: hookOverrideScopes,
      hookPreferences: hookPreferences,
      groupOverrides: groupOverrides,
      iterationCap: iterationCap,
    );
    iterationCap = result.iterationCap;
  }

  /// Project [base] with these overlays layered on, for building a
  /// [HookDecisionState] or feeding the synthesis invocation.
  Emulator applyTo(Emulator base) => base.copyWith(
        hookOverrides: hookOverrides,
        hookOverrideScopes: hookOverrideScopes,
        hookPreferences: hookPreferences,
        hookBindings: hookBindings,
        groupOverrides: groupOverrides,
      );
}

/// Decides how each round's recommendations are handled. The UI's
/// policy pauses for user Accept/Reject/Edit; the CLI's
/// [AcceptAllReviewPolicy] takes every recommendation as accepted.
abstract class AutoTuneReviewPolicy {
  /// Review the round's [result]. Return the per-recommendation
  /// decisions plus stop/cancel signals.
  Future<AutoTuneReviewOutcome> review(RecommendationResult result, int round);

  /// The recommendation call failed to parse. Return true to retry the
  /// round, false to stop (finishing with `parseFailed`).
  Future<bool> onParseFailure(RecommendationResult result, int round);
}

/// Outcome of a review step.
class AutoTuneReviewOutcome {
  const AutoTuneReviewOutcome({
    required this.decisions,
    this.userStopped = false,
    this.cancelled = false,
  });

  final List<RecommendationDecision> decisions;
  final bool userStopped;
  final bool cancelled;
}

/// Non-interactive policy for headless runs (the CLI): accept every
/// recommendation as-is and never retry a parse failure.
class AcceptAllReviewPolicy implements AutoTuneReviewPolicy {
  const AcceptAllReviewPolicy();

  @override
  Future<AutoTuneReviewOutcome> review(
          RecommendationResult result, int round) async =>
      AutoTuneReviewOutcome(
        decisions: [
          for (final rec in result.recommendations)
            RecommendationDecision(original: rec, action: UserAction.accepted),
        ],
      );

  @override
  Future<bool> onParseFailure(RecommendationResult result, int round) async =>
      false;
}

/// Progress + result stream from the engine. Every method is a
/// notification; none block the loop.
abstract class AutoTuneSink {
  /// A phase transition. [round] is the loop round (0 for baseline);
  /// [symbol] is set only for [AutoTunePhase.generatingHook].
  void phase(AutoTunePhase phase, {int round, String? symbol});

  /// A streamed reasoning ("thinking") chunk from the current phase's
  /// LLM call.
  void thinking(String chunk);

  /// A streamed response token from the current phase's LLM call.
  void token(String token);

  /// The full recommendation exchange for [round], emitted right after
  /// the LLM call whether it succeeded or errored — the source for the
  /// per-round trace file.
  void llmExchange(AutoTuneLlmExchange exchange);

  /// A completed round's structured report (round 0 = baseline).
  void round(AutoTuneRoundReport report);

  /// Terminal notification with the stop reason and the last completed
  /// round.
  void finished(AutoTuneStopReason reason,
      {required int finalRound, String? errorMessage});
}

/// Loop phases the engine announces via [AutoTuneSink.phase]. The
/// review + parse-failure states are owned by the review policy, not
/// the engine, so they are not enumerated here.
enum AutoTunePhase { baseline, llmGenerating, generatingHook, synthesizing }

/// The full recommendation exchange for one round.
class AutoTuneLlmExchange {
  const AutoTuneLlmExchange({
    required this.round,
    required this.prompt,
    required this.thinking,
    required this.response,
    this.model,
    this.result,
    this.errorMessage,
  });

  final int round;
  final String prompt;
  final String thinking;
  final String response;
  final String? model;
  final RecommendationResult? result;
  final String? errorMessage;
}

/// Structured record of one completed round — everything a report or
/// snapshot needs. [recommendation]/[decisions]/[appliedRecommendations]
/// are empty on the baseline round.
class AutoTuneRoundReport {
  const AutoTuneRoundReport({
    required this.round,
    required this.result,
    required this.metrics,
    required this.snapshot,
    this.recommendation,
    this.decisions = const [],
    this.appliedRecommendations = const [],
    this.skippedNoOps = const [],
  });

  final int round;
  final SynthesizerResult result;
  final ManifestMetrics metrics;
  final RoundSnapshot snapshot;
  final RecommendationResult? recommendation;
  final List<RecommendationDecision> decisions;
  final List<Recommendation> appliedRecommendations;

  /// Accepted recommendations dropped before apply because they were
  /// already in effect (see `filterNoOpRecommendations`). Surfaced in
  /// reports so a session that keeps re-recommending current state is
  /// visible at a glance.
  final List<Recommendation> skippedNoOps;
}

/// Why the auto-tune session ended. 1:1 with the UI's
/// `AutoTuneFinishReason`.
enum AutoTuneStopReason {
  baselineFailed,
  parseFailed,
  llmEmpty,
  userStopped,
  userRejectedAll,
  noProgressOnSymbol,

  /// Successful rounds kept reproducing the exact same executed-symbol
  /// set (or every recommendation was a no-op) for
  /// `AutoTuneConfig.stagnantRoundLimit` consecutive rounds, with the
  /// wrapper-skip escalation already tried. A soft finish — the loop
  /// converged as far as it can with the current playbook.
  noCoverageProgress,
  cancelled,
  maxRounds,
  synthesisError,
  llmError,
}

/// Fold [FidelityCalculator] output into [manifest] as v2 metrics +
/// executed symbols. Shared by the CLI adapter (which enriches the raw
/// workflow result) and any other headless caller so enrichment isn't
/// re-implemented.
SynthesisManifest enrichManifestWithMetrics({
  required SynthesisManifest manifest,
  required CallGraph callGraph,
  required Set<String> executedSymbols,
  Set<String> subgraphSymbols = const {},
}) {
  final fidelity = FidelityCalculator.compute(
    callGraph: callGraph,
    hookedSymbols: {for (final d in manifest.decisions) d.symbol},
    traversedSymbols: executedSymbols,
    subgraphSymbols: subgraphSymbols,
  );
  return manifest.withMetrics(
    metrics: ManifestMetrics(
      overallFidelity: fidelity.overallFidelity,
      coverageFidelity: fidelity.coverageFidelity,
      subgraphFidelity: fidelity.subgraphFidelity,
      intactCount: fidelity.intactFunctions,
      degradedCount: fidelity.degradedFunctions,
      hookedCount: fidelity.hookedFunctions,
    ),
    executedSymbols: executedSymbols.toList()..sort(),
  );
}

/// Return a copy of [result] whose manifest is enriched with metrics +
/// executed symbols. No-op when the result has no manifest.
SynthesizerResult enrichSynthesizerResult({
  required SynthesizerResult result,
  required CallGraph callGraph,
  required Set<String> executedSymbols,
  Set<String> subgraphSymbols = const {},
}) {
  final m = result.manifest;
  if (m == null) return result;
  return SynthesizerResult(
    success: result.success,
    totalIterations: result.totalIterations,
    resolvedHooks: result.resolvedHooks,
    resolvedHookCode: result.resolvedHookCode,
    failedSymbol: result.failedSymbol,
    lastPauseSymbol: result.lastPauseSymbol,
    terminationReason: result.terminationReason,
    finalExecutionSymbol: result.finalExecutionSymbol,
    recentExecutionTrace: result.recentExecutionTrace,
    totalDuration: result.totalDuration,
    manifest: enrichManifestWithMetrics(
      manifest: m,
      callGraph: callGraph,
      executedSymbols: executedSymbols,
      subgraphSymbols: subgraphSymbols,
    ),
  );
}
