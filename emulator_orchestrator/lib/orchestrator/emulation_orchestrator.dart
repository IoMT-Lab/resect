import 'dart:async';
import 'dart:io';

import '../data/services/lifecycle_service.dart';
import '../data/services/callgraph_service.dart';
import '../data/services/trace_service.dart';
import '../data/services/filtered_trace_service.dart';
import '../data/database/artifact_database.dart';
import '../data/repositories/emulator_repository.dart';
import '../data/models/emulator.dart';
import '../data/models/call_graph.dart';
import '../data/models/graph_point.dart';
import '../data/models/synthesizer_result.dart';
import '../data/models/emulation_state.dart';

import 'workflows/emulation_workflow.dart';
import 'workflows/emulator_workflow.dart';
import 'workflows/analysis_workflow.dart';
import 'workflows/synthesizer_workflow.dart';
import 'events/orchestrator_events.dart';
import 'exceptions/orchestrator_exceptions.dart';

/// Central orchestrator for all business logic operations.
///
/// This class coordinates services, manages complex workflows, and emits
/// events for UI state updates. It is independently testable and does not
/// depend on Flutter widgets.
///
/// The orchestrator sits between the UI and services:
/// ```
/// UI (widgets) → Orchestrator (business logic) → Services (Socket.IO) → Backend
/// ```
class EmulationOrchestrator {
  // Dependencies (injected)
  final LifecycleService lifecycleService;
  final CallgraphService callgraphService;
  final TraceService traceService;
  final FilteredTraceService filteredTraceService;
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
  Process? _serverProcess;
  EmulationState _state = EmulationState.stopped;
  Emulator? _currentEmulator;

  EmulationOrchestrator({
    required this.lifecycleService,
    required this.callgraphService,
    required this.traceService,
    required this.filteredTraceService,
    required this.emulatorRepository,
    required this.artifactDb,
  }) {
    // Initialize workflows with service dependencies
    emulationWorkflow = EmulationWorkflow(
      lifecycleService: lifecycleService,
      callgraphService: callgraphService,
      traceService: traceService,
      filteredTraceService: filteredTraceService,
      onServerProcessCreated: (process) {
        _serverProcess = process;
      },
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
      callgraphService: callgraphService,
    );

    synthesizerWorkflow = SynthesizerWorkflow(
      lifecycleService: lifecycleService,
      artifactDb: artifactDb,
    );

    // Forward trace events from workflows to orchestrator event stream
    _forwardTraceEvents();
  }

  // =========================================================================
  // PUBLIC API: EMULATION OPERATIONS
  // =========================================================================

  /// Start emulation with the given ELF file and configuration.
  ///
  /// Throws [EmulationException] on failure.
  Future<void> startEmulation({
    required String elfPath,
    String? baseImagePath,
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
    Map<String, int> hookOverrides = const {},
    Map<String, String> resolvedHooks = const {},
    String? memoryMapPath,
  }) async {
    // Resolve override artifact IDs → hook code
    final resolvedOverrides = <String, String>{};
    for (final entry in hookOverrides.entries) {
      final artifact = await artifactDb.getArtifactById(entry.value);
      if (artifact != null) {
        resolvedOverrides[entry.key] = artifact.artifactData;
      }
    }

    // Merge: resolved hooks first, overrides win on conflict
    final allHooks = <String, String>{...resolvedHooks, ...resolvedOverrides};

    await emulationWorkflow.start(
      elfPath: elfPath,
      baseImagePath: baseImagePath,
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
      resolvedOverrides: allHooks,
      memoryMapPath: memoryMapPath,
    );
  }

