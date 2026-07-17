import '../data/models/recommendation.dart';
import '../data/models/synthesis_manifest.dart';

/// Auto-tune no-progress detection. Pure functions over the manifest,
/// shared by the UI orchestrator and the headless CLI auto-tune engine
/// so both entry points apply the identical stopping rule (one source
/// of truth — a divergent copy is exactly how the earlier
/// self-comparison bug crept in).

/// The set of artifact ids tried for [m]'s failed symbol this run.
/// Reconstructed from the failed symbol's manifest decision:
/// `appliedHook.artifactId` (last tried) plus every
/// `previousAttempts[].artifactId` (earlier tries). Empty when the
/// run didn't fail, or the failed symbol has no decision recorded.
///
/// Used by [isNoProgress] to tell a genuinely-new attempt (the set
/// gained an id) from a true repeat (nothing new tried). Comparing
/// the full set — not just `appliedHook` — matters: for an exhausted
/// symbol `appliedHook` is only the last-in-sort candidate and can
/// stay constant even when a new higher-scored hook was tried first.
Set<int> triedArtifactsForFailedSymbol(SynthesisManifest m) {
  final failed = m.failedSymbol;
  if (failed == null) return const {};
  for (final d in m.decisions) {
    if (d.symbol != failed) continue;
    final ids = <int>{};
    final applied = d.appliedHook.artifactId;
    if (applied != null) ids.add(applied);
    for (final p in d.previousAttempts ?? const []) {
      ids.add(p.artifactId);
    }
    return ids;
  }
  return const {};
}

/// True when the auto-tune loop made no *real* progress: this round's
/// synthesis failed at the same symbol as the prior round AND no new
/// hook was tried for it (the current round's tried-set introduces
/// nothing the prior round didn't already try). A different failing
/// symbol, a new hook at the same symbol, or either round not failing
/// are all NOT no-progress — the loop keeps going (still bounded by
/// maxRounds + the LLM emitting empty recommendations).
///
/// Erring toward "continue" on ambiguous/empty data is deliberate: a
/// repeat only stops the session when we can positively confirm the
/// same hook failed the same way.
bool isNoProgress({
  required String? currentFailed,
  required String? prevFailed,
  required Set<int> currentTried,
  required Set<int> prevTried,
}) {
  if (currentFailed == null || currentFailed != prevFailed) return false;
  if (currentTried.isEmpty) return false;
  return currentTried.difference(prevTried).isEmpty;
}

/// Split a reviewed recommendation batch into the entries that would
/// actually change anything ([kept]) and the no-ops already in effect
/// ([skipped]). Applying a no-op burns a full synthesis round on an
/// identical run — the observed failure mode was the LLM re-pinning
/// `LSI_IsReady ← #4` three rounds straight while coverage sat frozen.
///
/// No-op semantics per kind:
/// - [SetForcedOverride]: already forced to the same artifact with the
///   same normalized scope (a scope change is NOT a no-op — the
///   wrapper-skip escalation may legitimately re-force with a scope),
///   OR the last run's manifest shows the same artifact was applied to
///   the symbol anyway (a reactively-applied identical body produces
///   identical firmware behavior; only the application timing differs).
/// - [SetPreference]: the preference already points at the artifact,
///   or an override/last-run application already selects it.
/// - [ClearForcedOverride]: no override exists to clear.
/// - [GenerateCustomHook] / [AdjustIterationCap]: never filtered —
///   authoring is always new work, and the engine applies cap changes
///   directly.
({List<Recommendation> kept, List<Recommendation> skipped})
    filterNoOpRecommendations({
  required List<Recommendation> recommendations,
  required Map<String, int> hookOverrides,
  required Map<String, String> hookOverrideScopes,
  required Map<String, int> hookPreferences,
  SynthesisManifest? lastManifest,
}) {
  int? lastAppliedId(String symbol) {
    final m = lastManifest;
    if (m == null) return null;
    for (final d in m.decisions) {
      if (d.symbol == symbol) return d.appliedHook.artifactId;
    }
    return null;
  }

  String normalizeScope(String? s) => (s == null || s.isEmpty) ? '' : s;

  final kept = <Recommendation>[];
  final skipped = <Recommendation>[];
  for (final rec in recommendations) {
    final isNoOp = switch (rec) {
      SetForcedOverride(:final symbol, :final artifactId, :final scope) =>
        (hookOverrides[symbol] == artifactId &&
                normalizeScope(hookOverrideScopes[symbol]) ==
                    normalizeScope(scope)) ||
            lastAppliedId(symbol) == artifactId,
      SetPreference(:final symbol, :final artifactId) =>
        hookPreferences[symbol] == artifactId ||
            hookOverrides[symbol] == artifactId ||
            lastAppliedId(symbol) == artifactId,
      ClearForcedOverride(:final symbol) =>
        !hookOverrides.containsKey(symbol),
      GenerateCustomHook() => false,
      AdjustIterationCap() => false,
    };
    (isNoOp ? skipped : kept).add(rec);
  }
  return (kept: kept, skipped: skipped);
}

/// True when a successful round reached NO symbol the prior round
/// hadn't already reached — the firmware is silently stuck and
/// re-running with unchanged overlays would produce identical
/// evidence. A shrunken set is still stagnant (observed live: a
/// wrapper-skip cost one symbol and gained none — that is not
/// progress, and treating it as movement reset the escalation
/// counter). Crash rounds are out of scope (that's [isNoProgress]'s
/// jurisdiction), and null executed sets (legacy / un-enriched
/// manifests) err toward continue, mirroring [isNoProgress]'s
/// philosophy: stagnation must be positively confirmed.
bool isCoverageStagnant({
  required Set<String>? prevExecuted,
  required Set<String>? currentExecuted,
  required String? currentFailedSymbol,
}) {
  if (currentFailedSymbol != null) return false;
  if (prevExecuted == null || currentExecuted == null) return false;
  return currentExecuted.difference(prevExecuted).isEmpty;
}
