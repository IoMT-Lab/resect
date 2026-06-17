import 'package:uuid/uuid.dart';

import 'call_graph.dart';
import 'comms_assignment.dart';
import 'hook_binding.dart';
import 'last_run_insight.dart';
import 'round_snapshot.dart';
import 'synthesizer_result.dart';

/// Represents an emulator configuration containing firmware files, settings,
/// and UI state.
///
/// Emulators are saved as `.emu` JSON files that users can create, save,
/// load, and export. This provides persistence between app sessions and allows
/// organizing emulation work.
class Emulator {
  /// Unique identifier for this emulator
  final String id;

  /// User-friendly emulator name
  final String name;

  /// Absolute path to the .emu file (null if never saved)
  final String? emulatorPath;

  /// When this emulator was created
  final DateTime createdAt;

  /// When this emulator was last modified
  final DateTime modifiedAt;

  /// Path to the primary firmware ELF file
  final String? elfFilePath;

  /// Path to the Renode platform description file (.repl)
  final String? baseImagePath;

  /// Emulation configuration
  final EmulationConfig emulationConfig;

  /// UI state for restoring workspace appearance
  final UiState uiState;

  /// Resolved hooks from synthesizer (symbol name → hook code)
  final Map<String, String> hooks;

  /// User-selected hook preferences (symbol name → artifact DB ID).
  /// Tells the synthesizer which hook to try first for each symbol.
  final Map<String, int> hookPreferences;

  /// Forced hook overrides (symbol name → artifact DB ID).
  /// These hooks are applied unconditionally before emulation starts,
  /// regardless of whether the function causes an unhandled access.
  final Map<String, int> hookOverrides;

  /// Per-override Renode scope (symbol name → scope string). Missing key
  /// or empty string means "no scope" — `AddHookAtSymbol` gets no 3rd arg
  /// and the hook lands in the unscoped Python global namespace. Paired
  /// with [hookOverrides]; entries here without a corresponding
  /// [hookOverrides] entry are ignored at apply time.
  final Map<String, String> hookOverrideScopes;

  /// Per-symbol compatibility bindings (symbol name → [HookBinding]).
  /// The third layer on top of [hookOverrides] (forced) and
  /// [hookPreferences] (soft re-order): a fidelity-scored record of which
  /// artifact this project considers the best substitute for each
  /// symbol, plus how that decision was reached (classifier rule, LLM
  /// generation, harness pass, user authorship). Consumed by the
  /// synthesizer's iteration ordering — see [HookBinding.fidelity].
  final Map<String, HookBinding> hookBindings;

  /// Open-ended metadata for future expansion
  final Map<String, dynamic> metadata;

  /// Documents associated with this emulator project.
  /// Files are stored in ~/.config/call_graph_viewer/projects/<id>/documents/
  final List<DocumentEntry> documents;

  /// Cached call graph for this project's ELF. Persisted so reopening the
  /// project restores it without re-running objdump. Null until generated.
  final CallGraph? cachedCallGraph;

  /// Last synthesis result. Persisted alongside [executedSymbols] so the
  /// fidelity report can be reconstructed on reopen without re-running.
  final SynthesizerResult? synthesisResult;

  /// Symbols executed during the last synthesis/run — the coverage input the
  /// fidelity calculation needs to reproduce its result on reopen.
  final Set<String> executedSymbols;

  /// Comms-bus classification per symbol (i2c / spi / uart / unclassified +
  /// optional read/write role). Populated by the classifier when a call
  /// graph is generated and merged across regenerations; persisted so the
  /// Comms tab survives project reopens. Symbols absent from this map are
  /// not surfaced in the Comms tab.
  final Map<String, CommsAssignment> commsAssignments;

  /// LLM-generated advisory text for the most-recently-generated
  /// insight. Cached against [SynthesizerResult.manifest]'s
  /// `synthesizerRunId`; goes stale when [synthesisResult] changes
  /// past that point. Null when the user hasn't asked for an insight
  /// yet. See [LastRunInsight].
  final LastRunInsight? lastRunInsight;

