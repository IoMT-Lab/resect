import 'dart:async';
import 'dart:io';

import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/services/analysis/coverage_frontier.dart';
import 'package:emulator_orchestrator/services/analysis/fidelity_calculator.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_progress.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import '../../../providers/autosave_provider.dart';
import 'recommendation_applier.dart';
import 'synthesis_controller.dart';

/// Closed-loop LLM-orchestrated synthesizer.
///
/// Drives the user-in-the-loop auto-tune session: runs a baseline
/// synthesis, asks the LLM for structured recommendations, pauses
/// for the user to Accept / Reject / Edit each, applies the
/// accepted/edited ones, re-runs synthesis, persists a
/// [RoundSnapshot] each round, and repeats until the LLM emits no
/// further recommendations or the user stops.
///
/// Exposes a [ChangeNotifier]-based [state] the auto-tune modal
/// listens to. Each user interaction in the modal (Accept-all,
/// Stop, Cancel, Retry) calls a method on the controller that
/// completes the relevant internal [Completer]. The loop is
/// linear and single-flight — `runAutoTune` throws on re-entry.
///
/// No mocks; the loop talks directly to the real services through
/// the injected [ProviderContainer].
class LlmSynthesisOrchestrator extends ChangeNotifier {
  LlmSynthesisOrchestrator(this.container);

  /// Riverpod container the orchestrator reads providers from.
  /// Production: `ProviderScope.containerOf(context)`. Tests: a
  /// real `ProviderContainer`.
  final ProviderContainer container;

  AutoTuneState _state = const AutoTuneIdle();
  AutoTuneState get state => _state;

  /// Drive the orchestrator's state directly. Intended for widget
  /// tests that render the modal against a scripted state sequence
  /// without invoking the real loop (no LLM, no Renode, no
  /// services). Production code routes through [runAutoTune].
  @visibleForTesting
  void setStateForTest(AutoTuneState newState) {
    _setState(newState);
  }

  Completer<_ReviewSubmission>? _reviewCompleter;
  Completer<_ParseFailureChoice>? _parseFailureCompleter;
  bool _cancelled = false;

