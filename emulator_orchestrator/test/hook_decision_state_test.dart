import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:test/test.dart';

void main() {
  group('buildHookDecisionState', () {
    Emulator baseEmulator({
      Map<String, int> hookOverrides = const {},
      Map<String, String> hookOverrideScopes = const {},
      Map<String, int> hookPreferences = const {},
      Map<String, HookBinding> hookBindings = const {},
      Map<String, String> hooks = const {},
      Map<String, CommsAssignment> commsAssignments = const {},
    }) {
      final now = DateTime.fromMillisecondsSinceEpoch(0);
      return Emulator(
        id: 'test',
        name: 'test',
        createdAt: now,
        modifiedAt: now,
        emulationConfig: EmulationConfig.defaults(),
        uiState: UiState.defaults(),
        hookOverrides: hookOverrides,
        hookOverrideScopes: hookOverrideScopes,
        hookPreferences: hookPreferences,
        hookBindings: hookBindings,
        hooks: hooks,
        commsAssignments: commsAssignments,
      );
    }

    test('empty emulator produces empty decisions list', () {
      final state = buildHookDecisionState(
        emulator: baseEmulator(),
        elfHash: 'abc123',
        commsConfigs: const {},
      );
      expect(state.elfHash, 'abc123');
      expect(state.decisions, isEmpty);
    });

    test('forced override beats every other overlay for the same symbol', () {
      final emulator = baseEmulator(
        hookOverrides: {'sym': 42},
        hookOverrideScopes: {'sym': 'i2c'},
        hookBindings: {
          'sym': HookBinding(
            artifactId: 99,
            fidelity: 1.0,
            provenance: 'user',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        },
        hooks: {'sym': 'unused warm-start body'},
      );
      final state = buildHookDecisionState(
        emulator: emulator,
        elfHash: 'abc',
        commsConfigs: const {},
      );
      expect(state.decisions, hasLength(1));
      final d = state.decisions.single;
      expect(d.kind, HookDecisionKind.override);
      expect(d.artifactId, 42);
      expect(d.scope, 'i2c');
    });

    test('comms decisions only emit when protocol is virtualized', () {
      final emulator = baseEmulator(
        commsAssignments: {
          'i2c_read_fn': const CommsAssignment(
            protocol: CommsClass.i2c,
            role: CommsRole.read,
          ),
          'spi_write_fn': const CommsAssignment(
            protocol: CommsClass.spi,
            role: CommsRole.write,
          ),
          'unclassified_fn':
              const CommsAssignment(protocol: CommsClass.unclassified),
        },
      );
      final state = buildHookDecisionState(
        emulator: emulator,
        elfHash: 'abc',
        commsConfigs: const {
          CommsClass.i2c: (virtualized: true, port: 6101),
          CommsClass.spi: (virtualized: false, port: 6102),
        },
      );
      expect(state.decisions, hasLength(1));
      final d = state.decisions.single;
      expect(d.symbol, 'i2c_read_fn');
      expect(d.kind, HookDecisionKind.comms);
      expect(d.protocol, 'i2c');
      expect(d.role, 'read');
      expect(d.port, 6101);
      expect(d.scope, 'i2c');
    });

    test('binding decision carries fidelity and provenance', () {
      final emulator = baseEmulator(
        hookBindings: {
          'fn': HookBinding(
            artifactId: 5,
            fidelity: 0.25,
            provenance: 'classifier:rule-2-return-literal',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        },
      );
      final state = buildHookDecisionState(
        emulator: emulator,
        elfHash: 'abc',
        commsConfigs: const {},
      );
      expect(state.decisions, hasLength(1));
      final d = state.decisions.single;
      expect(d.kind, HookDecisionKind.binding);
      expect(d.artifactId, 5);
      expect(d.fidelity, 0.25);
      expect(d.provenance, 'classifier:rule-2-return-literal');
    });

    test('preference attaches to an existing primary decision', () {
      final emulator = baseEmulator(
        hookBindings: {
          'fn': HookBinding(
            artifactId: 5,
            fidelity: 0.5,
            provenance: 'classifier:rule-3-counter-global',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        },
        hookPreferences: {'fn': 7},
      );
      final state = buildHookDecisionState(
        emulator: emulator,
        elfHash: 'abc',
        commsConfigs: const {},
      );
      expect(state.decisions, hasLength(1));
      final d = state.decisions.single;
      expect(d.kind, HookDecisionKind.binding);
      expect(d.artifactId, 5);
      expect(d.preferredArtifactId, 7);
    });

    test('preference alone creates a kind:none decision', () {
      final emulator = baseEmulator(
        hookPreferences: {'lonely': 99},
      );
      final state = buildHookDecisionState(
        emulator: emulator,
        elfHash: 'abc',
        commsConfigs: const {},
      );
      expect(state.decisions, hasLength(1));
      final d = state.decisions.single;
      expect(d.kind, HookDecisionKind.none);
      expect(d.preferredArtifactId, 99);
      expect(d.artifactId, isNull);
    });

    test('decisions are sorted by symbol name for stable diffs', () {
      final emulator = baseEmulator(
        hookOverrides: {'zzz': 1, 'aaa': 2, 'mmm': 3},
      );
      final state = buildHookDecisionState(
        emulator: emulator,
        elfHash: 'abc',
        commsConfigs: const {},
      );
      expect(state.decisions.map((d) => d.symbol).toList(),
          ['aaa', 'mmm', 'zzz']);
    });

    test('layered overlays — one of each kind plus a standalone preference',
        () {
      final emulator = baseEmulator(
        hookOverrides: {'forced': 10},
        hookOverrideScopes: {'forced': ''},
        commsAssignments: {
          'i2cfn': const CommsAssignment(
            protocol: CommsClass.i2c,
            role: CommsRole.write,
          ),
        },
        hooks: {'warm': 'setReturnValue(cpu, 0)'},
        hookBindings: {
          'bound': HookBinding(
            artifactId: 20,
            fidelity: 0.5,
            provenance: 'llm:gemma4:e4b',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        },
        hookPreferences: {'pref_only': 30, 'bound': 21},
      );
      final state = buildHookDecisionState(
        emulator: emulator,
        elfHash: 'abc',
        commsConfigs: const {
          CommsClass.i2c: (virtualized: true, port: 6101),
        },
      );

      final byKind = {
        for (final d in state.decisions) d.symbol: d,
      };
      expect(byKind['forced']!.kind, HookDecisionKind.override);
      expect(byKind['i2cfn']!.kind, HookDecisionKind.comms);
      expect(byKind['warm']!.kind, HookDecisionKind.resolved);
      expect(byKind['warm']!.body, 'setReturnValue(cpu, 0)');
      expect(byKind['bound']!.kind, HookDecisionKind.binding);
      expect(byKind['bound']!.preferredArtifactId, 21);
      expect(byKind['pref_only']!.kind, HookDecisionKind.none);
      expect(byKind['pref_only']!.preferredArtifactId, 30);
      // Empty-string scope on the override gets normalised to null.
      expect(byKind['forced']!.scope, isNull);
    });

    test('toJson omits null fields', () {
      const d = HookDecision(
        symbol: 'sym',
        kind: HookDecisionKind.binding,
        artifactId: 5,
        fidelity: 0.5,
        provenance: 'classifier:rule-3-counter-global',
      );
      final j = d.toJson();
      expect(j['symbol'], 'sym');
      expect(j['kind'], 'binding');
      expect(j['artifact_id'], 5);
      expect(j['fidelity'], 0.5);
      expect(j['provenance'], 'classifier:rule-3-counter-global');
      expect(j.containsKey('scope'), isFalse);
      expect(j.containsKey('body'), isFalse);
      expect(j.containsKey('protocol'), isFalse);
      expect(j.containsKey('preferred_artifact_id'), isFalse);
    });
  });
}
