import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/services/analysis/coverage_frontier.dart';
import 'package:emulator_orchestrator/services/llm/last_run_insight_service.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:test/test.dart';

ManifestRunResult _result(bool success) => ManifestRunResult(
      success: success,
      totalIterations: 9,
      durationSeconds: 42.5,
    );

ManifestDecision _decision({
  required String symbol,
  required int iteration,
  ManifestDecisionKind kind = ManifestDecisionKind.iterationFallback,
  String source = 'iteration_fallback',
}) =>
    ManifestDecision(
      symbol: symbol,
      appliedHook: const AppliedHook(bodyHash: 'h'),
      decisionKind: kind,
      decisionSource: source,
      iterationIndex: iteration,
    );

CallGraph _callGraph(int totalFunctions) {
  final symbols = <String, Symbol>{};
  for (var i = 0; i < totalFunctions; i++) {
    symbols['fn_$i'] = Symbol(
      name: 'fn_$i',
      numInstructions: 10,
      calledSymbols: const {},
    );
  }
  return CallGraph(elfPath: '/dev/null', symbols: symbols);
}

const _emptyDecisionState =
    HookDecisionState(elfHash: 'abc123', decisions: []);

void main() {
  late LastRunInsightService service;

  setUp(() {
    // The composePrompt code path is pure — the LlmClient never gets
    // called. Construct one anyway because the service requires it.
    service = LastRunInsightService(
      llmClient: LlmClient(host: 'localhost:11434', model: 'gemma4:e4b'),
    );
  });

  group('composePrompt — Run outcome block', () {
    test('relabels Success to "Synthesizer completed without throwing"',
        () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(10),
      );
      // The bare "Success: true" wording is gone — that's the
      // exact phrase the user's screenshot showed Gemma latching
      // onto.
      expect(
        prompt,
        isNot(contains('- Success: true')),
        reason: 'legacy Success: line must not appear verbatim',
      );
      expect(
        prompt,
        contains('Synthesizer completed without throwing: true'),
      );
    });
  });

  group('composePrompt — Halt point', () {
    test('emitted when failedSymbol is set (run-failed branch)', () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(false),
        decisions: const [],
        failedSymbol: 'LL_RCC_LSI_IsReady',
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      expect(
        prompt,
        contains(
            'Halt point: `LL_RCC_LSI_IsReady` (unhandled-access pause (run failed))'),
      );
    });

    test(
        'uses lastPauseSymbol on success=true runs (the new "firmware was '
        'still spinning on a busy-ready flag at the end" branch)',
        () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: [
          _decision(symbol: 'SystemInit', iteration: 1),
        ],
        // success=true but the firmware kept pausing at LSI_IsReady
        // each time the synthesizer's hook returned 0. This is the
        // exact case the user complained about with "Halt point:
        // SystemInit" being wrong.
        lastPauseSymbol: 'LL_RCC_LSI_IsReady',
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      expect(
        prompt,
        contains(
            'Halt point: `LL_RCC_LSI_IsReady` (last unhandled-access pause (run completed))'),
      );
      // And critically, the wrong fallback symbol must NOT win.
      expect(
        prompt,
        isNot(contains('Halt point: `SystemInit`')),
      );
    });

    test(
        'falls back to the CHRONOLOGICALLY-last decision when neither '
        'failedSymbol nor lastPauseSymbol is set (legacy manifests). '
        'Critically: NOT the alphabetically-last symbol from the '
        'manifest storage order.',
        () {
      // Pass the decisions in alphabetical order — exactly what
      // `buildManifest` produces. The legacy fallback must still
      // pick LL_RCC_LSI_IsReady (highest iterationIndex), not
      // SystemInit (alphabetically last). This is the regression
      // guard for the bug the user kept hitting.
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: [
          _decision(symbol: 'LL_RCC_LSI_IsReady', iteration: 9),
          _decision(symbol: 'SystemInit', iteration: 1),
        ],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      expect(
        prompt,
        contains(
            'Halt point: `LL_RCC_LSI_IsReady` (last decision (no pause recorded))'),
      );
      expect(
        prompt,
        isNot(contains('Halt point: `SystemInit`')),
        reason: 'SystemInit at iter 1 must NOT be the fallback',
      );
    });

    test('omitted when there is no failedSymbol, no lastPauseSymbol, and no decisions',
        () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      expect(prompt, isNot(contains('Halt point')));
    });
  });

  group('composePrompt — Current run metrics block', () {
    test(
        'renders overall + coverage fidelity, executed symbols with %, '
        'and hooked / intact / degraded counts',
        () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [],
        metrics: const ManifestMetrics(
          overallFidelity: 0.988,
          coverageFidelity: 0.123,
          subgraphFidelity: null,
          intactCount: 985,
          degradedCount: 7,
          hookedCount: 8,
        ),
        executedSymbols: List<String>.generate(20, (i) => 'fn_$i'),
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(1000),
      );
      expect(prompt, contains('## Current run metrics'));
      expect(prompt, contains('Overall fidelity: 0.988'));
      expect(prompt, contains('Coverage fidelity: 0.123'));
      // The coverage percent is the heavy-lifting signal — assert
      // it's present in both denominator and percentage form.
      expect(prompt, contains('Symbols executed: 20 of 1000 (2.0%)'));
      expect(
        prompt,
        contains('Symbols hooked: 8 (intact 985, degraded 7)'),
      );
    });

    test('omits Coverage fidelity row when null on the manifest', () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [],
        metrics: const ManifestMetrics(
          overallFidelity: 0.500,
          coverageFidelity: null,
          subgraphFidelity: null,
          intactCount: 1,
          degradedCount: 1,
          hookedCount: 1,
        ),
        executedSymbols: const ['fn_0'],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(10),
      );
      expect(prompt, contains('Overall fidelity: 0.500'));
      expect(prompt, isNot(contains('Coverage fidelity')));
    });

    test('block is omitted entirely when manifest is v1 (no metrics)', () {
      final manifest = SynthesisManifest(
        manifestVersion: 1,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(10),
      );
      expect(prompt, isNot(contains('## Current run metrics')));
    });
  });

  group('composePrompt — Decisions list order', () {
    test('latest decision (highest iteration) is listed FIRST', () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: [
          _decision(symbol: 'SystemInit', iteration: 1),
          _decision(symbol: 'LL_APB0_EnableClock', iteration: 2),
          _decision(symbol: 'LL_RCC_LSI_IsReady', iteration: 9),
        ],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      // Scope to the Decisions block so the Halt point line above
      // doesn't mask the order check via `indexOf`.
      final decisionsStart =
          prompt.indexOf('## Decisions applied during this run');
      final decisionsEnd = prompt.indexOf('\n##', decisionsStart + 1);
      final block = decisionsEnd == -1
          ? prompt.substring(decisionsStart)
          : prompt.substring(decisionsStart, decisionsEnd);
      final lsi = block.indexOf('LL_RCC_LSI_IsReady');
      final sysInit = block.indexOf('SystemInit');
      expect(lsi >= 0 && sysInit >= 0, isTrue);
      expect(
        lsi < sysInit,
        isTrue,
        reason:
            'LL_RCC_LSI_IsReady (latest) must appear before SystemInit '
            '(first iteration) in the rendered decisions list',
      );
      // No (most recent) / (first) markers — those were
      // editorializations the LLM treated as authoritative focus
      // signals. The Halt point line + the task framing now own
      // focus communication; the decisions block is pure context.
      expect(block, isNot(contains('(most recent)')));
      expect(block, isNot(contains('(first)')));
    });

    test(
        'chronological sort wins over storage order — decisions passed in '
        'alphabetical order (as buildManifest emits) are still rendered '
        'with iteration-last on top, NOT alphabetical-last',
        () {
      // Reproduces the production failure mode: `buildManifest`
      // sorts by symbol name, so on the user's aya_ppg manifest
      // `SystemInit` is the alphabetically-last decision but only
      // iteration-1. The previous prompt-composer code did
      // `decisions.reversed.toList()`, which on alphabetical input
      // tagged `SystemInit` as `(most recent)` — sending the LLM
      // chasing the wrong symbol.
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        // Alphabetical order — exactly what buildManifest produces.
        decisions: [
          _decision(symbol: 'LL_APB0_EnableClock', iteration: 2),
          _decision(symbol: 'LL_RCC_LSI_IsReady', iteration: 9),
          _decision(symbol: 'SystemInit', iteration: 1),
        ],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      // Scope to the Decisions block — symbols also appear in the
      // Halt point line which sits above and would otherwise win
      // `indexOf` and mask the actual order in the list.
      final decisionsStart =
          prompt.indexOf('## Decisions applied during this run');
      expect(decisionsStart, greaterThanOrEqualTo(0));
      final decisionsEnd = prompt.indexOf('\n##', decisionsStart + 1);
      final block = decisionsEnd == -1
          ? prompt.substring(decisionsStart)
          : prompt.substring(decisionsStart, decisionsEnd);
      final lsi = block.indexOf('LL_RCC_LSI_IsReady');
      final sysInit = block.indexOf('SystemInit');
      expect(lsi >= 0 && sysInit >= 0, isTrue);
      // Iteration 9 (LSI) must come before iteration 1 (SystemInit)
      // in the rendered Decisions block, regardless of alphabetical
      // storage order.
      expect(lsi < sysInit, isTrue,
          reason:
              'LSI (iter 9) must precede SystemInit (iter 1) '
              'after chronological sort');
      // No editorialization markers — the chronological order
      // alone conveys recency. The LLM was treating "(most recent)"
      // as an authoritative focus signal even on the alphabetical
      // mislabel; removing the markers entirely cuts the trap.
      expect(block, isNot(contains('(most recent)')));
      expect(block, isNot(contains('(first)')));
    });

    test(
        'every decision row carries `applied=#N` so the LLM can '
        'cross-reference the artifact catalog',
        () {
      // The LLM previously had no way to tell whether a
      // forced_override was Return 0 or Return 1 — only that one
      // existed. `applied=#N` is the cross-reference handle that
      // ties each decision back to a catalog row.
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [
          ManifestDecision(
            symbol: 'LL_RCC_HSE_IsReady',
            appliedHook: AppliedHook(bodyHash: 'h1', artifactId: 4),
            decisionKind: ManifestDecisionKind.forcedOverride,
            decisionSource: 'user.hookOverrides',
            iterationIndex: 0,
          ),
          ManifestDecision(
            symbol: 'SystemInit',
            appliedHook: AppliedHook(bodyHash: 'h2', artifactId: 13),
            decisionKind: ManifestDecisionKind.iterationFallback,
            decisionSource: 'user_artifact:#13',
            iterationIndex: 1,
          ),
        ],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      expect(prompt, contains('applied=#4'),
          reason: 'HSE_IsReady is bound to artifact 4 in the fixture');
      expect(prompt, contains('applied=#13'),
          reason: 'SystemInit fallback is artifact 13 in the fixture');
    });

    test('single-decision lists render the row without any markers',
        () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: [
          _decision(symbol: 'OnlyOne', iteration: 0),
        ],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(10),
      );
      expect(prompt, contains('OnlyOne` ←'));
      expect(prompt, isNot(contains('(most recent)')));
      expect(prompt, isNot(contains('(first)')));
    });
  });

  group('composePrompt — "## Your task" framing', () {
    test('names the halt symbol from lastPauseSymbol in the task line',
        () {
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: [_decision(symbol: 'SystemInit', iteration: 1)],
        lastPauseSymbol: 'LL_RCC_LSI_IsReady',
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(50),
      );
      // Scope to the task block to verify the halt symbol is in
      // the framing — not just up in the Halt point header.
      final taskStart = prompt.indexOf('## Your task');
      expect(taskStart, greaterThan(0));
      final taskBlock = prompt.substring(taskStart);
      expect(taskBlock, contains('`LL_RCC_LSI_IsReady`'),
          reason:
              'task framing must literally name the halt symbol; '
              'this is what redirects the model away from SystemInit');
      expect(taskBlock, contains('coverage and fidelity'),
          reason: 'task framing must state the metric-improvement goal');
      // SystemInit is in the decisions block as context — but it
      // must NOT appear in the task framing (which would confuse
      // the model about what the question is).
      expect(taskBlock, isNot(contains('SystemInit')));
    });

    test('falls back to the open-ended wording when no halt symbol exists',
        () {
      // Empty decisions, no pause — a fully clean baseline. The
      // task framing has nothing to anchor on, so it stays
      // open-ended.
      final manifest = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [],
      );
      final prompt = service.composePrompt(
        manifest: manifest,
        currentState: _emptyDecisionState,
        callGraph: _callGraph(10),
      );
      final taskStart = prompt.indexOf('## Your task');
      final taskBlock = prompt.substring(taskStart);
      expect(taskBlock,
          contains('suggest ONE concrete action the user could take'));
    });
  });

  group('composeContext — per-symbol overlay region + frontier annotations',
      () {
    // Halt symbol `HAL_RCC_OscConfig` calls the pollers; frontier
    // mirrors the aya_ppg shape: executed caller with unexecuted
    // callees of each classifier class.
    CallGraph graph() => CallGraph(elfPath: '/dev/null', symbols: {
          'HAL_RCC_OscConfig': Symbol(
            name: 'HAL_RCC_OscConfig',
            numInstructions: 100,
            calledSymbols: {
              'LL_RCC_LSI_IsReady': 1,
              'LL_RCC_LSCO_SetSource': 1,
              'HAL_I2C_Mem_Read': 1,
              'LL_RCC_HSE_IsReady': 1,
              'Mystery_Fn': 1,
            },
          ),
          'LL_RCC_LSI_IsReady': Symbol(
              name: 'LL_RCC_LSI_IsReady',
              numInstructions: 5,
              calledSymbols: {}),
          'LL_RCC_LSCO_SetSource': Symbol(
              name: 'LL_RCC_LSCO_SetSource',
              numInstructions: 5,
              calledSymbols: {}),
          'HAL_I2C_Mem_Read': Symbol(
              name: 'HAL_I2C_Mem_Read',
              numInstructions: 5,
              calledSymbols: {}),
          'LL_RCC_HSE_IsReady': Symbol(
              name: 'LL_RCC_HSE_IsReady',
              numInstructions: 5,
              calledSymbols: {}),
          'Mystery_Fn': Symbol(
              name: 'Mystery_Fn', numInstructions: 5, calledSymbols: {}),
          'FarAway_Fn': Symbol(
              name: 'FarAway_Fn', numInstructions: 5, calledSymbols: {}),
        });

    SynthesisManifest manifest() => SynthesisManifest(
          manifestVersion: 2,
          elfHash: 'abc',
          elfFileName: 'test.elf',
          synthesizerRunId: 'run1',
          result: _result(true),
          decisions: const [],
          lastPauseSymbol: 'HAL_RCC_OscConfig',
        );

    const state = HookDecisionState(elfHash: 'abc123', decisions: [
      HookDecision(
        symbol: 'LL_RCC_LSI_IsReady',
        kind: HookDecisionKind.binding,
        artifactId: 4,
        fidelity: 0.5,
        provenance: 'classifier:rule-5-busy-ready-flag',
      ),
      HookDecision(
        symbol: 'LL_RCC_LSCO_SetSource',
        kind: HookDecisionKind.binding,
        artifactId: 3,
        fidelity: 0.5,
        provenance: 'classifier:rule-6-pure-peripheral-writes',
      ),
      HookDecision(
        symbol: 'HAL_I2C_Mem_Read',
        kind: HookDecisionKind.comms,
        protocol: 'i2c',
        role: 'read',
        port: 1234,
        scope: 'i2c',
      ),
      HookDecision(
        symbol: 'LL_RCC_HSE_IsReady',
        kind: HookDecisionKind.override,
        artifactId: 4,
      ),
      // Overlay on a symbol far outside the halt/frontier region —
      // must NOT be rendered per-symbol (region scoping).
      HookDecision(
        symbol: 'FarAway_Fn',
        kind: HookDecisionKind.binding,
        artifactId: 7,
        fidelity: 0.5,
        provenance: 'classifier:rule-2-return-literal',
      ),
    ]);

    final frontier = [
      const FrontierEntry(
        symbol: 'HAL_RCC_OscConfig',
        unexecutedCallees: [
          'LL_RCC_LSI_IsReady',
          'LL_RCC_LSCO_SetSource',
          'HAL_I2C_Mem_Read',
          'Mystery_Fn',
        ],
      ),
    ];

    test('renders per-symbol lines for the region, with the binding caveat',
        () {
      final ctx = service.composeContext(
        manifest: manifest(),
        currentState: state,
        callGraph: graph(),
        frontier: frontier,
      );
      expect(
          ctx,
          contains('- `LL_RCC_HSE_IsReady` ← #4 (forced override)'));
      expect(
          ctx,
          contains('- `LL_RCC_LSI_IsReady` ← #4 (binding, '
              'classifier:rule-5-busy-ready-flag — NOT applied this '
              'run — takes effect only on fault or if promoted to a '
              'forced override)'));
      expect(
          ctx,
          contains('- `HAL_I2C_Mem_Read` (comms:i2c read — virtualized '
              'as a bus)'));
      // The caveat the model needs to reason about silent spins.
      expect(ctx, contains('a silent busy-wait never does'));
      // Totals stay for orientation.
      expect(
          ctx,
          contains('- Totals: 1 forced overrides, 3 fidelity-scored '
              'bindings, 0 carryover hooks, 1 comms-virtualized '
              'symbols'));
    });

    test('region scoping: overlays outside halt/frontier are not listed',
        () {
      final ctx = service.composeContext(
        manifest: manifest(),
        currentState: state,
        callGraph: graph(),
        frontier: frontier,
      );
      expect(ctx, isNot(contains('`FarAway_Fn` ← #7')));
    });

    test('frontier callees carry classifier annotations by rule class',
        () {
      final ctx = service.composeContext(
        manifest: manifest(),
        currentState: state,
        callGraph: graph(),
        frontier: frontier,
      );
      expect(
          ctx,
          contains('- LL_RCC_LSI_IsReady — ready/busy flag → #4; bound '
              'but NOT applied this run — promote to a forced override '
              'to take effect'));
      expect(
          ctx,
          contains('- LL_RCC_LSCO_SetSource — void register writes — '
              "forcing a return value won't help"));
      expect(
          ctx,
          contains('- HAL_I2C_Mem_Read — comms:i2c — virtualized, do '
              'not force individually'));
      // Unclassified callee renders bare — no dangling separator.
      expect(ctx, contains('  - Mystery_Fn\n'));
    });

    test(
        'a binding the manifest shows applied this run is flagged '
        'ALREADY IN EFFECT (re-forcing it is a no-op)', () {
      // The exact production trap: LSI_IsReady's binding #4 WAS
      // applied reactively during the run, but the annotation said
      // only "applies on fault" — so the model kept recommending the
      // promotion. The manifest decision is the ground truth.
      final m = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [
          ManifestDecision(
            symbol: 'LL_RCC_LSI_IsReady',
            appliedHook: AppliedHook(bodyHash: 'h', artifactId: 4),
            decisionKind: ManifestDecisionKind.binding,
            decisionSource: 'classifier:rule-5-busy-ready-flag',
            iterationIndex: 1,
          ),
        ],
        lastPauseSymbol: 'HAL_RCC_OscConfig',
      );
      final ctx = service.composeContext(
        manifest: m,
        currentState: state,
        callGraph: graph(),
        frontier: frontier,
      );
      expect(
          ctx,
          contains('- LL_RCC_LSI_IsReady — ready/busy flag → #4; '
              'ALREADY IN EFFECT this run — re-forcing #4 changes '
              'nothing'));
      expect(
          ctx,
          contains('- `LL_RCC_LSI_IsReady` ← #4 (binding, '
              'classifier:rule-5-busy-ready-flag — ALREADY IN EFFECT '
              'this run)'));
    });

    test('caps region rendering at 30 lines with a remainder note', () {
      // 40 unexecuted callees, each with a binding → all in region.
      final callees = List.generate(40, (i) => 'poll_$i');
      final syms = <String, Symbol>{
        'caller': Symbol(
          name: 'caller',
          numInstructions: 10,
          calledSymbols: {for (final c in callees) c: 1},
        ),
        for (final c in callees)
          c: Symbol(name: c, numInstructions: 5, calledSymbols: const {}),
      };
      final bigState = HookDecisionState(elfHash: 'abc123', decisions: [
        for (final c in callees)
          HookDecision(
            symbol: c,
            kind: HookDecisionKind.binding,
            artifactId: 4,
            fidelity: 0.5,
            provenance: 'classifier:rule-5-busy-ready-flag',
          ),
      ]);
      final m = SynthesisManifest(
        manifestVersion: 2,
        elfHash: 'abc',
        elfFileName: 'test.elf',
        synthesizerRunId: 'run1',
        result: _result(true),
        decisions: const [],
        lastPauseSymbol: 'caller',
      );
      final ctx = service.composeContext(
        manifest: m,
        currentState: bigState,
        callGraph: CallGraph(elfPath: '/dev/null', symbols: syms),
        frontier: [
          FrontierEntry(symbol: 'caller', unexecutedCallees: callees),
        ],
      );
      expect(ctx, contains('(+10 more overlays in this region)'));
    });
  });
}
