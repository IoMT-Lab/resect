import 'dart:async';

import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/trace_activity_event.dart';
import 'package:emulator_orchestrator/data/services/llm_hook_generator.dart'
    show PlatformFacts;
import 'package:emulator_orchestrator/orchestrator/events/orchestrator_events.dart';
import 'package:emulator_orchestrator/orchestrator/events/synthesizer_events.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import '../../../providers/autosave_provider.dart';
import '../../../providers/comms_bus_provider.dart';
import '../../../providers/comms_config_providers.dart';

/// Owns the synthesizer / emulation launch lifecycle.
///
/// Extracted from the graph viewer's old `_emulate` so the Synthesize tab
/// can drive synthesis while the Call Graph viewer continues to animate off
/// the same shared providers ([executedSymbolsProvider],
/// [hookedSymbolsProvider], etc.). The controller owns the stream
/// subscriptions; all user-facing dialogs stay in the UI.
class SynthesisController {
  SynthesisController(this.ref);
  final Ref ref;

  StreamSubscription? _traceSub;
  StreamSubscription? _filteredTraceSub;
  StreamSubscription? _synthEventSub;
  StreamSubscription? _pauseSub;

  /// "Synthesize" path — clears visual state, (re)starts emulation, then runs
  /// the synthesizer loop. Throws on failure; callers show the error.
  ///
  /// [resolvedHooks] is normally empty for a fresh synthesis; pass previously
  /// resolved hook code to warm-start.
  Future<void> startSynthesis(
    Emulator emulator, {
    Map<String, String> resolvedHooks = const {},
  }) async {
    final orchestrator = ref.read(emulationOrchestratorProvider);
    final elfPath = emulator.elfFilePath!;
    final baseImagePath = emulator.baseImagePath!;
    final config = emulator.emulationConfig;
    final hookOverrides = ref.read(hookOverridesProvider);
    final hookOverrideScopes = ref.read(hookOverrideScopesProvider);

    // Reset visual state so highlights start fresh.
    ref.read(executedSymbolsProvider.notifier).state = {};
    ref.read(hookedSymbolsProvider.notifier).state = {};
    ref.read(synthesisResultProvider.notifier).state = null;
    ref.read(traceActivityEventsProvider.notifier).state = [];

    ref.read(synthesisProgressProvider.notifier).state = SynthesisProgress(
      countdownStart: DateTime.now(),
      status: 'Starting emulation...',
    );

    _subscribeTrace();

    // Synthesizer manages pauses internally — don't subscribe to pause events.
    _pauseSub?.cancel();
    _pauseSub = null;

    final commsHooks = buildCommsHooks(
      emulator: emulator,
      configs: ref.read(commsProtocolConfigProvider),
      catalog: ref.read(hookCatalogProvider),
    );

    await orchestrator.restartEmulation(
      elfPath: elfPath,
      baseImagePath: baseImagePath,
      startFrom: config.startFrom,
      pauseOnUnhandled: true,
      hookOverrides: hookOverrides,
      hookOverrideScopes: hookOverrideScopes,
      resolvedHooks: resolvedHooks,
      commsHooks: commsHooks,
      memoryMapPath: config.memoryMapPath,
    );

    final firmwareRecord = ref.read(artifactProcessingProvider).valueOrNull;
    if (firmwareRecord == null) {
      ref.read(synthesisProgressProvider.notifier).state = null;
      throw StateError(
        'Firmware not processed. Ensure the call graph has loaded.',
      );
    }
    final elfHash = firmwareRecord.elfHash;

    ref.read(synthesisProgressProvider.notifier).state = SynthesisProgress(
      countdownStart: DateTime.now(),
      status: 'Emulation running...',
    );

    _subscribeSynthesizerEvents(emulator);

    final hookPreferences = ref.read(hookPreferencesProvider);
    final hookBindings = ref.read(hookBindingsProvider);
    final llmGenerator = ref.read(llmHookGeneratorProvider);
    final platform = await PlatformFacts.tryBuild(
      replPath: baseImagePath,
      archString: firmwareRecord.machine?.name,
      firmwareSymbols: emulator.cachedCallGraph?.symbols.keys ?? const <String>[],
    );
    await orchestrator.runSynthesizer(
      elfPath: elfPath,
      baseImagePath: baseImagePath,
      elfHash: elfHash,
      startFrom: config.startFrom,
      endAt: config.endAt,
      hookPreferences: hookPreferences,
      hookOverrides: hookOverrides,
      hookOverrideScopes: hookOverrideScopes,
      resolvedHooks: resolvedHooks,
      commsHooks: commsHooks,
      hookBindings: hookBindings,
      memoryMapPath: config.memoryMapPath,
      llmGenerator: llmGenerator,
      platform: platform,
    );
  }

  /// "Run" path — execute with the emulator's existing resolved hooks (and
  /// forced overrides), no synthesis loop. Subscribes to pause events so the
  /// trace feed reflects them. Throws on failure.
  Future<void> runWithResolvedHooks(Emulator emulator) async {
    final orchestrator = ref.read(emulationOrchestratorProvider);
    final elfPath = emulator.elfFilePath!;
    final baseImagePath = emulator.baseImagePath!;
    final config = emulator.emulationConfig;
    final hookOverrides = ref.read(hookOverridesProvider);
    final hookOverrideScopes = ref.read(hookOverrideScopesProvider);

    ref.read(executedSymbolsProvider.notifier).state = {};
    ref.read(synthesisResultProvider.notifier).state = null;
    ref.read(traceActivityEventsProvider.notifier).state = [];
    _synthEventSub?.cancel();

    ref.read(hookedSymbolsProvider.notifier).state = <String>{
      ...emulator.hooks.keys,
      ...hookOverrides.keys,
    };

    _subscribeTrace();
    _subscribePauseEvents();

    final commsHooks = buildCommsHooks(
      emulator: emulator,
      configs: ref.read(commsProtocolConfigProvider),
      catalog: ref.read(hookCatalogProvider),
    );

    await orchestrator.restartEmulation(
      elfPath: elfPath,
      baseImagePath: baseImagePath,
      startFrom: config.startFrom,
      endAt: config.endAt,
      pauseOnUnhandled: config.pauseOnUnhandled,
      hookOverrides: hookOverrides,
      hookOverrideScopes: hookOverrideScopes,
      resolvedHooks: emulator.hooks,
      commsHooks: commsHooks,
      memoryMapPath: config.memoryMapPath,
    );
  }

