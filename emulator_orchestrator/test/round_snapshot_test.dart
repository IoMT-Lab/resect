import 'dart:convert';

import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('Recommendation JSON', () {
    test('SetForcedOverride round-trips with all fields', () {
      const original = SetForcedOverride(
        rationale: 'busy bit always reads 1',
        symbol: 'LL_RCC_HSE_IsReady',
        artifactId: 4,
        scope: 'HSE',
      );
      final decoded = Recommendation.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(decoded, isA<SetForcedOverride>());
      final r = decoded! as SetForcedOverride;
      expect(r.symbol, 'LL_RCC_HSE_IsReady');
      expect(r.artifactId, 4);
      expect(r.scope, 'HSE');
      expect(r.rationale, 'busy bit always reads 1');
    });

    test('SetForcedOverride round-trips with null scope', () {
      const original = SetForcedOverride(
        rationale: 'pin',
        symbol: 's',
        artifactId: 1,
      );
      final json = original.toJson();
      expect(json.containsKey('scope'), isFalse);
      final decoded =
          Recommendation.fromJson(json)! as SetForcedOverride;
      expect(decoded.scope, isNull);
    });

    test('ClearForcedOverride round-trips', () {
      const original = ClearForcedOverride(rationale: 'oops', symbol: 's');
      final decoded =
          Recommendation.fromJson(original.toJson())! as ClearForcedOverride;
      expect(decoded.symbol, 's');
      expect(decoded.rationale, 'oops');
    });

    test('SetPreference round-trips', () {
      const original = SetPreference(
          rationale: 'try this first', symbol: 's', artifactId: 12);
      final decoded =
          Recommendation.fromJson(original.toJson())! as SetPreference;
      expect(decoded.symbol, 's');
      expect(decoded.artifactId, 12);
    });

    test('GenerateCustomHook round-trips with intent', () {
      const original = GenerateCustomHook(
        rationale: 'no catalog match',
        symbol: 'mystery_fn',
        intent: 'return current SpO2 reading',
      );
      final decoded =
          Recommendation.fromJson(original.toJson())! as GenerateCustomHook;
      expect(decoded.symbol, 'mystery_fn');
      expect(decoded.intent, 'return current SpO2 reading');
    });

    test('GenerateCustomHook round-trips without intent', () {
      const original = GenerateCustomHook(
        rationale: 'no catalog match',
        symbol: 's',
      );
      final json = original.toJson();
      expect(json.containsKey('intent'), isFalse);
      final decoded =
          Recommendation.fromJson(json)! as GenerateCustomHook;
      expect(decoded.intent, isNull);
    });

    test('AdjustIterationCap round-trips', () {
      const original = AdjustIterationCap(
        rationale: 'need more iterations',
        newValue: 25,
      );
      final decoded =
          Recommendation.fromJson(original.toJson())! as AdjustIterationCap;
      expect(decoded.newValue, 25);
    });

    test('unknown kind returns null instead of throwing', () {
      final decoded = Recommendation.fromJson({
        'kind': 'reroute_signal',
        'rationale': 'future feature',
        'symbol': 's',
      });
      expect(decoded, isNull);
    });

    test('missing rationale defaults to empty string', () {
      final decoded = Recommendation.fromJson({
        'kind': 'clear_forced_override',
        'symbol': 's',
      });
      expect(decoded, isNotNull);
      expect(decoded!.rationale, '');
    });
  });

  group('RecommendationDecision', () {
    test('accepted decision: applied == original', () {
      const original = SetPreference(
          rationale: 'try first', symbol: 's', artifactId: 5);
      const decision = RecommendationDecision(
        original: original,
        action: UserAction.accepted,
      );
      expect(decision.applied, original);
    });

    test('rejected decision: applied == null', () {
      const original = SetPreference(
          rationale: 'try first', symbol: 's', artifactId: 5);
      const decision = RecommendationDecision(
        original: original,
        action: UserAction.rejected,
      );
      expect(decision.applied, isNull);
    });

    test('edited decision: applied == edited', () {
      const original = SetPreference(
          rationale: 'try first', symbol: 's', artifactId: 5);
      const edited = SetPreference(
          rationale: 'try first', symbol: 's', artifactId: 12);
      const decision = RecommendationDecision(
        original: original,
        action: UserAction.edited,
        edited: edited,
      );
      expect((decision.applied! as SetPreference).artifactId, 12);
    });

    test('edited decision with null edited falls back to original', () {
      const original = SetPreference(
          rationale: 'try first', symbol: 's', artifactId: 5);
      const decision = RecommendationDecision(
        original: original,
        action: UserAction.edited,
      );
      expect(decision.applied, original);
    });

    test('round-trips through JSON', () {
      const original = SetForcedOverride(
        rationale: 'pin',
        symbol: 'sym',
        artifactId: 1,
        scope: 'HSE',
      );
      const decision = RecommendationDecision(
        original: original,
        action: UserAction.edited,
        edited: SetForcedOverride(
          rationale: 'pin',
          symbol: 'sym',
          artifactId: 2,
          scope: 'HSE',
        ),
        userNote: 'preferred artifact 2',
      );
      final decoded = RecommendationDecision.fromJson(
          jsonDecode(jsonEncode(decision.toJson())) as Map<String, dynamic>);
      expect(decoded.action, UserAction.edited);
      expect(decoded.userNote, 'preferred artifact 2');
      expect((decoded.original as SetForcedOverride).artifactId, 1);
      expect((decoded.edited! as SetForcedOverride).artifactId, 2);
    });
  });

  group('RoundSnapshot JSON', () {
    RoundSnapshot sample({int round = 1}) => RoundSnapshot(
          snapshotVersion: RoundSnapshot.currentVersion,
          round: round,
          synthesizerRunId: '2026-06-17T10:00:00.000',
          createdAt: DateTime.utc(2026, 6, 17, 10, 0),
          hookOverrides: const {'sym': 4},
          hookOverrideScopes: const {'sym': 'HSE'},
          hookPreferences: const {'sym2': 12},
          hookBindings: {
            'sym3': HookBinding(
              artifactId: 7,
              fidelity: 0.5,
              provenance: 'classifier:rule-6-pure-peripheral-writes',
              createdAt: DateTime.utc(2026, 6, 17, 10, 0),
            ),
          },
          iterationCap: 10,
          metrics: const ManifestMetrics(
            overallFidelity: 0.7,
            coverageFidelity: 0.8,
            subgraphFidelity: null,
            intactCount: 100,
            degradedCount: 20,
            hookedCount: 5,
          ),
          executedSymbols: const ['Reset_Handler', 'main'],
          manifestRef: const SynthesisManifestRef(
              runId: '2026-06-17T10:00:00.000', path: '/p/manifests/r.json'),
          llmRecommendations: const [
            SetForcedOverride(
              rationale: 'pin',
              symbol: 'sym',
              artifactId: 4,
              scope: 'HSE',
            ),
          ],
          userDecisions: const [
            RecommendationDecision(
              original: SetForcedOverride(
                rationale: 'pin',
                symbol: 'sym',
                artifactId: 4,
                scope: 'HSE',
              ),
              action: UserAction.accepted,
            ),
          ],
          llmProse: 'short summary',
        );

    test('full snapshot round-trips', () {
      final original = sample();
      final decoded = RoundSnapshot.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(decoded.round, original.round);
      expect(decoded.synthesizerRunId, original.synthesizerRunId);
      expect(decoded.hookOverrides, original.hookOverrides);
      expect(decoded.hookOverrideScopes, original.hookOverrideScopes);
      expect(decoded.hookPreferences, original.hookPreferences);
      expect(decoded.hookBindings.length, 1);
      expect(decoded.hookBindings['sym3']!.artifactId, 7);
      expect(decoded.iterationCap, 10);
      expect(decoded.metrics.overallFidelity, 0.7);
      expect(decoded.metrics.subgraphFidelity, isNull);
      expect(decoded.executedSymbols, ['Reset_Handler', 'main']);
      expect(decoded.manifestRef.runId, '2026-06-17T10:00:00.000');
      expect(decoded.manifestRef.path, '/p/manifests/r.json');
      expect(decoded.llmRecommendations!.length, 1);
      expect(decoded.userDecisions!.length, 1);
      expect(decoded.userDecisions!.single.action, UserAction.accepted);
      expect(decoded.llmProse, 'short summary');
    });

    test('reverted + warnings round-trip; absent keys default off', () {
      final base = sample().toJson();
      // Old snapshots (no keys) parse as not-reverted, no warnings.
      final old = RoundSnapshot.fromJson(
          jsonDecode(jsonEncode(base)) as Map<String, dynamic>);
      expect(old.reverted, isFalse);
      expect(old.warnings, isEmpty);

      base['reverted'] = true;
      base['warnings'] = ['`X` ← constant: looks like a frozen counter'];
      final decoded = RoundSnapshot.fromJson(
          jsonDecode(jsonEncode(base)) as Map<String, dynamic>);
      expect(decoded.reverted, isTrue);
      expect(decoded.warnings, hasLength(1));
    });

    test('forward-compat null slots round-trip as null', () {
      final original = sample();
      final decoded = RoundSnapshot.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);
      expect(decoded.memoryMapCheckpointPath, isNull);
      expect(decoded.resumePointSymbol, isNull);
      expect(decoded.deviceProfileSnapshot, isNull);
    });

    test('round-0 baseline with no LLM input round-trips', () {
      final baseline = RoundSnapshot(
        snapshotVersion: RoundSnapshot.currentVersion,
        round: 0,
        synthesizerRunId: 'r',
        createdAt: DateTime.utc(2026),
        hookOverrides: const {},
        hookOverrideScopes: const {},
        hookPreferences: const {},
        hookBindings: const {},
        iterationCap: 10,
        metrics: const ManifestMetrics(
          overallFidelity: 1.0,
          coverageFidelity: null,
          subgraphFidelity: null,
          intactCount: 0,
          degradedCount: 0,
          hookedCount: 0,
        ),
        executedSymbols: const [],
        manifestRef: const SynthesisManifestRef(runId: 'r'),
      );
      final decoded = RoundSnapshot.fromJson(
          jsonDecode(jsonEncode(baseline.toJson())) as Map<String, dynamic>);
      expect(decoded.llmRecommendations, isNull);
      expect(decoded.userDecisions, isNull);
      expect(decoded.llmProse, isNull);
    });

    test('rejects unknown future snapshot_version', () {
      final json = sample().toJson()..['snapshot_version'] = 99;
      expect(
        () => RoundSnapshot.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Emulator snapshot helpers', () {
    RoundSnapshot snap(int round) => RoundSnapshot(
          snapshotVersion: RoundSnapshot.currentVersion,
          round: round,
          synthesizerRunId: 'run-$round',
          createdAt: DateTime.utc(2026, 6, 17, 0, round),
          hookOverrides: const {},
          hookOverrideScopes: const {},
          hookPreferences: const {},
          hookBindings: const {},
          iterationCap: 10,
          metrics: const ManifestMetrics(
            overallFidelity: 1.0,
            coverageFidelity: null,
            subgraphFidelity: null,
            intactCount: 0,
            degradedCount: 0,
            hookedCount: 0,
          ),
          executedSymbols: const [],
          manifestRef: SynthesisManifestRef(runId: 'run-$round'),
        );

    Emulator emptyEmu({int cap = Emulator.defaultSnapshotCap}) => Emulator(
          id: 'id',
          name: 'name',
          createdAt: DateTime.utc(2026),
          modifiedAt: DateTime.utc(2026),
          emulationConfig: EmulationConfig.defaults(),
          uiState: UiState.defaults(),
          roundSnapshotCap: cap,
        );

    test('appendRoundSnapshot grows the list when under the cap', () {
      var emu = emptyEmu();
      emu = emu.appendRoundSnapshot(snap(0));
      emu = emu.appendRoundSnapshot(snap(1));
      expect(emu.roundSnapshots.length, 2);
      expect(emu.roundSnapshots[0].round, 0);
      expect(emu.roundSnapshots[1].round, 1);
    });

    test('appendRoundSnapshot prunes oldest FIFO at the cap', () {
      var emu = emptyEmu(cap: 3);
      for (var r = 0; r < 6; r++) {
        emu = emu.appendRoundSnapshot(snap(r));
      }
      expect(emu.roundSnapshots.length, 3);
      // Last three rounds survive.
      expect(emu.roundSnapshots.map((s) => s.round).toList(), [3, 4, 5]);
    });

    test('appendRoundSnapshot with cap=0 drops everything', () {
      var emu = emptyEmu(cap: 0);
      emu = emu.appendRoundSnapshot(snap(0));
      expect(emu.roundSnapshots, isEmpty);
    });

    test('appendRoundSnapshot with negative cap is unlimited', () {
      var emu = emptyEmu(cap: -1);
      for (var r = 0; r < 150; r++) {
        emu = emu.appendRoundSnapshot(snap(r));
      }
      expect(emu.roundSnapshots.length, 150);
    });

    test('latestSnapshot returns last appended', () {
      var emu = emptyEmu();
      expect(emu.latestSnapshot, isNull);
      emu = emu.appendRoundSnapshot(snap(0));
      emu = emu.appendRoundSnapshot(snap(1));
      expect(emu.latestSnapshot!.round, 1);
    });

    test('snapshotForRound finds by round number', () {
      var emu = emptyEmu();
      emu = emu.appendRoundSnapshot(snap(0));
      emu = emu.appendRoundSnapshot(snap(2));
      expect(emu.snapshotForRound(0)!.round, 0);
      expect(emu.snapshotForRound(1), isNull);
      expect(emu.snapshotForRound(2)!.round, 2);
    });

    test('snapshotsForRunId returns all matching', () {
      var emu = emptyEmu();
      emu = emu.appendRoundSnapshot(snap(0));
      emu = emu.appendRoundSnapshot(snap(1));
      expect(emu.snapshotsForRunId('run-1').length, 1);
      expect(emu.snapshotsForRunId('nonexistent'), isEmpty);
    });

    test('roundSnapshots survive .emu JSON round-trip', () {
      var emu = emptyEmu(cap: 5);
      emu = emu.appendRoundSnapshot(snap(0));
      emu = emu.appendRoundSnapshot(snap(1));
      final encoded = jsonEncode(emu.toJson());
      final decoded =
          Emulator.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded.roundSnapshots.length, 2);
      expect(decoded.roundSnapshots[0].round, 0);
      expect(decoded.roundSnapshotCap, 5);
    });

    test('default cap omitted from JSON, falls back on read', () {
      final emu = emptyEmu();
      final json = emu.toJson();
      expect(json.containsKey('round_snapshot_cap'), isFalse);
      final decoded =
          Emulator.fromJson(jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(decoded.roundSnapshotCap, Emulator.defaultSnapshotCap);
    });
  });
}
