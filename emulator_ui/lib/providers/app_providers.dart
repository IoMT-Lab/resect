import 'package:emulator_orchestrator/api/api_server.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/emulation_state.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/fidelity_result.dart';
import 'package:emulator_orchestrator/data/models/firmware_record.dart';
import 'package:emulator_orchestrator/data/models/recent_emulator.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/data/models/trace_activity_event.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/data/services/artifact_library_service.dart';
import 'package:emulator_orchestrator/data/services/fidelity_calculator.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_engine.dart';
import 'package:emulator_orchestrator/orchestrator/engine/paused_event.dart';
import 'package:emulator_orchestrator/orchestrator/events/orchestrator_events.dart';
import 'package:emulator_orchestrator/orchestrator/vagrant_test_event.dart';
import 'package:emulator_orchestrator/orchestrator/workflows/synthesizer_workflow.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'autosave_provider.dart';
import 'comms_bus_provider.dart';
import 'comms_classification_provider.dart';
import 'config_providers.dart';

export 'package:emulator_orchestrator/data/models/emulation_state.dart';
export 'package:emulator_orchestrator/orchestrator/vagrant_test_event.dart';

/// Provider for connection status (true = connected, false = disconnected).
///
/// This streams the current connection state from the service.
final connectionStatusProvider = StreamProvider<bool>((ref) async* {
  // Call-graph analysis is now in-process (objdump), so it's always available.
  final source = ref.watch(emulationOrchestratorProvider).callGraphSource;
  await source.connect();
  yield true;
  yield* source.connectionStatus;
});

/// Provider for the currently selected ELF file path.
///
/// When this changes, the call graph will be regenerated.
final selectedElfPathProvider = StateProvider<String?>((ref) => null);

/// Provider for the call graph data.
///
/// This automatically fetches a new call graph when the selected ELF path changes.
/// Returns null if no file is selected.
final callgraphProvider = FutureProvider<CallGraph?>((ref) async {
  final elfPath = ref.watch(selectedElfPathProvider);

  // No file selected, return null
  if (elfPath == null || elfPath.isEmpty) {
    return null;
  }

  // Reuse the open project's saved graph when it matches the loaded ELF, so
  // reopening a project doesn't re-run objdump. `ref.read` (not watch) is
  // intentional — the graph must not recompute when the emulator mutates for
  // other reasons (hooks, etc.). Regenerate Call Graph clears the cache and
  // invalidates this provider to force a fresh extraction.
  final cached = ref.read(currentEmulatorProvider)?.cachedCallGraph;
  if (cached != null && cached.elfPath == elfPath) {
    return cached;
  }

  // In-process call-graph extraction (objdump) via the engine abstraction.
  return ref.watch(emulationOrchestratorProvider).generateCallGraph(elfPath);
});

/// Provider for the currently selected symbol (function) in the graph.
///
/// Used to show details in the metadata sidebar.
final selectedSymbolProvider = StateProvider<String?>((ref) => null);

/// Provider for UI state - whether left sidebar is expanded.
final leftSidebarExpandedProvider = StateProvider<bool>((ref) => true);

/// Provider for UI state - whether right sidebar is expanded.
final rightSidebarExpandedProvider = StateProvider<bool>((ref) => true);

/// Provider for UI state - whether trace activity sidebar is expanded.
final traceActivitySidebarExpandedProvider = StateProvider<bool>((ref) => true);

/// Provider for trace activity events list.
/// Includes filtered function traces AND lifecycle events (pause/resume/reset).
final traceActivityEventsProvider = StateProvider<List<TraceActivityEvent>>((ref) => []);

/// Provider for the latest pause event details (for banner display).
final latestPauseEventProvider = StateProvider<PausedEvent?>((ref) => null);

// ============================================================================
// TABBED SHELL NAVIGATION
// ============================================================================

/// The five top-level tabs in the Resect shell, in display order.
enum ResectTab {
  library,
  callGraph,
  comms,
  synthesize,
  publish,
}

extension ResectTabLabel on ResectTab {
  /// Display label shown in the top tab strip (rendered uppercase).
  String get label {
    switch (this) {
      case ResectTab.library: return 'Library';
      case ResectTab.callGraph: return 'Call Graph';
      case ResectTab.comms: return 'Comms';
      case ResectTab.synthesize: return 'Synthesize';
      case ResectTab.publish: return 'Publish';
    }
  }
}

