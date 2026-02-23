import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../../providers/app_providers.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import '../dialogs/new_emulator_dialog.dart';
import '../dialogs/hook_database_dialog.dart';

/// EMULATOR tab content for Explorer sidebar.
///
/// Displays emulator structure: firmware files, configuration, hooks, etc.
/// Shows "No emulator open" state when no emulator is active.
/// When synthesis is running, shows live progress with a circular countdown.
class EmulatorExplorerWidget extends ConsumerStatefulWidget {
  const EmulatorExplorerWidget({super.key});

  @override
  ConsumerState<EmulatorExplorerWidget> createState() => _EmulatorExplorerWidgetState();
}

class _EmulatorExplorerWidgetState extends ConsumerState<EmulatorExplorerWidget> {
  @override
  Widget build(BuildContext context) {
    final emulator = ref.watch(currentEmulatorProvider);

    if (emulator == null) {
      return _buildNoEmulatorView(context);
    }

    return _buildEmulatorTreeView(context, emulator);
  }

  /// Show empty state when no emulator is open
  Widget _buildNoEmulatorView(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.memory,
              size: 48,
              color: Colors.grey.shade600,
            ),
            const SizedBox(height: 16),
            Text(
              'No Emulator Open',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Create or open an emulator to get started',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _createNewEmulator(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New Emulator'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openEmulator(context),
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Open Emulator'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Display emulator structure as a tree
  Widget _buildEmulatorTreeView(BuildContext context, Emulator emulator) {
    final isDirty = ref.watch(emulatorDirtyProvider);
    final synthesisProgress = ref.watch(synthesisProgressProvider);

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        // Synthesis progress (when active)
        if (synthesisProgress != null) ...[
          _SynthesisProgressSection(progress: synthesisProgress),
          const SizedBox(height: 12),
        ],

        // Emulator name header
        _buildEmulatorHeader(context, emulator, isDirty),

        const SizedBox(height: 12),

        // Firmware section
        _buildSection(
          context,
          title: 'Firmware',
          icon: Icons.memory,
          children: [
            if (emulator.elfFilePath != null)
              _buildFileNode(
                context,
                label: 'ELF File',
                path: emulator.elfFilePath!,
                icon: Icons.insert_drive_file,
              )
            else
              _buildEmptyNode(context, 'No firmware file'),
          ],
        ),

        const SizedBox(height: 8),

        // Platform section
        _buildSection(
          context,
          title: 'Platform',
          icon: Icons.developer_board,
          children: [
            if (emulator.baseImagePath != null)
              _buildFileNode(
                context,
                label: 'Base Image',
                path: emulator.baseImagePath!,
                icon: Icons.insert_drive_file,
              )
            else
              _buildEmptyNode(context, 'No platform file'),
          ],
        ),

        const SizedBox(height: 8),

        // Emulation config section
        _buildSection(
          context,
          title: 'Execution Range',
          icon: Icons.settings,
          children: [
            _buildEditableConfigNode(
              context,
              label: 'Start From',
              value: emulator.emulationConfig.startFrom,
              onTap: () => _pickSymbol(context, emulator, isStartFrom: true),
              onClear: emulator.emulationConfig.startFrom != null
                  ? () => _updateConfig(emulator, startFrom: '')
                  : null,
            ),
            _buildEditableConfigNode(
              context,
              label: 'Stop At',
              value: emulator.emulationConfig.endAt.isNotEmpty
                  ? emulator.emulationConfig.endAt.first
                  : null,
              onTap: () => _pickSymbol(context, emulator, isStartFrom: false),
              onClear: emulator.emulationConfig.endAt.isNotEmpty
                  ? () => _updateConfig(emulator, endAt: const [])
                  : null,
            ),
            _buildConfigNode(
              context,
              label: 'Pause on Unhandled',
              value: emulator.emulationConfig.pauseOnUnhandled ? 'Yes' : 'No',
            ),
            _buildEditableConfigNode(
              context,
              label: 'Memory Map',
              value: emulator.emulationConfig.memoryMapPath != null
                  ? p.basename(emulator.emulationConfig.memoryMapPath!)
                  : null,
              onTap: () => _pickMemoryMap(emulator),
              onClear: emulator.emulationConfig.memoryMapPath != null
                  ? () => _updateConfig(emulator, memoryMapPath: '')
                  : null,
            ),
          ],
        ),

        // Hooks section — always shown so the database button is accessible
        const SizedBox(height: 8),
        _buildSection(
          context,
          title: 'Hooks',
          icon: Icons.link,
          trailing: IconButton(
            icon: const Icon(Icons.storage, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Hook Database',
            onPressed: () => HookDatabaseDialog.show(context),
          ),
          children: [
            if (emulator.hookOverrides.isEmpty && emulator.hookPreferences.isEmpty && emulator.hooks.isEmpty)
              Text(
                'No hooks yet',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
              ),
            // Forced overrides (unconditional substitutions)
            if (emulator.hookOverrides.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'FORCED (${emulator.hookOverrides.length})',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: Colors.red.shade300,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                ...emulator.hookOverrides.entries.map((entry) => InkWell(
                      onTap: () => ref.read(selectedSymbolProvider.notifier).state = entry.key,
                      borderRadius: BorderRadius.circular(3),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Row(
                          children: [
                            Icon(Icons.lock, size: 10, color: Colors.red.shade300),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                entry.key,
                                style: const TextStyle(fontSize: 10),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '#${entry.value}',
                              style: TextStyle(fontSize: 9, color: Colors.red.shade400),
                            ),
                          ],
                        ),
                      ),
                    )),
                if (emulator.hookPreferences.isNotEmpty || emulator.hooks.isNotEmpty)
                  const Divider(height: 8),
              ],
              // Preferences (user-selected hook ordering)
              if (emulator.hookPreferences.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'PREFERENCES (${emulator.hookPreferences.length})',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange.shade300,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                ...emulator.hookPreferences.entries.map((entry) => InkWell(
                      onTap: () => ref.read(selectedSymbolProvider.notifier).state = entry.key,
                      borderRadius: BorderRadius.circular(3),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Row(
                          children: [
                            Icon(Icons.tune, size: 10, color: Colors.orange.shade300),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                entry.key,
                                style: const TextStyle(fontSize: 10),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '#${entry.value}',
                              style: TextStyle(fontSize: 9, color: Colors.orange.shade400),
                            ),
                          ],
                        ),
                      ),
                    )),
                if (emulator.hooks.isNotEmpty)
                  const Divider(height: 8),
              ],
              // Resolved hooks from synthesis
              if (emulator.hooks.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'RESOLVED (${emulator.hooks.length})',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: Colors.green.shade300,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                ...emulator.hooks.entries.map((entry) => InkWell(
                      onTap: () => ref.read(selectedSymbolProvider.notifier).state = entry.key,
                      borderRadius: BorderRadius.circular(3),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Row(
                          children: [
                            Icon(Icons.functions, size: 10, color: Colors.green.shade300),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                entry.key,
                                style: const TextStyle(fontSize: 10),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              _hookSummary(entry.value),
                              style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      ),
                    )),
              ],
            ],
          ),

