import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import 'package:emulator_orchestrator/core/app_paths.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import '../../providers/app_providers.dart';
import '../dialogs/new_emulator_dialog.dart';
import '../dialogs/unsaved_changes_dialog.dart';
import '../dialogs/hook_database_dialog.dart';
import '../dialogs/vagrant_test_dialog.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';

/// Top menu bar with File, View, and Help menus.
///
/// Similar to VSCode's menu bar, this provides access to main actions
/// like opening files, toggling panels, and viewing help.
class MenuBarWidget extends ConsumerWidget {
  const MenuBarWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentEmulator = ref.watch(currentEmulatorProvider);

    return Container(
      height: AppConstants.menuBarHeight,
      decoration: BoxDecoration(
        color: Theme.of(context).appBarTheme.backgroundColor,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).dividerTheme.color ?? Colors.grey,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          // App title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              AppConstants.appName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),

          // Menu items
          _MenuBarItem(
            title: 'File',
            items: [
              _MenuItem(
                title: 'New Emulator...',
                onTap: () => _createNewEmulator(context, ref),
                shortcut: 'Ctrl+Shift+N',
              ),
              _MenuItem(
                title: 'Open Emulator...',
                onTap: () => _openEmulator(context, ref),
                shortcut: 'Ctrl+Shift+O',
              ),
              const _MenuDivider(),
              _MenuItem(
                title: 'Open ELF File...',
                onTap: () => _openFileDialog(context, ref),
                shortcut: 'Ctrl+O',
              ),
              const _MenuDivider(),
              _MenuItem(
                title: 'Save Emulator',
                onTap: currentEmulator != null
                    ? () => _saveEmulator(context, ref)
                    : () {},
                shortcut: 'Ctrl+S',
                enabled: currentEmulator != null,
              ),
              _MenuItem(
                title: 'Save Emulator As...',
                onTap: currentEmulator != null
                    ? () => _saveEmulatorAs(context, ref)
                    : () {},
                shortcut: 'Ctrl+Shift+S',
                enabled: currentEmulator != null,
              ),
              _MenuItem(
                title: 'Export Emulator...',
                onTap: currentEmulator != null
                    ? () => _exportEmulator(context, ref)
                    : () {},
                enabled: currentEmulator != null,
              ),
              _MenuItem(
                title: 'Export Renode Script...',
                onTap: currentEmulator != null && currentEmulator.hooks.isNotEmpty
                    ? () => _exportResc(context, ref)
                    : () {},
                enabled: currentEmulator != null && currentEmulator.hooks.isNotEmpty,
              ),
              _MenuItem(
                title: 'Export Vagrant...',
                onTap: currentEmulator != null && currentEmulator.hooks.isNotEmpty
                    ? () => _exportVagrant(context, ref)
                    : () {},
                enabled: currentEmulator != null && currentEmulator.hooks.isNotEmpty,
              ),
              const _MenuDivider(),
              _MenuItem(
                title: 'Close Emulator',
                onTap: currentEmulator != null
                    ? () => _closeEmulator(context, ref)
                    : () {},
                enabled: currentEmulator != null,
              ),
              const _MenuDivider(),
              _MenuItem(
                title: 'Exit',
                onTap: () => _exit(context, ref),
                shortcut: 'Ctrl+Q',
              ),
            ],
          ),

          _MenuBarItem(
            title: 'View',
            items: [
              _MenuItem(
                title: 'Toggle Explorer',
                onTap: () => _toggleLeftSidebar(ref),
                shortcut: 'Ctrl+B',
              ),
              _MenuItem(
                title: 'Toggle Metadata',
                onTap: () => _toggleRightSidebar(ref),
                shortcut: 'Ctrl+M',
              ),
              const _MenuDivider(),
              _MenuItem(
                title: 'Hook Database...',
                onTap: () => HookDatabaseDialog.show(context),
              ),
            ],
          ),

          _MenuBarItem(
            title: 'Tools',
            items: [
              _MenuItem(
                title: 'Run Vagrant Test...',
                onTap: () => VagrantTestDialog.show(context),
              ),
            ],
          ),

          _MenuBarItem(
            title: 'Help',
            items: [
              _MenuItem(
                title: 'About',
                onTap: () => _showAbout(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Open file picker to select ELF file
  void _openFileDialog(BuildContext context, WidgetRef ref) {
    // This will be implemented with file_picker in ExplorerSidebar
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Use the Explorer sidebar to open files')),
    );
  }

  /// Toggle left sidebar visibility
  void _toggleLeftSidebar(WidgetRef ref) {
    final current = ref.read(leftSidebarExpandedProvider);
    ref.read(leftSidebarExpandedProvider.notifier).state = !current;
  }

  /// Toggle right sidebar visibility
  void _toggleRightSidebar(WidgetRef ref) {
    final current = ref.read(rightSidebarExpandedProvider);
    ref.read(rightSidebarExpandedProvider.notifier).state = !current;
  }

  /// Show about dialog
  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(AppConstants.appName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version: ${AppConstants.appVersion}'),
            const SizedBox(height: 8),
            const Text(AppConstants.appDescription),
            const SizedBox(height: 16),
            const Text(
              'A tool for visualizing ARM firmware call graphs '
              'generated from ELF binaries.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Create a new emulator
  Future<void> _createNewEmulator(BuildContext context, WidgetRef ref) async {
    // Check if there's an unsaved emulator
    final currentEmulator = ref.read(currentEmulatorProvider);
    final isDirty = ref.read(emulatorDirtyProvider);

    if (currentEmulator != null && isDirty) {
      final action = await UnsavedChangesDialog.show(
        context,
        emulatorName: currentEmulator.name,
      );

      if (action == UnsavedChangesAction.cancel || action == null) {
        return;
      }

      if (action == UnsavedChangesAction.save) {
        await _saveEmulator(context, ref);
      }
    }

    // Show new emulator dialog
    final result = await NewEmulatorDialog.show(context);
    if (result == null) return;

    // Create emulator
    final repository = ref.read(emulatorRepositoryProvider);
    final emulator = repository.createEmulator(
      name: result['name']!,
      elfFilePath: result['elfFilePath'],
      baseImagePath: result['baseImagePath'],
    );

    // Update state
    ref.read(currentEmulatorProvider.notifier).state = emulator;
    ref.read(emulatorDirtyProvider.notifier).state = true;

    // Update ELF path if provided
    if (emulator.elfFilePath != null) {
      ref.read(selectedElfPathProvider.notifier).state = emulator.elfFilePath;
    }

    // Switch to EMULATOR tab
    ref.read(explorerTabProvider.notifier).state = ExplorerTab.emulator;
  }

  /// Open an existing emulator
  Future<void> _openEmulator(BuildContext context, WidgetRef ref) async {
    // Check if there's an unsaved emulator
    final currentEmulator = ref.read(currentEmulatorProvider);
    final isDirty = ref.read(emulatorDirtyProvider);

    if (currentEmulator != null && isDirty) {
      final action = await UnsavedChangesDialog.show(
        context,
        emulatorName: currentEmulator.name,
      );

      if (action == UnsavedChangesAction.cancel || action == null) {
        return;
      }

      if (action == UnsavedChangesAction.save) {
        await _saveEmulator(context, ref);
      }
    }

    // Show file picker for .emu files (also accept legacy .emproj)
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['emu', 'emproj'],
      dialogTitle: 'Open Emulator',
      initialDirectory: AppPaths.projectsDir,
    );

    if (result == null || result.files.single.path == null) return;

    final emulatorPath = result.files.single.path!;
    final repository = ref.read(emulatorRepositoryProvider);

    try {
      // Load emulator
      final emulator = await repository.loadEmulator(emulatorPath);

      // Update state
      ref.read(currentEmulatorProvider.notifier).state = emulator;
      ref.read(emulatorDirtyProvider.notifier).state = false;

      // Sync to other providers
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

      // Add to recent emulators
      await repository.addToRecentEmulators(emulatorPath, emulator.name);

      // Switch to EMULATOR tab
      ref.read(explorerTabProvider.notifier).state = ExplorerTab.emulator;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load emulator: $e')),
        );
      }
    }
  }

  /// Save the current emulator.
  ///
  /// If the emulator has never been saved, saves to the default projects
  /// directory (`~/.config/call_graph_viewer/projects/<name>.emu`).
  Future<void> _saveEmulator(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator == null) return;

    // Default to projects dir if never saved
    final savePath = emulator.emulatorPath ??
        p.join(AppPaths.projectsDir, '${emulator.name}${AppConstants.emulatorFileExtension}');

    final repository = ref.read(emulatorRepositoryProvider);

    // Gather current state
    final updatedEmulator = _gatherEmulatorState(ref, emulator);

    try {
      await repository.saveEmulator(updatedEmulator, savePath);
      ref.read(currentEmulatorProvider.notifier).state =
          updatedEmulator.copyWith(emulatorPath: savePath);
      ref.read(emulatorDirtyProvider.notifier).state = false;

      // Track in recent emulators
      await repository.addToRecentEmulators(savePath, emulator.name);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved: $savePath')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save emulator: $e')),
        );
      }
    }
  }

  /// Save emulator with a new path
  Future<void> _saveEmulatorAs(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator == null) return;

    // Show file picker for save location (default to projects dir)
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Emulator As',
      fileName: '${emulator.name}.emu',
      initialDirectory: AppPaths.projectsDir,
      type: FileType.custom,
      allowedExtensions: ['emu'],
    );

    if (result == null) return;

    final repository = ref.read(emulatorRepositoryProvider);

    // Gather current state
    final updatedEmulator = _gatherEmulatorState(ref, emulator);

    try {
      await repository.saveEmulator(updatedEmulator, result);
      ref.read(currentEmulatorProvider.notifier).state =
          updatedEmulator.copyWith(emulatorPath: result);
      ref.read(emulatorDirtyProvider.notifier).state = false;

      // Add to recent emulators
      await repository.addToRecentEmulators(result, emulator.name);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Emulator saved successfully')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save emulator: $e')),
        );
      }
    }
  }

  /// Export emulator as .zip archive
  Future<void> _exportEmulator(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator == null) return;

    // Ensure emulator is saved first
    if (emulator.emulatorPath == null) {
      if (context.mounted) {
        final shouldSave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Save Emulator First'),
            content: const Text(
                'Emulator must be saved before exporting. Save now?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save'),
              ),
            ],
          ),
        );

        if (shouldSave != true) return;
        await _saveEmulatorAs(context, ref);

        // Check if save was successful
        if (ref.read(currentEmulatorProvider)?.emulatorPath == null) return;
      }
    }

    // Show file picker for export location
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Emulator',
      fileName: '${emulator.name}.zip',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (result == null) return;

    final repository = ref.read(emulatorRepositoryProvider);
    final currentEmu = ref.read(currentEmulatorProvider)!;

    try {
      await repository.exportEmulator(currentEmu, result);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Emulator exported successfully')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export emulator: $e')),
        );
      }
    }
  }

  /// Export emulator as standalone Renode .resc script
  Future<void> _exportResc(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator == null || emulator.hooks.isEmpty) return;

    // Show file picker for export location
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Renode Script',
      fileName: '${emulator.name}.resc',
      type: FileType.any,
    );

    if (result == null) return;

    final repository = ref.read(emulatorRepositoryProvider);

    try {
      await repository.exportResc(emulator, result);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Renode script exported successfully')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export Renode script: $e')),
        );
      }
    }
  }

  /// Export emulator as a self-contained Vagrant bundle (.zip)
  Future<void> _exportVagrant(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator == null || emulator.hooks.isEmpty) return;

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Vagrant Bundle',
      fileName: '${emulator.name}_vagrant.zip',
      type: FileType.any,
    );

    if (result == null) return;

    final repository = ref.read(emulatorRepositoryProvider);

    try {
      await repository.exportVagrant(emulator, result);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Vagrant bundle exported successfully')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export Vagrant bundle: $e')),
        );
      }
    }
  }

  /// Close the current emulator
  Future<void> _closeEmulator(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    if (emulator == null) return;

    final isDirty = ref.read(emulatorDirtyProvider);

    if (isDirty) {
      final action = await UnsavedChangesDialog.show(
        context,
        emulatorName: emulator.name,
      );

      if (action == UnsavedChangesAction.cancel || action == null) {
        return;
      }

      if (action == UnsavedChangesAction.save) {
        await _saveEmulator(context, ref);
      }
    }

    // Clear emulator state
    ref.read(currentEmulatorProvider.notifier).state = null;
    ref.read(emulatorDirtyProvider.notifier).state = false;
    ref.read(selectedElfPathProvider.notifier).state = null;

    // Switch to SYMBOLS tab
    ref.read(explorerTabProvider.notifier).state = ExplorerTab.symbols;
  }

  /// Gather current state into emulator
  Emulator _gatherEmulatorState(WidgetRef ref, Emulator emulator) {
    return emulator.copyWith(
      modifiedAt: DateTime.now(),
      elfFilePath: ref.read(selectedElfPathProvider),
      uiState: UiState(
        leftSidebarExpanded: ref.read(leftSidebarExpandedProvider),
        rightSidebarExpanded: ref.read(rightSidebarExpandedProvider),
        selectedSymbol: ref.read(selectedSymbolProvider),
      ),
    );
  }

  /// Exit the application
  Future<void> _exit(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    final isDirty = ref.read(emulatorDirtyProvider);

    if (emulator != null && isDirty) {
      final action = await UnsavedChangesDialog.show(
        context,
        emulatorName: emulator.name,
      );

      if (action == UnsavedChangesAction.cancel || action == null) {
        return;
      }

      if (action == UnsavedChangesAction.save) {
        await _saveEmulator(context, ref);
      }
    }

    // Exit the application
    await windowManager.destroy();
  }
}