/// The currently selected tab. Defaults to Library on app start.
final activeTabProvider = StateProvider<ResectTab>((ref) => ResectTab.library);

/// How a tab should render in the tab strip.
///
/// - [active]: the user is on this tab.
/// - [ready]: not active, but its prerequisites are met — fully clickable.
/// - [notReady]: not active and prerequisites aren't met — clickable but
///   rendered dimmed to hint that the user should set things up first.
enum TabReadiness { active, ready, notReady }

/// Compute the readiness state of a given tab based on app state.
///
/// Tabs are never navigationally gated — the user can always switch — but
/// the strip dims labels whose prerequisites aren't met.
final tabReadinessProvider = Provider.family<TabReadiness, ResectTab>((ref, tab) {
  final active = ref.watch(activeTabProvider);
  if (active == tab) return TabReadiness.active;

  final hasEmulator = ref.watch(currentEmulatorProvider) != null;
  final hasCallGraph = ref.watch(callgraphProvider).maybeWhen(
        data: (cg) => cg != null,
        orElse: () => false,
      );
  final hasResolvedWork = ref.watch(hookedSymbolsProvider).isNotEmpty ||
      ref.watch(currentEmulatorProvider)?.hooks.isNotEmpty == true;

  switch (tab) {
    case ResectTab.library:
      return TabReadiness.ready;
    case ResectTab.callGraph:
      return hasEmulator ? TabReadiness.ready : TabReadiness.notReady;
    case ResectTab.comms:
      final commsEnabled = ref.watch(moduleEnabledProvider('MODULE_COMMS_BUS'));
      return (commsEnabled && hasCallGraph)
          ? TabReadiness.ready
          : TabReadiness.notReady;
    case ResectTab.synthesize:
      return hasCallGraph ? TabReadiness.ready : TabReadiness.notReady;
    case ResectTab.publish:
      return hasResolvedWork ? TabReadiness.ready : TabReadiness.notReady;
  }
});

// ============================================================================
// EMULATION STATE PROVIDERS
// ============================================================================

/// Provider for current emulation state.
final emulationStateProvider = StateProvider<EmulationState>((ref) => EmulationState.stopped);

/// Provider for tracking which symbols have been executed during emulation.
///
/// This set contains the names of all functions that have been called at least once.
final executedSymbolsProvider = StateProvider<Set<String>>((ref) => {});

/// Symbols that have been substituted with hooks during synthesis.
/// These render as red in the graph to indicate they've been replaced.
final hookedSymbolsProvider = StateProvider<Set<String>>((ref) => {});

// ============================================================================
// SYNTHESIS PROGRESS PROVIDERS
// ============================================================================

/// Tracks the live state of a running synthesis workflow.
///
/// Null when no synthesis is running. Set by the graph viewer when
/// EMULATE mode launches the synthesizer. Read by the emulator explorer
/// to show live progress with a countdown timer.
class SynthesisProgress {
  final int iteration;
  final int hooksApplied;
  final String currentSymbol;
  final String status;
  final DateTime countdownStart; // when the 30s success countdown began/reset
  final bool complete;
  final bool success;

  const SynthesisProgress({
    required this.countdownStart, this.iteration = 0,
    this.hooksApplied = 0,
    this.currentSymbol = '',
    this.status = 'Starting...',
    this.complete = false,
    this.success = false,
  });

  SynthesisProgress copyWith({
    int? iteration,
    int? hooksApplied,
    String? currentSymbol,
    String? status,
    DateTime? countdownStart,
    bool? complete,
    bool? success,
  }) => SynthesisProgress(
      iteration: iteration ?? this.iteration,
      hooksApplied: hooksApplied ?? this.hooksApplied,
      currentSymbol: currentSymbol ?? this.currentSymbol,
      status: status ?? this.status,
      countdownStart: countdownStart ?? this.countdownStart,
      complete: complete ?? this.complete,
      success: success ?? this.success,
    );
}

final synthesisProgressProvider = StateProvider<SynthesisProgress?>((ref) => null);

/// Stores the full SynthesizerResult after synthesis completes.
///
/// Used by the synthesis report overlay to display the summary and
/// provide export options. Null when no result is available.
final synthesisResultProvider = StateProvider<SynthesizerResult?>((ref) => null);