  /// History of closed-loop LLM auto-tune rounds. Ordered by round
  /// number (round 0 is the baseline synthesis; rounds 1..N each
  /// follow a user-reviewed batch of [Recommendation]s). FIFO-pruned
  /// at [roundSnapshotCap] when [appendRoundSnapshot] is called.
  /// Empty when no auto-tune session has run against this project.
  final List<RoundSnapshot> roundSnapshots;

  /// Maximum length of [roundSnapshots]. When an append would push
  /// the list past this value the oldest snapshots are dropped FIFO
  /// — see [appendRoundSnapshot]. Configurable per-project from the
  /// auto-tune configuration dialog; default is [defaultSnapshotCap].
  final int roundSnapshotCap;

  /// Default cap on [roundSnapshots] length when the project hasn't
  /// configured a custom value.
  static const defaultSnapshotCap = 100;

  const Emulator({
    required this.id,
    required this.name,
    required this.createdAt, required this.modifiedAt, required this.emulationConfig, required this.uiState, this.emulatorPath,
    this.elfFilePath,
    this.baseImagePath,
    this.hooks = const {},
    this.hookPreferences = const {},
    this.hookOverrides = const {},
    this.hookOverrideScopes = const {},
    this.hookBindings = const {},
    this.metadata = const {},
    this.documents = const [],
    this.cachedCallGraph,
    this.synthesisResult,
    this.executedSymbols = const {},
    this.commsAssignments = const {},
    this.lastRunInsight,
    this.roundSnapshots = const [],
    this.roundSnapshotCap = defaultSnapshotCap,
  });

  /// Create a new emulator with default values
  factory Emulator.create({
    required String name,
    String? elfFilePath,
    String? baseImagePath,
  }) {
    final now = DateTime.now();
    return Emulator(
      id: const Uuid().v4(),
      name: name,
      emulatorPath: null, // Not saved yet
      createdAt: now,
      modifiedAt: now,
      elfFilePath: elfFilePath,
      baseImagePath: baseImagePath,
      emulationConfig: EmulationConfig.defaults(),
      uiState: UiState.defaults(),
      hooks: {},
      hookPreferences: {},
      hookOverrides: {},
      metadata: {},
      documents: [],
    );
  }

