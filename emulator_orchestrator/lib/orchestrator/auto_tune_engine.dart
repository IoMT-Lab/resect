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
import '../data/models/rag_index_status.dart';
import '../services/analysis/artifact_census.dart';
import '../services/llm/last_run_insight_service.dart'
    show overriddenHooksBeneath;
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
/// the best-so-far anchor, and the in-memory snapshot history it feeds
/// back to the recommendation model. It never reads a provider; the
/// artifact database is its one store (authored hook bodies in, labels
/// and census out) — persistence of session state is the sink's job.
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
    this.ragStatus,
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

  /// Optional RAG-index count snapshot for the per-round artifact
  /// census (`RagIndex.statusSnapshot`); null when no index exists.
  final Future<RagIndexStatus?> Function()? ragStatus;

  var _cancelled = false;

  /// Completed when [cancel] is called; raced against in-flight LLM
  /// calls so a cancel takes effect immediately instead of after the
  /// model finishes composing (an advisor call can run for minutes).
  var _cancelRequested = Completer<void>();

  /// Request cancellation. An in-flight advisor call is abandoned
  /// immediately (the HTTP stream keeps draining server-side — see
  /// `LlmClient.generate` — but nothing more is emitted or applied);
  /// otherwise the loop drops out at its next checkpoint. Either way
  /// the session finishes with `AutoTuneStopReason.cancelled`. The
  /// review policy is responsible for unblocking any pending review
  /// it is awaiting.
  void cancel() {
    _cancelled = true;
    if (!_cancelRequested.isCompleted) _cancelRequested.complete();
  }

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
    _cancelRequested = Completer<void>();
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
      List<Recommendation> refused = const [],
      List<Recommendation> revertedMoves = const [],
      String? revertedOutcome,
    }) {
      final executed = manifest.executedSymbols?.toSet() ?? const <String>{};
      final frontier = computeFrontier(
        executedSymbols: executed,
        callGraph: callGraph,
      );
      final base = [
        for (final e in frontier)
          if (!entryPoints.contains(e.symbol) &&
              !overlays.hookOverrides.containsKey(e.symbol) &&
              !commsCovered.contains(e.symbol))
            e.symbol,
      ];
      // Rank candidates by how likely they actually CONTAIN the stall:
      // callers on the recent-call path into the halt point first (the
      // spin is provably at/near the end of that path), and callers
      // whose subtree carries working overrides last (skipping one
      // forfeits those hooks) — kept only when nothing safer remains.
      final onPath = manifest.recentExecutionTrace?.toSet() ?? const <String>{};
      final overrideKeys = overlays.hookOverrides.keys.toSet();
      bool carriesHooks(String s) =>
          overriddenHooksBeneath(callGraph, s, overrideKeys).isNotEmpty;
      final ranked = [
        ...base.where((s) => onPath.contains(s) && !carriesHooks(s)),
        ...base.where((s) => !onPath.contains(s) && !carriesHooks(s)),
        ...base.where(carriesHooks),
      ];
      final safeCount = ranked.length - ranked.where(carriesHooks).length;
      return RoundFeedback(
        coveragePrev: prevExecuted?.length ?? executed.length,
        coverageNow: executed.length,
        stalledCallers: (safeCount > 0
                ? ranked.where((s) => !carriesHooks(s))
                : ranked)
            .take(8)
            .toList(),
        noOpSkipped: noOpSkipped,
        refused: refused,
        revertedMoves: revertedMoves,
        revertedOutcome: revertedOutcome,
      );
    }

    // Best-so-far anchor: the highest executed count seen this session
    // and the overlay state that produced it. Rounds that collapse
    // below half of it are reverted; the session's final overlays are
    // restored to the best on finish. This is the outcome-measurement
    // enforcement that replaced the per-pattern refusals.
    var bestExecuted = 0;
    var bestOverlays = overlays.copy();
    var bestRound = 0;
    _censusElfHash = elfHash;
    _censusOverlays = overlays;
    _lastAdvisorSeconds = null;
    _lastHookGenSeconds = null;
    void trackBest(int executedCount, int roundNo) {
      if (executedCount > bestExecuted) {
        bestExecuted = executedCount;
        bestOverlays = overlays.copy();
        bestRound = roundNo;
      }
    }

    // Round 0: baseline.
    if (seedBaseline != null) {
      prevFailure = failureOf(seedBaseline);
      prevExecuted = seedBaseline.manifest?.executedSymbols?.toSet();
      trackBest(prevExecuted?.length ?? 0, 0);
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
        census: await _census(project),
      );
      prevFailure = failureOf(baseline);
      prevExecuted = baseline.manifest!.executedSymbols?.toSet();
      trackBest(prevExecuted?.length ?? 0, 0);
    }

    // Rounds 1..maxRounds.
    var round = 1;
    while (round <= config.maxRounds) {
      if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round - 1);
      _lastAdvisorSeconds = null;
      _lastHookGenSeconds = null;

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

      // Dedupe identical entries BEFORE the no-op filter and budget
      // accounting — the model sometimes emits the same recommendation
      // several times in one response, and duplicates would otherwise
      // burn slots and misreport as distinct moves.
      final deduped = <Recommendation>[];
      final seenKeys = <String>{};
      for (final r in acceptedOrEdited) {
        if (seenKeys.add(_recommendationKey(r))) deduped.add(r);
      }
      final duplicateCount = acceptedOrEdited.length - deduped.length;
      if (duplicateCount > 0) {
        stderr.writeln('[auto-tune] ignored $duplicateCount duplicate '
            'recommendation(s) in round $round');
      }

      // One HARD guard and several ADVISORY checks. Hard: overriding an
      // entry point deletes the program — refused regardless of what the
      // model said (the decoder's enforcement is soft). Everything else
      // that USED to be refused here (constants on time readers, skips
      // of proven parents, multi-skip batches) is now a WARNING on the
      // round: the measure-and-revert loop below is the enforcement — a
      // round that regresses is rolled back wholesale — so the engine
      // no longer needs to predict badness by name pattern.
      final lastExecuted =
          lastManifest.executedSymbols?.toSet() ?? const <String>{};
      final refused = <Recommendation>[];
      final warnings = <String>[];
      final safe = <Recommendation>[];
      var executedSkipCount = 0;
      for (final r in deduped) {
        if (r is SetForcedOverride && kProtectedSymbols.contains(r.symbol)) {
          refused.add(r);
          stderr.writeln('[auto-tune] REFUSED override on entry point '
              '`${r.symbol}`');
          continue;
        }
        if (r is SetForcedOverride) {
          if (_kTimeReaderName.hasMatch(r.symbol) &&
              await _isConstantReturnArtifact(r.artifactId)) {
            warnings.add('`${r.symbol}` ← constant: looks like a frozen '
                'time/counter reader — likely wants a Stateful increment');
          }
          if (await _isReturnZeroArtifact(r.artifactId) &&
              lastExecuted.contains(r.symbol)) {
            executedSkipCount++;
            final hooksBeneath = overriddenHooksBeneath(
                callGraph, r.symbol, overlays.hookOverrides.keys.toSet());
            if (hooksBeneath.isNotEmpty) {
              warnings.add('`${r.symbol}` ← Return 0 skips a caller that '
                  'executed cleanly; working hooks beneath it stop '
                  'executing (${hooksBeneath.take(3).join(', ')})');
            }
          }
        }
        safe.add(r);
      }
      if (executedSkipCount > 1) {
        warnings.add('$executedSkipCount wrapper-skips in one round — each '
            'forfeits a subtree; a regressing round is reverted wholesale');
      }
      for (final w in warnings) {
        stderr.writeln('[auto-tune] WARN: $w');
      }
      if (safe.isEmpty && refused.isNotEmpty) {
        // Everything the model wanted targeted entry points. Treat like
        // an all-no-op round: stagnate, escalate with the refusals named.
        stagnantRounds++;
        if (stagnantRounds >= config.stagnantRoundLimit) {
          return _finish(AutoTuneStopReason.noCoverageProgress, round,
              errorMessage: 'Round $round: every recommendation was '
                  'refused as destructive.');
        }
        pendingFeedback = buildFeedback(
          manifest: lastManifest,
          noOpSkipped: const [],
          refused: refused,
        );
        round++;
        continue;
      }

      // Drop recommendations already in effect (same override/
      // preference, or the same artifact the last run applied
      // reactively). Re-applying one burns a full synthesis round on
      // an identical run — the observed 6-round flatline was exactly
      // this. Skipped entries surface in the round report and in the
      // next round's feedback so the model is told not to repeat them.
      final filtered = filterNoOpRecommendations(
        recommendations: safe,
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
        final genWatch = Stopwatch()..start();
        final err = await _generateAndSeedCustomHooks(
          generateRecs,
          round: round,
          elfHash: elfHash,
          overlays: overlays,
        );
        genWatch.stop();
        _lastHookGenSeconds = genWatch.elapsed.inMilliseconds / 1000.0;
        if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round - 1);
        if (err != null) {
          return _finish(AutoTuneStopReason.llmError, round,
              errorMessage: err);
        }
      }

      // Apply the reviewed overlay edits into the engine's overlays,
      // keeping the pre-apply state so a regressing round can be
      // rolled back wholesale.
      final preRoundOverlays = overlays.copy();
      overlays.apply(effective);

      // Re-synthesize with the new overlays. This synthesis IS round N —
      // the same number its round report and snapshot will carry — so the
      // phase event must use the same base or the panel and the result
      // card disagree about which round just ran.
      sink.phase(AutoTunePhase.synthesizing, round: round);
      final runResult = await runSynthesis(overlays, round);
      if (_cancelled) return _finish(AutoTuneStopReason.cancelled, round);
      if (runResult == null || runResult.manifest == null) {
        return _finish(AutoTuneStopReason.synthesisError, round,
            errorMessage: 'Synthesis returned no manifest.');
      }

      // Measure the round: a collapse below half of the session's best
      // means this round's changes made things worse — roll them back
      // (after reporting) and tell the model what was measured. This
      // catches every "locally reasonable, globally wrong" move —
      // frozen counters, bad skips — without name knowledge.
      final currentExecuted = runResult.manifest!.executedSymbols?.toSet();
      final executedCount = currentExecuted?.length ?? 0;
      final reverted = bestExecuted > 0 && executedCount < bestExecuted * 0.5;
      final revertNote = reverted
          ? 'executed fell $bestExecuted (best) → $executedCount'
          : null;

      // Emit this round's report (+ append to history for the next
      // recommend call) BEFORE any rollback, so the snapshot records
      // what actually ran.
      _emitRound(
        round: round,
        result: runResult,
        overlays: overlays,
        history: history,
        recommendation: llmResult,
        decisions: review.decisions,
        applied: effective,
        skippedNoOps: skippedNoOps,
        refused: refused,
        warnings: warnings,
        reverted: reverted,
        census: await _census(project),
      );

      if (reverted) {
        overlays.restoreFrom(preRoundOverlays);
        stderr.writeln('[auto-tune] REVERTED round $round: $revertNote — '
            'overlays restored');
        // A reverted round is a stagnant round: its changes are gone,
        // so the evidence next round is unchanged except for the
        // poisoned-move memory. prevFailure/prevExecuted stay put.
        stagnantRounds++;
        if (stagnantRounds >= config.stagnantRoundLimit) {
          overlays.restoreFrom(bestOverlays);
          return _finish(AutoTuneStopReason.noCoverageProgress, round,
              errorMessage: 'Round $round reverted ($revertNote); '
                  'no path forward after $stagnantRounds stagnant rounds. '
                  'Final overlays are round $bestRound\'s (best).');
        }
        pendingFeedback = buildFeedback(
          manifest: lastManifest,
          noOpSkipped: skippedNoOps,
          refused: refused,
          revertedMoves: effective,
          revertedOutcome: revertNote,
        );
        round++;
        continue;
      }

      trackBest(executedCount, round);

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
        overlays.restoreFrom(bestOverlays);
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
      if (isCoverageStagnant(
        prevExecuted: prevExecuted,
        currentExecuted: currentExecuted,
        currentFailedSymbol: currentFailed,
      )) {
        stagnantRounds++;
        if (stagnantRounds >= config.stagnantRoundLimit) {
          overlays.restoreFrom(bestOverlays);
          return _finish(AutoTuneStopReason.noCoverageProgress, round,
              errorMessage:
                  'Coverage frozen at ${currentExecuted?.length ?? 0} '
                  'executed symbols for $stagnantRounds rounds '
                  '(escalation tried). Final overlays are round '
                  '$bestRound\'s (best).');
        }
        pendingFeedback = buildFeedback(
          manifest: runResult.manifest!,
          noOpSkipped: skippedNoOps,
          refused: refused,
        );
      } else {
        stagnantRounds = 0;
      }
      prevExecuted = currentExecuted ?? prevExecuted;

      round++;
    }
    overlays.restoreFrom(bestOverlays);
    return _finish(AutoTuneStopReason.maxRounds, config.maxRounds);
  }

  // -- Internals -------------------------------------------------------------

  /// The most recent synthesis result emitted to a round report. Used
  /// as the manifest source for the next round's recommend call.
  SynthesizerResult? _lastResult;

  /// Wall time of the most recent advisor (recommendation) LLM call and
  /// custom-hook authoring pass, carried onto the round report.
  double? _lastAdvisorSeconds;
  double? _lastHookGenSeconds;

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
    // The prompt window is the MOST RECENT N rounds (RecommendationService
    // documents "last N rounds"); older rounds fall out of the evidence.
    final windowSize = config.snapshotWindowSize.clamp(1, 100);
    final windowed = history.length <= windowSize
        ? List<RoundSnapshot>.unmodifiable(history)
        : List<RoundSnapshot>.unmodifiable(
            history.sublist(history.length - windowSize));

    final thinkingBuf = StringBuffer();
    final responseBuf = StringBuffer();
    String? composedPrompt;
    final advisorWatch = Stopwatch()..start();
    try {
      final recommendFuture = recommendationService.recommend(
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
          if (_cancelled) return;
          responseBuf.write(tok);
          sink.token(tok);
        },
        onThinking: (chunk) {
          if (_cancelled) return;
          thinkingBuf.write(chunk);
          sink.thinking(chunk);
        },
      );
      // Race the model against cancellation: an advisor call can run
      // for minutes, and a Cancel click must not wait it out. On
      // cancel the call is abandoned (its eventual completion or error
      // is swallowed); the caller's cancelled-checkpoint finishes the
      // session.
      final result = await Future.any<RecommendationResult?>([
        recommendFuture,
        _cancelRequested.future.then((_) => null),
      ]);
      if (result == null) {
        unawaited(recommendFuture.then((_) {}, onError: (_) {}));
        return null;
      }
      advisorWatch.stop();
      _lastAdvisorSeconds = advisorWatch.elapsed.inMilliseconds / 1000.0;
      sink.llmExchange(AutoTuneLlmExchange(
        round: round,
        model: result.model,
        prompt: composedPrompt ?? '(prompt not captured)',
        thinking: thinkingBuf.toString(),
        response: responseBuf.toString(),
        result: result,
        durationSeconds: _lastAdvisorSeconds,
      ));
      return result;
    } catch (e) {
      advisorWatch.stop();
      _lastAdvisorSeconds = advisorWatch.elapsed.inMilliseconds / 1000.0;
      sink.llmExchange(AutoTuneLlmExchange(
        round: round,
        model: null,
        prompt: composedPrompt ?? '(prompt not captured)',
        thinking: thinkingBuf.toString(),
        response: responseBuf.toString(),
        result: null,
        errorMessage: e.toString(),
        durationSeconds: _lastAdvisorSeconds,
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
          round: round, symbol: rec.symbol);
      final responseBuf = StringBuffer();
      try {
        await for (final ev in generator.generateEvents(
          userPrompt: rec.intent ?? _defaultHookIntent(rec.symbol),
          targetSymbol: rec.symbol,
          elfHash: elfHash,
        )) {
          // Cancellation checkpoint per streamed chunk — tokens flow
          // continuously while the model generates, so a Cancel click
          // lands within a token's latency instead of after the full
          // hook is authored.
          if (_cancelled) return null;
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
      if (_cancelled) return null;
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
    List<Recommendation> refused = const [],
    List<String> warnings = const [],
    bool reverted = false,
    ArtifactCensus? census,
  }) {
    // Fold the round's telemetry (advisor / hook-gen wall time, census)
    // into the manifest BEFORE emitting, so the sink-written
    // round_NN_manifest.json is the complete per-round record and a
    // disk reader (UI session reload, tools) loses nothing.
    final manifest = result.manifest!.withRoundTelemetry(
      advisorSeconds: _lastAdvisorSeconds,
      roundHookGenSeconds: _lastHookGenSeconds,
      census: census,
    );
    final folded = result.withManifest(manifest);
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
      reverted: reverted,
      warnings: warnings,
    );
    history.add(snapshot);
    _lastResult = folded;
    sink.round(AutoTuneRoundReport(
      round: round,
      result: folded,
      metrics: metrics,
      snapshot: snapshot,
      recommendation: recommendation,
      decisions: decisions,
      appliedRecommendations: applied,
      skippedNoOps: skippedNoOps,
      refusedDestructive: refused,
      warnings: warnings,
      reverted: reverted,
      advisorSeconds: _lastAdvisorSeconds,
      hookGenSeconds: _lastHookGenSeconds,
      census: census,
    ));
  }

  /// Per-round artifact census — null when it fails (census must never
  /// break a round).
  Future<ArtifactCensus?> _census(Emulator project) async {
    try {
      return await computeArtifactCensus(
        db: artifactDb,
        elfHash: _censusElfHash ?? '',
        hookOverrides: _censusOverlays?.hookOverrides ?? const {},
        hookBindings: _censusOverlays?.hookBindings ?? const {},
        commsAssignments: project.commsAssignments,
        symbolGroups: symbolGroups,
        ragStatus: await ragStatus?.call(),
      );
    } catch (_) {
      return null;
    }
  }

  String? _censusElfHash;
  AutoTuneOverlays? _censusOverlays;

  /// Identity key for de-duplicating recommendations within one round's
  /// response — the model sometimes emits the same entry several times.
  static String _recommendationKey(Recommendation r) => switch (r) {
        SetForcedOverride(:final symbol, :final artifactId, :final scope) =>
          'sfo:$symbol:$artifactId:${scope ?? ''}',
        ClearForcedOverride(:final symbol) => 'cfo:$symbol',
        SetPreference(:final symbol, :final artifactId) =>
          'sp:$symbol:$artifactId',
        GenerateCustomHook(:final symbol) => 'gch:$symbol',
        SetGroupOverride(:final scope) => 'sgo:$scope',
        ClearGroupOverride(:final scope) => 'cgo:$scope',
        AdjustIterationCap(:final newValue) => 'aic:$newValue',
      };

  /// Function names that READ time/ticks/counters — forcing one to a
  /// constant freezes the clock. Same family the report grader uses.
  static final _kTimeReaderName = RegExp(
      r'GetTick|GetAbsoluteTime|GetCounter|GetTime|_Counter\b',
      caseSensitive: false);

  /// Whether [artifactId]'s body is the body-deleting "Return 0"
  /// template, per the shared [hookArtifactLabel] semantics. Bodies are
  /// cached per session; the cache refreshes when an unknown id shows
  /// up (freshly authored hooks land mid-session).
  Map<int, String>? _artifactBodyCache;
  Future<bool> _isReturnZeroArtifact(int artifactId) async =>
      await _artifactLabel(artifactId) == 'Return 0';

  /// Whether [artifactId] is any constant-return template (Return 0 /
  /// Return 1 / Return N) — the wrong shape for a value that must
  /// advance between calls.
  Future<bool> _isConstantReturnArtifact(int artifactId) async {
    final label = await _artifactLabel(artifactId);
    return label != null && label.startsWith('Return ');
  }

  Future<String?> _artifactLabel(int artifactId) async {
    if (_artifactBodyCache == null ||
        !_artifactBodyCache!.containsKey(artifactId)) {
      _artifactBodyCache = {
        for (final a in await artifactDb.getAllArtifacts())
          a.id: a.artifactData,
      };
    }
    final body = _artifactBodyCache![artifactId];
    return body == null ? null : hookArtifactLabel(body);
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

  /// Deep-enough copy for the engine's revert machinery (map contents
  /// copied; values are immutable).
  AutoTuneOverlays copy() => AutoTuneOverlays(
        hookOverrides: Map<String, int>.from(hookOverrides),
        hookOverrideScopes: Map<String, String>.from(hookOverrideScopes),
        hookPreferences: Map<String, int>.from(hookPreferences),
        hookBindings: Map<String, HookBinding>.from(hookBindings),
        groupOverrides: Map<String, GroupOverrideState>.from(groupOverrides),
        iterationCap: iterationCap,
      );

  /// Restore this instance IN PLACE to [other]'s state. In place
  /// because the engine hands the same instance to every synthesis
  /// call — reassigning would silently decouple them.
  void restoreFrom(AutoTuneOverlays other) {
    hookOverrides
      ..clear()
      ..addAll(other.hookOverrides);
    hookOverrideScopes
      ..clear()
      ..addAll(other.hookOverrideScopes);
    hookPreferences
      ..clear()
      ..addAll(other.hookPreferences);
    hookBindings
      ..clear()
      ..addAll(other.hookBindings);
    groupOverrides
      ..clear()
      ..addAll(other.groupOverrides);
    iterationCap = other.iterationCap;
  }

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

/// Fans every [AutoTuneSink] notification out to [sinks], in order.
///
/// Lets one engine feed several consumers at once — e.g. the UI's state
/// sink alongside an [AutoTuneReportSink] writing the report files — so
/// neither has to know about the other.
class MultiSink implements AutoTuneSink {
  const MultiSink(this.sinks);

  final List<AutoTuneSink> sinks;

  @override
  void phase(AutoTunePhase phase, {int round = 0, String? symbol}) {
    for (final s in sinks) {
      s.phase(phase, round: round, symbol: symbol);
    }
  }

  @override
  void thinking(String chunk) {
    for (final s in sinks) {
      s.thinking(chunk);
    }
  }

  @override
  void token(String token) {
    for (final s in sinks) {
      s.token(token);
    }
  }

  @override
  void llmExchange(AutoTuneLlmExchange exchange) {
    for (final s in sinks) {
      s.llmExchange(exchange);
    }
  }

  @override
  void round(AutoTuneRoundReport report) {
    for (final s in sinks) {
      s.round(report);
    }
  }

  @override
  void finished(AutoTuneStopReason reason,
      {required int finalRound, String? errorMessage}) {
    for (final s in sinks) {
      s.finished(reason, finalRound: finalRound, errorMessage: errorMessage);
    }
  }
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
    this.durationSeconds,
  });

  final int round;
  final String prompt;
  final String thinking;
  final String response;
  final String? model;
  final RecommendationResult? result;
  final String? errorMessage;

  /// Wall time of the LLM call, when measured.
  final double? durationSeconds;
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
    this.refusedDestructive = const [],
    this.warnings = const [],
    this.reverted = false,
    this.advisorSeconds,
    this.hookGenSeconds,
    this.census,
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

  /// Recommendations the engine REFUSED outright (entry-point targets).
  /// Surfaced in reports so a refusal is auditable, and echoed into the
  /// next round's feedback.
  final List<Recommendation> refusedDestructive;

  /// Advisory notes on this round's applied moves (suspected frozen
  /// counter, skip of a caller with working hooks beneath, multi-skip
  /// batch). Warnings never block — the measure-and-revert loop is the
  /// enforcement; these exist so a human reading the report (and the
  /// model reading feedback) can see the risk that was taken.
  final List<String> warnings;

  /// True when this round's changes were measured, found to collapse
  /// coverage below half the session best, and rolled back after the
  /// report was emitted. The snapshot still records what actually ran.
  final bool reverted;

  /// Wall time of this round's advisor (recommendation) LLM call, and
  /// of the custom-hook authoring pass when one ran. Null on the
  /// baseline round / when not measured.
  final double? advisorSeconds;
  final double? hookGenSeconds;

  /// Counts of the artifacts feeding this round's synthesis. Null when
  /// the census couldn't be computed.
  final ArtifactCensus? census;
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
      executedCount: executedSymbols.length,
      totalSymbols: callGraph.symbols.length,
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
