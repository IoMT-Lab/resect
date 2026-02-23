import 'package:uuid/uuid.dart';

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

  /// Open-ended metadata for future expansion
  final Map<String, dynamic> metadata;

  /// Documents associated with this emulator project.
  /// Files are stored in ~/.config/call_graph_viewer/projects/<id>/documents/
  final List<DocumentEntry> documents;

  const Emulator({
    required this.id,
    required this.name,
    this.emulatorPath,
    required this.createdAt,
    required this.modifiedAt,
    this.elfFilePath,
    this.baseImagePath,
    required this.emulationConfig,
    required this.uiState,
    this.hooks = const {},
    this.hookPreferences = const {},
    this.hookOverrides = const {},
    this.metadata = const {},
    this.documents = const [],
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
    final metadata = json['metadata'] as Map<String, dynamic>? ?? {};
    final documents = (json['documents'] as List<dynamic>?)
        ?.map((d) => DocumentEntry.fromJson(d as Map<String, dynamic>))
        .toList() ?? [];

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
      metadata: metadata,
      documents: documents,
    );
  }

  /// Convert emulator to JSON for saving
  Map<String, dynamic> toJson() {
    return {
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
      if (documents.isNotEmpty) 'documents': documents.map((d) => d.toJson()).toList(),
      'ui_state': uiState.toJson(),
      'metadata': metadata,
    };
  }

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
    Map<String, dynamic>? metadata,
    List<DocumentEntry>? documents,
  }) {
    return Emulator(
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
      metadata: metadata ?? this.metadata,
      documents: documents ?? this.documents,
    );
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

  factory DocumentEntry.fromJson(Map<String, dynamic> json) {
    return DocumentEntry(
      filename: json['filename'] as String,
      displayName: json['display_name'] as String? ?? json['filename'] as String,
      addedAt: DateTime.parse(json['added_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'display_name': displayName,
      'added_at': addedAt.toIso8601String(),
    };
  }
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

  factory EmulationConfig.defaults() {
    return const EmulationConfig();
  }

  factory EmulationConfig.fromJson(Map<String, dynamic> json) {
    return EmulationConfig(
      startFrom: json['start_from'] as String?,
      endAt: (json['end_at'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      pauseOnUnhandled: json['pause_on_unhandled'] as bool? ?? true,
      memoryMapPath: json['memory_map'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'start_from': startFrom,
      'end_at': endAt,
      'pause_on_unhandled': pauseOnUnhandled,
      'memory_map': memoryMapPath,
    };
  }

  EmulationConfig copyWith({
    String? startFrom,
    List<String>? endAt,
    bool? pauseOnUnhandled,
    String? memoryMapPath,
  }) {
    return EmulationConfig(
      startFrom: startFrom ?? this.startFrom,
      endAt: endAt ?? this.endAt,
      pauseOnUnhandled: pauseOnUnhandled ?? this.pauseOnUnhandled,
      memoryMapPath: memoryMapPath ?? this.memoryMapPath,
    );
  }
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

  factory UiState.defaults() {
    return const UiState();
  }

  factory UiState.fromJson(Map<String, dynamic> json) {
    return UiState(
      leftSidebarExpanded: json['left_sidebar_expanded'] as bool? ?? true,
      rightSidebarExpanded: json['right_sidebar_expanded'] as bool? ?? true,
      selectedSymbol: json['selected_symbol'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'left_sidebar_expanded': leftSidebarExpanded,
      'right_sidebar_expanded': rightSidebarExpanded,
      'selected_symbol': selectedSymbol,
    };
  }

  UiState copyWith({
    bool? leftSidebarExpanded,
    bool? rightSidebarExpanded,
    String? selectedSymbol,
  }) {
    return UiState(
      leftSidebarExpanded: leftSidebarExpanded ?? this.leftSidebarExpanded,
      rightSidebarExpanded: rightSidebarExpanded ?? this.rightSidebarExpanded,
      selectedSymbol: selectedSymbol ?? this.selectedSymbol,
    );
  }
}
