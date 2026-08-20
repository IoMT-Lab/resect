import 'dart:async';
import 'dart:io';

import 'package:emulator_orchestrator/core/app_paths.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/data/models/rag_index_status.dart';
import 'package:emulator_orchestrator/services/analysis/call_graph_guard.dart';
import 'package:emulator_orchestrator/services/hooks/hook_binding_seeder.dart';
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

  // Capture a ProviderContainer up-front. WidgetRef is tied to the
  // calling widget's lifecycle (typically LibraryEmptyState's button
  // click). Setting currentEmulatorProvider below switches the
  // LibraryScreen view from empty-state to loaded — which disposes
  // the calling widget mid-async. Any ref.read AFTER that yields
  // `Bad state: Cannot use "ref" after the widget was disposed`. The
  // ProviderContainer outlives individual widgets and is the right
  // handle for cross-rebuild reads in long-running async flows.
  final container = ProviderScope.containerOf(context, listen: false);
  final repository = container.read(emulatorRepositoryProvider);
  // Flip the RAG card into "Checking…" before the slow work starts.
  // Without this the card flashes "Never built" between the moment
  // the library view switches from empty-state to loaded-view and
  // the moment ragIndex.statusSnapshot completes at the end of this
  // function. The card renders the checking state via its
  // isInProgress branch (sync icon + "Checking…").
  container.read(ragIndexStatusProvider.notifier).state =
      RagIndexStatus.checking;
  stderr.writeln('[openEmulator] loading $emulatorPath');
  try {
    var emulator = await repository.loadEmulator(emulatorPath);
    stderr.writeln('[openEmulator] loaded; overrides=${emulator.hookOverrides.length} '
        'prefs=${emulator.hookPreferences.length} '
        'bindings=${emulator.hookBindings.length} '
        'hooks=${emulator.hooks.length} '
        'commsAssignments=${emulator.commsAssignments.length} '
        'elfFilePath=${emulator.elfFilePath}');

    // Trust the persisted call graph only if its sha256 stamp matches
    // the project's firmware bytes. A mismatched, unstamped (pre-stamp
    // .emu), or unverifiable graph is stripped here so every downstream
    // reader of cachedCallGraph (RAG index, synthesis, auto-tune) starts
    // from nothing rather than from another firmware's symbol universe;
    // callgraphProvider then re-extracts and re-stamps.
    final persistedGraph = emulator.cachedCallGraph;
    if (persistedGraph != null) {
      var matches = false;
      final elf = emulator.elfFilePath;
      if (elf != null) {
        try {
          matches = await callGraphMatchesElf(persistedGraph, elf);
        } on FileSystemException catch (e) {
          stderr.writeln('[openEmulator] cannot validate call graph '
              '(${e.message}: ${e.path}); stripping it.');
        }
      }
      if (!matches) {
        stderr.writeln('[openEmulator] stripping cached call graph: stamp '
            '${persistedGraph.elfHash ?? '(unstamped)'} does not match '
            'firmware $elf (graph extracted from ${persistedGraph.elfPath}). '
            'It will be re-extracted.');
        emulator = emulator.copyWith(clearCachedCallGraph: true);
      }
    }

    container.read(currentEmulatorProvider.notifier).state = emulator;
    container.read(emulatorDirtyProvider.notifier).state = false;

    if (emulator.elfFilePath != null) {
      container.read(selectedElfPathProvider.notifier).state =
          emulator.elfFilePath;
    }
    container.read(leftSidebarExpandedProvider.notifier).state =
        emulator.uiState.leftSidebarExpanded;
    container.read(rightSidebarExpandedProvider.notifier).state =
        emulator.uiState.rightSidebarExpanded;
    if (emulator.uiState.selectedSymbol != null) {
      container.read(selectedSymbolProvider.notifier).state =
          emulator.uiState.selectedSymbol;
    }
    container.read(hookPreferencesProvider.notifier).state =
        Map<String, int>.from(emulator.hookPreferences);
    container.read(hookOverridesProvider.notifier).state =
        Map<String, int>.from(emulator.hookOverrides);
    container.read(hookOverrideScopesProvider.notifier).state =
        Map<String, String>.from(emulator.hookOverrideScopes);
    final bindings = await _backfillBindingsForUserReplacements(
      container,
      Map<String, HookBinding>.from(emulator.hookBindings),
      preferences: emulator.hookPreferences,
      overrides: emulator.hookOverrides,
      overrideScopes: emulator.hookOverrideScopes,
    );
    stderr.writeln('[openEmulator] before _seedClassifierBindings; '
        'bindings so far: ${bindings.length}');
    await _seedClassifierBindings(
      container,
      bindings,
      elfFilePath: emulator.elfFilePath,
    );
    stderr.writeln('[openEmulator] after _seedClassifierBindings; '
        'bindings now: ${bindings.length}');
    container.read(hookBindingsProvider.notifier).state = bindings;
    if (bindings.length != emulator.hookBindings.length) {
      // New bindings were back-filled or seeded; mark the project
      // dirty so the next save persists them. (We don't trigger
      // autosave directly here — the user may want to inspect first.)
      container.read(emulatorDirtyProvider.notifier).state = true;
    }
    container.read(hookedSymbolsProvider.notifier).state =
        emulator.hooks.keys.toSet();
    container.read(autosaveControllerProvider).restoreArtifacts(emulator);

    // Refresh the RAG card's status from the on-disk index for the
    // newly-loaded project. Without this the card stays at
    // `RagIndexStatus.empty` (the StateProvider's initial value) and
    // reads "Never built" even when a previously-saved index exists.
    // refreshRagIndexStatus(ref) takes a WidgetRef and is used by
    // doc-add/remove paths; inline here using container since
    // openEmulator runs across widget rebuilds.
    final ragIndex = container.read(ragIndexProvider);
    if (ragIndex != null) {
      container.read(ragIndexStatusProvider.notifier).state =
          ragIndex.statusSnapshot(emulator);
    }

    await repository.addToRecentEmulators(emulatorPath, emulator.name);
    container.invalidate(recentEmulatorsProvider);
    stderr.writeln('[openEmulator] complete');
  } catch (e, st) {
    stderr
      ..writeln('[openEmulator] FAILED: $e')
      ..writeln(st.toString());
    // Reset the checking state we set up front so the card doesn't
    // stay stuck on "Checking…" after a failed open.
    container.read(ragIndexStatusProvider.notifier).state =
        RagIndexStatus.empty;
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
  ProviderContainer container,
  Map<String, HookBinding> bindings, {
  required String? elfFilePath,
}) async {
  if (elfFilePath == null || elfFilePath.isEmpty) return;

  final service = container.read(artifactLibraryServiceProvider);
  final String elfHash;
  try {
    elfHash = await service.hashElfFile(elfFilePath);
  } catch (e) {
    debugPrint('[openEmulator] classifier seed skipped — '
        'hashElfFile failed: $e');
    return;
  }

  final seeder = HookBindingSeeder(
    artifactDb: container.read(artifactDatabaseProvider),
  );
  // Pre-scope-migration projects may have classifier-provenance
  // bindings with no scope. Re-classify those symbols and fill in
  // the scope before running the normal seed (so stateful classifier
  // hooks regain correct interpreter isolation on next open). The
  // migration mutates `bindings` in place; the new-seed pass below
  // skips any symbol that already has a binding.
  final upgraded = await seeder.upgradeBindingsMissingScope(
    elfHash: elfHash,
    bindings: bindings,
  );
  if (upgraded > 0) {
    debugPrint('[openEmulator] migrated $upgraded classifier '
        'binding${upgraded == 1 ? '' : 's'} with missing scope');
  }
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
///
/// The back-fill carries over `hookOverrideScopes[symbol]` (when set)
/// onto the binding's `scope` field. This preserves the user's explicit
/// Renode-scope choice from the Hook Database dialog — without it, a
/// user-authored stateful Replacement would deploy stateless when the
/// override is later removed in favor of the binding-driven sort.
Future<Map<String, HookBinding>> _backfillBindingsForUserReplacements(
  ProviderContainer container,
  Map<String, HookBinding> bindings, {
  required Map<String, int> preferences,
  required Map<String, int> overrides,
  required Map<String, String> overrideScopes,
}) async {
  final candidates = <String, int>{
    ...preferences,
    ...overrides, // overrides win on collision; the artifactId is the same in either case
  };
  if (candidates.isEmpty) return bindings;

  final db = container.read(artifactDatabaseProvider);
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
    final rawScope = overrideScopes[symbol];
    final scope = (rawScope == null || rawScope.isEmpty) ? null : rawScope;
    bindings[symbol] = HookBinding(
      artifactId: artifact.id,
      fidelity: 1.0,
      provenance: 'user',
      createdAt: now,
      scope: scope,
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
  // Capture ProviderContainer because the calling widget (Save button on
  // emulator_card) may be unmounted during the disk-I/O await if the
  // user navigates away mid-save. Same pattern as openEmulator.
  final container = ProviderScope.containerOf(context, listen: false);
  final emulator = container.read(currentEmulatorProvider);
  if (emulator == null) return false;

  if (emulator.emulatorPath == null) {
    return saveEmulatorAs(context, ref);
  }

  final repository = container.read(emulatorRepositoryProvider);
  final updated =
      container.read(autosaveControllerProvider).gatherState(emulator);

  try {
    await repository.saveEmulator(updated, emulator.emulatorPath!);
    container.read(currentEmulatorProvider.notifier).state = updated;
    container.read(emulatorDirtyProvider.notifier).state = false;
    await repository.addToRecentEmulators(emulator.emulatorPath!, emulator.name);
    container.invalidate(recentEmulatorsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: ${emulator.emulatorPath}')),
      );
    }
    return true;
  } catch (e, st) {
    stderr
      ..writeln('[saveEmulator] FAILED: $e')
      ..writeln(st.toString());
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
  final container = ProviderScope.containerOf(context, listen: false);
  final emulator = container.read(currentEmulatorProvider);
  if (emulator == null) return false;

  // Make sure the default save directory exists before the save dialog
  // opens — without this it can fall back to the user's home directory on
  // first run.
  await AppPaths.ensureProjectsDir();

  final result = await container.read(fileSelectorProvider).saveFile(
        dialogTitle: 'Save Emulator As',
        suggestedName: '${emulator.name}${AppConstants.emulatorFileExtension}',
        initialDirectory: AppPaths.projectsDir,
        extensions: ['emu'],
      );
  if (result == null) return false;

  final savePath = result.endsWith(AppConstants.emulatorFileExtension)
      ? result
      : '$result${AppConstants.emulatorFileExtension}';

  final repository = container.read(emulatorRepositoryProvider);
  final updated = container
      .read(autosaveControllerProvider)
      .gatherState(emulator)
      .copyWith(emulatorPath: savePath);

  try {
    await repository.saveEmulator(updated, savePath);
    container.read(currentEmulatorProvider.notifier).state = updated;
    container.read(emulatorDirtyProvider.notifier).state = false;
    await repository.addToRecentEmulators(savePath, emulator.name);
    container.invalidate(recentEmulatorsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved: $savePath')),
      );
    }
    return true;
  } catch (e, st) {
    stderr
      ..writeln('[saveEmulatorAs] FAILED: $e')
      ..writeln(st.toString());
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
  final container = ProviderScope.containerOf(context, listen: false);
  final emulator = container.read(currentEmulatorProvider);
  if (emulator == null) return;

  final sourcePath = await container.read(fileSelectorProvider).openFile(
        dialogTitle: 'Add document to project',
      );
  if (sourcePath == null) return;
  if (!context.mounted) return;

  final repository = container.read(emulatorRepositoryProvider);
  try {
    final entry = await repository.addDocument(emulator.id, sourcePath);
    container.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
      documents: [...emulator.documents, entry],
      modifiedAt: DateTime.now(),
    );
    container.read(emulatorDirtyProvider.notifier).state = true;
    unawaited(container.read(autosaveControllerProvider).trigger());
    refreshRagIndexStatus(container);
  } catch (e, st) {
    stderr
      ..writeln('[addDocumentToEmulator] FAILED: $e')
      ..writeln(st.toString());
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
  final container = ProviderScope.containerOf(context, listen: false);
  final emulator = container.read(currentEmulatorProvider);
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

  final repository = container.read(emulatorRepositoryProvider);
  try {
    await repository.removeDocument(emulator.id, doc.filename);
    container.read(currentEmulatorProvider.notifier).state = emulator.copyWith(
      documents: emulator.documents
          .where((d) => d.filename != doc.filename)
          .toList(),
      modifiedAt: DateTime.now(),
    );
    container.read(emulatorDirtyProvider.notifier).state = true;
    unawaited(container.read(autosaveControllerProvider).trigger());
    refreshRagIndexStatus(container);
  } catch (e, st) {
    stderr
      ..writeln('[removeDocumentFromEmulator] FAILED: $e')
      ..writeln(st.toString());
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
  } catch (e, st) {
    stderr
      ..writeln('[openDocument] FAILED: $e')
      ..writeln(st.toString());
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
///
/// Takes a [ProviderContainer] (not a [WidgetRef]) so callers can keep
/// invoking this after async operations that may have rebuilt their
/// owning widget — see the ref-after-dispose comment on openEmulator.
void refreshRagIndexStatus(ProviderContainer container) {
  final emulator = container.read(currentEmulatorProvider);
  final index = container.read(ragIndexProvider);
  if (emulator == null || index == null) return;
  container.read(ragIndexStatusProvider.notifier).state =
      index.statusSnapshot(emulator);
}
