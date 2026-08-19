import 'dart:async';
import 'dart:io';

import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_report_writer.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import '../../../providers/auto_tune_session_provider.dart';
import '../../../providers/comms_bus_provider.dart';
import '../../../providers/comms_config_providers.dart';
import '../../../providers/comms_session_scope.dart';
import 'synthesis_controller.dart';
import 'ui_auto_tune_sink.dart';
import 'ui_review_policy.dart';

/// The auto-tune orchestrator whose session the Synthesize tab is
/// currently rendering inline (null = no active/undismissed session).
/// Set by the Auto-tune launch flow; cleared (and the orchestrator
/// disposed) by the panel's Close button.
final autoTuneOrchestratorProvider =
    StateProvider<LlmSynthesisOrchestrator?>((ref) => null);

/// UI adapter for the shared [AutoTuneEngine] — the closed-loop
/// LLM-orchestrated synthesizer.
///
/// The loop itself lives in the orchestrator package and is the SAME
/// engine `resect-cli autotune` drives: stagnation escalation, no-op
/// filtering, per-round recommendation caps, named stop reasons — one
/// implementation, two surfaces. This class is pure wiring:
///
/// - a [UiReviewPolicy] pauses the loop for the modal's
///   Accept/Reject/Edit (or auto-accepts, per session choice),
/// - a [UiAutoTuneSink] maps engine events onto the modal's
///   [AutoTuneState]s and persists round snapshots onto the project,
/// - an [AutoTuneReportSink] writes the same report files a CLI
///   session writes (`round_NN.md`, `round_NN_trace.txt`,
///   `summary.md`) into `<projectDir>/autotune_reports/<timestamp>/`,
/// - a `runSynthesis` adapter mirrors the engine's overlays into the
///   shadow providers and runs [SynthesisController].
///
/// Exposes a [ChangeNotifier]-based [state] the auto-tune modal
/// listens to, plus [roundLines] — a compact per-round session strip.
/// `runAutoTune` is single-flight and throws on re-entry.
class LlmSynthesisOrchestrator extends ChangeNotifier {
  LlmSynthesisOrchestrator(this.container);

  /// Riverpod container the adapter reads providers from.
  /// Production: `ProviderScope.containerOf(context)`. Tests: a
  /// real `ProviderContainer`.
  final ProviderContainer container;

  AutoTuneState _state = const AutoTuneIdle();
  AutoTuneState get state => _state;

  final List<AutoTuneRoundLine> _roundLines = [];

  /// One compact line per completed round (outcome, fidelity,
  /// executed count/delta) — the modal's session strip. Full detail
  /// is in the written report files.
  List<AutoTuneRoundLine> get roundLines => List.unmodifiable(_roundLines);

  /// Drive the adapter's state directly. Intended for widget tests
  /// that render the modal against a scripted state sequence without
  /// invoking the real loop (no LLM, no Renode, no services).
  /// Production code routes through [runAutoTune].
  @visibleForTesting
  void setStateForTest(AutoTuneState newState) {
    _setState(newState);
  }

  AutoTuneEngine? _engine;
  UiReviewPolicy? _policy;

  /// Warm-start carry: the previous round's resolved hook code,
  /// session-local. Only consulted when the session's config enables
  /// warm start.
  Map<String, String> _carriedHooks = const {};

