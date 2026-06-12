import 'dart:convert';

import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
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
}