/// Computed fidelity metric for the current synthesis result.
///
/// Automatically recomputes when the call graph or synthesis result changes.
/// Returns null if either is unavailable.
final fidelityResultProvider = Provider<FidelityResult?>((ref) {
  final callgraphAsync = ref.watch(callgraphProvider);
  final callGraph = callgraphAsync.valueOrNull;
  final synthResult = ref.watch(synthesisResultProvider);
  if (callGraph == null || synthResult == null) return null;
  final executedSymbols = ref.watch(executedSymbolsProvider);

  // Compute subgraph between start/stop if both are configured.
  final emulator = ref.watch(currentEmulatorProvider);
  Set<String> subgraphSymbols = const {};
  final startFrom = emulator?.emulationConfig.startFrom;
  final endAt = emulator?.emulationConfig.endAt;
  if (startFrom != null && startFrom.isNotEmpty && endAt != null && endAt.isNotEmpty) {
    // Use the first endAt symbol for the subgraph path.
    // Union with executed symbols so runtime-discovered dependencies
    // (function pointers, interrupts, etc.) are included.
    subgraphSymbols = FidelityCalculator.subgraphBetween(
      callGraph,
      startFrom,
      endAt.first,
    ).union(executedSymbols);
  }

  return FidelityCalculator.compute(
    callGraph: callGraph,
    hookedSymbols: synthResult.resolvedHooks.keys.toSet(),
    traversedSymbols: executedSymbols,
    subgraphSymbols: subgraphSymbols,
  );
});

// ============================================================================
// EMULATOR MANAGEMENT PROVIDERS
// ============================================================================

/// Provider for the EmulatorRepository singleton.
///
/// Handles all emulator file I/O operations.
final emulatorRepositoryProvider = Provider<EmulatorRepository>((ref) => EmulatorRepository());

// ============================================================================
// ORCHESTRATOR PROVIDER
// ============================================================================

/// Provider for the EmulationOrchestrator singleton.
///
/// The orchestrator coordinates all business logic operations and emits
/// events that update Riverpod providers. This separates business logic
/// from UI concerns, making it testable independently.
final dartEngineProvider = Provider<DartEngine>((ref) {
  final engine = DartEngine();
  ref.onDispose(engine.stopProcess);
  return engine;
});

final emulationOrchestratorProvider = Provider<EmulationOrchestrator>((ref) {
  // The pure-Dart engine (renode-dart + callgraph-dart) supplies all four
  // capabilities off a single shared client; no Python/Socket.IO server.
  final engine = ref.watch(dartEngineProvider);
  final orchestrator = EmulationOrchestrator(
    engineLifecycle: engine.lifecycle,
    emulationController: engine.controller,
    callGraphSource: engine.callGraphSource,
    traceSource: engine.traceSource,
    emulatorRepository: ref.watch(emulatorRepositoryProvider),
    artifactDb: ref.watch(artifactDatabaseProvider),
  );

  // Listen to orchestrator events and update providers accordingly
  orchestrator.events.listen((event) {
    if (event is EmulationStateChangedEvent) {
      ref.read(emulationStateProvider.notifier).state = event.state;
    } else if (event is EmulationPausedEvent) {
      // Store pause event details for banner and add to trace activity
      ref.read(latestPauseEventProvider.notifier).state = event.pauseDetails;
      final currentEvents = ref.read(traceActivityEventsProvider);
      ref.read(traceActivityEventsProvider.notifier).state = [
        ...currentEvents,
        TraceActivityEvent.paused(event.pauseDetails),
      ];
    } else if (event is EmulatorChangedEvent) {
      ref.read(currentEmulatorProvider.notifier).state = event.emulator;
      if (event.emulator?.elfFilePath != null) {
        ref.read(selectedElfPathProvider.notifier).state = event.emulator!.elfFilePath;
      }
      // Restore persisted hook preferences, overrides, and resolved hooks
      ref.read(hookPreferencesProvider.notifier).state =
          Map<String, int>.from(event.emulator?.hookPreferences ?? {});
      ref.read(hookOverridesProvider.notifier).state =
          Map<String, int>.from(event.emulator?.hookOverrides ?? {});
      ref.read(hookedSymbolsProvider.notifier).state =
          event.emulator?.hooks.keys.toSet() ?? {};
      // Restore persisted synthesis artifacts so the fidelity report can be
      // reconstructed without re-running (see also library_actions.openEmulator).
      ref.read(autosaveControllerProvider).restoreArtifacts(event.emulator);
    } else if (event is SymbolExecutedEvent && event.isEntry) {
      ref.read(executedSymbolsProvider.notifier).update((state) =>
        {...state, event.symbol}
      );
    } else if (event is EmulatorSavedEvent) {
      ref.read(emulatorDirtyProvider.notifier).state = false;
    }
  });

  ref.onDispose(orchestrator.dispose);

  // Eager-instantiate side-effect controllers so their ref.listen()s on
  // upstream providers (callgraphProvider, commsProtocolConfigProvider)
  // fire from app boot, not lazily on first widget read.
  ref.read(commsClassificationControllerProvider);
  ref.read(commsBusControllerProvider);

  return orchestrator;
});