  /// Run a complete auto-tune session against the currently-open
  /// project. Returns when the loop terminates (any reason); the
  /// final state is available on [state].
  ///
  /// Throws [StateError] if a session is already in progress or
  /// the project hasn't been saved (the manifest disk write is
  /// gated on `emulatorPath != null`).
  Future<void> runAutoTune(AutoTuneConfig config) async {
    if (_state is! AutoTuneIdle && _state is! AutoTuneFinished) {
      throw StateError('Auto-tune already in progress.');
    }
    final emulator = container.read(currentEmulatorProvider);
    if (emulator == null) {
      throw StateError('No project loaded.');
    }
    if (emulator.emulatorPath == null) {
      throw StateError(
          'Save the project before starting auto-tune so snapshots '
          'persist.');
    }

    _cancelled = false;
    _setState(const AutoTuneRunningBaseline());

    // Round 0: baseline. Run a synthesis if we don't have a recent
    // snapshot already.
    var current = container.read(currentEmulatorProvider)!;
    final lastSnapshot = current.latestSnapshot;
    final needsBaseline = lastSnapshot == null ||
        current.synthesisResult?.manifest?.synthesizerRunId !=
            lastSnapshot.synthesizerRunId;

    // The PREVIOUS round's failure: the symbol its synthesis failed
    // at plus the set of artifact ids tried for that symbol. Null when
    // the prior round didn't crash. Threaded across loop iterations so
    // the no-progress guard can tell a true repeat (same symbol, no
    // new hook tried) from legitimate exploration. Carried from each
    // round's own SynthesizerResult — the round snapshot only holds a
    // runId, and the live provider always holds the CURRENT run (that
    // was the original self-comparison bug).
    ({String symbol, Set<int> tried})? prevFailure;

    ({String symbol, Set<int> tried})? failureOf(SynthesizerResult? r) {
      final m = r?.manifest;
      final failed = m?.failedSymbol;
      if (m == null || failed == null) return null;
      return (symbol: failed, tried: triedArtifactsForFailedSymbol(m));
    }

    if (needsBaseline) {
      final baseline = await _runSynthesisAndAwait();
      if (_cancelled) {
        _finish(AutoTuneFinishReason.cancelled, round: 0);
        return;
      }
      if (baseline == null || baseline.manifest == null) {
        _finish(AutoTuneFinishReason.baselineFailed,
            round: 0, errorMessage: 'Synthesis returned no manifest.');
        return;
      }
      _appendSnapshot(round: 0, result: baseline, llmInput: null);
      prevFailure = failureOf(baseline);
    } else {
      prevFailure = failureOf(current.synthesisResult);
    }

    // Rounds 1..maxRounds.
    var round = 1;
    while (round <= config.maxRounds) {
      if (_cancelled) {
        _finish(AutoTuneFinishReason.cancelled, round: round - 1);
        return;
      }

      // Ask the LLM for recommendations.
      final llmResult = await _askLlm(round: round, config: config);
      if (_cancelled) {
        _finish(AutoTuneFinishReason.cancelled, round: round - 1);
        return;
      }
      if (llmResult == null) {
        // LLM call errored out; _askLlm already set the finished state.
        return;
      }

      // Parse failure → modal pauses for user choice (Retry / Stop).
      if (llmResult.parseFailure) {
        // Surface the diagnostic to stderr too — the previous
        // failure mode died silently in the terminal log, leaving
        // the user with only "(empty)" in the modal. Concrete
        // line: `[AutoTune] round N parse failure: <kind> ...`.
        final kind = llmResult.parseFailureKind;
        final diag = llmResult.diagnostic;
        if (kind == RecommendationParseFailureKind.emptyResponse) {
          debugPrint(
              '[AutoTune] round $round parse failure: emptyResponse '
              '${diag?.toLogLine() ?? '(no diagnostic captured)'}');
        } else {
          debugPrint(
              '[AutoTune] round $round parse failure: '
              '${kind?.name ?? "unknown"} '
              '(${(llmResult.raw ?? "").length} bytes of raw output)');
        }
        _setState(AutoTuneParseFailed(
          round: round,
          raw: llmResult.raw ?? '',
          kind: kind,
          diagnostic: diag,
        ));
        final choice = await _waitForParseFailureChoice();
        if (choice == _ParseFailureChoice.retry) continue;
        _finish(AutoTuneFinishReason.parseFailed, round: round);
        return;
      }

      // Empty recommendations → success termination.
      if (llmResult.recommendations.isEmpty) {
        _finish(AutoTuneFinishReason.llmEmpty, round: round - 1);
        return;
      }

      // User reviews each recommendation.
      _setState(AutoTuneReviewing(round: round, result: llmResult));
      final review = await _waitForReview();
      if (review.cancelled) {
        _finish(AutoTuneFinishReason.cancelled, round: round - 1);
        return;
      }
      if (review.userStopped) {
        _finish(AutoTuneFinishReason.userStopped, round: round - 1);
        return;
      }
      final acceptedOrEdited = review.decisions
          .where((d) => d.action != UserAction.rejected)
          .map((d) => d.applied!)
          .toList();
      if (acceptedOrEdited.isEmpty) {
        _finish(AutoTuneFinishReason.userRejectedAll, round: round - 1);
        return;
      }

      // Author + seed any accepted GenerateCustomHook recs BEFORE
      // the applier runs — the applier filters these out by
      // design, so we need to handle them ourselves. The body
      // generated here lands in the artifact DB as a user-origin
      // row, and a hookBinding is set so the next synthesis run
      // picks it up.
      final generateRecs =
          acceptedOrEdited.whereType<GenerateCustomHook>().toList();
      if (generateRecs.isNotEmpty) {
        final ok = await _generateAndSeedCustomHooks(
            generateRecs, round: round);
        if (!ok) return; // _generateAndSeedCustomHooks called _finish
        if (_cancelled) {
          _finish(AutoTuneFinishReason.cancelled, round: round - 1);
          return;
        }
      }
      const applier = RecommendationApplier();
      applier.apply(container, acceptedOrEdited);

      // Run synthesis with the new overlay. Display round+1 — the
      // user just applied round N's recommendations, so the
      // synthesis that's running now is round N+1's input. The
      // internal `round` counter stays at N until the loop-tail
      // increment; only the user-facing state shows N+1.
      _setState(AutoTuneSynthesizing(round: round + 1));
      final runResult = await _runSynthesisAndAwait();
      if (_cancelled) {
        _finish(AutoTuneFinishReason.cancelled, round: round);
        return;
      }
      if (runResult == null || runResult.manifest == null) {
        _finish(AutoTuneFinishReason.synthesisError,
            round: round,
            errorMessage: 'Synthesis returned no manifest.');
        return;
      }

      // Persist the snapshot for this round.
      _appendSnapshot(
        round: round,
        result: runResult,
        llmInput: _LlmInputForRound(
          recommendations: llmResult.recommendations,
          decisions: review.decisions,
          prose: llmResult.prose,
        ),
      );

      // No-progress check: stop only on a TRUE repeat — this round
      // failed at the same symbol as the prior round AND no new hook
      // was tried for it (the tried-set gained nothing). A new hook at
      // the same symbol, or a different symbol, is progress and the
      // loop continues (still bounded by maxRounds + llmEmpty).
      // `prevFailure` was carried from the prior round (or baseline)
      // at the bottom of the loop.
      final currentFailed = runResult.manifest!.failedSymbol;
      final currentTried =
          triedArtifactsForFailedSymbol(runResult.manifest!);
      if (isNoProgress(
        currentFailed: currentFailed,
        prevFailed: prevFailure?.symbol,
        currentTried: currentTried,
        prevTried: prevFailure?.tried ?? const {},
      )) {
        _finish(AutoTuneFinishReason.noProgressOnSymbol, round: round);
        return;
      }
      prevFailure = currentFailed == null
          ? null
          : (symbol: currentFailed, tried: currentTried);

      round++;
    }
    _finish(AutoTuneFinishReason.maxRounds, round: config.maxRounds);
  }