        // Documents section
        const SizedBox(height: 8),
        _buildSection(
          context,
          title: 'Documents',
          icon: Icons.description,
          trailing: IconButton(
            icon: const Icon(Icons.add, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Add Document',
            onPressed: () => _addDocument(context, emulator),
          ),
          children: [
            if (emulator.documents.isEmpty)
              Text(
                'No documents yet',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
              ),
            ...emulator.documents.map((doc) =>
              _buildDocumentNode(context, emulator, doc),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmulatorHeader(BuildContext context, Emulator emulator, bool isDirty) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(
            Icons.memory,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        emulator.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isDirty)
                      const Text(
                        ' *',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Modified: ${_formatDate(emulator.modifiedAt)}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required IconData icon,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: Colors.grey),
            const SizedBox(width: 6),
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            if (trailing != null) ...[
              const Spacer(),
              trailing,
            ],
          ],
        ),
        const SizedBox(height: 4),
        Container(
          margin: const EdgeInsets.only(left: 12),
          padding: const EdgeInsets.only(left: 8),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: Colors.grey, width: 1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildFileNode(
    BuildContext context, {
    required String label,
    required String path,
    required IconData icon,
  }) {
    final fileName = path.split('/').last;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 12, color: Colors.blue.shade300),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: const TextStyle(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  path,
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyNode(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        message,
        style: TextStyle(
          fontSize: 11,
          fontStyle: FontStyle.italic,
          color: Colors.grey.shade600,
        ),
      ),
    );
  }

  Widget _buildConfigNode(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Interactive config row with tap-to-edit and clear button.
  Widget _buildEditableConfigNode(
    BuildContext context, {
    required String label,
    required String? value,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(3),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
                      child: Text(
                        value ?? 'Not set',
                        style: TextStyle(
                          fontSize: 11,
                          color: value != null ? Colors.blue.shade300 : Colors.grey.shade600,
                          fontStyle: value == null ? FontStyle.italic : FontStyle.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                if (onClear != null)
                  InkWell(
                    onTap: onClear,
                    borderRadius: BorderRadius.circular(8),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 12, color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Show symbol picker dialog and update the emulator config.
  Future<void> _pickSymbol(BuildContext context, Emulator emulator, {required bool isStartFrom}) async {
    final callgraphAsync = ref.read(callgraphProvider);
    final callGraph = callgraphAsync.valueOrNull;

    if (callGraph == null || callGraph.symbols.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Load a firmware ELF first to select symbols')),
        );
      }
      return;
    }

    final symbols = callGraph.symbols.keys.toList()..sort();
    final selected = await _showSymbolPickerDialog(context, symbols, isStartFrom ? 'Start From' : 'Stop At');
    if (selected == null) return;

    if (isStartFrom) {
      _updateConfig(emulator, startFrom: selected);
    } else {
      _updateConfig(emulator, endAt: [selected]);
    }
  }

  /// Pick a memory map JSON file via file picker.
  Future<void> _pickMemoryMap(Emulator emulator) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Select Memory Map File',
    );

    if (result == null || result.files.single.path == null) return;
    _updateConfig(emulator, memoryMapPath: result.files.single.path!);
  }

  /// Update emulator config and mark dirty.
  ///
  /// Pass empty string for [startFrom] or [memoryMapPath] to clear it
  /// (since copyWith treats null as "keep").
  void _updateConfig(Emulator emulator, {String? startFrom, List<String>? endAt, String? memoryMapPath}) {
    final clearStartFrom = startFrom == '';
    final clearMemoryMap = memoryMapPath == '';
    final newConfig = EmulationConfig(
      startFrom: clearStartFrom ? null : (startFrom ?? emulator.emulationConfig.startFrom),
      endAt: endAt ?? emulator.emulationConfig.endAt,
      pauseOnUnhandled: emulator.emulationConfig.pauseOnUnhandled,
      memoryMapPath: clearMemoryMap ? null : (memoryMapPath ?? emulator.emulationConfig.memoryMapPath),
    );

    final updated = emulator.copyWith(emulationConfig: newConfig);
    ref.read(currentEmulatorProvider.notifier).state = updated;
    ref.read(emulatorDirtyProvider.notifier).state = true;
  }

  /// Show a dialog with a search field and scrollable symbol list.
  Future<String?> _showSymbolPickerDialog(BuildContext context, List<String> symbols, String title) {
    return showDialog<String>(
      context: context,
      builder: (context) => _SymbolPickerDialog(symbols: symbols, title: title),
    );
  }

  /// Derive a short summary from hook Python code.
  String _hookSummary(String code) {
    final trimmed = code.trim();
    if (trimmed.contains('Create(0,')) return 'ret 0';
    if (trimmed.contains('Create(1,')) return 'ret 1';
    final lastLine = trimmed.split('\n').last.trim();
    return lastLine.length > 20 ? '${lastLine.substring(0, 17)}...' : lastLine;
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  // ===========================================================================
  // DOCUMENT HELPERS
  // ===========================================================================

  Widget _buildDocumentNode(BuildContext context, Emulator emulator, DocumentEntry doc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Icon(
            _documentIcon(doc.filename),
            size: 10,
            color: Colors.blue.shade300,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Tooltip(
              message: doc.filename,
              child: Text(
                doc.displayName,
                style: const TextStyle(fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          InkWell(
            onTap: () => _openDocument(emulator, doc),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.open_in_new, size: 10, color: Colors.grey.shade500),
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: () => _removeDocument(emulator, doc),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close, size: 10, color: Colors.grey.shade500),
            ),
          ),
        ],
      ),
    );
  }

  IconData _documentIcon(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'c':
      case 'h':
      case 'cpp':
      case 'py':
      case 'dart':
      case 'rs':
      case 'js':
      case 'ts':
        return Icons.code;
      case 'md':
      case 'txt':
      case 'rst':
        return Icons.article;
      default:
        return Icons.insert_drive_file;
    }
  }

  Future<void> _addDocument(BuildContext context, Emulator emulator) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      dialogTitle: 'Add Documents',
    );

    if (result == null || result.files.isEmpty) return;

    final repository = ref.read(emulatorRepositoryProvider);
    var updated = emulator;

    for (final file in result.files) {
      if (file.path == null) continue;
      try {
        final entry = await repository.addDocument(emulator.id, file.path!);
        updated = updated.copyWith(
          documents: [...updated.documents, entry],
          modifiedAt: DateTime.now(),
        );
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to add ${file.name}: $e')),
          );
        }
      }
    }

    ref.read(currentEmulatorProvider.notifier).state = updated;
    ref.read(emulatorDirtyProvider.notifier).state = true;
  }

  Future<void> _removeDocument(Emulator emulator, DocumentEntry doc) async {
    final repository = ref.read(emulatorRepositoryProvider);
    try {
      await repository.removeDocument(emulator.id, doc.filename);
    } catch (_) {
      // File might already be gone — not critical
    }

    final updatedDocs = emulator.documents
        .where((d) => d.filename != doc.filename)
        .toList();
    ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
      documents: updatedDocs,
      modifiedAt: DateTime.now(),
    );
    ref.read(emulatorDirtyProvider.notifier).state = true;
  }

  Future<void> _openDocument(Emulator emulator, DocumentEntry doc) async {
    final repository = ref.read(emulatorRepositoryProvider);
    final path = repository.getDocumentPath(emulator.id, doc.filename);
    await Process.run('xdg-open', [path]);
  }

  /// Create a new emulator via dialog
  Future<void> _createNewEmulator(BuildContext context) async {
    final result = await NewEmulatorDialog.show(context);
    if (result == null) return;

    final repository = ref.read(emulatorRepositoryProvider);
    final emulator = repository.createEmulator(
      name: result['name']!,
      elfFilePath: result['elfFilePath'],
      baseImagePath: result['baseImagePath'],
    );

    ref.read(currentEmulatorProvider.notifier).state = emulator;
    ref.read(emulatorDirtyProvider.notifier).state = true;

    if (emulator.elfFilePath != null) {
      ref.read(selectedElfPathProvider.notifier).state = emulator.elfFilePath;
    }
  }

  /// Open an existing emulator via file picker
  Future<void> _openEmulator(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['emu', 'emproj'],
      dialogTitle: 'Open Emulator',
    );

    if (result == null || result.files.single.path == null) return;

    final emulatorPath = result.files.single.path!;
    final repository = ref.read(emulatorRepositoryProvider);

    try {
      final emulator = await repository.loadEmulator(emulatorPath);

      ref.read(currentEmulatorProvider.notifier).state = emulator;
      ref.read(emulatorDirtyProvider.notifier).state = false;

      if (emulator.elfFilePath != null) {
        ref.read(selectedElfPathProvider.notifier).state = emulator.elfFilePath;
      }
      ref.read(leftSidebarExpandedProvider.notifier).state =
          emulator.uiState.leftSidebarExpanded;
      ref.read(rightSidebarExpandedProvider.notifier).state =
          emulator.uiState.rightSidebarExpanded;
      if (emulator.uiState.selectedSymbol != null) {
        ref.read(selectedSymbolProvider.notifier).state =
            emulator.uiState.selectedSymbol;
      }

      // Restore persisted hook preferences, overrides, and resolved hooks
      ref.read(hookPreferencesProvider.notifier).state =
          Map<String, int>.from(emulator.hookPreferences);
      ref.read(hookOverridesProvider.notifier).state =
          Map<String, int>.from(emulator.hookOverrides);
      ref.read(hookedSymbolsProvider.notifier).state =
          emulator.hooks.keys.toSet();

      await repository.addToRecentEmulators(emulatorPath, emulator.name);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load emulator: $e')),
        );
      }
    }
  }
}

