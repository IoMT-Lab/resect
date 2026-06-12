import 'dart:async';
import 'dart:io';

import 'package:emulator_orchestrator/core/app_paths.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/data/models/rag_index_status.dart';
import 'package:emulator_orchestrator/data/services/hook_binding_seeder.dart';
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
    final bindings = await _backfillBindingsForUserReplacements(
      ref,
      Map<String, HookBinding>.from(emulator.hookBindings),
      preferences: emulator.hookPreferences,
      overrides: emulator.hookOverrides,
    );
    await _seedClassifierBindings(
      ref,
      bindings,
      elfFilePath: emulator.elfFilePath,
    );
    ref.read(hookBindingsProvider.notifier).state = bindings;
    if (bindings.length != emulator.hookBindings.length) {
      // New bindings were back-filled or seeded; mark the project
      // dirty so the next save persists them. (We don't trigger
      // autosave directly here — the user may want to inspect first.)
      ref.read(emulatorDirtyProvider.notifier).state = true;
    }
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

/// Run [HookBindingSeeder] against the project's ELF and merge any
/// classifier-produced bindings into [bindings] for symbols that don't
/// already have one. Mutates [bindings] in place.
///
/// Safe to call before Ghidra extraction has run for the firmware —
/// the seeder no-ops when its inputs (decompilations + signatures)
/// are absent. Errors from hashing/reading the ELF are swallowed with
/// a debug log so a missing or moved firmware file never blocks
/// project open.
Future<void> _seedClassifierBindings(
  WidgetRef ref,
  Map<String, HookBinding> bindings, {
  required String? elfFilePath,
}) async {
  if (elfFilePath == null || elfFilePath.isEmpty) return;

  final service = ref.read(artifactLibraryServiceProvider);
  final String elfHash;
  try {
    elfHash = await service.hashElfFile(elfFilePath);
  } catch (e) {
    debugPrint('[openEmulator] classifier seed skipped — '
        'hashElfFile failed: $e');
    return;
  }

  final seeder = HookBindingSeeder(
    artifactDb: ref.read(artifactDatabaseProvider),
  );
  final seeded = await seeder.seedBindingsForElf(
    elfHash: elfHash,
    skipSymbols: bindings.keys.toSet(),
  );
  if (seeded.isEmpty) return;
  bindings.addAll(seeded);
  debugPrint('[openEmulator] seeded ${seeded.length} classifier '
      'binding${seeded.length == 1 ? '' : 's'}');
}

/// Write a fidelity-1.0 binding for any (symbol → artifact) pair the
/// user has already wired up via `hookOverrides` or `hookPreferences`,
/// when the artifact is a user-authored Replacement (the targetSymbolName
/// non-null kind) AND the project doesn't already have a binding for
/// that symbol. Returns the merged map.
///
/// Run on project open so existing projects don't lose their per-symbol
/// picks under the new fidelity-driven candidate ordering. Idempotent:
/// re-running over an already-back-filled project is a no-op.
Future<Map<String, HookBinding>> _backfillBindingsForUserReplacements(
  WidgetRef ref,
  Map<String, HookBinding> bindings, {
  required Map<String, int> preferences,
  required Map<String, int> overrides,
}) async {
  final candidates = <String, int>{
    ...preferences,
    ...overrides, // overrides win on collision; the artifactId is the same in either case
  };
  if (candidates.isEmpty) return bindings;

  final db = ref.read(artifactDatabaseProvider);
  final now = DateTime.now();
  var added = 0;
  for (final entry in candidates.entries) {
    final symbol = entry.key;
    if (bindings.containsKey(symbol)) continue;
    final artifact = await db.getArtifactById(entry.value);
    if (artifact == null) continue;
    if (artifact.origin != 'user' || artifact.targetSymbolName == null) {
      continue;
    }
    bindings[symbol] = HookBinding(
      artifactId: artifact.id,
      fidelity: 1.0,
      provenance: 'user',
      createdAt: now,
    );
    added++;
  }
  if (added > 0) {
    debugPrint('[openEmulator] back-filled $added user-Replacement '
        'binding${added == 1 ? '' : 's'} at fidelity 1.0');
  }
  return bindings;
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

/// Prompt the user for a file, copy it into the emulator's documents
/// directory, and attach it to [currentEmulatorProvider]. The repository
/// handles filename collisions by appending a numeric suffix.
Future<void> addDocumentToEmulator(BuildContext context, WidgetRef ref) async {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return;

  final sourcePath = await ref.read(fileSelectorProvider).openFile(
        dialogTitle: 'Add document to project',
      );
  if (sourcePath == null) return;
  if (!context.mounted) return;

  final repository = ref.read(emulatorRepositoryProvider);
  try {
    final entry = await repository.addDocument(emulator.id, sourcePath);
    ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
      documents: [...emulator.documents, entry],
      modifiedAt: DateTime.now(),
    );
    ref.read(emulatorDirtyProvider.notifier).state = true;
    unawaited(ref.read(autosaveControllerProvider).trigger());
    refreshRagIndexStatus(ref);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add document: $e')),
      );
    }
  }
}