  // -- Modal-facing methods --------------------------------------------------

  /// Called by the modal when the user clicks Apply-and-continue.
  void submitReview(List<RecommendationDecision> decisions) {
    if (_reviewCompleter == null || _reviewCompleter!.isCompleted) return;
    _reviewCompleter!.complete(_ReviewSubmission(decisions: decisions));
  }

  /// Called by the modal when the user clicks Stop during review.
  void stopAfterReview(List<RecommendationDecision> decisions) {
    if (_reviewCompleter == null || _reviewCompleter!.isCompleted) return;
    _reviewCompleter!.complete(_ReviewSubmission(
      decisions: decisions,
      userStopped: true,
    ));
  }

  /// Called by the modal when the user clicks Cancel during running
  /// or LLM streaming. Disposes the active LLM subscription and
  /// flips the [_cancelled] flag; the loop drops out at its next
  /// check.
  void cancel() {
    _cancelled = true;
    if (_reviewCompleter != null && !_reviewCompleter!.isCompleted) {
      _reviewCompleter!.complete(
          const _ReviewSubmission(decisions: [], cancelled: true));
    }
    if (_parseFailureCompleter != null &&
        !_parseFailureCompleter!.isCompleted) {
      _parseFailureCompleter!.complete(_ParseFailureChoice.stop);
    }
  }

  /// Called by the modal when the user clicks Retry on the
  /// parse-failure notice.
  void retryAfterParseFailure() {
    _parseFailureCompleter?.complete(_ParseFailureChoice.retry);
  }

  /// Called by the modal when the user clicks Stop on the
  /// parse-failure notice.
  void stopAfterParseFailure() {
    _parseFailureCompleter?.complete(_ParseFailureChoice.stop);
  }

  // -- Internal helpers ------------------------------------------------------

  void _setState(AutoTuneState newState) {
    _state = newState;
    notifyListeners();
  }

  void _finish(
    AutoTuneFinishReason reason, {
    required int round,
    String? errorMessage,
  }) {
    _setState(AutoTuneFinished(
      reason: reason,
      finalRound: round,
      errorMessage: errorMessage,
    ));
  }