// =============================================================================
// SYNTHESIS PROGRESS SECTION
// =============================================================================

/// Displays synthesis progress in the emulator explorer sidebar.
///
/// Shows a circular countdown timer (30s success condition), iteration count,
/// hooks applied, and current symbol being processed.
class _SynthesisProgressSection extends StatefulWidget {
  final SynthesisProgress progress;

  const _SynthesisProgressSection({required this.progress});

  @override
  State<_SynthesisProgressSection> createState() => _SynthesisProgressSectionState();
}

class _SynthesisProgressSectionState extends State<_SynthesisProgressSection> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!widget.progress.complete) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void didUpdateWidget(_SynthesisProgressSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progress.complete && _timer != null) {
      _timer?.cancel();
      _timer = null;
    } else if (!widget.progress.complete && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final elapsed = DateTime.now().difference(progress.countdownStart);
    final countdownSeconds = 30.0;
    final remaining = (countdownSeconds - elapsed.inMilliseconds / 1000.0).clamp(0.0, countdownSeconds);
    final fraction = remaining / countdownSeconds;

    // Color transitions: green when lots of time, yellow in middle, matches state when complete
    final Color timerColor;
    if (progress.complete) {
      timerColor = progress.success ? Colors.green : Colors.red;
    } else {
      timerColor = Color.lerp(Colors.orange, Colors.green, fraction) ?? Colors.green;
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: timerColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: timerColor.withOpacity(0.3), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with countdown circle
          Row(
            children: [
              // Circular countdown
              SizedBox(
                width: 40,
                height: 40,
                child: CustomPaint(
                  painter: _CountdownPainter(
                    fraction: progress.complete ? 1.0 : fraction,
                    color: timerColor,
                    complete: progress.complete,
                    success: progress.success,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      progress.complete
                          ? (progress.success ? 'SYNTHESIS COMPLETE' : 'SYNTHESIS FAILED')
                          : 'SYNTHESIZING',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: timerColor,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      progress.status,
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Stats row
          Row(
            children: [
              _buildStat('Iter', '${progress.iteration}'),
              const SizedBox(width: 12),
              _buildStat('Hooks', '${progress.hooksApplied}'),
              if (!progress.complete) ...[
                const SizedBox(width: 12),
                _buildStat('Timer', '${remaining.toStringAsFixed(0)}s'),
              ],
            ],
          ),

          // Current symbol
          if (progress.currentSymbol.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.functions,
                  size: 10,
                  color: Colors.red.shade300,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    progress.currentSymbol,
                    style: const TextStyle(fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

/// Custom painter for the circular countdown timer.
///
/// Draws an arc that depletes clockwise over 30 seconds.
/// When synthesis is complete, shows a filled circle (green check or red X).
class _CountdownPainter extends CustomPainter {
  final double fraction; // 0.0 = empty, 1.0 = full
  final Color color;
  final bool complete;
  final bool success;

  _CountdownPainter({
    required this.fraction,
    required this.color,
    required this.complete,
    required this.success,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 2;

    // Background track
    final trackPaint = Paint()
      ..color = Colors.grey.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    if (complete) {
      // Filled circle background
      final fillPaint = Paint()
        ..color = color.withOpacity(0.2)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, fillPaint);

      // Border
      final borderPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;
      canvas.drawCircle(center, radius, borderPaint);

      // Check or X icon
      final iconPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;

      if (success) {
        // Checkmark
        final path = Path()
          ..moveTo(center.dx - 6, center.dy)
          ..lineTo(center.dx - 2, center.dy + 5)
          ..lineTo(center.dx + 7, center.dy - 5);
        canvas.drawPath(path, iconPaint);
      } else {
        // X mark
        canvas.drawLine(
          Offset(center.dx - 5, center.dy - 5),
          Offset(center.dx + 5, center.dy + 5),
          iconPaint,
        );
        canvas.drawLine(
          Offset(center.dx + 5, center.dy - 5),
          Offset(center.dx - 5, center.dy + 5),
          iconPaint,
        );
      }
    } else {
      // Animated arc
      final arcPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;

      final sweepAngle = fraction * 2 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2, // start from top
        sweepAngle,
        false,
        arcPaint,
      );

      // Seconds text in the center
      final remaining = (fraction * 30).round();
      final textPainter = TextPainter(
        text: TextSpan(
          text: '$remaining',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(center.dx - textPainter.width / 2, center.dy - textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(_CountdownPainter oldDelegate) => true;
}

/// Dialog for searching and selecting a symbol from the call graph.
class _SymbolPickerDialog extends StatefulWidget {
  final List<String> symbols;
  final String title;

  const _SymbolPickerDialog({required this.symbols, required this.title});

  @override
  State<_SymbolPickerDialog> createState() => _SymbolPickerDialogState();
}

class _SymbolPickerDialogState extends State<_SymbolPickerDialog> {
  final _controller = TextEditingController();
  List<String> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = widget.symbols;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _filter(String query) {
    setState(() {
      if (query.isEmpty) {
        _filtered = widget.symbols;
      } else {
        final lower = query.toLowerCase();
        _filtered = widget.symbols.where((s) => s.toLowerCase().contains(lower)).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select ${widget.title}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search symbols...',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: _filter,
              ),
              const SizedBox(height: 8),
              Text(
                '${_filtered.length} symbols',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _filtered.length,
                  itemBuilder: (context, index) {
                    final symbol = _filtered[index];
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(symbol),
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                        child: Row(
                          children: [
                            Icon(Icons.functions, size: 14, color: Colors.blue.shade300),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                symbol,
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
