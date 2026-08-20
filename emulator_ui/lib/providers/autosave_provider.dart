import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';
import 'auto_tune_session_provider.dart';
import 'config_providers.dart';

/// Owns the bidirectional sync between an [Emulator] project and the live
/// Riverpod providers: gathering provider state into the project before a
/// save, restoring persisted artifacts back into providers on open, and
/// performing the actual write (manual or autosave).
///
/// Holds the provider [Ref] so it can be reached from both [Ref] (the
/// synthesis controller) and [WidgetRef] (UI) call sites via
/// `ref.read(autosaveControllerProvider)`.
class AutosaveController {
  AutosaveController(this.ref);
  final Ref ref;

  /// Snapshot every provider that contributes to persisted project state into
  /// [base] before writing it to disk. Falls back to the base's existing
  /// values when a provider has nothing fresh to contribute, so a save never
  /// wipes previously persisted artifacts.
  Emulator gatherState(Emulator base) {
    final elfFilePath = ref.read(selectedElfPathProvider) ?? base.elfFilePath;
    // Persist a call graph only if it belongs to the firmware this save
    // records. While callgraphProvider re-extracts after an ELF switch,
    // valueOrNull still serves the PREVIOUS firmware's graph (riverpod
    // keeps the prior value through a rebuild) — writing that here is
    // how a project gets durably poisoned with another firmware's graph.
    // Path equality is the (sync) filter for that cross-firmware case;
    // content (sha256 stamp) is validated at every load/use site. A base
    // graph that doesn't match the saved ELF path is dropped, so a save
    // actively cleans an already-poisoned project.
    final liveGraph = ref.read(callgraphProvider).valueOrNull;
    final graphToPersist = liveGraph != null && liveGraph.elfPath == elfFilePath
        ? liveGraph
        : (base.cachedCallGraph?.elfPath == elfFilePath
            ? base.cachedCallGraph
            : null);
    return base.copyWith(
        modifiedAt: DateTime.now(),
        elfFilePath: elfFilePath,
        uiState: UiState(
          leftSidebarExpanded: ref.read(leftSidebarExpandedProvider),
          rightSidebarExpanded: ref.read(rightSidebarExpandedProvider),
          selectedSymbol: ref.read(selectedSymbolProvider),
        ),
        hookPreferences: Map<String, int>.from(ref.read(hookPreferencesProvider)),
        hookOverrides: Map<String, int>.from(ref.read(hookOverridesProvider)),
        hookOverrideScopes:
            Map<String, String>.from(ref.read(hookOverrideScopesProvider)),
        hookBindings:
            Map<String, HookBinding>.from(ref.read(hookBindingsProvider)),
        cachedCallGraph: graphToPersist,
        clearCachedCallGraph: graphToPersist == null,
        synthesisResult: ref.read(synthesisResultProvider) ?? base.synthesisResult,
        executedSymbols: Set<String>.from(ref.read(executedSymbolsProvider)),
        lastRunInsight:
            ref.read(lastRunInsightProvider) ?? base.lastRunInsight,
      );
  }

  /// Restore persisted synthesis artifacts from [emulator] into the live
  /// providers, reconstructing a completed [SynthesisProgress] when a result
  /// exists so the Synthesize tab shows its report on reopen.
  void restoreArtifacts(Emulator? emulator) {
    final result = emulator?.synthesisResult;
    ref.read(synthesisResultProvider.notifier).state = result;
    // Rehydrate the newest persisted auto-tune session (if any) so the
    // Synthesize tab's session view survives a reopen — including
    // sessions run headlessly against the same project.
    ref.read(autoTuneSessionProvider.notifier).hydrateFromDisk(emulator);
    ref.read(executedSymbolsProvider.notifier).state =
        Set<String>.from(emulator?.executedSymbols ?? const <String>{});
    ref.read(lastRunInsightProvider.notifier).state = emulator?.lastRunInsight;
    if (result != null) {
      ref.read(synthesisProgressProvider.notifier).state = SynthesisProgress(
        countdownStart: DateTime.now(),
        complete: true,
        success: result.success,
        hooksApplied: result.resolvedHooks.length,
        status: result.success
            ? 'Complete — ${result.resolvedHooks.length} hooks'
            : 'Failed at ${result.failedSymbol}',
      );
    } else {
      ref.read(synthesisProgressProvider.notifier).state = null;
    }
  }

  /// Gather current state into the open project and write it to [path],
  /// updating [currentEmulatorProvider] and clearing the dirty flag.
  Future<void> save(String path) async {
    final base = ref.read(currentEmulatorProvider);
    if (base == null) return;
    final updated = gatherState(base);
    await ref.read(emulatorRepositoryProvider).saveEmulator(updated, path);
    ref.read(currentEmulatorProvider.notifier).state = updated;
    ref.read(emulatorDirtyProvider.notifier).state = false;
  }

  /// Save the open project iff autosave is enabled AND it already has a path.
  /// Never-saved projects are skipped silently (no Save As popup).
  Future<void> trigger() async {
    if (!ref.read(autosaveEnabledProvider)) return;
    final path = ref.read(currentEmulatorProvider)?.emulatorPath;
    if (path == null) return;
    await save(path);
  }
}

final autosaveControllerProvider =
    Provider<AutosaveController>(AutosaveController.new);
