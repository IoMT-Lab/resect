import 'dart:async';

import 'package:emulator_orchestrator/data/models/recommendation.dart';
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
    final ordered = _planBatch(recommendations);
    if (ordered.isEmpty) return const [];

    final overrides =
        Map<String, int>.from(container.read(hookOverridesProvider));
    final scopes =
        Map<String, String>.from(container.read(hookOverrideScopesProvider));
    final preferences =
        Map<String, int>.from(container.read(hookPreferencesProvider));
    var iterationCap = container.read(synthesisMaxIterationsProvider);

    for (final rec in ordered) {
      switch (rec) {
        case SetForcedOverride(:final symbol, :final artifactId, :final scope):
          overrides[symbol] = artifactId;
          if (scope == null || scope.isEmpty) {
            scopes.remove(symbol);
          } else {
            scopes[symbol] = scope;
          }

        case ClearForcedOverride(:final symbol):
          overrides.remove(symbol);
          scopes.remove(symbol);

        case SetPreference(:final symbol, :final artifactId):
          preferences[symbol] = artifactId;

        case AdjustIterationCap(:final newValue):
          if (newValue > 0) iterationCap = newValue;

        case GenerateCustomHook():
          // Pre-processed by the orchestrator; should already be
          // dropped by _planBatch but skip defensively.
          break;
      }
    }

    container.read(hookOverridesProvider.notifier).state = overrides;
    container.read(hookOverrideScopesProvider.notifier).state = scopes;
    container.read(hookPreferencesProvider.notifier).state = preferences;
    container.read(synthesisMaxIterationsProvider.notifier).state = iterationCap;
    container.read(emulatorDirtyProvider.notifier).state = true;
    // Autosave is a no-op for unsaved projects; safe to call
    // unconditionally per the autosave_provider contract.
    unawaited(container.read(autosaveControllerProvider).trigger());
    return ordered;
  }

  /// Order: ClearForcedOverride → SetForcedOverride → SetPreference
  /// → AdjustIterationCap. Dedup by symbol last-write-wins
  /// (AdjustIterationCap doesn't have a symbol and is collapsed to
  /// the last entry).
  ///
  /// `GenerateCustomHook` entries are dropped entirely — the
  /// orchestrator handles those upstream and may emit follow-on
  /// `SetForcedOverride` entries referencing the new artifact id.
  ///
  /// Exposed `@visibleForTesting`-style as a static so unit tests
  /// can exercise the planning logic without a `ProviderContainer`.
  static List<Recommendation> planBatch(
          List<Recommendation> recommendations) =>
      _planBatch(recommendations);

  static List<Recommendation> _planBatch(
      List<Recommendation> recommendations) {
    // Track the last symbol-targeting rec per symbol. Two recs that
    // both name the same symbol collapse to the second.
    final bySymbol = <String, Recommendation>{};
    AdjustIterationCap? lastCap;
    for (final rec in recommendations) {
      switch (rec) {
        case GenerateCustomHook():
          // Handled by the orchestrator; drop here.
          break;
        case SetForcedOverride(:final symbol):
          bySymbol[symbol] = rec;
        case ClearForcedOverride(:final symbol):
          bySymbol[symbol] = rec;
        case SetPreference(:final symbol):
          bySymbol[symbol] = rec;
        case AdjustIterationCap():
          lastCap = rec;
      }
    }

    final ordered = <Recommendation>[];
    // Clears first, then sets / preferences in input order (modulo
    // dedupe). Stable across the input.
    for (final rec in bySymbol.values) {
      if (rec is ClearForcedOverride) ordered.add(rec);
    }
    for (final rec in bySymbol.values) {
      if (rec is SetForcedOverride) ordered.add(rec);
    }
    for (final rec in bySymbol.values) {
      if (rec is SetPreference) ordered.add(rec);
    }
    if (lastCap != null) ordered.add(lastCap);
    return ordered;
  }
}
