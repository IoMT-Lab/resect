import 'dart:async';

import '../data/database/artifact_database.dart';
import '../data/models/call_graph.dart';
import '../data/models/emulation_state.dart';
import '../data/models/emulator.dart';
import '../data/models/graph_point.dart';
import '../data/models/hook_binding.dart';
import '../data/services/llm_hook_generator.dart'
    show LlmHookGenerator, PlatformFacts;
import '../data/models/synthesizer_result.dart';
import '../data/repositories/emulator_repository.dart';

import 'engine/call_graph_source.dart';
import 'engine/emulation_controller.dart';
import 'engine/engine_lifecycle.dart';
import 'engine/trace_source.dart';

import 'events/orchestrator_events.dart';
import 'hook_spec.dart';
import 'workflows/analysis_workflow.dart';
import 'workflows/emulation_workflow.dart';
import 'workflows/emulator_workflow.dart';
import 'workflows/synthesizer_workflow.dart';

/// Central orchestrator for all business logic operations.
///
/// This class coordinates engine capabilities, manages complex workflows,
/// and emits events for UI state updates. It is independently testable and
/// does not depend on Flutter widgets.
///
/// The orchestrator sits between the UI and the engine abstractions:
/// ```
/// UI (widgets) → Orchestrator (business logic) → Engine (interfaces) → Engine impl
/// ```
class EmulationOrchestrator {
  // Engine capabilities (injected — engine-agnostic)
  final EngineLifecycle engineLifecycle;
  final EmulationController emulationController;
  final CallGraphSource callGraphSource;
  final TraceSource traceSource;

  // Other dependencies
  final EmulatorRepository emulatorRepository;
  final ArtifactDatabase artifactDb;

  // Workflows (composition over inheritance)
  late final EmulationWorkflow emulationWorkflow;
  late final EmulatorWorkflow emulatorWorkflow;
  late final AnalysisWorkflow analysisWorkflow;
  late final SynthesizerWorkflow synthesizerWorkflow;

  // Event stream for UI updates
  final _eventController = StreamController<OrchestrationEvent>.broadcast();
  Stream<OrchestrationEvent> get events => _eventController.stream;

  // Internal state
  EmulationState _state = EmulationState.stopped;
  Emulator? _currentEmulator;

  EmulationOrchestrator({
    required this.engineLifecycle,
    required this.emulationController,
    required this.callGraphSource,
    required this.traceSource,
    required this.emulatorRepository,
    required this.artifactDb,
  }) {
    emulationWorkflow = EmulationWorkflow(
      engineLifecycle: engineLifecycle,
      emulationController: emulationController,
      callGraphSource: callGraphSource,
      traceSource: traceSource,
      onStateChanged: (state) {
        _state = state;
        _emitEvent(EmulationStateChangedEvent(state));
      },
      onPauseEvent: (pauseEvent) {
        _emitEvent(EmulationPausedEvent(pauseEvent));
      },
    );

    emulatorWorkflow = EmulatorWorkflow(
      repository: emulatorRepository,
      onEmulatorChanged: (emulator) {
        _currentEmulator = emulator;
        _emitEvent(EmulatorChangedEvent(emulator));
      },
    );

    analysisWorkflow = AnalysisWorkflow(
      callGraphSource: callGraphSource,
    );

    synthesizerWorkflow = SynthesizerWorkflow(
      emulationController: emulationController,
      artifactDb: artifactDb,
    );
  }

  // =========================================================================
  // PUBLIC API: EMULATION OPERATIONS
  // =========================================================================

  /// Start emulation with the given ELF file and configuration.
  ///
  /// Throws on failure.
  Future<void> startEmulation({
    required String elfPath,
    String? baseImagePath,
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
    Map<String, int> hookOverrides = const {},
    Map<String, String> hookOverrideScopes = const {},
    Map<String, String> resolvedHooks = const {},
    Map<String, HookSpec> commsHooks = const {},
    String? memoryMapPath,
  }) async {
    final allHooks = await _resolveHookOverrides(
        resolvedHooks, hookOverrides, hookOverrideScopes);
    await emulationWorkflow.start(
      elfPath: elfPath,
      baseImagePath: baseImagePath,
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
      resolvedOverrides: allHooks,
      commsHooks: commsHooks,
      memoryMapPath: memoryMapPath,
    );
  }

  /// Restart emulation using the existing engine process.
  ///
  /// Lighter than resetEmulation() + startEmulation() — keeps the engine
  /// alive and just resets state, reloads firmware, and restarts.
  /// Falls back to full start if no engine is running.
  Future<void> restartEmulation({
    required String elfPath,
    String? baseImagePath,
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
    Map<String, int> hookOverrides = const {},
    Map<String, String> hookOverrideScopes = const {},
    Map<String, String> resolvedHooks = const {},
    Map<String, HookSpec> commsHooks = const {},
    String? memoryMapPath,
  }) async {
    final allHooks = await _resolveHookOverrides(
        resolvedHooks, hookOverrides, hookOverrideScopes);
    await emulationWorkflow.restart(
      elfPath: elfPath,
      baseImagePath: baseImagePath,
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
      resolvedOverrides: allHooks,
      commsHooks: commsHooks,
      memoryMapPath: memoryMapPath,
    );
  }