/// Single menu bar item (e.g., "File", "View")
class _MenuBarItem extends StatefulWidget {
  final String title;
  final List<Widget> items;

  const _MenuBarItem({required this.title, required this.items});

  @override
  State<_MenuBarItem> createState() => _MenuBarItemState();
}

class _MenuBarItemState extends State<_MenuBarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: PopupMenuButton<void>(
        offset: const Offset(0, AppConstants.menuBarHeight),
        padding: EdgeInsets.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _isHovered
                ? Colors.white.withOpacity(0.1)
                : Colors.transparent,
          ),
          child: Text(
            widget.title,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        itemBuilder: (context) => widget.items
            .map((item) => PopupMenuItem<void>(
                  padding: EdgeInsets.zero,
                  child: item,
                ))
            .toList(),
      ),
    );
  }
}

/// Single menu item within a dropdown
class _MenuItem extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  final String? shortcut;
  final bool enabled;

  const _MenuItem({
    required this.title,
    required this.onTap,
    this.shortcut,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled
          ? () {
              Navigator.pop(context);
              onTap();
            }
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: enabled ? null : Colors.grey.shade600,
                  ),
            ),
            if (shortcut != null) ...[
              const SizedBox(width: 24),
              Text(
                shortcut!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: enabled ? null : Colors.grey.shade600,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Divider in menu dropdown
class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1);
  }
}
