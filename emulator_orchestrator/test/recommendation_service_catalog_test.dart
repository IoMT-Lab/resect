import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart' as cg_sym;
import 'package:emulator_orchestrator/data/models/symbol_group.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:emulator_orchestrator/services/hooks/symbol_group_classifier.dart';
import 'package:emulator_orchestrator/services/analysis/coverage_frontier.dart';
import 'package:emulator_orchestrator/services/llm/last_run_insight_service.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:test/test.dart';

typedef _SeedRow = ({
  String body,
  String origin,
  String? name,
  String? targetSymbolName,
});

/// Seed an in-memory artifact DB with [rows] (id will be assigned
/// AUTOINCREMENT-style). To create a gap (id 12 missing) insert
/// rows id=1..N then delete the row mid-range.
Future<ArtifactDatabase> _seedDb(
  List<_SeedRow> rows, {
  List<int> deleteAfterInsert = const [],
}) async {
  final db = ArtifactDatabase.forTesting(NativeDatabase.memory());
  for (final r in rows) {
    await db.addArtifact(
      artifactType: 'renode_hook',
      artifactData: r.body,
      origin: r.origin,
      name: r.name,
      targetSymbolName: r.targetSymbolName,
    );
  }
  for (final id in deleteAfterInsert) {
    await db.deleteArtifact(id);
  }
  return db;
}

SynthesisManifest _manifest({
  List<ManifestDecision> decisions = const [],
  String? failedSymbol,
}) =>
    SynthesisManifest(
      manifestVersion: 2,
      elfHash: 'a' * 64,
      elfFileName: 'test.elf',
      synthesizerRunId: 'run1',
      result: ManifestRunResult(
        success: failedSymbol == null,
        totalIterations: 1,
        durationSeconds: 1.0,
      ),
      decisions: decisions,
      failedSymbol: failedSymbol,
    );

ManifestDecision _decision(String symbol, int iter) => ManifestDecision(
      symbol: symbol,
      appliedHook: const AppliedHook(bodyHash: 'h'),
      decisionKind: ManifestDecisionKind.iterationFallback,
      decisionSource: 'iteration_fallback',
      iterationIndex: iter,
    );

CallGraph _callGraph(List<String> symbols) {
  final map = {
    for (final s in symbols)
      s: cg_sym.Symbol(name: s, numInstructions: 1, calledSymbols: const {})
  };
  return CallGraph(elfPath: '/dev/null', symbols: map);
}

const _emptyState =
    HookDecisionState(elfHash: 'aaaaaaaa', decisions: []);

RecommendationService _makeService(ArtifactDatabase db) {
  final client = LlmClient(host: 'localhost:11434', model: 'gemma4:e4b');
  return RecommendationService(
    llmClient: client,
    insightService: LastRunInsightService(llmClient: client),
    artifactDb: db,
    // ragIndex omitted — exercising the catalog section in isolation.
  );
}