  /// Run a complete auto-tune session against the currently-open
  /// project. Returns when the loop terminates (any reason); the
  /// final state is available on [state].
  ///
  /// [interactiveReview] selects the review mode chosen at session
  /// start: true pauses each round for the modal's review, false
  /// auto-accepts every recommendation (the CLI's behavior).
  ///
  /// Throws [StateError] if a session is already in progress or
  /// the project hasn't been saved (snapshots and report files need
  /// a project directory).
  Future<void> runAutoTune(
    AutoTuneConfig config, {
    bool interactiveReview = true,
  }) async {
    if (_state is! AutoTuneIdle && _state is! AutoTuneFinished) {
      throw StateError('Auto-tune already in progress.');
    }
    var emulator = container.read(currentEmulatorProvider);
    if (emulator == null) {
      throw StateError('No project loaded.');
    }
    final emulatorPath = emulator.emulatorPath;
    if (emulatorPath == null) {
      throw StateError(
          'Save the project before starting auto-tune so snapshots '
          'persist.');
    }

    // Session inputs the engine needs up front.
    final callGraph = emulator.cachedCallGraph ??
        container.read(callgraphProvider).valueOrNull;
    if (callGraph == null) {
      throw StateError('No call graph loaded.');
    }
    final elfHash =
        container.read(artifactProcessingProvider).valueOrNull?.elfHash ??
            emulator.synthesisResult?.manifest?.elfHash;
    if (elfHash == null) {
      throw StateError(
          'Firmware not processed. Ensure the call graph has loaded.');
    }

    // Apply the session's snapshot cap to the project so
    // appendRoundSnapshot prunes to what the dialog asked for.
    emulator = emulator.copyWith(roundSnapshotCap: config.snapshotCap);
    container.read(currentEmulatorProvider.notifier).state = emulator;

    _roundLines.clear();
    _carriedHooks = const {};
    _setState(const AutoTuneRunningBaseline());

    // Baseline seeding: skip the round-0 synthesis when the project
    // already holds a fresh result (its runId isn't snapshotted yet).
    final lastSnapshot = emulator.latestSnapshot;
    final needsBaseline = lastSnapshot == null ||
        emulator.synthesisResult?.manifest?.synthesizerRunId !=
            lastSnapshot.synthesizerRunId;
    final seedBaseline = needsBaseline ? null : emulator.synthesisResult;

    // Comms bracket — one session-scoped acquire, shared by every
    // round, released when the session ends (mirrors the CLI's
    // try/finally around the whole autotune run).
    final comms = await CommsSessionScope.acquire(
      emulator: emulator,
      tabConfigs: container.read(commsProtocolConfigProvider),
      bus: container.read(commsBusServiceProvider),
      catalog: container.read(hookCatalogProvider),
    );

    try {
      final symbolGroups =
          SymbolGroupClassifier(catalog: container.read(hookCatalogProvider))
              .classify(
        callGraph.symbols.keys,
        exclude: comms.hooks.keys.toSet(),
      );

      // Report files — the identical set a CLI session writes, in the
      // identical location. Manifests are not double-written: the
      // SynthesisController already writes manifests/<run_id>.json.
      final startedAt = DateTime.now();
      final projectDir = File(emulatorPath).parent.path;
      final reportDir = Directory('$projectDir/autotune_reports/'
          '${startedAt.toIso8601String().replaceAll(':', '-')}');
      // A fresh session replaces whatever the session view was showing
      // (a previous live run or a disk-hydrated one).
      container
          .read(autoTuneSessionProvider.notifier)
          .beginLive(reportDir.path, maxRounds: config.maxRounds);
      final reportSink = AutoTuneReportSink(
        reportDir: reportDir,
        callGraph: callGraph,
        startedAt: startedAt,
        artifactLabels:
            await artifactLabelsFor(container.read(artifactDatabaseProvider)),
        color: false,
        log: debugPrint,
      );
      final uiSink = UiAutoTuneSink(
        container: container,
        emitState: _setState,
        onRoundLine: (line) {
          _roundLines.add(line);
          notifyListeners();
        },
      );

      final policy = UiReviewPolicy(
        emitState: _setState,
        interactive: interactiveReview,
      );
      _policy = policy;

      final engine = AutoTuneEngine(
        runSynthesis: _makeRunSynthesis(config, comms),
        recommendationService: container.read(recommendationServiceProvider),
        artifactDb: container.read(artifactDatabaseProvider),
        hookGenerator: container.read(llmHookGeneratorProvider),
        reviewPolicy: policy,
        sink: MultiSink([uiSink, reportSink]),
        symbolGroups: symbolGroups,
        ragStatus: () async {
          final index = container.read(ragIndexProvider);
          final project = container.read(currentEmulatorProvider);
          if (index == null || project == null) return null;
          return index.statusSnapshot(project);
        },
      );
      _engine = engine;

      await engine.run(
        project: emulator,
        elfHash: elfHash,
        callGraph: callGraph,
        config: config,
        commsConfigs: comms.status,
        seedBaseline: seedBaseline,
        iterationCap: container.read(synthesisMaxIterationsProvider),
      );
    } finally {
      await comms.release();
      _engine = null;
      _policy = null;
      _carriedHooks = const {};
    }
  }

