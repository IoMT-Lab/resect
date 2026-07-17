import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_progress.dart';
import 'package:test/test.dart';

/// Guards the auto-tune loop's no-progress termination. It must stop
/// ONLY on a true repeat — the same halt symbol failing again with no
/// new hook tried — not on any repeated symbol (the original
/// self-comparison bug) and not when a genuinely different hook was
/// tried for a hard symbol (legitimate exploration).
void main() {
  group('isNoProgress', () {
    test('same symbol, nothing new tried → no progress (stop)', () {
      expect(
        isNoProgress(
          currentFailed: 'LL_RCC_LSI_IsReady',
          prevFailed: 'LL_RCC_LSI_IsReady',
          currentTried: {3, 4},
          prevTried: {3, 4},
        ),
        isTrue,
      );
    });

    test('same symbol but a NEW hook was tried → progress (continue)', () {
      expect(
        isNoProgress(
          currentFailed: 'LL_RCC_LSI_IsReady',
          prevFailed: 'LL_RCC_LSI_IsReady',
          currentTried: {3, 4, 9}, // #9 is new this round
          prevTried: {3, 4},
        ),
        isFalse,
        reason: 'a new hook at the same symbol is exploration, not stagnation',
      );
    });

    test('different failing symbol → progress (continue)', () {
      expect(
        isNoProgress(
          currentFailed: 'LL_RCC_LSI_IsReady',
          prevFailed: 'SystemInit',
          currentTried: {3},
          prevTried: {3},
        ),
        isFalse,
      );
    });

    test('this round did not fail → not no-progress', () {
      expect(
        isNoProgress(
          currentFailed: null,
          prevFailed: 'LL_RCC_LSI_IsReady',
          currentTried: const {},
          prevTried: {3, 4},
        ),
        isFalse,
      );
    });

    test('same symbol but no tried-set evidence → do not stop', () {
      // Ambiguous data: can't confirm a true repeat, so keep going
      // (maxRounds still bounds the session).
      expect(
        isNoProgress(
          currentFailed: 'LL_RCC_LSI_IsReady',
          prevFailed: 'LL_RCC_LSI_IsReady',
          currentTried: const {},
          prevTried: {3, 4},
        ),
        isFalse,
      );
    });
  });

  group('triedArtifactsForFailedSymbol', () {
    ManifestDecision decision(String symbol, int applied, List<int> priors) =>
        ManifestDecision(
          symbol: symbol,
          appliedHook: AppliedHook(bodyHash: 'h', artifactId: applied),
          decisionKind: ManifestDecisionKind.iterationFallback,
          decisionSource: 'x',
          previousAttempts: [
            for (final id in priors)
              PreviousAttempt(artifactId: id, outcome: 'unhandled_access_repeat'),
          ],
        );

    SynthesisManifest manifest({
      String? failedSymbol,
      List<ManifestDecision> decisions = const [],
    }) =>
        SynthesisManifest(
          manifestVersion: 2,
          elfHash: 'abc',
          elfFileName: 'f.elf',
          synthesizerRunId: 'run',
          result: const ManifestRunResult(
              success: false, totalIterations: 1, durationSeconds: 1),
          decisions: decisions,
          failedSymbol: failedSymbol,
        );

    test('collects appliedHook + previousAttempts artifact ids', () {
      final m = manifest(
        failedSymbol: 'X',
        decisions: [decision('X', 5, [3, 4])],
      );
      expect(triedArtifactsForFailedSymbol(m), {3, 4, 5});
    });

    test('success run (no failed symbol) → empty', () {
      expect(triedArtifactsForFailedSymbol(manifest()), isEmpty);
    });

    test('failed symbol absent from decisions → empty', () {
      final m = manifest(
        failedSymbol: 'X',
        decisions: [decision('Y', 1, const [])],
      );
      expect(triedArtifactsForFailedSymbol(m), isEmpty);
    });
  });

  group('filterNoOpRecommendations', () {
    ({List<Recommendation> kept, List<Recommendation> skipped}) run(
      List<Recommendation> recs, {
      Map<String, int> overrides = const {},
      Map<String, String> scopes = const {},
      Map<String, int> preferences = const {},
      SynthesisManifest? lastManifest,
    }) =>
        filterNoOpRecommendations(
          recommendations: recs,
          hookOverrides: overrides,
          hookOverrideScopes: scopes,
          hookPreferences: preferences,
          lastManifest: lastManifest,
        );

    const forceA4 =
        SetForcedOverride(rationale: 'r', symbol: 'A', artifactId: 4);

    test('override already forced to the same artifact → skipped', () {
      final r = run([forceA4], overrides: {'A': 4});
      expect(r.kept, isEmpty);
      expect(r.skipped, [forceA4]);
    });

    test('override to a DIFFERENT artifact → kept', () {
      final r = run([forceA4], overrides: {'A': 3});
      expect(r.kept, [forceA4]);
      expect(r.skipped, isEmpty);
    });

    test('scope change on the same artifact is NOT a no-op', () {
      const withScope = SetForcedOverride(
          rationale: 'r', symbol: 'A', artifactId: 4, scope: 'HSE');
      final r = run([withScope], overrides: {'A': 4});
      expect(r.kept, [withScope],
          reason: 'same artifact but scope "" → "HSE" is a real change');
    });

    test(
        "override matching the last run's reactively-applied artifact "
        '→ skipped (identical body, identical behavior)', () {
      // No override in the overlay — but the manifest shows the
      // binding already applied #4 to A last run. Forcing #4 changes
      // nothing (the original LSI_IsReady ← #4 no-op).
      const m = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'f.elf',
        synthesizerRunId: 'run',
        result: ManifestRunResult(
            success: true, totalIterations: 1, durationSeconds: 1),
        decisions: [
          ManifestDecision(
            symbol: 'A',
            appliedHook: AppliedHook(bodyHash: 'h', artifactId: 4),
            decisionKind: ManifestDecisionKind.binding,
            decisionSource: 'classifier:rule-5-busy-ready-flag',
          ),
        ],
      );
      final r = run([forceA4], lastManifest: m);
      expect(r.kept, isEmpty);
      expect(r.skipped, [forceA4]);
    });

    test('preference already selected via override → skipped', () {
      const pref = SetPreference(rationale: 'r', symbol: 'A', artifactId: 4);
      final r = run([pref], overrides: {'A': 4});
      expect(r.skipped, [pref]);
    });

    test('preference already set → skipped; new preference → kept', () {
      const pref = SetPreference(rationale: 'r', symbol: 'A', artifactId: 4);
      expect(run([pref], preferences: {'A': 4}).skipped, [pref]);
      expect(run([pref], preferences: {'A': 3}).kept, [pref]);
    });

    test('clear of an absent override → skipped', () {
      const clear = ClearForcedOverride(rationale: 'r', symbol: 'A');
      final r = run([clear]);
      expect(r.skipped, [clear]);
    });

    test('clear of an existing override → kept', () {
      const clear = ClearForcedOverride(rationale: 'r', symbol: 'A');
      final r = run([clear], overrides: {'A': 4});
      expect(r.kept, [clear]);
    });

    test('GenerateCustomHook and AdjustIterationCap are never filtered',
        () {
      const gen = GenerateCustomHook(rationale: 'r', symbol: 'A');
      const cap = AdjustIterationCap(rationale: 'r', newValue: 10);
      final r = run([gen, cap], overrides: {'A': 4});
      expect(r.kept, [gen, cap]);
      expect(r.skipped, isEmpty);
    });
  });

  group('isCoverageStagnant', () {
    test('identical executed sets on successful rounds → stagnant', () {
      expect(
        isCoverageStagnant(
          prevExecuted: {'a', 'b'},
          currentExecuted: {'a', 'b'},
          currentFailedSymbol: null,
        ),
        isTrue,
      );
    });

    test('grown executed set → not stagnant', () {
      expect(
        isCoverageStagnant(
          prevExecuted: {'a', 'b'},
          currentExecuted: {'a', 'b', 'c'},
          currentFailedSymbol: null,
        ),
        isFalse,
      );
    });

    test('SHRUNKEN executed set → stagnant (nothing new was reached)',
        () {
      // Observed live: a wrapper-skip lost one symbol and gained
      // none. Treating the shrink as "movement" reset the escalation
      // counter and wasted the remaining rounds.
      expect(
        isCoverageStagnant(
          prevExecuted: {'a', 'b'},
          currentExecuted: {'a'},
          currentFailedSymbol: null,
        ),
        isTrue,
      );
    });

    test('same count but different symbols → not stagnant (shifted path)',
        () {
      expect(
        isCoverageStagnant(
          prevExecuted: {'a', 'b'},
          currentExecuted: {'a', 'c'},
          currentFailedSymbol: null,
        ),
        isFalse,
      );
    });

    test('crash rounds are out of scope', () {
      expect(
        isCoverageStagnant(
          prevExecuted: {'a'},
          currentExecuted: {'a'},
          currentFailedSymbol: 'X',
        ),
        isFalse,
        reason: "repeated crashes are isNoProgress's jurisdiction",
      );
    });

    test('null executed sets (legacy manifests) → not stagnant', () {
      expect(
        isCoverageStagnant(
          prevExecuted: null,
          currentExecuted: {'a'},
          currentFailedSymbol: null,
        ),
        isFalse,
      );
      expect(
        isCoverageStagnant(
          prevExecuted: {'a'},
          currentExecuted: null,
          currentFailedSymbol: null,
        ),
        isFalse,
      );
    });
  });
}