/// Confirm with the user, delete the on-disk file from the documents
/// directory, and drop the entry from [currentEmulatorProvider].
Future<void> removeDocumentFromEmulator(
  BuildContext context,
  WidgetRef ref,
  DocumentEntry doc,
) async {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Remove document'),
      content: Text(
        'Remove "${doc.displayName}" from this project? The file will be '
        "deleted from the project's documents directory.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (!context.mounted) return;

  final repository = ref.read(emulatorRepositoryProvider);
  try {
    await repository.removeDocument(emulator.id, doc.filename);
    ref.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
      documents: emulator.documents
          .where((d) => d.filename != doc.filename)
          .toList(),
      modifiedAt: DateTime.now(),
    );
    ref.read(emulatorDirtyProvider.notifier).state = true;
    unawaited(ref.read(autosaveControllerProvider).trigger());
    refreshRagIndexStatus(ref);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove document: $e')),
      );
    }
  }
}

/// Open a project document in the OS's default application for the file
/// type. Uses `xdg-open` on Linux, `open` on macOS, `start` on Windows.
Future<void> openDocument(
  BuildContext context,
  WidgetRef ref,
  DocumentEntry doc,
) async {
  final emulator = ref.read(currentEmulatorProvider);
  if (emulator == null) return;
  final repository = ref.read(emulatorRepositoryProvider);
  final path = repository.getDocumentPath(emulator.id, doc.filename);

  try {
    if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to open document: $e')),
      );
    }
  }
}

/// Tracks the in-flight RAG rebuild subscription so [cancelRagIndex]
/// can stop it. There's only ever one active rebuild per session;
/// the RAG card hides the Rebuild button while in progress.
StreamSubscription<void>? _activeRagRebuild;

/// Kick off a full rebuild of the per-project RAG index.
///
/// Streams progress into [ragIndexStatusProvider] so the RAG card's
/// "Embedding (3/12)…" line updates live. When the rebuild ends
/// (success, cancel, or error) the provider is refreshed with the
/// final on-disk snapshot.
Future<void> rebuildRagIndex(BuildContext context, WidgetRef ref) async {
  final emulator = ref.read(currentEmulatorProvider);
  final index = ref.read(ragIndexProvider);
  if (emulator == null || index == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Save the project before building the RAG index (it lives next '
          'to the .emu file).',
        ),
      ),
    );
    return;
  }
  if (_activeRagRebuild != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('A RAG rebuild is already in progress.')),
    );
    return;
  }
  final statusNotifier = ref.read(ragIndexStatusProvider.notifier);
  final previous = ref.read(ragIndexStatusProvider);
  statusNotifier.state = RagIndexStatus(
    lastBuiltAt: previous.lastBuiltAt,
    chunkCount: previous.chunkCount,
    chunkCountsByKind: previous.chunkCountsByKind,
    staleSourceCount: 0,
    inProgressPhase: 'Starting…',
  );
  // Pull the current ELF hash so the RAG rebuild can pick up
  // Ghidra-derived program facts (decompilation / data types /
  // data symbols / memory map). Null when no ELF is loaded yet —
  // the RAG side just skips its Ghidra pass in that case.
  final elfHash =
      ref.read(artifactProcessingProvider).valueOrNull?.elfHash;
  _activeRagRebuild = index.rebuildFor(emulator, elfHash: elfHash).listen(
    (event) {
      statusNotifier.state = RagIndexStatus(
        lastBuiltAt: previous.lastBuiltAt,
        chunkCount: previous.chunkCount,
        chunkCountsByKind: previous.chunkCountsByKind,
        staleSourceCount: 0,
        inProgressPhase: event.total == 0
            ? event.phase
            : '${event.phase} (${event.done}/${event.total})',
      );
    },
    onError: (Object e) {
      _activeRagRebuild = null;
      statusNotifier.state = index.statusSnapshot(emulator);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('RAG index rebuild failed: $e')),
        );
      }
    },
    onDone: () {
      _activeRagRebuild = null;
      statusNotifier.state = index.statusSnapshot(emulator);
    },
  );
}

/// Cancel an in-progress RAG index rebuild.
Future<void> cancelRagIndex(BuildContext context, WidgetRef ref) async {
  final sub = _activeRagRebuild;
  if (sub == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No rebuild in progress.')),
    );
    return;
  }
  await sub.cancel();
  _activeRagRebuild = null;
  final emulator = ref.read(currentEmulatorProvider);
  final index = ref.read(ragIndexProvider);
  if (emulator != null && index != null) {
    ref.read(ragIndexStatusProvider.notifier).state =
        index.statusSnapshot(emulator);
  }
}

/// Refresh the RAG card's status from the on-disk index. Cheap; safe to
/// call after any mutation (doc add/remove, hook save, call-graph
/// regen) so the card's staleness banner stays accurate.
void refreshRagIndexStatus(WidgetRef ref) {
  final emulator = ref.read(currentEmulatorProvider);
  final index = ref.read(ragIndexProvider);
  if (emulator == null || index == null) return;
  ref.read(ragIndexStatusProvider.notifier).state =
      index.statusSnapshot(emulator);
}
