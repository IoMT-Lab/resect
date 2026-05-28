import 'package:emulator_orchestrator/core/app_paths.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/file_selection.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/autosave_provider.dart';
import '../../dialogs/new_emulator_dialog.dart';
import '../../dialogs/unsaved_changes_dialog.dart';

/// Shared emulator file-management actions used by the Library tab and the
/// (slimmed) File menu. Each call coordinates the dialog → repository →
/// provider update sequence in one place so both UIs stay in sync.

/// Prompt the user about unsaved changes before a destructive action.
///
/// Returns `false` if the user cancels — caller should abort the action.
/// Returns `true` if it's safe to proceed (either no unsaved work, or the
/// user chose Save / Discard).
Future<bool> guardUnsavedChanges(BuildContext context, WidgetRef ref) async {
  final emulator = ref.read(currentEmulatorProvider);
  final isDirty = ref.read(emulatorDirtyProvider);
  if (emulator == null || !isDirty) return true;

  final action = await UnsavedChangesDialog.show(
    context,
    emulatorName: emulator.name,
  );
  if (action == null || action == UnsavedChangesAction.cancel) return false;
  if (action == UnsavedChangesAction.save) {
    if (!context.mounted) return false;
    return saveEmulator(context, ref);
  }
  return true; // discard
}

/// Create a new emulator project. Prompts for unsaved changes first, then
/// runs [NewEmulatorDialog].
Future<void> createNewEmulator(BuildContext context, WidgetRef ref) async {
  if (!await guardUnsavedChanges(context, ref)) return;
  if (!context.mounted) return;

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
  ref.read(autosaveControllerProvider).restoreArtifacts(null);
  if (emulator.elfFilePath != null) {
    ref.read(selectedElfPathProvider.notifier).state = emulator.elfFilePath;
  }
}

/// Open an existing `.emu` file. If [path] is null, shows a file dialog.
/// Used by both the "Open Existing" button and Recent-list clicks.
Future<void> openEmulator(
  BuildContext context,
  WidgetRef ref, {
  String? path,
}) async {
  if (!await guardUnsavedChanges(context, ref)) return;

  var emulatorPath = path;
  if (emulatorPath == null) {
    if (!context.mounted) return;
    emulatorPath = await ref.read(fileSelectorProvider).openFile(
          dialogTitle: 'Open Emulator',
          extensions: ['emu', 'emproj'],
          initialDirectory: AppPaths.projectsDir,
        );
    if (emulatorPath == null) return;
  }

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
    ref.read(hookPreferencesProvider.notifier).state =
        Map<String, int>.from(emulator.hookPreferences);
    ref.read(hookOverridesProvider.notifier).state =
        Map<String, int>.from(emulator.hookOverrides);
    ref.read(hookedSymbolsProvider.notifier).state =
        emulator.hooks.keys.toSet();
    ref.read(autosaveControllerProvider).restoreArtifacts(emulator);

    await repository.addToRecentEmulators(emulatorPath, emulator.name);
    ref.invalidate(recentEmulatorsProvider);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load emulator: $e')),
      );
    }
  }
}

/// Save the current emulator. If it has no path yet, falls through to
/// [saveEmulatorAs]. Returns `true` on success.
Future<bool> saveEmulator(BuildContext context, WidgetRef ref) async {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return false;

  if (emulator.emulatorPath == null) {
    return saveEmulatorAs(context, ref);
  }

  final repository = ref.read(emulatorRepositoryProvider);
  final updated = ref.read(autosaveControllerProvider).gatherState(emulator);

  try {
    await repository.saveEmulator(updated, emulator.emulatorPath!);
    ref.read(currentEmulatorProvider.notifier).state = updated;
    ref.read(emulatorDirtyProvider.notifier).state = false;
    await repository.addToRecentEmulators(emulator.emulatorPath!, emulator.name);
    ref.invalidate(recentEmulatorsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: ${emulator.emulatorPath}')),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save emulator: $e')),
      );
    }
    return false;
  }
}

/// Save the current emulator to a new path chosen via a save dialog.
Future<bool> saveEmulatorAs(BuildContext context, WidgetRef ref) async {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return false;

  // Make sure the default save directory exists before the save dialog
  // opens — without this it can fall back to the user's home directory on
  // first run.
  await AppPaths.ensureProjectsDir();

  final result = await ref.read(fileSelectorProvider).saveFile(
        dialogTitle: 'Save Emulator As',
        suggestedName: '${emulator.name}${AppConstants.emulatorFileExtension}',
        initialDirectory: AppPaths.projectsDir,
        extensions: ['emu'],
      );
  if (result == null) return false;

  final savePath = result.endsWith(AppConstants.emulatorFileExtension)
      ? result
      : '$result${AppConstants.emulatorFileExtension}';

  final repository = ref.read(emulatorRepositoryProvider);
  final updated = ref.read(autosaveControllerProvider).gatherState(emulator)
      .copyWith(emulatorPath: savePath);

  try {
    await repository.saveEmulator(updated, savePath);
    ref.read(currentEmulatorProvider.notifier).state = updated;
    ref.read(emulatorDirtyProvider.notifier).state = false;
    await repository.addToRecentEmulators(savePath, emulator.name);
    ref.invalidate(recentEmulatorsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: $savePath')),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save emulator: $e')),
      );
    }
    return false;
  }
}

/// Close the current emulator. Prompts about unsaved changes first.
Future<void> closeEmulator(BuildContext context, WidgetRef ref) async {
  if (!await guardUnsavedChanges(context, ref)) return;
  ref.read(currentEmulatorProvider.notifier).state = null;
  ref.read(emulatorDirtyProvider.notifier).state = false;
  ref.read(selectedElfPathProvider.notifier).state = null;
  ref.read(selectedSymbolProvider.notifier).state = null;
  ref.read(hookPreferencesProvider.notifier).state = const {};
  ref.read(hookOverridesProvider.notifier).state = const {};
  ref.read(hookedSymbolsProvider.notifier).state = const {};
  ref.read(autosaveControllerProvider).restoreArtifacts(null);
}

/// Resolve the path that "Save" would use for a never-saved emulator —
/// used in disabled-button hover tooltips and similar copy.
String defaultSavePathFor(Emulator emulator) => p.join(
    AppPaths.projectsDir,
    '${emulator.name}${AppConstants.emulatorFileExtension}',
  );
