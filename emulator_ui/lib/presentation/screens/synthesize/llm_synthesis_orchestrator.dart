import 'dart:async';

import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/data/services/fidelity_calculator.dart';
import 'package:emulator_orchestrator/data/services/recommendation_service.dart';
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
  DateTime? _sessionStart;

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
    _sessionStart = DateTime.now();
    _setState(const AutoTuneRunningBaseline());

    // Round 0: baseline. Run a synthesis if we don't have a recent
    // snapshot already.
    var current = container.read(currentEmulatorProvider)!;
    final lastSnapshot = current.latestSnapshot;
    final needsBaseline = lastSnapshot == null ||
        current.synthesisResult?.manifest?.synthesizerRunId !=
            lastSnapshot.synthesizerRunId;

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
    }

    // Rounds 1..maxRounds.
    var round = 1;
    while (round <= config.maxRounds) {
      if (_cancelled) {
        _finish(AutoTuneFinishReason.cancelled, round: round - 1);
        return;
      }
      if (_budgetExhausted(config)) {
        _finish(AutoTuneFinishReason.budgetExhausted, round: round - 1);
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
        _setState(AutoTuneParseFailed(
          round: round,
          raw: llmResult.raw ?? '',
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

      // Apply the user-approved batch. GenerateCustomHook recs are
      // currently logged-and-dropped — full wiring (calling
      // LlmHookGenerator + seeding the new binding) is the next
      // increment. The Applier drops them silently per its contract.
      final generateRecs =
          acceptedOrEdited.whereType<GenerateCustomHook>().toList();
      if (generateRecs.isNotEmpty) {
        debugPrint(
            '[AutoTune] ${generateRecs.length} GenerateCustomHook '
            'recommendation(s) accepted but not yet wired — they '
            'will be dropped by the applier.');
      }
      const applier = RecommendationApplier();
      applier.apply(container, acceptedOrEdited);

      // Run synthesis with the new overlay.
      _setState(AutoTuneSynthesizing(round: round));
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

      // Same-symbol no-progress check.
      final priorSnap = container
          .read(currentEmulatorProvider)
          ?.snapshotForRound(round - 1);
      final priorFailed = priorSnap?.manifestRef.runId == null
          ? null
          : container
              .read(currentEmulatorProvider)
              ?.synthesisResult
              ?.manifest
              ?.failedSymbol;
      // Best-effort: compare last manifest's failed_symbol with
      // what's on the snapshot's manifest. The snapshot doesn't
      // carry failed_symbol directly; for now we look at the prior
      // ROUND's manifest via the on-disk manifestRef if available.
      // Until manifestRef.failedSymbol lands, we fall back to a
      // simpler check using the live synthesisResultProvider.
      final priorRoundFailed = priorFailed;
      final currentFailed = runResult.manifest!.failedSymbol;
      if (currentFailed != null &&
          priorRoundFailed != null &&
          currentFailed == priorRoundFailed) {
        _finish(AutoTuneFinishReason.noProgressOnSymbol, round: round);
        return;
      }

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

  bool _budgetExhausted(AutoTuneConfig config) {
    final start = _sessionStart;
    if (start == null) return false;
    return DateTime.now().difference(start) > config.maxWallClock;
  }

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
    _setState(AutoTuneLlmGenerating(round: round, streamedText: ''));
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
    final service = container.read(recommendationServiceProvider);
    final buf = StringBuffer();
    try {
      return await service.recommend(
        currentManifest: manifest,
        currentState: overlayState,
        callGraph: callGraph,
        history: history,
        optimizationTarget: config.optimizationTarget,
        onToken: (tok) {
          buf.write(tok);
          _setState(AutoTuneLlmGenerating(
            round: round,
            streamedText: buf.toString(),
          ));
        },
      );
    } catch (e) {
      _finish(AutoTuneFinishReason.llmError,
          round: round - 1, errorMessage: e.toString());
      return null;
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
    required this.streamedText,
  });
  final int round;
  final String streamedText;
}

class AutoTuneReviewing extends AutoTuneState {
  const AutoTuneReviewing({required this.round, required this.result});
  final int round;
  final RecommendationResult result;
}

class AutoTuneParseFailed extends AutoTuneState {
  const AutoTuneParseFailed({required this.round, required this.raw});
  final int round;
  final String raw;
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
  budgetExhausted,
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