  /// Restart emulation using the existing server process.
  ///
  /// Lighter than resetEmulation() + startEmulation() — keeps the server
  /// alive and just resets Renode state, reloads firmware, and restarts.
  /// Falls back to full start if no server is running.
  Future<void> restartEmulation({
    required String elfPath,
    String? baseImagePath,
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
    Map<String, int> hookOverrides = const {},
    Map<String, String> resolvedHooks = const {},
    String? memoryMapPath,
  }) async {
    // Resolve override artifact IDs → hook code
    final resolvedOverrides = <String, String>{};
    for (final entry in hookOverrides.entries) {
      final artifact = await artifactDb.getArtifactById(entry.value);
      if (artifact != null) {
        resolvedOverrides[entry.key] = artifact.artifactData;
      }
    }

    // Merge: resolved hooks first, overrides win on conflict
    final allHooks = <String, String>{...resolvedHooks, ...resolvedOverrides};

    await emulationWorkflow.restart(
      elfPath: elfPath,
      baseImagePath: baseImagePath,
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
      resolvedOverrides: allHooks,
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
  /// Cancels subscriptions, disconnects services, and kills the server process.
  Future<void> resetEmulation() async {
    // Cancel subscriptions and disconnect services
    await emulationWorkflow.reset();

    // Kill server process
    if (_serverProcess != null) {
      _serverProcess!.kill();
      _serverProcess = null;
      print('Python server stopped');
    }

    _state = EmulationState.stopped;
  }

  // =========================================================================
  // PUBLIC API: EMULATOR OPERATIONS
  // =========================================================================

  /// Create a new emulator.
  Future<Emulator> createEmulator({
    required String name,
    String? elfFilePath,
    String? baseImagePath,
  }) async {
    return await emulatorWorkflow.createEmulator(
      name: name,
      elfFilePath: elfFilePath,
      baseImagePath: baseImagePath,
    );
  }

  /// Load an existing emulator from file.
  Future<Emulator> loadEmulator(String emulatorPath) async {
    return await emulatorWorkflow.loadEmulator(emulatorPath);
  }

  /// Save the current emulator.
  Future<void> saveEmulator(Emulator emulator, {String? savePath}) async {
    await emulatorWorkflow.saveEmulator(emulator, savePath: savePath);
    _emitEvent(EmulatorSavedEvent(emulator, savePath ?? emulator.emulatorPath!));
  }

  /// Close the current emulator.
  Future<void> closeEmulator({bool checkUnsaved = true}) async {
    await emulatorWorkflow.closeEmulator(checkUnsaved: checkUnsaved);
  }

  /// Mark the current emulator as having unsaved changes.
  void markEmulatorDirty() {
    emulatorWorkflow.markDirty();
  }

  /// Check if the current emulator has unsaved changes.
  bool get hasUnsavedChanges => emulatorWorkflow.hasUnsavedChanges;

  // =========================================================================
  // PUBLIC API: SYNTHESIZER OPERATIONS
  // =========================================================================

  /// Run the automated hook synthesizer.
  ///
  /// Prerequisites: Emulation must be started first (server running, firmware
  /// loaded). The synthesizer takes over and manages reset/hook/restart cycles.
  ///
  /// Returns a [SynthesizerResult] with the outcome.
  Future<SynthesizerResult> runSynthesizer({
    required String elfPath,
    required String baseImagePath,
    required String elfHash,
    String? startFrom,
    List<String>? endAt,
    int maxIterations = 100,
    Map<String, int> hookPreferences = const {},
    Map<String, int> hookOverrides = const {},
    Map<String, String> resolvedHooks = const {},
    String? memoryMapPath,
  }) async {
    return synthesizerWorkflow.run(
      elfPath: elfPath,
      elfHash: elfHash,
      baseImagePath: baseImagePath,
      startFrom: startFrom,
      endAt: endAt,
      maxIterations: maxIterations,
      hookPreferences: hookPreferences,
      hookOverrides: hookOverrides,
      resolvedHooks: resolvedHooks,
      memoryMapPath: memoryMapPath,
    );
  }

  // =========================================================================
  // PUBLIC API: ANALYSIS OPERATIONS
  // =========================================================================

  /// Generate call graph for the given ELF file.
  Future<CallGraph> generateCallGraph(String elfPath) async {
    return await analysisWorkflow.generateCallGraph(elfPath);
  }

  /// Apply layout algorithm to call graph nodes.
  Map<String, GraphPoint> applyLayout({
    required CallGraph callGraph,
    required GraphLayout layoutType,
  }) {
    final positions = analysisWorkflow.applyLayout(
      callGraph: callGraph,
      layoutType: layoutType,
    );
    return positions;
  }

  // =========================================================================
  // INTERNAL HELPERS
  // =========================================================================

  void _emitEvent(OrchestrationEvent event) {
    _eventController.add(event);
  }

  void _forwardTraceEvents() {
    // Listen to trace events from emulation workflow and forward them
    // This is set up when trace services are connected
    // The actual subscription happens in EmulationWorkflow
  }

  // =========================================================================
  // GETTERS
  // =========================================================================

  /// Get current emulation state
  EmulationState get state => _state;

  /// Get current emulator
  Emulator? get currentEmulator => _currentEmulator;

  /// Check if a server process is running
  bool get hasServerProcess => _serverProcess != null;

  // =========================================================================
  // CLEANUP
  // =========================================================================

  /// Clean up resources
  void dispose() {
    _serverProcess?.kill();
    _eventController.close();
    emulationWorkflow.dispose();
    emulatorWorkflow.dispose();
    analysisWorkflow.dispose();
    synthesizerWorkflow.dispose();
  }
}