  /// Pause the running emulation.
  Future<void> pauseEmulation() async {
    await emulationWorkflow.pause();
  }

  /// Resume paused emulation.
  Future<void> resumeEmulation() async {
    await emulationWorkflow.resume();
  }

  /// Reset emulation to initial state.
  ///
  /// Cancels subscriptions, disconnects channels, and stops the engine.
  Future<void> resetEmulation() async {
    await emulationWorkflow.reset();
    await engineLifecycle.stop();
    _state = EmulationState.stopped;
  }

  // =========================================================================
  // PUBLIC API: EMULATOR OPERATIONS
  // =========================================================================

  Future<Emulator> createEmulator({
    required String name,
    String? elfFilePath,
    String? baseImagePath,
  }) async => emulatorWorkflow.createEmulator(
      name: name,
      elfFilePath: elfFilePath,
      baseImagePath: baseImagePath,
    );

  Future<Emulator> loadEmulator(String emulatorPath) async => emulatorWorkflow.loadEmulator(emulatorPath);

  Future<void> saveEmulator(Emulator emulator, {String? savePath}) async {
    await emulatorWorkflow.saveEmulator(emulator, savePath: savePath);
    _emitEvent(EmulatorSavedEvent(emulator, savePath ?? emulator.emulatorPath!));
  }

  Future<void> closeEmulator({bool checkUnsaved = true}) async {
    await emulatorWorkflow.closeEmulator(checkUnsaved: checkUnsaved);
  }

  void markEmulatorDirty() {
    emulatorWorkflow.markDirty();
  }

  bool get hasUnsavedChanges => emulatorWorkflow.hasUnsavedChanges;

  // =========================================================================
  // PUBLIC API: SYNTHESIZER OPERATIONS
  // =========================================================================

  Future<SynthesizerResult> runSynthesizer({
    required String elfPath,
    required String baseImagePath,
    required String elfHash,
    String? startFrom,
    List<String>? endAt,
    int maxIterations = 100,
    Map<String, int> hookPreferences = const {},
    Map<String, int> hookOverrides = const {},
    Map<String, String> hookOverrideScopes = const {},
    Map<String, String> resolvedHooks = const {},
    Map<String, HookSpec> commsHooks = const {},
    Map<String, HookBinding> hookBindings = const {},
    String? memoryMapPath,
    LlmHookGenerator? llmGenerator,
    PlatformFacts? platform,
  }) async => synthesizerWorkflow.run(
      elfPath: elfPath,
      elfHash: elfHash,
      baseImagePath: baseImagePath,
      startFrom: startFrom,
      endAt: endAt,
      maxIterations: maxIterations,
      hookPreferences: hookPreferences,
      hookOverrides: hookOverrides,
      hookOverrideScopes: hookOverrideScopes,
      resolvedHooks: resolvedHooks,
      commsHooks: commsHooks,
      hookBindings: hookBindings,
      memoryMapPath: memoryMapPath,
      llmGenerator: llmGenerator,
      platform: platform,
    );

  // =========================================================================
  // PUBLIC API: ANALYSIS OPERATIONS
  // =========================================================================

  Future<CallGraph> generateCallGraph(String elfPath) async => analysisWorkflow.generateCallGraph(elfPath);

  Map<String, GraphPoint> applyLayout({
    required CallGraph callGraph,
    required GraphLayout layoutType,
  }) => analysisWorkflow.applyLayout(
      callGraph: callGraph,
      layoutType: layoutType,
    );

  // =========================================================================
  // INTERNAL HELPERS
  // =========================================================================

  void _emitEvent(OrchestrationEvent event) {
    _eventController.add(event);
  }

  /// Resolve hookOverrides (symbol → artifactId) into [HookSpec]s carrying
  /// the artifact's code body plus the user's per-override scope (from
  /// [Emulator.hookOverrideScopes]). Merges with [resolvedHooks] (symbol →
  /// hookCode, warm-start hooks from a previous synthesis run — no scope).
  /// Overrides win on conflict.
  Future<Map<String, HookSpec>> _resolveHookOverrides(
    Map<String, String> resolvedHooks,
    Map<String, int> hookOverrides,
    Map<String, String> hookOverrideScopes,
  ) async {
    final merged = <String, HookSpec>{
      for (final entry in resolvedHooks.entries)
        entry.key: (code: entry.value, scope: null),
    };
    for (final entry in hookOverrides.entries) {
      final artifact = await artifactDb.getArtifactById(entry.value);
      if (artifact != null) {
        final scope = hookOverrideScopes[entry.key];
        merged[entry.key] = (
          code: artifact.artifactData,
          scope: (scope == null || scope.isEmpty) ? null : scope,
        );
      }
    }
    return merged;
  }

  // =========================================================================
  // GETTERS
  // =========================================================================

  EmulationState get state => _state;
  Emulator? get currentEmulator => _currentEmulator;
  bool get hasServerProcess => engineLifecycle.isRunning;

  // =========================================================================
  // CLEANUP
  // =========================================================================

  void dispose() {
    engineLifecycle.stop();
    _eventController.close();
    emulationWorkflow.dispose();
    emulatorWorkflow.dispose();
    analysisWorkflow.dispose();
    synthesizerWorkflow.dispose();
  }
}