  /// Load emulator from JSON (supports both 'emulator' and legacy 'project' keys)
  factory Emulator.fromJson(Map<String, dynamic> json) {
    final emulatorData = (json['emulator'] ?? json['project']) as Map<String, dynamic>;
    final firmware = json['firmware'] as Map<String, dynamic>?;
    final emulation = json['emulation'] as Map<String, dynamic>?;
    final uiState = json['ui_state'] as Map<String, dynamic>?;
    final hooks = (json['hooks'] as Map<String, dynamic>?)
        ?.map((k, v) => MapEntry(k, v as String)) ?? {};
    final hookPreferences = (json['hook_preferences'] as Map<String, dynamic>?)
        ?.map((k, v) => MapEntry(k, v as int)) ?? {};
    final hookOverrides = (json['hook_overrides'] as Map<String, dynamic>?)
        ?.map((k, v) => MapEntry(k, v as int)) ?? {};
    final hookOverrideScopes =
        (json['hook_override_scopes'] as Map<String, dynamic>?)
                ?.map((k, v) => MapEntry(k, v as String)) ??
            {};
    final hookBindings = (json['hook_bindings'] as Map<String, dynamic>?)
            ?.map((k, v) =>
                MapEntry(k, HookBinding.fromJson(v as Map<String, dynamic>))) ??
        <String, HookBinding>{};
    final metadata = json['metadata'] as Map<String, dynamic>? ?? {};
    final documents = (json['documents'] as List<dynamic>?)
        ?.map((d) => DocumentEntry.fromJson(d as Map<String, dynamic>))
        .toList() ?? [];
    final callGraphJson = json['call_graph'] as Map<String, dynamic>?;
    final synthesisResultJson = json['synthesis_result'] as Map<String, dynamic>?;
    final executedSymbols = (json['executed_symbols'] as List<dynamic>?)
        ?.map((e) => e as String)
        .toSet() ?? <String>{};
    final commsAssignments = (json['comms_assignments'] as Map<String, dynamic>?)
            ?.map((k, v) =>
                MapEntry(k, CommsAssignment.fromJson(v as Map<String, dynamic>))) ??
        <String, CommsAssignment>{};
    final lastRunInsightJson =
        json['last_run_insight'] as Map<String, dynamic>?;
    final roundSnapshots = (json['round_snapshots'] as List<dynamic>?)
            ?.map((e) =>
                RoundSnapshot.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <RoundSnapshot>[];
    final roundSnapshotCap =
        json['round_snapshot_cap'] as int? ?? Emulator.defaultSnapshotCap;

    return Emulator(
      id: emulatorData['id'] as String,
      name: emulatorData['name'] as String,
      emulatorPath: null, // Set by repository after loading
      createdAt: DateTime.parse(emulatorData['created_at'] as String),
      modifiedAt: DateTime.parse(emulatorData['modified_at'] as String),
      elfFilePath: firmware?['elf_file'] as String?,
      baseImagePath: firmware?['base_image'] as String?,
      emulationConfig: EmulationConfig.fromJson(emulation ?? {}),
      uiState: UiState.fromJson(uiState ?? {}),
      hooks: hooks,
      hookPreferences: hookPreferences,
      hookOverrides: hookOverrides,
      hookOverrideScopes: hookOverrideScopes,
      hookBindings: hookBindings,
      metadata: metadata,
      documents: documents,
      cachedCallGraph:
          callGraphJson != null ? CallGraph.fromSerializedJson(callGraphJson) : null,
      synthesisResult: synthesisResultJson != null
          ? SynthesizerResult.fromJson(synthesisResultJson)
          : null,
      executedSymbols: executedSymbols,
      commsAssignments: commsAssignments,
      lastRunInsight: lastRunInsightJson != null
          ? LastRunInsight.fromJson(lastRunInsightJson)
          : null,
      roundSnapshots: roundSnapshots,
      roundSnapshotCap: roundSnapshotCap,
    );
  }

  /// Convert emulator to JSON for saving
  Map<String, dynamic> toJson() => {
      'version': '1.0',
      'emulator': {
        'id': id,
        'name': name,
        'created_at': createdAt.toIso8601String(),
        'modified_at': modifiedAt.toIso8601String(),
      },
      'firmware': {
        'elf_file': elfFilePath,
        'base_image': baseImagePath,
      },
      'emulation': emulationConfig.toJson(),
      if (hooks.isNotEmpty) 'hooks': hooks,
      if (hookPreferences.isNotEmpty) 'hook_preferences': hookPreferences,
      if (hookOverrides.isNotEmpty) 'hook_overrides': hookOverrides,
      if (hookOverrideScopes.isNotEmpty)
        'hook_override_scopes': hookOverrideScopes,
      if (hookBindings.isNotEmpty)
        'hook_bindings':
            hookBindings.map((k, v) => MapEntry(k, v.toJson())),
      if (documents.isNotEmpty) 'documents': documents.map((d) => d.toJson()).toList(),
      if (cachedCallGraph != null) 'call_graph': cachedCallGraph!.toJson(),
      if (synthesisResult != null) 'synthesis_result': synthesisResult!.toJson(),
      if (executedSymbols.isNotEmpty) 'executed_symbols': executedSymbols.toList(),
      if (commsAssignments.isNotEmpty)
        'comms_assignments': commsAssignments.map((k, v) => MapEntry(k, v.toJson())),
      if (lastRunInsight != null) 'last_run_insight': lastRunInsight!.toJson(),
      if (roundSnapshots.isNotEmpty)
        'round_snapshots': roundSnapshots.map((s) => s.toJson()).toList(),
      if (roundSnapshotCap != defaultSnapshotCap)
        'round_snapshot_cap': roundSnapshotCap,
      'ui_state': uiState.toJson(),
      'metadata': metadata,
    };

  /// Create a copy with updated fields
  Emulator copyWith({
    String? id,
    String? name,
    String? emulatorPath,
    DateTime? createdAt,
    DateTime? modifiedAt,
    String? elfFilePath,
    String? baseImagePath,
    EmulationConfig? emulationConfig,
    UiState? uiState,
    Map<String, String>? hooks,
    Map<String, int>? hookPreferences,
    Map<String, int>? hookOverrides,
    Map<String, String>? hookOverrideScopes,
    Map<String, HookBinding>? hookBindings,
    Map<String, dynamic>? metadata,
    List<DocumentEntry>? documents,
    CallGraph? cachedCallGraph,
    bool clearCachedCallGraph = false,
    SynthesizerResult? synthesisResult,
    bool clearSynthesisResult = false,
    Set<String>? executedSymbols,
    Map<String, CommsAssignment>? commsAssignments,
    LastRunInsight? lastRunInsight,
    bool clearLastRunInsight = false,
    List<RoundSnapshot>? roundSnapshots,
    int? roundSnapshotCap,
  }) => Emulator(
      id: id ?? this.id,
      name: name ?? this.name,
      emulatorPath: emulatorPath ?? this.emulatorPath,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      elfFilePath: elfFilePath ?? this.elfFilePath,
      baseImagePath: baseImagePath ?? this.baseImagePath,
      emulationConfig: emulationConfig ?? this.emulationConfig,
      uiState: uiState ?? this.uiState,
      hooks: hooks ?? this.hooks,
      hookPreferences: hookPreferences ?? this.hookPreferences,
      hookOverrides: hookOverrides ?? this.hookOverrides,
      hookOverrideScopes: hookOverrideScopes ?? this.hookOverrideScopes,
      hookBindings: hookBindings ?? this.hookBindings,
      metadata: metadata ?? this.metadata,
      documents: documents ?? this.documents,
      cachedCallGraph:
          clearCachedCallGraph ? null : (cachedCallGraph ?? this.cachedCallGraph),
      synthesisResult:
          clearSynthesisResult ? null : (synthesisResult ?? this.synthesisResult),
      executedSymbols: executedSymbols ?? this.executedSymbols,
      commsAssignments: commsAssignments ?? this.commsAssignments,
      lastRunInsight: clearLastRunInsight
          ? null
          : (lastRunInsight ?? this.lastRunInsight),
      roundSnapshots: roundSnapshots ?? this.roundSnapshots,
      roundSnapshotCap: roundSnapshotCap ?? this.roundSnapshotCap,
    );

  /// Most recent snapshot, or null when the auto-tune history is
  /// empty.
  RoundSnapshot? get latestSnapshot =>
      roundSnapshots.isEmpty ? null : roundSnapshots.last;

  /// Snapshot for the given round number, or null when no snapshot
  /// is recorded for that round (e.g. it was pruned, or the round
  /// number is from a future not-yet-run session).
  RoundSnapshot? snapshotForRound(int round) {
    for (final s in roundSnapshots) {
      if (s.round == round) return s;
    }
    return null;
  }

  /// All snapshots that recorded the given synthesizer run. Typically
  /// a singleton — each round's snapshot pairs with a unique run ID
  /// — but the list shape leaves room for future branch-and-explore
  /// where multiple snapshots could share a baseline run.
  List<RoundSnapshot> snapshotsForRunId(String runId) =>
      roundSnapshots
          .where((s) => s.synthesizerRunId == runId)
          .toList(growable: false);

  /// Append [snapshot] to [roundSnapshots], FIFO-pruning to
  /// [roundSnapshotCap]. Returns a copy of this [Emulator] with the
  /// updated list; the original is left unchanged.
  ///
  /// If the cap is positive and the new length would exceed it, the
  /// oldest snapshots are dropped from the front of the list until
  /// the length equals the cap. A cap of 0 means "drop everything"
  /// (the new snapshot is also dropped — degenerate but consistent);
  /// a negative cap is treated as unlimited.
  Emulator appendRoundSnapshot(RoundSnapshot snapshot) {
    final next = [...roundSnapshots, snapshot];
    final cap = roundSnapshotCap;
    if (cap >= 0 && next.length > cap) {
      next.removeRange(0, next.length - cap);
    }
    return copyWith(roundSnapshots: next);
  }
}

/// A document file associated with an emulator project.
///
/// Files are stored in the project documents directory. Only the filename
/// is persisted in the .emu JSON; the full path is derived from the emulator ID.
class DocumentEntry {
  /// Filename within the documents directory (e.g., "programming_guide.pdf")
  final String filename;

