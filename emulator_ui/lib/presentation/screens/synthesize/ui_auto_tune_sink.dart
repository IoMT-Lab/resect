import 'dart:async';

import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import '../../../providers/auto_tune_session_provider.dart';
import '../../../providers/autosave_provider.dart';
import 'llm_synthesis_orchestrator.dart'
    show
        AutoTuneFinished,
        AutoTuneGeneratingHook,
        AutoTuneLlmGenerating,
        AutoTuneRunningBaseline,
        AutoTuneState,
        AutoTuneSynthesizing;

/// Compact one-line summary of a completed round, for the modal's
/// session strip. Full detail lives in the written report files.
class AutoTuneRoundLine {
  const AutoTuneRoundLine({
    required this.round,
    required this.outcome,
    required this.overallFidelity,
    required this.executedCount,
    required this.executedDelta,
    this.reverted = false,
  });

  final int round;
  final String outcome;
  final double overallFidelity;
  final int executedCount;

  /// Executed-symbol count change vs the previous reported round
  /// (0 for the first line).
  final int executedDelta;

  /// True when the engine measured this round, saw coverage collapse,
  /// and rolled its changes back — the strip marks it so a reverted
  /// round doesn't read as a kept one.
  final bool reverted;
}

/// [AutoTuneSink] that feeds the auto-tune modal: maps engine phases
/// onto the modal's [AutoTuneState] sum type, accumulates the engine's
/// DELTA token/thinking chunks into cumulative text, persists each
/// round's snapshot into the project (the engine never touches the
/// Emulator — this sink is the sole persistence hook), mirrors the
/// engine's overlays back into the shadow providers, and emits a
/// compact [AutoTuneRoundLine] per round.
///
/// All methods are synchronous per the sink contract; the autosave
/// trigger is fire-and-forget.
class UiAutoTuneSink implements AutoTuneSink {
  UiAutoTuneSink({
    required this.container,
    required this.emitState,
    required this.onRoundLine,
  });

  final ProviderContainer container;
  final void Function(AutoTuneState state) emitState;
  final void Function(AutoTuneRoundLine line) onRoundLine;

  final _thinkingBuf = StringBuffer();
  final _responseBuf = StringBuffer();
  var _lastPhase = AutoTunePhase.baseline;
  int _lastRound = 0;
  String? _lastSymbol;
  int? _prevExecutedCount;

  @override
  void phase(AutoTunePhase phase, {int round = 0, String? symbol}) {
    _lastPhase = phase;
    _lastRound = round;
    _lastSymbol = symbol;
    _thinkingBuf.clear();
    _responseBuf.clear();
    switch (phase) {
      case AutoTunePhase.baseline:
        emitState(const AutoTuneRunningBaseline());
      case AutoTunePhase.llmGenerating:
        emitState(AutoTuneLlmGenerating(
            round: round, thinkingText: '', responseText: ''));
      case AutoTunePhase.generatingHook:
        emitState(AutoTuneGeneratingHook(
            round: round,
            symbol: symbol ?? '?',
            thinkingText: '',
            responseText: ''));
      case AutoTunePhase.synthesizing:
        emitState(AutoTuneSynthesizing(round: round));
    }
  }

  @override
  void thinking(String chunk) {
    _thinkingBuf.write(chunk);
    _emitStreaming();
  }

  @override
  void token(String token) {
    _responseBuf.write(token);
    _emitStreaming();
  }

  /// Re-emit the current streaming state with cumulative buffers —
  /// the engine streams deltas, the modal renders totals. Routing
  /// depends on the last phase: recommendation tokens vs hook-gen
  /// tokens are indistinguishable at the sink otherwise.
  void _emitStreaming() {
    switch (_lastPhase) {
      case AutoTunePhase.generatingHook:
        emitState(AutoTuneGeneratingHook(
          round: _lastRound,
          symbol: _lastSymbol ?? '?',
          thinkingText: _thinkingBuf.toString(),
          responseText: _responseBuf.toString(),
        ));
      case AutoTunePhase.baseline:
      case AutoTunePhase.llmGenerating:
      case AutoTunePhase.synthesizing:
        emitState(AutoTuneLlmGenerating(
          round: _lastRound,
          thinkingText: _thinkingBuf.toString(),
          responseText: _responseBuf.toString(),
        ));
    }
  }

  @override
  void llmExchange(AutoTuneLlmExchange exchange) {
    // File writing (round_NN_trace.txt) is the report sink's job.
  }

  @override
  void round(AutoTuneRoundReport report) {
    final snapshot = report.snapshot;

    // 1. Persist the snapshot onto the project. Group overrides have
    //    no shadow provider — they live on the Emulator itself, so
    //    the engine's view is written back here too.
    final emulator = container.read(currentEmulatorProvider);
    if (emulator != null) {
      final updated = emulator
          .copyWith(groupOverrides: snapshot.groupOverrides)
          .appendRoundSnapshot(snapshot);
      container.read(currentEmulatorProvider.notifier).state = updated;

      // 2. Mirror the round's overlays into the shadow providers so
      //    the rest of the UI (metadata panel, decision state) shows
      //    what the session actually ran with. Idempotent with the
      //    pre-run mirror in the runSynthesis adapter.
      container.read(hookOverridesProvider.notifier).state =
          Map<String, int>.from(snapshot.hookOverrides);
      container.read(hookOverrideScopesProvider.notifier).state =
          Map<String, String>.from(snapshot.hookOverrideScopes);
      container.read(hookPreferencesProvider.notifier).state =
          Map<String, int>.from(snapshot.hookPreferences);
      container.read(hookBindingsProvider.notifier).state =
          Map<String, HookBinding>.from(snapshot.hookBindings);
      container.read(synthesisMaxIterationsProvider.notifier).state =
          snapshot.iterationCap;

      container.read(emulatorDirtyProvider.notifier).state = true;
      unawaited(container.read(autosaveControllerProvider).trigger());
    }

    // 3. Feed the session view: the folded manifest (metrics, stops,
    //    phase timings, census) + snapshot, straight from the report —
    //    the same record the report files are rendered from. A result
    //    with no manifest (possible in scripted tests) has nothing for
    //    the session view.
    final manifest = report.result.manifest;
    if (manifest != null) {
      container.read(autoTuneSessionProvider.notifier).addRound(
            AutoTuneSessionRoundRecord(
              round: report.round,
              manifest: manifest,
              snapshot: snapshot,
            ),
          );
    }

    // 4. The compact strip line.
    final executedCount = snapshot.executedSymbols.length;
    final result = report.result;
    final outcome = result.success
        ? 'success'
        : result.failedSymbol != null
            ? 'failed @${result.failedSymbol}'
            : 'no-converge';
    onRoundLine(AutoTuneRoundLine(
      round: report.round,
      outcome: outcome,
      overallFidelity: report.metrics.overallFidelity,
      executedCount: executedCount,
      executedDelta:
          _prevExecutedCount == null ? 0 : executedCount - _prevExecutedCount!,
      reverted: report.reverted,
    ));
    _prevExecutedCount = executedCount;
  }

  @override
  void finished(AutoTuneStopReason reason,
      {required int finalRound, String? errorMessage}) {
    container
        .read(autoTuneSessionProvider.notifier)
        .finishLive(reason.name, errorMessage: errorMessage);
    emitState(AutoTuneFinished(
      reason: reason,
      finalRound: finalRound,
      errorMessage: errorMessage,
    ));
  }
}