/// Provider for the currently active emulator.
///
/// Null if no emulator is open. When an emulator is loaded, this triggers
/// updates to other providers (selectedElfPath, UI state, etc).
final currentEmulatorProvider = StateProvider<Emulator?>((ref) => null);

/// Provider for emulator dirty state (unsaved changes).
///
/// True if the emulator has been modified since last save.
final emulatorDirtyProvider = StateProvider<bool>((ref) => false);

/// List of recently opened emulators, newest first.
///
/// Loaded from the on-disk recents file the first time it's read; consumers
/// should `ref.invalidate(recentEmulatorsProvider)` after any open/save so
/// the list reflects the latest activity.
final recentEmulatorsProvider = FutureProvider<List<RecentEmulator>>((ref) async => ref.watch(emulatorRepositoryProvider).getRecentEmulators());

// ============================================================================
// ARTIFACT LIBRARY PROVIDERS
// ============================================================================

/// Provider for the ArtifactDatabase singleton.
///
/// Creates and manages the local SQLite database for firmware artifacts.
final artifactDatabaseProvider = Provider<ArtifactDatabase>((ref) {
  final db = ArtifactDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Provider for the ArtifactLibraryService singleton.
///
/// Handles firmware hashing, lookup, and registration in the local library.
final artifactLibraryServiceProvider = Provider<ArtifactLibraryService>((ref) {
  final db = ref.watch(artifactDatabaseProvider);
  return ArtifactLibraryService(db);
});

/// Provider that automatically processes the current ELF file through
/// the artifact library when a call graph is generated.
///
/// This reactive provider watches callgraphProvider and selectedElfPathProvider.
/// When both have values, it hashes the ELF, checks the local library, and
/// registers the firmware if it's new. Returns the FirmwareRecord or null.
final artifactProcessingProvider = FutureProvider<FirmwareRecord?>((ref) async {
  final elfPath = ref.watch(selectedElfPathProvider);
  final callgraphAsync = ref.watch(callgraphProvider);

  // Need both an ELF path and a successfully loaded call graph
  if (elfPath == null || elfPath.isEmpty) return null;

  final callGraph = callgraphAsync.valueOrNull;
  if (callGraph == null) return null;

  final service = ref.watch(artifactLibraryServiceProvider);

  // Extract symbol names from the call graph
  final symbolNames = callGraph.symbols.keys.toList();

  // Process the ELF file (hash → lookup → register if new)
  return service.processElfFile(
    elfFilePath: elfPath,
    symbolNames: symbolNames,
  );
});

// ============================================================================
// HOOK PREFERENCE PROVIDERS
// ============================================================================

/// Fetches ALL hook artifacts for the current firmware (all symbols).
///
/// Returns a flat list of (symbolName, artifact) records. Used by the
/// Hook Database Viewer dialog. Invalidate after add/delete to refresh.
final allHooksForFirmwareProvider =
    FutureProvider<List<({String symbolName, Artifact artifact})>>((ref) async {
  final firmwareRecord = ref.watch(artifactProcessingProvider).valueOrNull;
  if (firmwareRecord == null) return [];

  final db = ref.watch(artifactDatabaseProvider);
  return db.getAllArtifactsForFirmware(firmwareRecord.elfHash);
});

/// Fetches all hook artifacts for the currently selected symbol.
///
/// Watches selectedSymbolProvider and artifactProcessingProvider so it
/// automatically refetches when the user clicks a different node or
/// when firmware is first processed.
final hooksForSelectedSymbolProvider = FutureProvider<List<Artifact>>((ref) async {
  final selectedSymbol = ref.watch(selectedSymbolProvider);
  final firmwareRecord = ref.watch(artifactProcessingProvider).valueOrNull;

  if (selectedSymbol == null || firmwareRecord == null) return [];

  final db = ref.watch(artifactDatabaseProvider);
  return db.getArtifactsForSymbolByName(firmwareRecord.elfHash, selectedSymbol);
});

/// User-selected hook preferences: symbol name → artifact ID.
///
/// When the user selects a hook in the metadata sidebar dropdown,
/// the preference is stored here. The synthesizer reads this map
/// at launch time to reorder hooks so the preferred one is tried first.
final hookPreferencesProvider = StateProvider<Map<String, int>>((ref) => {});

/// Forced hook overrides: symbol name → artifact ID.
///
/// Unlike preferences (which only influence ordering during synthesis),
/// overrides are applied unconditionally before emulation starts.
/// The function is always substituted, whether or not it causes an error.
final hookOverridesProvider = StateProvider<Map<String, int>>((ref) => {});

// ============================================================================
// SYNTHESIZER PROVIDERS
// ============================================================================

/// Provider for the SynthesizerWorkflow.
///
/// Exposes the synthesizer from the orchestrator for future UI integration.
final synthesizerWorkflowProvider = Provider<SynthesizerWorkflow>((ref) => ref.watch(emulationOrchestratorProvider).synthesizerWorkflow);

// ============================================================================
// API SERVER PROVIDER
// ============================================================================

/// Provider for the HTTP API server.
///
/// Creates an ApiServer wrapping the orchestrator for programmatic access.
/// The server must be started explicitly by calling `serve()`.
final apiServerProvider = Provider<ApiServer>((ref) => ApiServer(
    orchestrator: ref.watch(emulationOrchestratorProvider),
    callGraphSource: ref.watch(dartEngineProvider).callGraphSource,
    artifactLibraryService: ref.watch(artifactLibraryServiceProvider),
  ));

// =============================================================================
// VAGRANT CI/CD TEST STATE
// =============================================================================

/// Status of a single test step.
enum VagrantStepStatus { pending, running, passed, failed }

/// State for one step in the Vagrant CI/CD test panel.
class VagrantTestStepState {
  final VagrantTestStepId id;
  final VagrantStepStatus status;
  final List<String> logs;

  const VagrantTestStepState({
    required this.id,
    this.status = VagrantStepStatus.pending,
    this.logs = const [],
  });

  VagrantTestStepState copyWith({
    VagrantStepStatus? status,
    List<String>? logs,
  }) =>
      VagrantTestStepState(
        id: id,
        status: status ?? this.status,
        logs: logs ?? this.logs,
      );
}

/// State of the entire Vagrant CI/CD test run.
class VagrantTestState {
  final List<VagrantTestStepState> steps;
  final bool isRunning;
  final bool complete;
  final bool? passed; // null until complete

  VagrantTestState({
    List<VagrantTestStepState>? steps,
    this.isRunning = false,
    this.complete = false,
    this.passed,
  }) : steps = steps ??
            VagrantTestStepId.values
                .map((id) => VagrantTestStepState(id: id))
                .toList();

  VagrantTestState copyWith({
    List<VagrantTestStepState>? steps,
    bool? isRunning,
    bool? complete,
    bool? passed,
  }) =>
      VagrantTestState(
        steps: steps ?? this.steps,
        isRunning: isRunning ?? this.isRunning,
        complete: complete ?? this.complete,
        passed: passed ?? this.passed,
      );

  VagrantTestState withStepUpdate(
    VagrantTestStepId id,
    VagrantTestStepState Function(VagrantTestStepState) update,
  ) {
    final updated = steps.map((s) => s.id == id ? update(s) : s).toList();
    return copyWith(steps: updated);
  }
}

/// Live state of the Vagrant CI/CD test panel.
final vagrantTestStateProvider =
    StateProvider<VagrantTestState>((ref) => VagrantTestState());