  /// User-facing display name (original filename before deduplication)
  final String displayName;

  /// When this document was added to the project
  final DateTime addedAt;

  const DocumentEntry({
    required this.filename,
    required this.displayName,
    required this.addedAt,
  });

  factory DocumentEntry.fromJson(Map<String, dynamic> json) => DocumentEntry(
      filename: json['filename'] as String,
      displayName: json['display_name'] as String? ?? json['filename'] as String,
      addedAt: DateTime.parse(json['added_at'] as String),
    );

  Map<String, dynamic> toJson() => {
      'filename': filename,
      'display_name': displayName,
      'added_at': addedAt.toIso8601String(),
    };
}

/// Emulation configuration settings
class EmulationConfig {
  /// Optional symbol/address to start execution from
  final String? startFrom;

  /// List of symbols/addresses to pause at (breakpoints)
  final List<String> endAt;

  /// Whether to pause on unhandled memory access
  final bool pauseOnUnhandled;

  /// Path to a memory map JSON file (snapshot format) to apply after firmware load
  final String? memoryMapPath;

  const EmulationConfig({
    this.startFrom,
    this.endAt = const [],
    this.pauseOnUnhandled = true,
    this.memoryMapPath,
  });

  factory EmulationConfig.defaults() => const EmulationConfig();

