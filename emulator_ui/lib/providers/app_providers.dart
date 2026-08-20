import 'dart:io';

import 'package:emulator_orchestrator/api/api_server.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/emulation_state.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart'
    show ManifestMetrics;
import 'package:emulator_orchestrator/data/models/firmware_record.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/last_run_insight.dart';
import 'package:emulator_orchestrator/data/models/rag_index_status.dart';
import 'package:emulator_orchestrator/data/models/recent_emulator.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/data/models/trace_activity_event.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/engine/call_graph_source.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_engine.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/ghidra_call_graph_source.dart';
import 'package:emulator_orchestrator/orchestrator/engine/paused_event.dart';
import 'package:emulator_orchestrator/orchestrator/events/orchestrator_events.dart';
import 'package:emulator_orchestrator/orchestrator/vagrant_test_event.dart';
import 'package:emulator_orchestrator/orchestrator/workflows/synthesizer_workflow.dart';
import 'package:emulator_orchestrator/services/analysis/call_graph_guard.dart';
import 'package:emulator_orchestrator/services/analysis/call_graph_service.dart';
import 'package:emulator_orchestrator/services/analysis/fidelity_calculator.dart';
import 'package:emulator_orchestrator/services/external/signatures_service.dart';
import 'package:emulator_orchestrator/services/hooks/artifact_library_service.dart';
import 'package:emulator_orchestrator/services/llm/last_run_insight_service.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/llm_hook_generator.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:emulator_orchestrator/services/quality/hook_test_harness.dart';
import 'package:emulator_orchestrator/services/rag/rag_index.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'autosave_provider.dart';
import 'comms_bus_provider.dart';
import 'comms_classification_provider.dart';
import 'comms_config_providers.dart';
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

  // Reuse the open project's saved graph when its sha256 stamp matches
  // the loaded ELF's bytes, so reopening a project doesn't re-run
  // objdump. Content identity, not path identity: a path match proves
  // nothing (the file may have been replaced; stale graphs can cross
  // project switches), and unstamped legacy graphs never match — they
  // regenerate once and come back stamped. `ref.read` (not watch) is
  // intentional — the graph must not recompute when the emulator mutates
  // for other reasons (hooks, etc.). Regenerate Call Graph clears the
  // cache and invalidates this provider to force a fresh extraction.
  final cached = ref.read(currentEmulatorProvider)?.cachedCallGraph;
  if (cached != null && await callGraphMatchesElf(cached, elfPath)) {
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
      // Ready when the call graph is loaded AND either the user has opted into
      // the Comms module OR the classifier has actually found comms functions
      // in this firmware. The second clause means a firmware with detected
      // comms functions un-dims the tab even if the user never explicitly
      // enabled the module in System Configuration.
      final commsEnabled = ref.watch(moduleEnabledProvider('MODULE_COMMS_BUS'));
      final hasAssignments =
          ref.watch(currentEmulatorProvider)?.commsAssignments.isNotEmpty ??
              false;
      return (hasCallGraph && (commsEnabled || hasAssignments))
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

/// Symbols reachable from the firmware's entry points via the
/// statically-extracted call graph (forward BFS over `calledSymbols`
/// edges). Used by the pre-synthesis report to distinguish "uncovered
/// AND reachable" (the real synthesis-relevant unbound count) from
/// "uncovered AND dead code" (libc / unused weak symbols / unreferenced
/// functions that the firmware never executes).
///
/// Entry points checked in order: `Reset_Handler` (Cortex-M boot
/// vector), `main`. The first one present in the graph anchors the
/// BFS. Returns an empty set when neither entry is present so the UI
/// can fall back to "treat every symbol as reachable" semantics.
final reachableSymbolsProvider = Provider<Set<String>>((ref) {
  final callGraph = ref.watch(callgraphProvider).valueOrNull;
  if (callGraph == null) return const {};
  return FidelityCalculator.reachableFromEntries(
    callGraph,
    const ['Reset_Handler', 'main'],
  );
});

/// The current synthesis result's manifest metrics — the ONE fidelity
/// source every surface renders (the UI report card, the CLI output,
/// and the auto-tune round reports all read the same enrichment; see
/// `enrichSynthesizerResult`). Null until an enriched result exists.
final manifestMetricsProvider = Provider<ManifestMetrics?>(
  (ref) => ref.watch(synthesisResultProvider)?.manifest?.metrics,
);

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
    // Picks Ghidra-backed source when MODULE_GHIDRA=1 + GHIDRA_DIR
    // is set; falls back to engine.callGraphSource (objdump path)
    // otherwise. See [callGraphSourceProvider] for the contract.
    callGraphSource: ref.watch(callGraphSourceProvider),
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
      ref.read(hookOverrideScopesProvider.notifier).state =
          Map<String, String>.from(event.emulator?.hookOverrideScopes ?? {});
      ref.read(hookBindingsProvider.notifier).state =
          Map<String, HookBinding>.from(event.emulator?.hookBindings ?? {});
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

/// Snapshot of the per-project RAG index state — last-built time,
/// chunk counts, staleness flag, in-progress phase. Surfaced in the
/// Library tab's RAG INDEX card. Updated by [ragIndexProvider]'s
/// rebuild / status-refresh actions.
final ragIndexStatusProvider =
    StateProvider<RagIndexStatus>((ref) => RagIndexStatus.empty);

/// Local Ollama HTTP client built from the user's resect.config. Disposed
/// when the host/model change or the app closes. The model tag is read
/// from `LLM_MODEL`; the host from `LLM_OLLAMA_HOST`.
final llmClientProvider = Provider<LlmClient>((ref) {
  final cfg = ref.watch(systemConfigProvider);
  final host = (cfg.values['LLM_OLLAMA_HOST'] ?? '').trim();
  final model = (cfg.values['LLM_MODEL'] ?? '').trim();
  final client = LlmClient(
    host: host.isEmpty ? 'localhost:11434' : host,
    // Default matches `LlmHookGenComponent._defaultModel` and the
    // catalog's `recommended: true` entry. Update both together.
    model: model.isEmpty ? 'gemma4:e4b' : model,
  );
  ref.onDispose(client.close);
  return client;
});

/// Service that composes the Last Run Insights prompt and streams the
/// LLM's recommendation. Reads model + host from `llmClientProvider`.
final lastRunInsightServiceProvider = Provider<LastRunInsightService>(
  (ref) => LastRunInsightService(llmClient: ref.watch(llmClientProvider)),
);

/// JSON-emitting LLM service used by the closed-loop auto-tune
/// orchestrator. Reuses `LastRunInsightService.composePrompt` for
/// the input context section so device-class additions land in
/// both services when that work ships.
final recommendationServiceProvider = Provider<RecommendationService>(
  (ref) => RecommendationService(
    llmClient: ref.watch(llmClientProvider),
    insightService: ref.watch(lastRunInsightServiceProvider),
    artifactDb: ref.watch(artifactDatabaseProvider),
    ragIndex: ref.watch(ragIndexProvider),
  ),
);

/// LLM-generated advisory for the last successful synthesis run.
/// Hydrated from `Emulator.lastRunInsight` on project open by
/// `AutosaveController.restoreArtifacts`; written by the Generate
/// button in the Last Run card. Null when no insight has been
/// generated for the current project.
final lastRunInsightProvider =
    StateProvider<LastRunInsight?>((ref) => null);

/// Toggles while the LLM call is in flight so the recommendation
/// panel can render a streaming indicator. Set true when the Generate
/// button is pressed, false when the stream ends or is cancelled.
final lastRunInsightGeneratingProvider =
    StateProvider<bool>((ref) => false);

/// In-flight buffer of streamed response tokens for the recommendation
/// panel. Lives in a provider so multiple widgets (panel body + a
/// future debug surface) can subscribe; cleared back to empty when
/// the stream ends or is cancelled.
final lastRunInsightStreamBufferProvider =
    StateProvider<String>((ref) => '');

/// In-flight buffer of the model's reasoning trace (the `thinking`
/// channel from Ollama) for the recommendation panel. Surfaced in a
/// dimmed pane above the response buffer while the LLM is running.
/// Cleared alongside [lastRunInsightStreamBufferProvider] on stream
/// end/cancel.
final lastRunInsightThinkingBufferProvider =
    StateProvider<String>((ref) => '');

/// Per-project RAG index. Null until an emulator is loaded with a
/// project directory on disk (unsaved projects don't get one).
///
/// Threads the shared [ArtifactDatabase] in so the rebuild pass can
/// pull Ghidra-extracted decompilation / data types / data symbols
/// / memory map into the index when the Ghidra module is enabled.
/// Library tabs without Ghidra installed get a no-op pass (the
/// new tables are simply empty for the current ELF hash).
final ragIndexProvider = Provider<RagIndex?>((ref) {
  final emulator = ref.watch(currentEmulatorProvider);
  final projectPath = emulator?.emulatorPath;
  if (projectPath == null) return null;
  final projectDir = File(projectPath).parent.path;
  final client = ref.watch(llmClientProvider);
  final index = RagIndex(
    projectDir: projectDir,
    client: client,
    artifactDb: ref.watch(artifactDatabaseProvider),
  );
  ref.onDispose(index.close);
  return index;
});

/// Composes the RAG-context lookup with the Ollama generate stream.
/// Null until [ragIndexProvider] is ready (i.e. an emulator is loaded).
///
/// Threads the artifact DB through so the generator can pin the
/// target function's Ghidra decompilation as the first
/// project-context chunk when MODULE_GHIDRA has extracted one.
final llmHookGeneratorProvider = Provider<LlmHookGenerator?>((ref) {
  final index = ref.watch(ragIndexProvider);
  if (index == null) return null;
  return LlmHookGenerator(
    index: index,
    client: ref.watch(llmClientProvider),
    artifactDb: ref.watch(artifactDatabaseProvider),
  );
});

/// Per-project [SignaturesService] — wraps the artifact-database
/// signature cache and the Ghidra-headless extraction path. Read-
/// only methods (lookup, hasSignaturesFor) short-circuit when the
/// MODULE_GHIDRA toggle is off, so callers can use this provider
/// unconditionally and let the service decide.
final signaturesServiceProvider = Provider<SignaturesService>(
  (ref) => SignaturesService(
    db: ref.watch(artifactDatabaseProvider),
    // Share the same GhidraInstaller the install flow uses, so
    // detect + extract see consistent state for the managed Temurin
    // JRE path (`~/.local/share/resect/jdk/jdk-*/`).
    ghidraInstaller: ref.watch(ghidraInstallerProvider),
  ),
);

/// Cache-aware reader for the Ghidra-extracted call graph. Same
/// table that [SignaturesService.extractFor] writes to in the same
/// transaction as the signatures cache, so any time the signatures
/// cache has data, this one does too.
final callGraphServiceProvider = Provider<CallGraphService>(
  (ref) => CallGraphService(db: ref.watch(artifactDatabaseProvider)),
);

/// Selects which [CallGraphSource] the orchestrator uses for the
/// session. Two implementations:
///
/// - When `MODULE_GHIDRA=1` AND `GHIDRA_DIR` is set, use
///   [GhidraCallGraphSource] — accurate across architectures, picks
///   up indirect calls and Thumb branches the objdump regex would
///   miss, and serves from cache after the first extraction.
/// - Otherwise fall back to [DartEngine.callGraphSource] (the
///   existing objdump-based [DartCallGraphSource]).
///
/// The choice is resolved ONCE at provider construction. Toggling
/// `MODULE_GHIDRA` after the app is running won't live-swap the
/// source — restart Resect for the change to take effect. (The
/// orchestrator caches its capabilities at construction time, so a
/// live swap would require tearing it down anyway.)
final callGraphSourceProvider = Provider<CallGraphSource>((ref) {
  final ghidraEnabled = ref.watch(moduleEnabledProvider('MODULE_GHIDRA'));
  final ghidraDir =
      (ref.watch(systemConfigProvider).values['GHIDRA_DIR'] ?? '').trim();
  if (ghidraEnabled && ghidraDir.isNotEmpty) {
    return GhidraCallGraphSource(
      signaturesService: ref.watch(signaturesServiceProvider),
      callGraphService: ref.watch(callGraphServiceProvider),
    );
  }
  return ref.watch(dartEngineProvider).callGraphSource;
});

/// Look up the cached signature for a single symbol in the currently
/// loaded ELF. Returns null when:
/// - No emulator is loaded
/// - The Ghidra module is disabled
/// - The ELF hasn't been signature-extracted yet
/// - The symbol isn't in the ELF (e.g., external imports)
///
/// Cache-only — never triggers a Ghidra subprocess. The caller
/// (likely a Library-tab action or background job) is responsible
/// for kicking off `SignaturesService.extractFor` when needed.
final signatureForProvider =
    FutureProvider.family<FunctionSignature?, String>((ref, symbolName) async {
  final emulator = ref.watch(currentEmulatorProvider);
  if (emulator == null) return null;
  final firmware = ref.watch(artifactProcessingProvider).valueOrNull;
  final elfHash = firmware?.elfHash;
  if (elfHash == null) return null;
  return ref
      .watch(signaturesServiceProvider)
      .signatureFor(elfHash: elfHash, symbolName: symbolName);
});

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

/// Singleton harness for running a hook against a minimal Renode
/// machine. Used by the Hook DB dialog's ▶ Test button. See
/// [HookTestHarness] for behavior.
final hookTestHarnessProvider =
    Provider<HookTestHarness>((ref) => HookTestHarness());

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
  // While callgraphProvider re-extracts after an ELF switch, valueOrNull
  // still serves the PREVIOUS firmware's graph (riverpod keeps the prior
  // value through a rebuild). Registering this hash with that graph's
  // symbol list would poison the firmware record — wait for the matching
  // graph instead (this provider re-fires when it lands).
  if (callGraph.elfPath != elfPath) return null;

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
/// Returns the artifact pool relevant to the loaded firmware: every
/// global template + every user-authored artifact targeted at this
/// firmware. Used by the Hook Database Viewer dialog. Invalidate after
/// add/delete/reseed to refresh.
final allHooksForFirmwareProvider =
    FutureProvider<List<Artifact>>((ref) async {
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

/// Per-override Renode scope: symbol name → scope string.
///
/// Paired with [hookOverridesProvider]. Missing key or empty string means
/// "no scope" — the hook is applied without a 3rd-arg to `AddHookAtSymbol`,
/// so it lands in the unscoped Python global namespace. Stateful hook
/// builders (read/write/increment) need a non-empty scope to coordinate
/// across symbols.
final hookOverrideScopesProvider =
    StateProvider<Map<String, String>>((ref) => {});

/// Per-symbol compatibility bindings: symbol name → [HookBinding].
///
/// The third layer on top of [hookOverridesProvider] (forced) and
/// [hookPreferencesProvider] (soft re-order). Each binding records which
/// artifact is the preferred substitute for the symbol, the fidelity of
/// that choice (0.0–1.0), and the provenance — classifier rule, LLM
/// model, harness verdict, or user authorship. The synthesizer's
/// iteration ordering uses `COALESCE(binding.fidelity,
/// artifact.intrinsicScore, 0.0)` as the candidate-sort key, so a
/// fidelity-bearing binding wins over the artifact's intrinsic floor.
///
/// Populated by the Stage 1+ classifier and LLM passes (per the
/// radiant-inventing-dream plan), and back-filled at fidelity 1.0 for
/// any user-authored Replacement that already has a matching override
/// on project open.
final hookBindingsProvider =
    StateProvider<Map<String, HookBinding>>((ref) => {});

/// Synthesizer's per-run iteration cap. Pre-existing default of 10
/// matches the orchestrator's `runSynthesizer` default. Exposed as a
/// provider so the closed-loop LLM orchestrator's `AdjustIterationCap`
/// recommendation can mutate it between rounds, and so the eventual
/// auto-tune config dialog can surface it as a user-facing knob.
///
/// SynthesisController reads this when calling
/// `orchestrator.runSynthesizer(...)` so changes take effect on the
/// next synthesis run.
final synthesisMaxIterationsProvider = StateProvider<int>((ref) => 10);

/// Reactive [HookDecisionState] projection of the current project's
/// overlays plus the live comms-protocol config. Consumed by the
/// pre-synthesis report widget (and, eventually, the manifest builder
/// and the headless CLI when those land).
///
/// Builds from the live providers — not the persisted [Emulator] —
/// so user edits in the Hook Database / Comms / Symbol-picker tabs
/// surface in the report without waiting for an autosave round-trip.
/// Null when no emulator is open.
final hookDecisionStateProvider = Provider<HookDecisionState?>((ref) {
  final emulator = ref.watch(currentEmulatorProvider);
  if (emulator == null) return null;

  final firmware = ref.watch(artifactProcessingProvider).valueOrNull;
  // elfHash can be empty if the firmware hasn't finished processing
  // yet — the report still works, the field just shows blank.
  final elfHash = firmware?.elfHash ?? '';

  final live = emulator.copyWith(
    hookOverrides: ref.watch(hookOverridesProvider),
    hookOverrideScopes: ref.watch(hookOverrideScopesProvider),
    hookPreferences: ref.watch(hookPreferencesProvider),
    hookBindings: ref.watch(hookBindingsProvider),
    // hooks (warm-start) lives on the Emulator itself, no provider
    // shadow today — pass through.
  );

  final commsConfig = ref.watch(commsProtocolConfigProvider);
  final commsConfigsForBuilder = <CommsClass, CommsProtocolStatus>{
    for (final entry in commsConfig.entries)
      entry.key: (virtualized: entry.value.virtualized, port: entry.value.port),
  };

  return buildHookDecisionState(
    emulator: live,
    elfHash: elfHash,
    commsConfigs: commsConfigsForBuilder,
  );
});

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