  /// For each accepted [GenerateCustomHook] in [recs], stream the
  /// hook-body generation via [LlmHookGenerator], persist the
  /// resulting body as a user-origin artifact, and seed a
  /// [HookBinding] so the next synthesis run picks it up. Updates
  /// the modal with [AutoTuneGeneratingHook] state during each
  /// stream so the user sees progress.
  ///
  /// Returns false (and calls [_finish] with `llmError`) when the
  /// hook generator isn't wired (no project loaded) or a generation
  /// errors out; the caller should `return` early. Returns true
  /// when every rec generated and seeded successfully.
  Future<bool> _generateAndSeedCustomHooks(
    List<GenerateCustomHook> recs, {
    required int round,
  }) async {
    final generator = container.read(llmHookGeneratorProvider);
    if (generator == null) {
      _finish(AutoTuneFinishReason.llmError,
          round: round,
          errorMessage:
              'LlmHookGenerator unavailable (no project / RAG index '
              'not ready); cannot author custom hooks.');
      return false;
    }
    final artifactDb = container.read(artifactDatabaseProvider);
    final emulator = container.read(currentEmulatorProvider);
    final elfHash = emulator?.synthesisResult?.manifest?.elfHash;

    for (final rec in recs) {
      if (_cancelled) return false;
      final thinkingBuf = StringBuffer();
      final responseBuf = StringBuffer();
      _setState(AutoTuneGeneratingHook(
        round: round + 1,
        symbol: rec.symbol,
        thinkingText: '',
        responseText: '',
      ));
      try {
        // Streaming generation — route thinking to a side buffer
        // for live UI display, accumulate response chunks for the
        // hook body itself. Same shape the recommendation flow
        // uses.
        await for (final ev in generator.generateEvents(
          userPrompt: rec.intent ?? _defaultHookIntent(rec.symbol),
          targetSymbol: rec.symbol,
          elfHash: elfHash,
        )) {
          switch (ev) {
            case LlmThinkingChunk(:final text):
              thinkingBuf.write(text);
              _setState(AutoTuneGeneratingHook(
                round: round + 1,
                symbol: rec.symbol,
                thinkingText: thinkingBuf.toString(),
                responseText: responseBuf.toString(),
              ));
            case LlmResponseChunk(:final text):
              responseBuf.write(text);
              _setState(AutoTuneGeneratingHook(
                round: round + 1,
                symbol: rec.symbol,
                thinkingText: thinkingBuf.toString(),
                responseText: responseBuf.toString(),
              ));
            case LlmStreamDone():
              break;
          }
        }
      } catch (e) {
        _finish(AutoTuneFinishReason.llmError,
            round: round,
            errorMessage:
                'Hook generation failed for ${rec.symbol}: $e');
        return false;
      }
      final body = responseBuf.toString().trim();
      if (body.isEmpty) {
        _finish(AutoTuneFinishReason.llmError,
            round: round,
            errorMessage:
                'Hook generation produced no output for ${rec.symbol}.');
        return false;
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

      final currentBindings = Map<String, HookBinding>.from(
          container.read(hookBindingsProvider));
      currentBindings[rec.symbol] = HookBinding(
        artifactId: newId,
        fidelity: 0.5,
        provenance: 'llm:auto-tune-r$round',
        createdAt: DateTime.now(),
      );
      container.read(hookBindingsProvider.notifier).state =
          currentBindings;
      container.read(emulatorDirtyProvider.notifier).state = true;
      debugPrint(
          '[AutoTune] generated custom hook for ${rec.symbol} '
          '→ artifact #$newId (round $round)'
          '${generator.lastWatchdogFired ? ' [watchdog_fired: '
              'a thinking spiral was bounded and retried think-off]' : ''}');
    }
    return true;
  }

  /// Fallback `userPrompt` when the LLM didn't include an
  /// `intent` on the GenerateCustomHook recommendation. Generic
  /// enough that the hook-gen LLM falls back to its own
  /// reasoning over the symbol's decompilation.
  static String _defaultHookIntent(String symbol) =>
      'Author a Renode hook for the firmware function `$symbol`. '
      "Its existing template-based hook didn't progress the "
      'firmware past this symbol; design a behavior (returning a '
      'sentinel value, toggling a status bit, etc.) that lets '
      'execution continue.';

  Future<SynthesizerResult?> _runSynthesisAndAwait() async {
    final emulator = container.read(currentEmulatorProvider);
    if (emulator == null) return null;
    try {
      await container.read(synthesisControllerProvider).startSynthesis(emulator);
    } catch (e) {
      debugPrint('[AutoTune] synthesis failed: $e');
      return null;
    }
    // Yield once so the SynthesisController's stream listener has a
    // chance to enrich + publish synthesisResultProvider before we
    // read it back.
    await Future<void>.delayed(Duration.zero);
    return container.read(synthesisResultProvider);
  }

  Future<RecommendationResult?> _askLlm({
    required int round,
    required AutoTuneConfig config,
  }) async {
    _setState(AutoTuneLlmGenerating(
      round: round,
      thinkingText: '',
      responseText: '',
    ));
    final emulator = container.read(currentEmulatorProvider);
    final manifest = emulator?.synthesisResult?.manifest;
    final callGraph = emulator?.cachedCallGraph;
    final overlayState = container.read(hookDecisionStateProvider);
    if (manifest == null || callGraph == null || overlayState == null) {
      _finish(AutoTuneFinishReason.llmError,
          round: round - 1,
          errorMessage: 'Missing manifest, call graph, or overlay state.');
      return null;
    }
    final history = emulator!.roundSnapshots
        .take(config.snapshotWindowSize.clamp(1, 100))
        .toList();
    // Derive the coverage frontier — the boundary functions where
    // execution stopped expanding. This is the Job-2 (proactive
    // coverage) signal; RecommendationService includes it in the
    // prompt + narrows the output schema to it when the run didn't
    // crash. Empty for job-1 (crash) runs, which is fine — recommend()
    // only uses it in job2 mode.
    final executed = manifest.executedSymbols?.toSet() ?? <String>{};
    final frontier =
        computeFrontier(executedSymbols: executed, callGraph: callGraph);
    final service = container.read(recommendationServiceProvider);
    final thinkingBuf = StringBuffer();
    final responseBuf = StringBuffer();
    String? composedPrompt;
    try {
      final result = await service.recommend(
        currentManifest: manifest,
        currentState: overlayState,
        callGraph: callGraph,
        history: history,
        optimizationTarget: config.optimizationTarget,
        frontier: frontier,
        onPromptComposed: (p) => composedPrompt = p,
        onToken: (tok) {
          responseBuf.write(tok);
          _setState(AutoTuneLlmGenerating(
            round: round,
            thinkingText: thinkingBuf.toString(),
            responseText: responseBuf.toString(),
          ));
        },
        onThinking: (chunk) {
          thinkingBuf.write(chunk);
          _setState(AutoTuneLlmGenerating(
            round: round,
            thinkingText: thinkingBuf.toString(),
            responseText: responseBuf.toString(),
          ));
        },
      );
      _persistLlmTrace(
        round: round,
        emulator: emulator,
        prompt: composedPrompt ?? '(prompt not captured)',
        thinking: thinkingBuf.toString(),
        response: responseBuf.toString(),
        result: result,
      );
      return result;
    } catch (e) {
      _persistLlmTrace(
        round: round,
        emulator: emulator,
        prompt: composedPrompt ?? '(prompt not captured)',
        thinking: thinkingBuf.toString(),
        response: responseBuf.toString(),
        result: null,
        errorMessage: e.toString(),
      );
      _finish(AutoTuneFinishReason.llmError,
          round: round - 1, errorMessage: e.toString());
      return null;
    }
  }

  /// Overwrite the per-project debug trace file with the round's
  /// full LLM exchange — prompt, thinking stream, response stream,
  /// and the done_reason / token-count footer.
  ///
  /// Behavior: single file at `<emulatorDir>/last_recommendation_trace.txt`,
  /// overwritten on every round. No append, no rotation — the
  /// user always sees the most recent round's trace.
  /// Best-effort: any IO error is swallowed via debugPrint so the
  /// auto-tune flow keeps running even if the disk is read-only or
  /// the project hasn't been saved (no path to write to).
  void _persistLlmTrace({
    required int round,
    required Emulator emulator,
    required String prompt,
    required String thinking,
    required String response,
    required RecommendationResult? result,
    String? errorMessage,
  }) {
    final emulatorPath = emulator.emulatorPath;
    if (emulatorPath == null) return;
    try {
      final dir = File(emulatorPath).parent;
      final out = File('${dir.path}/last_recommendation_trace.txt');
      final modelTag = result?.model ?? '(unknown)';
      final timestamp = DateTime.now().toIso8601String();
      final buf = StringBuffer()
        ..writeln(
            '=== Auto-tune round $round | $timestamp | model: $modelTag ===')
        ..writeln()
        ..writeln('--- Prompt ---')
        ..writeln(prompt)
        ..writeln()
        ..writeln('--- Thinking ---')
        ..writeln(thinking.isEmpty ? '(no thinking emitted)' : thinking)
        ..writeln()
        ..writeln('--- Response ---')
        ..writeln(response.isEmpty ? '(no response emitted)' : response)
        ..writeln()
        ..writeln('--- Result ---');
      if (errorMessage != null) {
        buf.writeln('exception: $errorMessage');
      } else if (result == null) {
        buf.writeln('result: null (no result returned)');
      } else {
        final diag = result.diagnostic;
        buf
          ..writeln('done_reason: ${diag?.doneReason ?? "(unknown)"}')
          ..writeln('response_tokens: ${diag?.responseTokens ?? "(unknown)"}')
          ..writeln('thinking_chunks: ${diag?.thinkingChunks ?? "(unknown)"}')
          ..writeln(
              'parse_failure_kind: ${result.parseFailureKind?.name ?? "(none)"}')
          ..writeln('recommendations_count: ${result.recommendations.length}');
      }
      out.writeAsStringSync(buf.toString());
    } catch (e) {
      debugPrint('[AutoTune] failed to write LLM trace: $e');
    }
  }

  Future<_ReviewSubmission> _waitForReview() {
    final c = Completer<_ReviewSubmission>();
    _reviewCompleter = c;
    return c.future;
  }

  Future<_ParseFailureChoice> _waitForParseFailureChoice() {
    final c = Completer<_ParseFailureChoice>();
    _parseFailureCompleter = c;
    return c.future;
  }

  void _appendSnapshot({
    required int round,
    required SynthesizerResult result,
    required _LlmInputForRound? llmInput,
  }) {
    final emulator = container.read(currentEmulatorProvider);
    if (emulator == null) return;
    final manifest = result.manifest!;
    final metrics = manifest.metrics ??
        _recomputeMetrics(emulator: emulator, manifest: manifest);
    final executed =
        manifest.executedSymbols ?? container.read(executedSymbolsProvider).toList();
    final snapshot = RoundSnapshot(
      snapshotVersion: RoundSnapshot.currentVersion,
      round: round,
      synthesizerRunId: manifest.synthesizerRunId,
      createdAt: DateTime.now(),
      hookOverrides: Map<String, int>.from(
          container.read(hookOverridesProvider)),
      hookOverrideScopes: Map<String, String>.from(
          container.read(hookOverrideScopesProvider)),
      hookPreferences: Map<String, int>.from(
          container.read(hookPreferencesProvider)),
      hookBindings: Map.from(container.read(hookBindingsProvider)),
      iterationCap: container.read(synthesisMaxIterationsProvider),
      metrics: metrics,
      executedSymbols: executed,
      manifestRef: SynthesisManifestRef(runId: manifest.synthesizerRunId),
      llmRecommendations: llmInput?.recommendations,
      userDecisions: llmInput?.decisions,
      llmProse: llmInput?.prose,
    );
    final updated = emulator.appendRoundSnapshot(snapshot);
    container.read(currentEmulatorProvider.notifier).state = updated;
    container.read(emulatorDirtyProvider.notifier).state = true;
    unawaited(container.read(autosaveControllerProvider).trigger());
  }

  ManifestMetrics _recomputeMetrics({
    required Emulator emulator,
    required SynthesisManifest manifest,
  }) {
    final callGraph = emulator.cachedCallGraph!;
    final executed = container.read(executedSymbolsProvider);
    final fidelity = FidelityCalculator.compute(
      callGraph: callGraph,
      hookedSymbols: {for (final d in manifest.decisions) d.symbol},
      traversedSymbols: executed,
    );
    return ManifestMetrics(
      overallFidelity: fidelity.overallFidelity,
      coverageFidelity: fidelity.coverageFidelity,
      subgraphFidelity: fidelity.subgraphFidelity,
      intactCount: fidelity.intactFunctions,
      degradedCount: fidelity.degradedFunctions,
      hookedCount: fidelity.hookedFunctions,
    );
  }
}

/// Construct an orchestrator from a Flutter [BuildContext].
///
/// The orchestrator needs a [ProviderContainer] to drive providers
/// imperatively; Riverpod 2.x's `Ref` doesn't expose `.container`,
/// so the canonical entry point is `ProviderScope.containerOf(context)`
/// from the auto-tune button. Tests construct an orchestrator with
/// a real `ProviderContainer` directly — no helper needed there.
LlmSynthesisOrchestrator orchestratorFromContainer(
        ProviderContainer container) =>
    LlmSynthesisOrchestrator(container);

// -- State sum type ----------------------------------------------------------

/// Sealed state the auto-tune modal watches.
sealed class AutoTuneState {
  const AutoTuneState();
}

class AutoTuneIdle extends AutoTuneState {
  const AutoTuneIdle();
}

class AutoTuneRunningBaseline extends AutoTuneState {
  const AutoTuneRunningBaseline();
}

class AutoTuneSynthesizing extends AutoTuneState {
  const AutoTuneSynthesizing({required this.round});
  final int round;
}

class AutoTuneLlmGenerating extends AutoTuneState {
  const AutoTuneLlmGenerating({
    required this.round,
    required this.thinkingText,
    required this.responseText,
  });

  /// Round number the LLM is currently generating recommendations
  /// for.
  final int round;

  /// Accumulated reasoning trace tokens streamed from Ollama's
  /// `thinking` channel. Surfaced as a dimmed pane above the
  /// response so the user has something meaningful to watch while
  /// the model decides.
  final String thinkingText;

  /// Accumulated response-channel tokens (the eventual JSON
  /// payload). Surfaced as the primary streaming view.
  final String responseText;
}

/// State while an accepted [GenerateCustomHook] recommendation is
/// being authored by [LlmHookGenerator]. Hook generation is slow
/// (30-90s on a 12B model) so the modal needs a state with
/// streaming progress instead of freezing. Reuses the same
/// thinking/response stream shape as [AutoTuneLlmGenerating].
class AutoTuneGeneratingHook extends AutoTuneState {
  const AutoTuneGeneratingHook({
    required this.round,
    required this.symbol,
    required this.thinkingText,
    required this.responseText,
  });

  /// Round number whose accepted GenerateCustomHook recs are being
  /// authored. Same `round + 1`-ish display semantics as
  /// [AutoTuneSynthesizing] — the user just applied round N's
  /// recommendations.
  final int round;

  /// Symbol the hook is being generated for.
  final String symbol;

  /// Reasoning trace from the hook-gen model. Streamed live.
  final String thinkingText;

  /// Accumulated Python hook body the model is writing. Streamed
  /// into the body pane as it comes.
  final String responseText;
}

class AutoTuneReviewing extends AutoTuneState {
  const AutoTuneReviewing({required this.round, required this.result});
  final int round;
  final RecommendationResult result;
}

class AutoTuneParseFailed extends AutoTuneState {
  const AutoTuneParseFailed({
    required this.round,
    required this.raw,
    this.kind,
    this.diagnostic,
  });

  final int round;
  final String raw;

  /// Why the parser failed. When `null`, the modal falls back to the
  /// legacy "couldn't be parsed as JSON" body. New code threads
  /// [RecommendationParseFailureKind] from `RecommendationResult`
  /// through here so the modal can render a remediation tailored to
  /// the actual failure mode.
  final RecommendationParseFailureKind? kind;

  /// Diagnostic stats from Ollama's final NDJSON line, present when
  /// [kind] is [RecommendationParseFailureKind.emptyResponse]. Lets
  /// the modal show `done_reason`, response/thinking token counts so
  /// the user knows exactly why no response landed.
  final RecommendationDiagnostic? diagnostic;
}

class AutoTuneFinished extends AutoTuneState {
  const AutoTuneFinished({
    required this.reason,
    required this.finalRound,
    this.errorMessage,
  });
  final AutoTuneFinishReason reason;
  final int finalRound;
  final String? errorMessage;
}

/// Exit reasons surfaced by [AutoTuneFinished]. Matches the
/// taxonomy in the plan.
enum AutoTuneFinishReason {
  baselineFailed,
  parseFailed,
  llmEmpty,
  userStopped,
  userRejectedAll,
  noProgressOnSymbol,
  cancelled,
  maxRounds,
  synthesisError,
  llmError,
}

// -- Internal helper types ---------------------------------------------------

class _ReviewSubmission {
  const _ReviewSubmission({
    required this.decisions,
    this.userStopped = false,
    this.cancelled = false,
  });
  final List<RecommendationDecision> decisions;
  final bool userStopped;
  final bool cancelled;
}

enum _ParseFailureChoice { retry, stop }

class _LlmInputForRound {
  const _LlmInputForRound({
    required this.recommendations,
    required this.decisions,
    required this.prose,
  });
  final List<Recommendation> recommendations;
  final List<RecommendationDecision> decisions;
  final String prose;
}
