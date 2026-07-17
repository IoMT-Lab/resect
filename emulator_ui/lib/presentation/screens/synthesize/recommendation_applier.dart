import 'dart:async';

import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/orchestrator/recommendation_overlay_applier.dart'
    as overlay;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_providers.dart';
import '../../../providers/autosave_provider.dart';

/// Applies a batch of accepted-or-edited [Recommendation]s to the
/// project's overlay providers.
///
/// The closed-loop LLM orchestrator hands the applier a list of
/// recommendations the user reviewed and chose to apply (rejected
/// ones never reach here). The applier:
///
/// 1. Drops [GenerateCustomHook] entries — those are handled
///    upstream by the orchestrator (it calls [LlmHookGenerator],
///    seeds the new artifactId into [hookBindingsProvider], and
///    rewrites any downstream references). The applier core has
///    no LLM dependency.
/// 2. Dedupes the remaining symbol-targeted recommendations by
///    symbol, last-write-wins. So a batch carrying both
///    `ClearForcedOverride{sym=A}` and
///    `SetForcedOverride{sym=A, artifactId=4}` ends up applying
///    only the set.
/// 3. Mutates the overlay providers atomically per recommendation:
///    [hookOverridesProvider] + [hookOverrideScopesProvider] for
///    [SetForcedOverride] / [ClearForcedOverride];
///    [hookPreferencesProvider] for [SetPreference];
///    [synthesisMaxIterationsProvider] for [AdjustIterationCap].
/// 4. Flips [emulatorDirtyProvider] and triggers autosave once at
///    the end of the batch.
///
/// Pure-function in spirit — no I/O beyond the Riverpod writes.
/// Tested against a real `ProviderContainer` with the real notifier
/// classes (no fakes), per the no-mock-tests policy.
class RecommendationApplier {
  const RecommendationApplier({this.roundNumber});

  /// The auto-tune round these recommendations were applied during.
  /// Surfaced into the manifest's per-decision `autoTuneRound` field
  /// at synthesis time (the SynthesizerWorkflow reads it from the
  /// overlay-write timestamp; for now this is informational only).
  final int? roundNumber;

  /// Apply [recommendations] in dedupe + ordered fashion. Returns
  /// the recommendations actually applied (post-dedup, post-drop of
  /// GenerateCustomHook entries) so the caller can correlate the
  /// batch with the snapshot it'll persist.
  ///
  /// Takes a [ProviderContainer] rather than a [Ref] so the same
  /// code path runs in unit tests (which construct a container
  /// directly) and in production (where the orchestrator stores a
  /// container reference and calls in imperatively).
  List<Recommendation> apply(
    ProviderContainer container,
    List<Recommendation> recommendations,
  ) {
    // Read providers into plain maps, delegate the per-kind mutation
    // to the shared orchestrator-side applier (one source of truth
    // with the headless auto-tune engine), then write back.
    final overrides =
        Map<String, int>.from(container.read(hookOverridesProvider));
    final scopes =
        Map<String, String>.from(container.read(hookOverrideScopesProvider));
    final preferences =
        Map<String, int>.from(container.read(hookPreferencesProvider));
    final result = overlay.applyRecommendationsToOverlays(
      recommendations: recommendations,
      hookOverrides: overrides,
      hookOverrideScopes: scopes,
      hookPreferences: preferences,
      iterationCap: container.read(synthesisMaxIterationsProvider),
    );
    if (result.applied.isEmpty) return const [];

    container.read(hookOverridesProvider.notifier).state = overrides;
    container.read(hookOverrideScopesProvider.notifier).state = scopes;
    container.read(hookPreferencesProvider.notifier).state = preferences;
    container.read(synthesisMaxIterationsProvider.notifier).state =
        result.iterationCap;
    container.read(emulatorDirtyProvider.notifier).state = true;
    // Autosave is a no-op for unsaved projects; safe to call
    // unconditionally per the autosave_provider contract.
    unawaited(container.read(autosaveControllerProvider).trigger());
    return result.applied;
  }

  /// Order + dedupe the batch. Delegates to the shared
  /// [overlay.planRecommendationBatch]; kept as a static entry point
  /// so existing unit tests can exercise the planning logic without a
  /// `ProviderContainer`.
  static List<Recommendation> planBatch(
          List<Recommendation> recommendations) =>
      overlay.planRecommendationBatch(recommendations);
}