  /// Cancel an in-flight synthesis. The synthesizer loop exits at its next
  /// iteration check; its finally block resets Renode state.
  void stopSynthesis() {
    ref.read(synthesisProgressProvider.notifier).state = null;
    ref.read(emulationOrchestratorProvider).synthesizerWorkflow.cancel();
  }

  /// Pause a running emulation.
  Future<void> pause() async {
    await ref.read(emulationOrchestratorProvider).pauseEmulation();
  }

  /// Reset emulation and clear all live state.
  Future<void> reset() async {
    final orchestrator = ref.read(emulationOrchestratorProvider);
    await orchestrator.resetEmulation();
    _cancelSubscriptions();
    ref.read(executedSymbolsProvider.notifier).state = {};
    ref.read(hookedSymbolsProvider.notifier).state = {};
    ref.read(synthesisProgressProvider.notifier).state = null;
    ref.read(synthesisResultProvider.notifier).state = null;
    ref.read(traceActivityEventsProvider.notifier).state = [
      TraceActivityEvent.reset(),
    ];
  }

  // ---------------------------------------------------------------------------
  // Subscriptions
  // ---------------------------------------------------------------------------

  void _subscribeTrace() {
    final traceSource = ref.read(emulationOrchestratorProvider).traceSource;
    _traceSub?.cancel();
    _traceSub = traceSource.traceStream.listen((event) {
      if (!event.isEntry) return;
      final executed = ref.read(executedSymbolsProvider);
      if (!executed.contains(event.symbol)) {
        ref
            .read(executedSymbolsProvider.notifier)
            .update((state) => {...state, event.symbol});
      }
    });

    _filteredTraceSub?.cancel();
    _filteredTraceSub = traceSource.filteredTraceStream.listen((event) {
      if (!event.isEntry) return;
      final current = ref.read(traceActivityEventsProvider);
      ref.read(traceActivityEventsProvider.notifier).state = [
        ...current,
        TraceActivityEvent.functionCall(event.symbol),
      ];
    });
  }

  void _subscribePauseEvents() {
    final orchestrator = ref.read(emulationOrchestratorProvider);
    _pauseSub?.cancel();
    _pauseSub = orchestrator.events.listen((event) {
      if (event is EmulationPausedEvent) {
        final current = ref.read(traceActivityEventsProvider);
        ref.read(traceActivityEventsProvider.notifier).state = [
          ...current,
          TraceActivityEvent.paused(event.pauseDetails),
        ];
      } else if (event is EmulationStateChangedEvent &&
          event.state == EmulationState.running) {
        final current = ref.read(traceActivityEventsProvider);
        ref.read(traceActivityEventsProvider.notifier).state = [
          ...current,
          TraceActivityEvent.resumed(),
        ];
      }
    });
  }

  void _subscribeSynthesizerEvents(Emulator emulator) {
    final orchestrator = ref.read(emulationOrchestratorProvider);
    _synthEventSub?.cancel();
    _synthEventSub = orchestrator.synthesizerWorkflow.events.listen((event) {
      final current = ref.read(synthesisProgressProvider);
      if (current == null) return;

      if (event is SynthesizerIterationStarted) {
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          iteration: event.iteration,
          status: 'Iteration ${event.iteration}',
          countdownStart: DateTime.now(),
        );
      } else if (event is SynthesizerHookApplied) {
        ref
            .read(hookedSymbolsProvider.notifier)
            .update((state) => {...state, event.symbol});
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          hooksApplied: current.hooksApplied + 1,
          currentSymbol: event.symbol,
          status: 'Hook: ${event.hookName}',
          countdownStart: DateTime.now(),
        );
      } else if (event is SynthesizerSymbolExhausted) {
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          currentSymbol: event.symbol,
          status: 'Exhausted: ${event.symbol}',
        );
      } else if (event is SynthesizerCompleted) {
        final result = event.result;
        ref.read(synthesisResultProvider.notifier).state = result;
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          complete: true,
          success: result.success,
          status: result.success
              ? 'Complete — ${result.resolvedHooks.length} hooks'
              : 'Failed at ${result.failedSymbol}',
        );
        if (result.resolvedHookCode.isNotEmpty) {
          ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
            hooks: result.resolvedHookCode,
            modifiedAt: DateTime.now(),
          );
          ref.read(emulatorDirtyProvider.notifier).state = true;
        }
        unawaited(ref.read(autosaveControllerProvider).trigger());
      }
    });
  }

  void _cancelSubscriptions() {
    _traceSub?.cancel();
    _filteredTraceSub?.cancel();
    _synthEventSub?.cancel();
    _pauseSub?.cancel();
    _traceSub = null;
    _filteredTraceSub = null;
    _synthEventSub = null;
    _pauseSub = null;
  }

  void dispose() => _cancelSubscriptions();
}

final synthesisControllerProvider = Provider<SynthesisController>((ref) {
  final controller = SynthesisController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});
