import 'dart:convert';

import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/orchestrator/manifest_builder.dart';
import 'package:test/test.dart';

void main() {
  group('SynthesisManifest', () {
    String hashOf(String c) => List.filled(64, c).join();
    SynthesisManifest sample() => SynthesisManifest(
          manifestVersion: 1,
          elfHash: 'abc123def456',
          elfFileName: 'aya_ppg.elf',
          synthesizerRunId: '2026-06-12T15:30:00.000',
          result: const ManifestRunResult(
            success: true,
            totalIterations: 18,
            durationSeconds: 47.2,
          ),
          decisions: [
            ManifestDecision(
              symbol: 'HAL_GetTick',
              appliedHook: AppliedHook(artifactId: 12, bodyHash: hashOf('a')),
              decisionKind: ManifestDecisionKind.forcedOverride,
              decisionSource: 'user.hookOverrides',
            ),
            ManifestDecision(
              symbol: 'HAL_NVIC_GetPriority',
              appliedHook: AppliedHook(artifactId: 1, bodyHash: hashOf('b')),
              decisionKind: ManifestDecisionKind.binding,
              decisionSource: 'classifier:rule-2-return-literal',
              fidelityAtDecision: 0.25,
              iterationIndex: 0,
            ),
            ManifestDecision(
              symbol: 'app_eeprom_read_block',
              appliedHook: AppliedHook(artifactId: 41, bodyHash: hashOf('c')),
              decisionKind: ManifestDecisionKind.llmOnDemand,
              decisionSource: 'llm:gemma4:e4b',
              fidelityAtDecision: 0.5,
              iterationIndex: 0,
              llmInvocation: const LlmInvocation(model: 'gemma4:e4b'),
            ),
            ManifestDecision(
              symbol: 'fn_8000abcd',
              appliedHook: AppliedHook(artifactId: 5, bodyHash: hashOf('d')),
              decisionKind: ManifestDecisionKind.iterationFallback,
              decisionSource: 'default_template:#5',
              fidelityAtDecision: 0.0,
              iterationIndex: 1,
              previousAttempts: const [
                PreviousAttempt(
                  artifactId: 14,
                  outcome: 'unhandled_access_repeat',
                ),
              ],
            ),
            // Comms hook — no artifactId since the body is catalog-built.
            ManifestDecision(
              symbol: 'HAL_I2C_Master_Transmit',
              appliedHook: AppliedHook(bodyHash: hashOf('e'), scope: 'i2c'),
              decisionKind: ManifestDecisionKind.comms,
              decisionSource: 'comms:i2c',
            ),
          ],
        );

    test('toJson preserves all populated fields', () {
      final j = sample().toJson();
      expect(j['manifest_version'], 1);
      expect(j['elf_hash'], 'abc123def456');
      expect(j['elf_file_name'], 'aya_ppg.elf');
      expect(j['synthesizer_run_id'], '2026-06-12T15:30:00.000');
      expect((j['decisions'] as List).length, 5);
    });

    test('round-trips through JSON without losing fields', () {
      final original = sample();
      final encoded = jsonEncode(original.toJson());
      final decoded = SynthesisManifest.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>);

      expect(decoded.manifestVersion, original.manifestVersion);
      expect(decoded.elfHash, original.elfHash);
      expect(decoded.elfFileName, original.elfFileName);
      expect(decoded.synthesizerRunId, original.synthesizerRunId);
      expect(decoded.result.success, original.result.success);
      expect(decoded.result.totalIterations, original.result.totalIterations);
      expect(decoded.result.durationSeconds, original.result.durationSeconds);
      expect(decoded.decisions.length, original.decisions.length);
      for (var i = 0; i < decoded.decisions.length; i++) {
        final d = decoded.decisions[i];
        final o = original.decisions[i];
        expect(d.symbol, o.symbol);
        expect(d.decisionKind, o.decisionKind);
        expect(d.decisionSource, o.decisionSource);
        expect(d.fidelityAtDecision, o.fidelityAtDecision);
        expect(d.iterationIndex, o.iterationIndex);
        expect(d.appliedHook.artifactId, o.appliedHook.artifactId);
        expect(d.appliedHook.bodyHash, o.appliedHook.bodyHash);
        expect(d.appliedHook.scope, o.appliedHook.scope);
        expect(d.previousAttempts?.length, o.previousAttempts?.length);
        expect(d.llmInvocation?.model, o.llmInvocation?.model);
      }
    });

    test('rejects unknown manifest_version', () {
      final j = sample().toJson()..['manifest_version'] = 99;
      expect(
        () => SynthesisManifest.fromJson(j),
        throwsA(isA<FormatException>()),
      );
    });

    test('omits null/empty optional fields from JSON', () {
      const minimal = ManifestDecision(
        symbol: 'sym',
        appliedHook: AppliedHook(bodyHash: 'abc'),
        decisionKind: ManifestDecisionKind.warmStart,
        decisionSource: 'warm_start',
      );
      final j = minimal.toJson();
      expect(j.containsKey('fidelity_at_decision'), isFalse);
      expect(j.containsKey('iteration_index'), isFalse);
      expect(j.containsKey('previous_attempts'), isFalse);
      expect(j.containsKey('llm_invocation'), isFalse);
      expect((j['applied_hook'] as Map).containsKey('artifact_id'), isFalse);
      expect((j['applied_hook'] as Map).containsKey('scope'), isFalse);
    });

    test('terminationReason round-trips; null omits the key', () {
      final withReason = SynthesisManifest(
        manifestVersion: 2,
        elfHash: hashOf('a'),
        elfFileName: 'x.elf',
        synthesizerRunId: 'run1',
        result: const ManifestRunResult(
            success: false, totalIterations: 500, durationSeconds: 1.0),
        decisions: const [],
        terminationReason: SynthesisTerminationReason.maxIterations,
        finalExecutionSymbol: 'idle_loop',
        recentExecutionTrace: const ['main', 'SystemClock_Config', 'idle_loop'],
      );
      final j = withReason.toJson();
      expect(j['termination_reason'], 'maxIterations');
      expect(j['final_execution_symbol'], 'idle_loop');
      expect(j['recent_execution_trace'],
          ['main', 'SystemClock_Config', 'idle_loop']);
      final reparsed = SynthesisManifest.fromJson(
          jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(reparsed.terminationReason,
          SynthesisTerminationReason.maxIterations);
      expect(reparsed.finalExecutionSymbol, 'idle_loop');
      expect(reparsed.recentExecutionTrace,
          ['main', 'SystemClock_Config', 'idle_loop']);

      // Absent reason (legacy manifest) → key omitted, parses to null.
      final noReason = SynthesisManifest(
        manifestVersion: 2,
        elfHash: hashOf('a'),
        elfFileName: 'x.elf',
        synthesizerRunId: 'run1',
        result: const ManifestRunResult(
            success: true, totalIterations: 1, durationSeconds: 1.0),
        decisions: const [],
      );
      expect(noReason.toJson().containsKey('termination_reason'), isFalse);
      expect(terminationReasonFromName(null), isNull);
      expect(terminationReasonFromName('bogus'), isNull);
    });

    test('ManifestDecisionKind.fromJson is symmetric with jsonName', () {
      for (final kind in ManifestDecisionKind.values) {
        expect(ManifestDecisionKind.fromJson(kind.jsonName), kind);
      }
    });

    test('ManifestDecisionKind.fromJson rejects unknown names', () {
      expect(
        () => ManifestDecisionKind.fromJson('bogus_kind'),
        throwsA(isA<FormatException>()),
      );
    });

    test('AppliedHook.hashBody returns a stable 64-char hex string', () {
      const body = 'import set_return_value\nsetReturnValue(cpu, 0)\n';
      final h1 = AppliedHook.hashBody(body);
      final h2 = AppliedHook.hashBody(body);
      expect(h1, h2);
      expect(h1.length, 64);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(h1), isTrue);
    });

    test('toPrettyJson is parseable and 2-space indented', () {
      final pretty = sample().toPrettyJson();
      // Indented JSON has at least one line starting with two spaces.
      expect(pretty.contains('\n  '), isTrue);
      final reparsed = SynthesisManifest.fromJson(
          jsonDecode(pretty) as Map<String, dynamic>);
      expect(reparsed.decisions.length, 5);
    });
  });

  group('SynthesisManifest v2 schema', () {
    SynthesisManifest v2Sample() => SynthesisManifest(
          manifestVersion: SynthesisManifest.currentVersion,
          elfHash: 'abc123',
          elfFileName: 'aya_ppg.elf',
          synthesizerRunId: '2026-06-17T10:00:00.000',
          result: const ManifestRunResult(
            success: true,
            totalIterations: 4,
            durationSeconds: 12.5,
          ),
          decisions: [
            ManifestDecision(
              symbol: 'HAL_GetTick',
              appliedHook: AppliedHook(
                artifactId: 12,
                bodyHash: List.filled(64, 'a').join(),
              ),
              decisionKind: ManifestDecisionKind.binding,
              decisionSource: 'classifier:rule-3-counter-global',
              fidelityAtDecision: 0.5,
              iterationIndex: 0,
              autoTuneRound: 2,
            ),
          ],
          metrics: const ManifestMetrics(
            overallFidelity: 0.74,
            coverageFidelity: 0.82,
            subgraphFidelity: 0.91,
            intactCount: 120,
            degradedCount: 22,
            hookedCount: 8,
          ),
          executedSymbols: const ['Reset_Handler', 'main', 'HAL_GetTick'],
          timing: const [
            IterationTiming(iterationIndex: 0, wallClockSeconds: 3.1),
            IterationTiming(iterationIndex: 1, wallClockSeconds: 4.4),
          ],
        );

    test('currentVersion is 2', () {
      expect(SynthesisManifest.currentVersion, 2);
    });

    test('v2 manifest with all enrichment fields round-trips', () {
      final original = v2Sample();
      final encoded = jsonEncode(original.toJson());
      final decoded = SynthesisManifest.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>);

      expect(decoded.manifestVersion, 2);
      expect(decoded.metrics, isNotNull);
      expect(decoded.metrics!.overallFidelity, original.metrics!.overallFidelity);
      expect(decoded.metrics!.coverageFidelity, original.metrics!.coverageFidelity);
      expect(decoded.metrics!.subgraphFidelity, original.metrics!.subgraphFidelity);
      expect(decoded.metrics!.intactCount, original.metrics!.intactCount);
      expect(decoded.metrics!.degradedCount, original.metrics!.degradedCount);
      expect(decoded.metrics!.hookedCount, original.metrics!.hookedCount);
      expect(decoded.executedSymbols, original.executedSymbols);
      expect(decoded.timing?.length, 2);
      expect(decoded.timing![0].iterationIndex, 0);
      expect(decoded.timing![0].wallClockSeconds, 3.1);
      expect(decoded.decisions.first.autoTuneRound, 2);
    });

    test('v2 manifest with no enrichment leaves new fields null', () {
      final bare = SynthesisManifest(
        manifestVersion: SynthesisManifest.currentVersion,
        elfHash: 'h',
        elfFileName: 'f.elf',
        synthesizerRunId: 'r',
        result: const ManifestRunResult(
            success: true, totalIterations: 0, durationSeconds: 0.0),
        decisions: const [],
      );
      final encoded = jsonEncode(bare.toJson());
      final decoded = SynthesisManifest.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded.metrics, isNull);
      expect(decoded.executedSymbols, isNull);
      expect(decoded.timing, isNull);
    });

    test('v1 manifest (no enrichment keys) loads in the v2 reader', () {
      // Hand-crafted v1 JSON — what a manifest written by the prior
      // build would look like on disk. The v2 reader must accept it.
      final v1Json = {
        'manifest_version': 1,
        'elf_hash': 'abc',
        'elf_file_name': 'old.elf',
        'synthesizer_run_id': '2026-03-01T00:00:00.000',
        'result': {
          'success': true,
          'total_iterations': 5,
          'duration_seconds': 30.0,
        },
        'decisions': [
          {
            'symbol': 'HAL_GetTick',
            'applied_hook': {
              'artifact_id': 12,
              'body_hash': List.filled(64, 'a').join(),
            },
            'decision_kind': 'binding',
            'decision_source': 'classifier:rule-3-counter-global',
            'fidelity_at_decision': 0.5,
            'iteration_index': 0,
          },
        ],
      };
      final decoded = SynthesisManifest.fromJson(v1Json);
      expect(decoded.manifestVersion, 1);
      expect(decoded.metrics, isNull);
      expect(decoded.executedSymbols, isNull);
      expect(decoded.timing, isNull);
      expect(decoded.decisions.single.autoTuneRound, isNull);
      expect(decoded.decisions.single.symbol, 'HAL_GetTick');
    });

    test('lastPauseSymbol round-trips on success=true manifests', () {
      // The exact case the user complained about: success=true
      // (every paused symbol got a hook) but the firmware was
      // still spinning on LL_RCC_LSI_IsReady at the end. The
      // manifest needs to carry that signal so the LLM advisor
      // doesn't fall back to the wrong "Halt point" symbol.
      final manifest = SynthesisManifest(
        manifestVersion: SynthesisManifest.currentVersion,
        elfHash: 'h',
        elfFileName: 'f.elf',
        synthesizerRunId: 'r',
        result: const ManifestRunResult(
            success: true, totalIterations: 9, durationSeconds: 38.8),
        decisions: const [],
        lastPauseSymbol: 'LL_RCC_LSI_IsReady',
      );
      final encoded = jsonEncode(manifest.toJson());
      // Wire-format check: the JSON key is `last_pause_symbol`
      // (snake_case), matching the rest of the manifest schema.
      expect(encoded, contains('"last_pause_symbol":"LL_RCC_LSI_IsReady"'));
      final decoded = SynthesisManifest.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded.lastPauseSymbol, 'LL_RCC_LSI_IsReady');
      expect(decoded.failedSymbol, isNull);
    });

    test('lastPauseSymbol is omitted from JSON when null (legacy compat)',
        () {
      final manifest = SynthesisManifest(
        manifestVersion: SynthesisManifest.currentVersion,
        elfHash: 'h',
        elfFileName: 'f.elf',
        synthesizerRunId: 'r',
        result: const ManifestRunResult(
            success: true, totalIterations: 0, durationSeconds: 0.0),
        decisions: const [],
      );
      final encoded = jsonEncode(manifest.toJson());
      expect(encoded, isNot(contains('last_pause_symbol')));
    });

    test('v1 manifests load with lastPauseSymbol null', () {
      // Legacy on-disk manifests don't carry the field — loader
      // must tolerate its absence.
      final v1Json = {
        'manifest_version': 1,
        'elf_hash': 'abc',
        'elf_file_name': 'old.elf',
        'synthesizer_run_id': '2026-03-01T00:00:00.000',
        'result': {
          'success': true,
          'total_iterations': 5,
          'duration_seconds': 30.0,
        },
        'decisions': const <dynamic>[],
      };
      final decoded = SynthesisManifest.fromJson(v1Json);
      expect(decoded.lastPauseSymbol, isNull);
    });

    test('withMetrics produces a copy with enrichment populated', () {
      final bare = SynthesisManifest(
        manifestVersion: SynthesisManifest.currentVersion,
        elfHash: 'h',
        elfFileName: 'f.elf',
        synthesizerRunId: 'r',
        result: const ManifestRunResult(
            success: true, totalIterations: 0, durationSeconds: 0.0),
        decisions: const [],
      );
      final enriched = bare.withMetrics(
        metrics: const ManifestMetrics(
          overallFidelity: 0.5,
          coverageFidelity: 0.6,
          subgraphFidelity: 0.7,
          intactCount: 1,
          degradedCount: 2,
          hookedCount: 3,
        ),
        executedSymbols: const ['main'],
      );
      expect(bare.metrics, isNull); // original untouched
      expect(enriched.metrics, isNotNull);
      expect(enriched.metrics!.overallFidelity, 0.5);
      expect(enriched.executedSymbols, ['main']);
      // Other fields preserved.
      expect(enriched.elfHash, bare.elfHash);
      expect(enriched.synthesizerRunId, bare.synthesizerRunId);
    });
  });

  group('buildManifest reliable creation', () {
    Map<String, List<ManifestAttempt>> successAttempts() => {
          'HAL_GetTick': [
            ManifestAttempt(
              code: 'return 42',
              kind: ManifestDecisionKind.binding,
              source: 'classifier:rule-3-counter-global',
              artifactId: 12,
              fidelity: 0.5,
              iterationIndex: 0,
            ),
          ],
          'app_main': [
            ManifestAttempt(
              code: 'return 0',
              kind: ManifestDecisionKind.iterationFallback,
              source: 'default_template:#5',
              artifactId: 5,
              fidelity: 0.0,
              iterationIndex: 1,
            ),
          ],
        };

    test('success path: manifest carries all decisions, no failed_symbol',
        () {
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: true,
        totalIterations: 4,
        duration: const Duration(milliseconds: 12500),
        failedSymbol: null,
        attempts: successAttempts(),
      );
      expect(manifest, isNotNull);
      expect(manifest.manifestVersion, SynthesisManifest.currentVersion);
      expect(manifest.result.success, isTrue);
      expect(manifest.result.totalIterations, 4);
      expect(manifest.failedSymbol, isNull);
      expect(manifest.decisions.length, 2);
      // Sorted by symbol name.
      expect(manifest.decisions[0].symbol, 'HAL_GetTick');
      expect(manifest.decisions[1].symbol, 'app_main');
    });

    test('exhausted-symbol failure: failed_symbol populated, prior attempts kept',
        () {
      final attempts = {
        'StuckSymbol': [
          ManifestAttempt(
            code: 'return 0',
            kind: ManifestDecisionKind.iterationFallback,
            source: 'default_template:#1',
            artifactId: 1,
            iterationIndex: 0,
          ),
          ManifestAttempt(
            code: 'return 1',
            kind: ManifestDecisionKind.iterationFallback,
            source: 'default_template:#2',
            artifactId: 2,
            iterationIndex: 1,
          ),
        ],
      };
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: false,
        totalIterations: 2,
        duration: const Duration(seconds: 5),
        failedSymbol: 'StuckSymbol',
        attempts: attempts,
      );
      expect(manifest.result.success, isFalse);
      expect(manifest.failedSymbol, 'StuckSymbol');
      // Last attempt becomes applied_hook; earlier becomes previous_attempts.
      final d = manifest.decisions.single;
      expect(d.appliedHook.artifactId, 2);
      expect(d.previousAttempts, isNotNull);
      expect(d.previousAttempts!.length, 1);
      expect(d.previousAttempts!.first.artifactId, 1);
    });

    test('max-iterations exit: success=false, no failed_symbol, attempts intact',
        () {
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: false,
        totalIterations: 10,
        duration: const Duration(seconds: 60),
        failedSymbol: null,
        attempts: successAttempts(),
      );
      expect(manifest.result.success, isFalse);
      expect(manifest.failedSymbol, isNull);
      expect(manifest.result.totalIterations, 10);
      expect(manifest.decisions.length, 2);
    });

    test('cancellation exit: partial attempts produce a valid manifest', () {
      // User cancelled after one hook landed; only one symbol's attempt
      // captured.
      final attempts = {
        'EarlySymbol': [
          ManifestAttempt(
            code: 'return 0',
            kind: ManifestDecisionKind.binding,
            source: 'classifier:rule-1-empty-or-void-return',
            artifactId: 3,
            fidelity: 0.25,
            iterationIndex: 0,
          ),
        ],
      };
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: false,
        totalIterations: 1,
        duration: const Duration(seconds: 2),
        failedSymbol: null,
        attempts: attempts,
      );
      expect(manifest.decisions.length, 1);
      expect(manifest.decisions.single.symbol, 'EarlySymbol');
    });

    test('empty attempts: manifest still builds with zero decisions', () {
      // Synthesis crashed before any hook was tried. The manifest must
      // still exist so `result.manifest != null` holds and the auto-tune
      // orchestrator can snapshot the failed round.
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: false,
        totalIterations: 0,
        duration: Duration.zero,
        failedSymbol: null,
        attempts: const {},
      );
      expect(manifest, isNotNull);
      expect(manifest.decisions, isEmpty);
      expect(manifest.result.success, isFalse);
      expect(manifest.result.totalIterations, 0);
    });

    test('timing metrics round-trip through JSON', () {
      // stops / phase_timings / census / timing are the report metrics
      // added for the report reorg — all optional, so a v2 manifest
      // stays valid without them (next test).
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: false,
        totalIterations: 3,
        duration: const Duration(seconds: 9),
        failedSymbol: 'HAL_Init',
        attempts: const {},
        timing: const [
          IterationTiming(iterationIndex: 0, wallClockSeconds: 1.5),
          IterationTiming(iterationIndex: 1, wallClockSeconds: 2.0),
        ],
        stops: const [
          StopTiming(
              elapsedSeconds: 0.8, kind: 'unhandled_access', symbol: 'HAL_Init'),
          StopTiming(elapsedSeconds: 4.2, kind: 'pause'),
          StopTiming(elapsedSeconds: 9.0, kind: 'clean_exit'),
        ],
        phaseTimings:
            const PhaseTimings(selectionSeconds: 1.2, generationSeconds: 30.5),
      );
      final decoded = SynthesisManifest.fromJson(
          jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>);
      expect(decoded.timing, hasLength(2));
      expect(decoded.timing![1].wallClockSeconds, 2.0);
      expect(decoded.stops, hasLength(3));
      expect(decoded.stops!.first.elapsedSeconds, 0.8);
      expect(decoded.stops!.first.kind, 'unhandled_access');
      expect(decoded.stops!.first.symbol, 'HAL_Init');
      expect(decoded.stops![1].symbol, isNull);
      expect(decoded.phaseTimings!.selectionSeconds, 1.2);
      expect(decoded.phaseTimings!.generationSeconds, 30.5);
      // Auto-tune round fields default null until folded in.
      expect(decoded.phaseTimings!.advisorSeconds, isNull);
      expect(decoded.phaseTimings!.roundHookGenSeconds, isNull);
    });

    test('withRoundTelemetry folds advisor/hook-gen/census in', () {
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: true,
        totalIterations: 1,
        duration: const Duration(seconds: 2),
        failedSymbol: null,
        attempts: const {},
        phaseTimings:
            const PhaseTimings(selectionSeconds: 1.0, generationSeconds: 2.0),
      );
      final folded = manifest.withRoundTelemetry(
        advisorSeconds: 40.0,
        roundHookGenSeconds: 5.0,
        census: const ArtifactCensus(
          hookArtifacts: 1,
          hookBindings: 0,
          forcedOverrides: 0,
          commsAssignments: 0,
          groupMembers: 0,
          ragChunksByKind: {},
          signatures: 0,
          decompilations: 0,
        ),
      );
      final decoded = SynthesisManifest.fromJson(
          jsonDecode(jsonEncode(folded.toJson())) as Map<String, dynamic>);
      expect(decoded.phaseTimings!.selectionSeconds, 1.0);
      expect(decoded.phaseTimings!.advisorSeconds, 40.0);
      expect(decoded.phaseTimings!.roundHookGenSeconds, 5.0);
      expect(decoded.census!.hookArtifacts, 1);

      // Folding onto a manifest with NO phase timings creates them
      // (zeroed workflow phases) rather than dropping the round times.
      final bare = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r2',
        success: true,
        totalIterations: 1,
        duration: Duration.zero,
        failedSymbol: null,
        attempts: const {},
      ).withRoundTelemetry(advisorSeconds: 7.0);
      expect(bare.phaseTimings!.advisorSeconds, 7.0);
      expect(bare.phaseTimings!.selectionSeconds, 0.0);
    });

    test('metrics coverage numbers round-trip and back-fill as null', () {
      const withCoverage = ManifestMetrics(
        overallFidelity: 0.8,
        coverageFidelity: null,
        subgraphFidelity: null,
        intactCount: 1,
        degradedCount: 0,
        hookedCount: 0,
        executedCount: 50,
        totalSymbols: 945,
      );
      final decoded = ManifestMetrics.fromJson(
          jsonDecode(jsonEncode(withCoverage.toJson()))
              as Map<String, dynamic>);
      expect(decoded.executedCount, 50);
      expect(decoded.totalSymbols, 945);
      expect(decoded.coverageRatio, closeTo(50 / 945, 1e-9));

      // Old metrics JSON without the keys → nulls, no ratio.
      final old = ManifestMetrics.fromJson(const {
        'overall_fidelity': 0.5,
        'intact_count': 1,
        'degraded_count': 0,
        'hooked_count': 0,
      });
      expect(old.executedCount, isNull);
      expect(old.coverageRatio, isNull);
    });

    test('census round-trips through JSON and totals add up', () {
      const census = ArtifactCensus(
        hookArtifacts: 40,
        hookBindings: 3,
        forcedOverrides: 2,
        commsAssignments: 5,
        groupMembers: 12,
        ragChunksByKind: {'docs': 100, 'symbols': 50},
        signatures: 900,
        decompilations: 7,
      );
      final decoded = ArtifactCensus.fromJson(
          jsonDecode(jsonEncode(census.toJson())) as Map<String, dynamic>);
      expect(decoded.ragChunksByKind, {'docs': 100, 'symbols': 50});
      expect(decoded.ragChunksTotal, 150);
      expect(decoded.total, 40 + 3 + 2 + 5 + 12 + 150 + 900 + 7);
    });

    test('v2 manifest without timing metrics still parses', () {
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: true,
        totalIterations: 0,
        duration: Duration.zero,
        failedSymbol: null,
        attempts: const {},
      );
      final decoded = SynthesisManifest.fromJson(
          jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>);
      expect(decoded.timing, isNull);
      expect(decoded.stops, isNull);
      expect(decoded.phaseTimings, isNull);
      expect(decoded.census, isNull);
    });

    test('every built manifest stamps the current version', () {
      // Regression guard: a manifest built fresh always claims v2 (or
      // whatever the current version is). Old code paths that hardcoded
      // version=1 would surface here.
      final manifest = buildManifest(
        elfHash: 'abc',
        elfFileName: 'f.elf',
        runId: 'r',
        success: true,
        totalIterations: 0,
        duration: Duration.zero,
        failedSymbol: null,
        attempts: const {},
      );
      expect(manifest.manifestVersion, SynthesisManifest.currentVersion);
    });
  });
}
