import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:test/test.dart';

void main() {
  group('HookBinding scope', () {
    final stamp = DateTime.utc(2026, 6, 12, 15, 30);

    test('scope round-trips through JSON', () {
      final original = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'classifier:rule-3-counter-global',
        createdAt: stamp,
        scope: 'HAL_GetTick',
      );
      final decoded = HookBinding.fromJson(original.toJson());
      expect(decoded.artifactId, 5);
      expect(decoded.fidelity, 0.5);
      expect(decoded.provenance, 'classifier:rule-3-counter-global');
      expect(decoded.createdAt, stamp);
      expect(decoded.scope, 'HAL_GetTick');
    });

    test('null scope is omitted from JSON and round-trips as null', () {
      final original = HookBinding(
        artifactId: 1,
        fidelity: 0.25,
        provenance: 'classifier:rule-2-return-literal',
        createdAt: stamp,
        // scope intentionally omitted
      );
      final json = original.toJson();
      expect(json.containsKey('scope'), isFalse);
      final decoded = HookBinding.fromJson(json);
      expect(decoded.scope, isNull);
    });

    test('empty-string scope in JSON normalizes to null on read', () {
      final json = {
        'artifact_id': 1,
        'fidelity': 0.5,
        'provenance': 'user',
        'created_at': stamp.toIso8601String(),
        'scope': '', // legacy / cleared
      };
      final decoded = HookBinding.fromJson(json);
      expect(decoded.scope, isNull);
    });

    test('copyWith preserves scope unless explicitly cleared', () {
      final original = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'classifier:rule-3-counter-global',
        createdAt: stamp,
        scope: 'HAL_GetTick',
      );
      final kept = original.copyWith(fidelity: 0.6);
      expect(kept.scope, 'HAL_GetTick');
      expect(kept.fidelity, 0.6);

      final cleared = original.copyWith(clearScope: true);
      expect(cleared.scope, isNull);

      final changed = original.copyWith(scope: 'new_scope');
      expect(changed.scope, 'new_scope');
    });

    test('equality and hashCode include scope', () {
      final a = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'user',
        createdAt: stamp,
        scope: 's1',
      );
      final b = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'user',
        createdAt: stamp,
        scope: 's1',
      );
      final c = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'user',
        createdAt: stamp,
        scope: 's2',
      );
      final d = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'user',
        createdAt: stamp,
        // no scope
      );
      expect(a == b, isTrue);
      expect(a.hashCode == b.hashCode, isTrue);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });

    test('toString includes scope when present', () {
      final withScope = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'classifier:rule-3-counter-global',
        createdAt: stamp,
        scope: 'HAL_GetTick',
      );
      expect(withScope.toString(), contains('scope: HAL_GetTick'));

      final noScope = HookBinding(
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'classifier:rule-2-return-literal',
        createdAt: stamp,
      );
      expect(noScope.toString(), isNot(contains('scope:')));
    });
  });
}