  /// The engine's synthesis seam: mirror the round's overlays into the
  /// shadow providers (SynthesisController reads them), run the shared
  /// controller, and hand back the enriched result. Cold start (the
  /// default) runs every round from the overlay set alone; warm start
  /// carries the previous round's resolved hooks forward.
  RunSynthesis _makeRunSynthesis(
          AutoTuneConfig config, CommsSessionScope comms) =>
      (overlays, round) async {
      final emulator = container.read(currentEmulatorProvider);
      if (emulator == null) return null;

      // Pre-run mirror: providers must reflect the engine's overlay
      // state before startSynthesis reads them. Group overrides have
      // no shadow provider — they ride the Emulator.
      container.read(hookOverridesProvider.notifier).state =
          Map<String, int>.from(overlays.hookOverrides);
      container.read(hookOverrideScopesProvider.notifier).state =
          Map<String, String>.from(overlays.hookOverrideScopes);
      container.read(hookPreferencesProvider.notifier).state =
          Map<String, int>.from(overlays.hookPreferences);
      container.read(hookBindingsProvider.notifier).state =
          Map.from(overlays.hookBindings);
      container.read(synthesisMaxIterationsProvider.notifier).state =
          overlays.iterationCap;
      final withGroups =
          emulator.copyWith(groupOverrides: Map.from(overlays.groupOverrides));
      container.read(currentEmulatorProvider.notifier).state = withGroups;

      try {
        await container.read(synthesisControllerProvider).startSynthesis(
              withGroups,
              resolvedHooks: config.warmStart ? _carriedHooks : const {},
              commsSession: comms,
              persistResolvedHooks: config.warmStart,
            );
      } catch (e) {
        debugPrint('[AutoTune] synthesis failed in round $round: $e');
        return null;
      }
      // Yield once so the SynthesisController's stream listener has a
      // chance to enrich + publish synthesisResultProvider before we
      // read it back.
      await Future<void>.delayed(Duration.zero);
      final result = container.read(synthesisResultProvider);
      if (config.warmStart && result != null) {
        _carriedHooks = result.resolvedHookCode;
      }
      return result;
    };

  // -- Modal-facing methods, delegated to the policy/engine -------------------

  /// Called by the modal when the user clicks Apply-and-continue.
  void submitReview(List<RecommendationDecision> decisions) =>
      _policy?.submitReview(decisions);

  /// Called by the modal when the user clicks Stop during review.
  void stopAfterReview(List<RecommendationDecision> decisions) =>
      _policy?.stopAfterReview(decisions);

  /// Called by the modal when the user clicks Cancel. The engine
  /// drops out at its next checkpoint; the policy unblocks any
  /// pending review (the engine never does that itself).
  void cancel() {
    _engine?.cancel();
    _policy?.cancel();
  }

  /// Called by the modal when the user clicks Retry on the
  /// parse-failure notice.
  void retryAfterParseFailure() => _policy?.retryAfterParseFailure();

  /// Called by the modal when the user clicks Stop on the
  /// parse-failure notice.
  void stopAfterParseFailure() => _policy?.stopAfterParseFailure();

  void _setState(AutoTuneState newState) {
    _state = newState;
    notifyListeners();
  }
}

// -- State sum type ----------------------------------------------------------

/// Sealed state the auto-tune modal watches. Emitted by the
/// [UiAutoTuneSink] (progress phases, finished) and the
/// [UiReviewPolicy] (reviewing, parse-failed) — the engine itself
/// knows nothing about these types.
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

/// Exit reasons surfaced by [AutoTuneFinished] — the engine's stop
/// reasons, verbatim. Kept as a typedef so existing UI code and tests
/// keep compiling while the two surfaces share one taxonomy.
typedef AutoTuneFinishReason = AutoTuneStopReason;
