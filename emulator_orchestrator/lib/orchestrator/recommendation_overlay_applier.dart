import '../data/models/recommendation.dart';

/// Pure recommendation → overlay-map mutation, shared by the UI's
/// `RecommendationApplier` (which wraps it with Riverpod provider
/// reads/writes) and the headless auto-tune engine (which owns plain
/// maps). One source of truth for the per-kind semantics so the two
/// entry points can't drift.
///
/// [GenerateCustomHook] is NOT applied here — it's authored upstream
/// (the caller invokes the hook generator, inserts the artifact, and
/// seeds a binding). It's dropped from the plan; the caller extracts
/// those separately.

/// Order + dedupe a batch: dedupe symbol-targeting recs by symbol
/// (last-write-wins), then emit ClearForcedOverride → SetForcedOverride
/// → SetPreference, then a single trailing AdjustIterationCap.
/// GenerateCustomHook entries are dropped.
List<Recommendation> planRecommendationBatch(
    List<Recommendation> recommendations) {
  final bySymbol = <String, Recommendation>{};
  AdjustIterationCap? lastCap;
  for (final rec in recommendations) {
    switch (rec) {
      case GenerateCustomHook():
        break; // authored upstream, not an overlay mutation
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

/// Apply [recommendations] to the given overlay maps in place
/// (dedupe + ordered via [planRecommendationBatch]). Returns the
/// recommendations actually applied (post-plan, GenerateCustomHook
/// excluded) and the resulting iteration cap (an `int` is a value
/// type, so it's returned rather than mutated).
({List<Recommendation> applied, int iterationCap})
    applyRecommendationsToOverlays({
  required List<Recommendation> recommendations,
  required Map<String, int> hookOverrides,
  required Map<String, String> hookOverrideScopes,
  required Map<String, int> hookPreferences,
  required int iterationCap,
}) {
  final ordered = planRecommendationBatch(recommendations);
  var cap = iterationCap;
  for (final rec in ordered) {
    switch (rec) {
      case SetForcedOverride(:final symbol, :final artifactId, :final scope):
        hookOverrides[symbol] = artifactId;
        if (scope == null || scope.isEmpty) {
          hookOverrideScopes.remove(symbol);
        } else {
          hookOverrideScopes[symbol] = scope;
        }
      case ClearForcedOverride(:final symbol):
        hookOverrides.remove(symbol);
        hookOverrideScopes.remove(symbol);
      case SetPreference(:final symbol, :final artifactId):
        hookPreferences[symbol] = artifactId;
      case AdjustIterationCap(:final newValue):
        if (newValue > 0) cap = newValue;
      case GenerateCustomHook():
        break; // never in `ordered`; defensive
    }
  }
  return (applied: ordered, iterationCap: cap);
}