  factory EmulationConfig.fromJson(Map<String, dynamic> json) => EmulationConfig(
      startFrom: json['start_from'] as String?,
      endAt: (json['end_at'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      pauseOnUnhandled: json['pause_on_unhandled'] as bool? ?? true,
      memoryMapPath: json['memory_map'] as String?,
    );

  Map<String, dynamic> toJson() => {
      'start_from': startFrom,
      'end_at': endAt,
      'pause_on_unhandled': pauseOnUnhandled,
      'memory_map': memoryMapPath,
    };

  EmulationConfig copyWith({
    String? startFrom,
    List<String>? endAt,
    bool? pauseOnUnhandled,
    String? memoryMapPath,
  }) => EmulationConfig(
      startFrom: startFrom ?? this.startFrom,
      endAt: endAt ?? this.endAt,
      pauseOnUnhandled: pauseOnUnhandled ?? this.pauseOnUnhandled,
      memoryMapPath: memoryMapPath ?? this.memoryMapPath,
    );
}

/// UI state for restoring workspace appearance
class UiState {
  /// Whether left sidebar (Explorer) is expanded
  final bool leftSidebarExpanded;

  /// Whether right sidebar (Metadata) is expanded
  final bool rightSidebarExpanded;

  /// Currently selected symbol in the graph
  final String? selectedSymbol;

  const UiState({
    this.leftSidebarExpanded = true,
    this.rightSidebarExpanded = true,
    this.selectedSymbol,
  });

  factory UiState.defaults() => const UiState();

  factory UiState.fromJson(Map<String, dynamic> json) => UiState(
      leftSidebarExpanded: json['left_sidebar_expanded'] as bool? ?? true,
      rightSidebarExpanded: json['right_sidebar_expanded'] as bool? ?? true,
      selectedSymbol: json['selected_symbol'] as String?,
    );

  Map<String, dynamic> toJson() => {
      'left_sidebar_expanded': leftSidebarExpanded,
      'right_sidebar_expanded': rightSidebarExpanded,
      'selected_symbol': selectedSymbol,
    };

  UiState copyWith({
    bool? leftSidebarExpanded,
    bool? rightSidebarExpanded,
    String? selectedSymbol,
  }) => UiState(
      leftSidebarExpanded: leftSidebarExpanded ?? this.leftSidebarExpanded,
      rightSidebarExpanded: rightSidebarExpanded ?? this.rightSidebarExpanded,
      selectedSymbol: selectedSymbol ?? this.selectedSymbol,
    );
}