void main() {
  group('composePrompt — Available hook artifacts', () {
    test('renders id + origin + derived label + target_symbol', () async {
      final db = await _seedDb([
        (
          body: 'setReturnValue(cpu, 0)',
          origin: 'default',
          name: null,
          targetSymbolName: null,
        ),
        (
          body: 'setReturnValue(cpu, 1)',
          origin: 'default',
          name: null,
          targetSymbolName: null,
        ),
        (
          body: 'setReturnValue(cpu, 64000000)',
          origin: 'user',
          name: null,
          targetSymbolName: 'HAL_RCC_GetSysClockFreq',
        ),
      ]);
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: _manifest(
            decisions: [_decision('LL_RCC_LSI_IsReady', 1)]),
        currentState: _emptyState,
        callGraph: _callGraph(['LL_RCC_LSI_IsReady']),
      );
      expect(prompt, contains('## Available hook artifacts'));
      // The derived labels match what the Hook Database dialog shows.
      expect(prompt, contains('id=1  default  "Return 0"'));
      expect(prompt, contains('id=2  default  "Return 1"'));
      expect(prompt, contains('id=3  user  "Return 64000000"'));
      // Target symbol surfaced when set.
      expect(prompt, contains('target=HAL_RCC_GetSysClockFreq'));
      await db.close();
    });

    test(
        'preserves gaps in the id sequence (the bug class that '
        'caused artifact_id 12 to be invented)', () async {
      // Insert 4 rows, then delete id=2. AUTOINCREMENT means the
      // next insert gets id=5, NOT id=2. Render must show 1, 3, 4
      // — never 2.
      final db = await _seedDb(
        [
          (
            body: 'setReturnValue(cpu, 0)',
            origin: 'default',
            name: null,
            targetSymbolName: null,
          ),
          (
            body: 'setReturnValue(cpu, 1)',
            origin: 'default',
            name: null,
            targetSymbolName: null,
          ),
          (
            body: 'setReturnValue(cpu, 2)',
            origin: 'default',
            name: null,
            targetSymbolName: null,
          ),
          (
            body: 'setReturnValue(cpu, 3)',
            origin: 'default',
            name: null,
            targetSymbolName: null,
          ),
        ],
        deleteAfterInsert: [2],
      );
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: _manifest(
            decisions: [_decision('SystemInit', 1)]),
        currentState: _emptyState,
        callGraph: _callGraph(['SystemInit']),
      );
      // Surviving ids must appear.
      expect(prompt, contains('id=1'));
      expect(prompt, contains('id=3'));
      expect(prompt, contains('id=4'));
      // The deleted id must NOT appear in the catalog block.
      // (Match the exact "id=2  " token to avoid colliding with
      // strings like "20" inside labels.)
      final catalogStart = prompt.indexOf('## Available hook artifacts');
      final catalogEnd = prompt.indexOf('\n##', catalogStart + 1);
      final catalogBlock = catalogEnd == -1
          ? prompt.substring(catalogStart)
          : prompt.substring(catalogStart, catalogEnd);
      expect(catalogBlock, isNot(contains('id=2 ')));
      // The hint about AUTOINCREMENT gaps must be in the prompt so
      // the LLM knows not to invent intermediate IDs.
      expect(prompt, contains('gaps in the sequence'));
      expect(prompt, contains('do not invent IDs'));
      await db.close();
    });

    test('empty catalog renders the "(no artifacts registered)" line',
        () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: _manifest(),
        currentState: _emptyState,
        callGraph: _callGraph(const []),
      );
      expect(prompt, contains('## Available hook artifacts'));
      expect(prompt, contains('(no artifacts registered)'));
      await db.close();
    });
  });

  group('composePrompt — Auto-tune round history', () {
    /// Construct a minimal RoundSnapshot for fixture use. Captures
    /// the fields the prompt's history block actually renders;
    /// other required slots get reasonable defaults.
    RoundSnapshot makeSnapshot({
      required int round,
      required List<Recommendation> recs,
      required List<UserAction> actions,
    }) {
      assert(recs.length == actions.length);
      return RoundSnapshot(
        snapshotVersion: RoundSnapshot.currentVersion,
        round: round,
        synthesizerRunId: 'run$round',
        createdAt: DateTime(2026, 6, 17, 10, round),
        hookOverrides: const {},
        hookOverrideScopes: const {},
        hookPreferences: const {},
        hookBindings: const {},
        iterationCap: 10,
        metrics: const ManifestMetrics(
          overallFidelity: 0.988,
          coverageFidelity: 0.603,
          subgraphFidelity: null,
          intactCount: 829,
          degradedCount: 19,
          hookedCount: 8,
        ),
        executedSymbols: List<String>.generate(25, (i) => 'fn_$i'),
        manifestRef: SynthesisManifestRef(runId: 'run$round'),
        llmRecommendations: recs,
        userDecisions: [
          for (var i = 0; i < recs.length; i++)
            RecommendationDecision(original: recs[i], action: actions[i]),
        ],
      );
    }

    test(
        'renders each prior round\'s recommendations in compact form so '
        'the model can see what was already tried',
        () async {
      final db = await _seedDb([
        (
          body: 'setReturnValue(cpu, 0)',
          origin: 'default',
          name: null,
          targetSymbolName: null,
        ),
        (
          body: 'setReturnValue(cpu, 1)',
          origin: 'default',
          name: null,
          targetSymbolName: null,
        ),
      ]);
      final svc = _makeService(db);
      final history = [
        makeSnapshot(
          round: 1,
          recs: const [
            SetForcedOverride(
              rationale: 'try forcing busy bit ready',
              symbol: 'LL_RCC_HSE_IsReady',
              artifactId: 2,
              scope: 'HSE',
            ),
          ],
          actions: const [UserAction.accepted],
        ),
        makeSnapshot(
          round: 2,
          recs: const [
            SetForcedOverride(
              rationale: 'same idea, LSI side',
              symbol: 'LL_RCC_LSI_IsReady',
              artifactId: 2,
            ),
          ],
          actions: const [UserAction.accepted],
        ),
      ];
      final prompt = await svc.composePrompt(
        currentManifest: _manifest(
            decisions: [_decision('LL_RCC_LSI_Disable', 0)]),
        currentState: _emptyState,
        callGraph: _callGraph(['LL_RCC_LSI_Disable']),
        history: history,
      );
      // The model must see WHAT was tried, not just the count.
      expect(
        prompt,
        contains(
            'set_forced_override LL_RCC_HSE_IsReady ← #2 scope=HSE (accepted)'),
      );
      expect(
        prompt,
        contains('set_forced_override LL_RCC_LSI_IsReady ← #2 (accepted)'),
      );
      // The "Recommendations applied:" header introduces the bullets.
      expect(prompt, contains('- Recommendations applied:'));
      await db.close();
    });

    test('compact form covers every recommendation kind', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final history = [
        makeSnapshot(
          round: 1,
          recs: const [
            SetForcedOverride(
                rationale: 'a', symbol: 's1', artifactId: 4, scope: 'HSE'),
            ClearForcedOverride(rationale: 'b', symbol: 's2'),
            SetPreference(rationale: 'c', symbol: 's3', artifactId: 9),
            GenerateCustomHook(
                rationale: 'd',
                symbol: 's4',
                intent: 'flip the busy bit'),
            AdjustIterationCap(rationale: 'e', newValue: 25),
          ],
          actions: const [
            UserAction.accepted,
            UserAction.rejected,
            UserAction.edited,
            UserAction.accepted,
            UserAction.accepted,
          ],
        ),
      ];
      final prompt = await svc.composePrompt(
        currentManifest: _manifest(),
        currentState: _emptyState,
        callGraph: _callGraph(const []),
        history: history,
      );
      expect(
          prompt, contains('set_forced_override s1 ← #4 scope=HSE (accepted)'));
      expect(prompt, contains('clear_forced_override s2 (rejected)'));
      expect(prompt, contains('set_preference s3 ← #9 (edited)'));
      expect(prompt,
          contains('generate_custom_hook s4 intent="flip the busy bit"'));
      expect(prompt, contains('adjust_iteration_cap → 25 (accepted)'));
      await db.close();
    });
  });

  group('composePrompt — Retrieved context', () {
    test(
        'omitted entirely when ragIndex is null (the headless / no-project '
        'case)',
        () async {
      final db = await _seedDb([
        (
          body: 'setReturnValue(cpu, 0)',
          origin: 'default',
          name: null,
          targetSymbolName: null,
        ),
      ]);
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: _manifest(
            decisions: [_decision('SystemInit', 1)]),
        currentState: _emptyState,
        callGraph: _callGraph(['SystemInit']),
      );
      expect(prompt, isNot(contains('## Retrieved context')));
      await db.close();
    });
  });

  group('buildRecommendationSchema — constrained decoding', () {
    /// Pull the per-kind `anyOf` branches out of the items schema.
    List<Map<String, Object?>> branches(Map<String, Object?> schema) {
      final props = schema['properties'] as Map<String, Object?>;
      final recs = props['recommendations'] as Map<String, Object?>;
      final items = recs['items'] as Map<String, Object?>;
      return (items['anyOf'] as List).cast<Map<String, Object?>>();
    }

    Map<String, Object?> propsOf(Map<String, Object?> branch) =>
        branch['properties'] as Map<String, Object?>;

    /// The branch whose `kind` const matches [kind].
    Map<String, Object?> branchFor(
            Map<String, Object?> schema, String kind) =>
        branches(schema).firstWhere((b) =>
            (propsOf(b)['kind'] as Map<String, Object?>)['const'] == kind);

    test('artifact_id enum = real catalog ids; deleted ids excluded',
        () async {
      final db = await _seedDb(
        [
          (body: 'a', origin: 'default', name: null, targetSymbolName: null),
          (body: 'b', origin: 'default', name: null, targetSymbolName: null),
          (body: 'c', origin: 'default', name: null, targetSymbolName: null),
        ],
        deleteAfterInsert: [2], // leaves ids 1, 3
      );
      final svc = _makeService(db);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(decisions: [_decision('SystemInit', 1)]),
        currentState: _emptyState,
        callGraph: _callGraph(['SystemInit']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
      );
      final artifactId = propsOf(branchFor(schema, 'set_forced_override'))[
          'artifact_id'] as Map<String, Object?>;
      expect(artifactId['enum'], [1, 3]); // NOT 2 — deleted
      // And it is REQUIRED — an id-less override must be
      // unrepresentable (the false-llmEmpty bug).
      expect(
          (branchFor(schema, 'set_forced_override')['required'] as List)
              .cast<String>(),
          containsAll(['kind', 'rationale', 'symbol', 'artifact_id']));
      await db.close();
    });

    test('kind enum lists exactly the wired action kinds', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(),
        currentState: _emptyState,
        callGraph: _callGraph(const []),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
      );
      final kinds = [
        for (final b in branches(schema))
          (propsOf(b)['kind'] as Map<String, Object?>)['const'],
      ];
      expect(kinds, [
        'set_forced_override',
        'clear_forced_override',
        'set_preference',
        'generate_custom_hook',
        'adjust_iteration_cap',
      ]);
      await db.close();
    });

    test('group branches appear with a scope enum when a group is relevant',
        () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final groups = SymbolGroupClassifier(catalog: HookCatalog.system())
          .classify([
        'LL_RCC_LSI_Enable',
        'LL_RCC_LSI_Disable',
        'LL_RCC_LSI_IsReady',
      ]);
      final schema = await svc.buildRecommendationSchema(
        currentManifest:
            _manifest(decisions: [_decision('LL_RCC_LSI_IsReady', 0)]),
        currentState: _emptyState,
        callGraph: _callGraph(['LL_RCC_LSI_IsReady']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
        symbolGroups: groups,
      );
      final kinds = [
        for (final b in branches(schema))
          (propsOf(b)['kind'] as Map<String, Object?>)['const'],
      ];
      expect(kinds, containsAll(['set_group_override', 'clear_group_override']));
      final scope = propsOf(branchFor(schema, 'set_group_override'))['scope']
          as Map<String, Object?>;
      expect((scope['enum'] as List).cast<String>(), ['LL_RCC_LSI']);
      await db.close();
    });

    test('no group branches when no group is relevant this round', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final groups = SymbolGroupClassifier(catalog: HookCatalog.system())
          .classify([
        'LL_RCC_LSI_Enable',
        'LL_RCC_LSI_Disable',
        'LL_RCC_LSI_IsReady',
      ]);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(decisions: [_decision('SystemInit', 0)]),
        currentState: _emptyState,
        callGraph: _callGraph(['SystemInit']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
        symbolGroups: groups, // present, but no member is a candidate
      );
      final kinds = [
        for (final b in branches(schema))
          (propsOf(b)['kind'] as Map<String, Object?>)['const'],
      ];
      expect(kinds, isNot(contains('set_group_override')));
      await db.close();
    });

    test('symbol enum includes the frontier + its unexecuted callees',
        () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(decisions: [_decision('main', 0)]),
        currentState: _emptyState,
        callGraph: _callGraph(['main', 'blocker', 'unreached']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [
          FrontierEntry(
              symbol: 'blocker', unexecutedCallees: <String>['unreached']),
        ],
      );
      final symbol = propsOf(branchFor(schema, 'set_forced_override'))[
          'symbol'] as Map<String, Object?>;
      final symEnum = (symbol['enum'] as List).cast<String>();
      expect(symEnum, containsAll(['blocker', 'unreached']));
      await db.close();
    });

    test('symbol falls back to plain string when no candidates exist',
        () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final schema = await svc.buildRecommendationSchema(
        // No decisions, no failedSymbol/lastPauseSymbol → no halt
        // symbol; empty frontier → no candidate set.
        currentManifest: _manifest(),
        currentState: _emptyState,
        callGraph: _callGraph(const []),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
      );
      final symbol = propsOf(branchFor(schema, 'set_forced_override'))[
          'symbol'] as Map<String, Object?>;
      expect(symbol.containsKey('enum'), isFalse);
      expect(symbol['type'], 'string');
      await db.close();
    });

    Map<String, Object?> recsSchema(Map<String, Object?> schema) {
      final props = schema['properties'] as Map<String, Object?>;
      return props['recommendations'] as Map<String, Object?>;
    }

    test('maxItems defaults to 10 and honors the parameter', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final def = await svc.buildRecommendationSchema(
        currentManifest: _manifest(),
        currentState: _emptyState,
        callGraph: _callGraph(const []),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
      );
      expect(recsSchema(def)['maxItems'],
          RecommendationService.defaultMaxRecommendations);
      expect(recsSchema(def)['maxItems'], 10);
      final custom = await svc.buildRecommendationSchema(
        currentManifest: _manifest(),
        currentState: _emptyState,
        callGraph: _callGraph(const []),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
        maxRecommendations: 4,
      );
      expect(recsSchema(custom)['maxItems'], 4);
      await db.close();
    });

    test('comms-virtualized symbols are excluded from the symbol enum',
        () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      const state = HookDecisionState(elfHash: 'aaaaaaaa', decisions: [
        HookDecision(
          symbol: 'HAL_I2C_Mem_Read',
          kind: HookDecisionKind.comms,
          protocol: 'i2c',
          role: 'read',
          port: 1234,
        ),
      ]);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(decisions: [_decision('main', 0)]),
        currentState: state,
        callGraph: _callGraph(['main', 'blocker', 'HAL_I2C_Mem_Read']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [
          FrontierEntry(
              symbol: 'blocker',
              unexecutedCallees: <String>['HAL_I2C_Mem_Read']),
        ],
      );
      final symbol = propsOf(branchFor(schema, 'set_forced_override'))[
          'symbol'] as Map<String, Object?>;
      final symEnum = (symbol['enum'] as List).cast<String>();
      expect(symEnum, isNot(contains('HAL_I2C_Mem_Read')),
          reason: 'an individual force on a virtualized bus symbol '
              'produces incoherent protocol state — unrepresentable');
      expect(symEnum, contains('blocker'));
      await db.close();
    });

    test('halt symbol is retained even when comms-classified', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      const state = HookDecisionState(elfHash: 'aaaaaaaa', decisions: [
        HookDecision(
          symbol: 'HAL_I2C_Mem_Read',
          kind: HookDecisionKind.comms,
          protocol: 'i2c',
          role: 'read',
          port: 1234,
        ),
      ]);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(
          decisions: [_decision('HAL_I2C_Mem_Read', 1)],
          failedSymbol: 'HAL_I2C_Mem_Read',
        ),
        currentState: state,
        callGraph: _callGraph(['HAL_I2C_Mem_Read']),
        mode: RecommendationMode.job1Authorship,
        frontier: const [],
      );
      final symbol = propsOf(branchFor(schema, 'set_forced_override'))[
          'symbol'] as Map<String, Object?>;
      final symEnum = (symbol['enum'] as List).cast<String>();
      expect(symEnum, contains('HAL_I2C_Mem_Read'),
          reason: 'job 1 must be able to target the error site');
      await db.close();
    });

    test(
        'exclusion never degrades a non-empty candidate set to the '
        'unconstrained free-string fallback', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      // Every candidate is comms-classified and there is no halt
      // symbol — naive exclusion would empty the set and drop the
      // enum entirely (strictly worse). The guard keeps the
      // pre-exclusion set.
      const state = HookDecisionState(elfHash: 'aaaaaaaa', decisions: [
        HookDecision(
          symbol: 'uart_tx',
          kind: HookDecisionKind.comms,
          protocol: 'uart',
          role: 'write',
          port: 1236,
        ),
      ]);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(),
        currentState: state,
        callGraph: _callGraph(['uart_tx']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [],
      );
      final symbol = propsOf(branchFor(schema, 'set_forced_override'))[
          'symbol'] as Map<String, Object?>;
      expect(symbol.containsKey('enum'), isTrue,
          reason: 'must not fall back to unconstrained string');
      expect((symbol['enum'] as List).cast<String>(), ['uart_tx']);
      await db.close();
    });
  });

  group('composePrompt — playbook + feedback', () {
    SynthesisManifest lowCoverage() => SynthesisManifest(
          manifestVersion: 2,
          elfHash: 'a' * 64,
          elfFileName: 'test.elf',
          synthesizerRunId: 'run1',
          result: const ManifestRunResult(
              success: true, totalIterations: 1, durationSeconds: 1.0),
          decisions: [_decision('main', 1)],
          lastPauseSymbol: 'main',
        );

    test('job2 task teaches the playbook and drops the old throttle',
        () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: lowCoverage(),
        currentState: _emptyState,
        callGraph: _callGraph(['main', 'blocker']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [
          FrontierEntry(
              symbol: 'main', unexecutedCallees: <String>['blocker']),
        ],
      );
      // The four playbook moves.
      expect(prompt, contains('LEAF POLLS'));
      expect(prompt, contains('WRAPPER-SKIP'));
      expect(prompt, contains('HANDS OFF'));
      expect(prompt, contains('BOUNDARY ONLY'));
      // Batch allowance replaces the throttle phrasing.
      expect(prompt, contains('up to 10 recommendations'));
      expect(prompt, isNot(contains('one or a small number')));
      await db.close();
    });

    test('feedback section renders coverage freeze, skipped no-ops, '
        'and the wrapper-skip escalation', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: lowCoverage(),
        currentState: _emptyState,
        callGraph: _callGraph(['main', 'HAL_RCC_OscConfig']),
        mode: RecommendationMode.job2Coverage,
        feedback: const RoundFeedback(
          coveragePrev: 25,
          coverageNow: 25,
          stalledCallers: ['HAL_RCC_OscConfig'],
          noOpSkipped: [
            SetForcedOverride(
                rationale: 'r', symbol: 'LL_RCC_LSI_IsReady', artifactId: 4),
          ],
        ),
      );
      expect(prompt, contains('## Feedback from last round'));
      expect(prompt, contains('Coverage did NOT move: 25 → 25'));
      expect(prompt,
          contains('set_forced_override LL_RCC_LSI_IsReady ← #4'));
      expect(prompt, contains('do not repeat them'));
      expect(prompt, contains('`HAL_RCC_OscConfig`'));
      expect(prompt, contains('ESCALATE'));
      await db.close();
    });

    test(
        'escalation (feedback with stalled callers) restricts the '
        'symbol enum to the stalled callers', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final schema = await svc.buildRecommendationSchema(
        currentManifest: _manifest(decisions: [_decision('main', 0)]),
        currentState: _emptyState,
        callGraph: _callGraph(
            ['main', 'HAL_RCC_OscConfig', 'LL_RCC_LSI_IsReady']),
        mode: RecommendationMode.job2Coverage,
        frontier: const [
          FrontierEntry(
              symbol: 'HAL_RCC_OscConfig',
              unexecutedCallees: <String>['LL_RCC_LSI_IsReady']),
        ],
        feedback: const RoundFeedback(
          coveragePrev: 25,
          coverageNow: 25,
          stalledCallers: ['HAL_RCC_OscConfig', 'SystemClock_Config'],
        ),
      );
      // Inline branch extraction (helpers are local to the schema
      // group): find the set_forced_override anyOf branch.
      final props = schema['properties'] as Map<String, Object?>;
      final recs = props['recommendations'] as Map<String, Object?>;
      final items = recs['items'] as Map<String, Object?>;
      final branch = (items['anyOf'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((b) =>
              ((b['properties'] as Map<String, Object?>)['kind']
                  as Map<String, Object?>)['const'] ==
              'set_forced_override');
      final symbol = (branch['properties']
          as Map<String, Object?>)['symbol'] as Map<String, Object?>;
      expect((symbol['enum'] as List).cast<String>(),
          ['HAL_RCC_OscConfig', 'SystemClock_Config'],
          reason: 'repeating leaf-poll recommendations must be '
              'unrepresentable during escalation');
      await db.close();
    });

    test('escalation task framing replaces the playbook', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: lowCoverage(),
        currentState: _emptyState,
        callGraph: _callGraph(['main', 'HAL_RCC_OscConfig']),
        mode: RecommendationMode.job2Coverage,
        feedback: const RoundFeedback(
          coveragePrev: 25,
          coverageNow: 25,
          stalledCallers: ['HAL_RCC_OscConfig'],
        ),
      );
      expect(prompt, contains('ESCALATION ROUND'));
      expect(prompt, isNot(contains('LEAF POLLS')),
          reason: 'the playbook is replaced, not appended — leaf-poll '
              'guidance is what the model kept repeating');
      await db.close();
    });

    test('no feedback section when feedback is null', () async {
      final db = await _seedDb(const []);
      final svc = _makeService(db);
      final prompt = await svc.composePrompt(
        currentManifest: lowCoverage(),
        currentState: _emptyState,
        callGraph: _callGraph(['main']),
        mode: RecommendationMode.job2Coverage,
      );
      expect(prompt, isNot(contains('## Feedback from last round')));
      await db.close();
    });
  });
}
