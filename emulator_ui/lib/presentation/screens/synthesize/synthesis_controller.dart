import 'dart:async';
import 'dart:io';

import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/data/models/trace_activity_event.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart'
    show enrichSynthesizerResult;
import 'package:emulator_orchestrator/orchestrator/events/orchestrator_events.dart';
import 'package:emulator_orchestrator/orchestrator/events/synthesizer_events.dart';
import 'package:emulator_orchestrator/services/analysis/fidelity_calculator.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart'
    show PlatformFacts;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import '../../../providers/autosave_provider.dart';
import '../../../providers/comms_bus_provider.dart';
import '../../../providers/comms_config_providers.dart';
import '../../../providers/comms_session_scope.dart';

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

  /// Comms session owned by [runWithResolvedHooks] — that path starts
  /// emulation and returns while the firmware keeps running, so its bus
  /// servers must outlive the method. Released on reset/dispose/next run.
  CommsSessionScope? _ownedCommsSession;

  Future<CommsSessionScope> _acquireComms(Emulator emulator) =>
      CommsSessionScope.acquire(
        emulator: emulator,
        tabConfigs: ref.read(commsProtocolConfigProvider),
        bus: ref.read(commsBusServiceProvider),
        catalog: ref.read(hookCatalogProvider),
      );

  /// "Synthesize" path — clears visual state, (re)starts emulation, then runs
  /// the synthesizer loop. Throws on failure; callers show the error.
  ///
  /// [resolvedHooks] is normally empty for a fresh synthesis; pass previously
  /// resolved hook code to warm-start. [commsSession] lets a caller (the
  /// auto-tune session) own the comms bracket across rounds; when null this
  /// run acquires and releases its own. [persistResolvedHooks] controls the
  /// post-run writeback of resolved hook code into the project — cold-start
  /// auto-tune rounds pass false so independent rounds don't overwrite
  /// `Emulator.hooks`.
  Future<void> startSynthesis(
    Emulator emulator, {
    Map<String, String> resolvedHooks = const {},
    CommsSessionScope? commsSession,
    bool persistResolvedHooks = true,
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

    // Comms bracket: same defaults as the CLI (i2c/uart/spi zero-fill)
    // unless the Comms tab configured protocols. A plain run owns its
    // scope for exactly the length of the synthesis.
    await _ownedCommsSession?.release();
    _ownedCommsSession = null;
    final ownComms = commsSession == null;
    final comms = commsSession ?? await _acquireComms(emulator);
    final commsHooks = comms.hooks;

    try {
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

      _subscribeSynthesizerEvents(emulator,
          persistResolvedHooks: persistResolvedHooks);

      final hookPreferences = ref.read(hookPreferencesProvider);
      final hookBindings = ref.read(hookBindingsProvider);
      final llmGenerator = ref.read(llmHookGeneratorProvider);
      final platform = await PlatformFacts.tryBuild(
        replPath: baseImagePath,
        archString: firmwareRecord.machine?.name,
        firmwareSymbols:
            emulator.cachedCallGraph?.symbols.keys ?? const <String>[],
      );
      // Object groups (peripheral member-function families), computed from the
      // call graph. Comms symbols are excluded so grouping never touches the
      // bus mechanism.
      final symbolGroups =
          SymbolGroupClassifier(catalog: ref.read(hookCatalogProvider))
              .classify(
        emulator.cachedCallGraph?.symbols.keys ?? const <String>[],
        exclude: commsHooks.keys.toSet(),
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
        symbolGroups: symbolGroups,
        groupOverrides: emulator.groupOverrides,
        memoryMapPath: config.memoryMapPath,
        llmGenerator: llmGenerator,
        platform: platform,
        maxIterations: ref.read(synthesisMaxIterationsProvider),
      );
    } finally {
      if (ownComms) await comms.release();
    }
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

    // This path starts emulation and returns while the firmware keeps
    // running, so the comms servers must outlive the method: the
    // controller owns them until reset/dispose/the next run.
    await _ownedCommsSession?.release();
    _ownedCommsSession = await _acquireComms(emulator);
    final commsHooks = _ownedCommsSession!.hooks;

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
    await _ownedCommsSession?.release();
    _ownedCommsSession = null;
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

  void _subscribeSynthesizerEvents(Emulator emulator,
      {bool persistResolvedHooks = true}) {
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
          llmActive: false,
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
          llmActive: false,
        );
      } else if (event is SynthesizerSymbolExhausted) {
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          currentSymbol: event.symbol,
          status: 'Exhausted: ${event.symbol}',
        );
      } else if (event is SynthesizerLlmGenerating) {
        // The iteration loop has exhausted DB candidates for this
        // symbol and the on-demand LLM is generating a fresh hook
        // — ~2 min on gemma4:e4b. Emulation is functionally paused,
        // so flag llmActive (the view swaps the 30s countdown for an
        // elapsed timer) and restart the timestamp at the LLM call.
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          currentSymbol: event.symbol,
          status: 'LLM generating: ${event.symbol} '
              '(${event.modelTag})',
          countdownStart: DateTime.now(),
          llmActive: true,
        );
      } else if (event is SynthesizerLlmGenerated) {
        // Fresh artifact + binding ready. Don't bump hooksApplied
        // yet — the next iteration's SynthesizerHookApplied will
        // do that when the synthesizer actually installs the hook.
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          currentSymbol: event.symbol,
          status: 'LLM produced hook for ${event.symbol} '
              '(fidelity ${event.fidelity.toStringAsFixed(2)})',
          countdownStart: DateTime.now(),
          llmActive: false,
        );
      } else if (event is SynthesizerLlmFailed) {
        // The fallback died or returned nothing — leave the LLM state
        // so the countdown resumes; the synthesizer continues on its
        // own (symbol-exhausted path).
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          currentSymbol: event.symbol,
          status: 'LLM failed for ${event.symbol} — continuing '
              '(${event.reason})',
          countdownStart: DateTime.now(),
          llmActive: false,
        );
      } else if (event is SynthesizerCompleted) {
        final result = _enrichManifest(event.result);
        ref.read(synthesisResultProvider.notifier).state = result;
        ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
          complete: true,
          success: result.success,
          status: result.success
              ? 'Complete — ${result.resolvedHooks.length} hooks'
              : 'Failed at ${result.failedSymbol}',
        );
        if (persistResolvedHooks && result.resolvedHookCode.isNotEmpty) {
          ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
            hooks: result.resolvedHookCode,
            modifiedAt: DateTime.now(),
          );
          ref.read(emulatorDirtyProvider.notifier).state = true;
        }
        // Persist the run manifest next to the .emu so the post-run
        // report can re-render and future audits have a durable
        // record. No-op when the project hasn't been saved yet (no
        // emulatorPath) — the manifest lives on disk, not in the
        // project JSON.
        if (result.manifest != null && emulator.emulatorPath != null) {
          unawaited(
              _writeManifestToDisk(emulator.emulatorPath!, result.manifest!));
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

  void dispose() {
    _cancelSubscriptions();
    unawaited(_ownedCommsSession?.release() ?? Future.value());
    _ownedCommsSession = null;
  }

  /// Fold run-level fidelity metrics + executed-symbols into the
  /// manifest carried by [result], through the one shared enrichment
  /// (`enrichSynthesizerResult`) so the UI, the CLI, and the auto-tune
  /// engine all compute the same numbers.
  ///
  /// Returns [result] unchanged when the manifest is null (legacy test
  /// path) or the call graph isn't loaded — in either case the v2
  /// enrichment fields stay null and downstream code falls back to
  /// recomputing as needed.
  SynthesizerResult _enrichManifest(SynthesizerResult result) {
    if (result.manifest == null) return result;

    final callGraph = ref.read(callgraphProvider).valueOrNull;
    if (callGraph == null) return result;

    final executedSymbols = ref.read(executedSymbolsProvider);
    final currentEmulator = ref.read(currentEmulatorProvider);
    final startFrom = currentEmulator?.emulationConfig.startFrom;
    final endAt = currentEmulator?.emulationConfig.endAt;

    Set<String> subgraphSymbols = const {};
    if (startFrom != null &&
        startFrom.isNotEmpty &&
        endAt != null &&
        endAt.isNotEmpty) {
      subgraphSymbols = FidelityCalculator.subgraphBetween(
        callGraph,
        startFrom,
        endAt.first,
      ).union(executedSymbols);
    }

    return enrichSynthesizerResult(
      result: result,
      callGraph: callGraph,
      executedSymbols: executedSymbols,
      subgraphSymbols: subgraphSymbols,
    );
  }

  /// Write [manifest] to `<projectDir>/manifests/<run_id>.json`,
  /// creating the directory if needed. Best-effort: any I/O error is
  /// logged to stderr but doesn't propagate — the manifest lives on
  /// the SynthesizerResult either way, and the UI can still render
  /// it from memory.
  ///
  /// The run_id is an ISO-8601 timestamp; we replace `:` with `-` so
  /// the filename is portable across filesystems.
  Future<void> _writeManifestToDisk(
    String emulatorPath,
    SynthesisManifest manifest,
  ) async {
    try {
      final projectDir = File(emulatorPath).parent.path;
      final manifestsDir = Directory('$projectDir/manifests');
      if (!manifestsDir.existsSync()) {
        await manifestsDir.create(recursive: true);
      }
      final safeRunId = manifest.synthesizerRunId.replaceAll(':', '-');
      final file = File('${manifestsDir.path}/$safeRunId.json');
      await file.writeAsString(manifest.toPrettyJson());
      debugPrint('[Synthesis] manifest written: ${file.path}');
    } catch (e) {
      debugPrint('[Synthesis] manifest write failed: $e');
    }
  }
}

final synthesisControllerProvider = Provider<SynthesisController>((ref) {
  final controller = SynthesisController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});
