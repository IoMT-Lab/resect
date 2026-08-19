import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/symbol.dart' as cg_sym;
import 'package:emulator_orchestrator/data/models/symbol_group.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:emulator_orchestrator/services/analysis/coverage_frontier.dart';
import 'package:emulator_orchestrator/services/llm/last_run_insight_service.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:test/test.dart';

/// Engine loop tests. They exercise the real [AutoTuneEngine] against a
/// scripted synthesis function + a scripted recommender + a recording
/// sink — no Renode, no Ollama. The point is to pin the loop's control
/// flow (round sequence, applied overlays, every termination reason)
/// so the CLI and UI adapters, which both drive this exact engine,
/// inherit verified behavior.
void main() {
  // Two in-memory DBs per test (engine's + the scripted service's
  // unused super dep); neither shares an executor, so drift's
  // multiple-database race warning is a false positive here.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const config2 = AutoTuneConfig(maxRounds: 2);

  test('baseline + rounds emit in order; overlays carry applied edits',
      () async {
    // Baseline fails at A. Round 1 forces an override for A + bumps the
    // iteration cap; round 1 synth succeeds. Round 2 recommend returns
    // empty → llmEmpty at round 1.
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 7),
      _result(runId: 'r1', success: true, executed: ['A', 'B']),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([
          const SetForcedOverride(
              rationale: 'force A', symbol: 'A', artifactId: 4, scope: 'HSE'),
          const AdjustIterationCap(rationale: 'more room', newValue: 20),
        ]),
        _recs(const []), // round 2 → empty → done
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B']),
      config: config2,
    );

    expect(reason, AutoTuneStopReason.llmEmpty);
    expect(sink.finishedReason, AutoTuneStopReason.llmEmpty);
    expect(sink.finishedRound, 1);
    // Baseline (0) + round 1 reports, in order.
    expect(sink.roundNumbers, [0, 1]);
    // Round 1 synth saw the applied overlays.
    final round1Overlays = synth.overlaysAt(1);
    expect(round1Overlays.hookOverrides['A'], 4);
    expect(round1Overlays.hookOverrideScopes['A'], 'HSE');
    expect(round1Overlays.iterationCap, 20);
    // And the round-1 snapshot recorded them.
    final round1 = sink.reports[1];
    expect(round1.snapshot.hookOverrides['A'], 4);
    expect(round1.snapshot.iterationCap, 20);
    expect(round1.appliedRecommendations, hasLength(2));
  });

  test('stops on maxRounds when the LLM keeps recommending', () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', failedSymbol: 'B', triedArtifactId: 2),
      _result(runId: 'r2', failedSymbol: 'C', triedArtifactId: 3),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4)]),
        _recs([_pref('B', 4)]),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B', 'C']),
      config: config2,
    );

    expect(reason, AutoTuneStopReason.maxRounds);
    expect(sink.finishedRound, 2);
    expect(sink.roundNumbers, [0, 1, 2]);
  });

  test('stops on a true repeat (same symbol, no new hook tried)',
      () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', failedSymbol: 'A', triedArtifactId: 1), // repeat
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4)]),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: config2,
    );

    expect(reason, AutoTuneStopReason.noProgressOnSymbol);
    expect(sink.finishedRound, 1);
    expect(sink.roundNumbers, [0, 1]);
  });

  test('a new hook at the same symbol is progress, not a repeat',
      () async {
    // Same failing symbol both rounds but the tried-set grows → the
    // loop keeps going and hits maxRounds instead of stopping early.
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', failedSymbol: 'A', triedArtifactId: 9), // new hook
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 9)]),
        _recs([_pref('A', 5)]),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: const AutoTuneConfig(maxRounds: 1),
    );

    expect(reason, AutoTuneStopReason.maxRounds);
  });

  test('baseline failure short-circuits before any round', () async {
    final sink = _RecordingSink();
    final engine = AutoTuneEngine(
      runSynthesis: (_, _) async => null, // no manifest
      recommendationService: _scripted(const []),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: config2,
    );

    expect(reason, AutoTuneStopReason.baselineFailed);
    expect(sink.roundNumbers, isEmpty);
  });

  test('rejecting every recommendation ends the session', () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4)]),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const _RejectAllPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: config2,
    );

    expect(reason, AutoTuneStopReason.userRejectedAll);
    // Only the baseline round was reported; nothing re-synthesized.
    expect(sink.roundNumbers, [0]);
  });

  test('parse failure with a non-retrying policy stops the round',
      () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        const RecommendationResult(
          prose: '',
          recommendations: [],
          parseFailure: true,
          parseFailureKind: RecommendationParseFailureKind.emptyResponse,
        ),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: config2,
    );

    expect(reason, AutoTuneStopReason.parseFailed);
    expect(sink.finishedRound, 1);
    // The LLM exchange was still emitted (trace files depend on it).
    expect(sink.exchanges, hasLength(1));
    expect(sink.exchanges.single.round, 1);
  });

  test('no-op recommendations are skipped and surfaced in the report',
      () async {
    // The overlay already forces A ← #4 (seeded from the project), so
    // re-recommending it is a no-op; the preference on B is new.
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', success: true, executed: ['A', 'B']),
    ]);
    const noOp =
        SetForcedOverride(rationale: 'r', symbol: 'A', artifactId: 4);
    final effective = _pref('B', 3);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([noOp, effective]),
        _recs(const []),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    await engine.run(
      project: _project().copyWith(hookOverrides: {'A': 4}),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B']),
      config: config2,
    );

    final round1 = sink.reports[1];
    expect(round1.skippedNoOps, [noOp]);
    expect(round1.appliedRecommendations, [effective]);
    // The no-op never reached the overlays (still the seeded value,
    // no scope side-effects), and the effective preference did.
    expect(synth.overlaysAt(1).hookPreferences['B'], 3);
  });

  test(
      'all-no-op round skips synthesis, escalates with feedback, and '
      'stops at the stagnant limit', () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', success: true, executed: ['A']),
    ]);
    const noOp =
        SetForcedOverride(rationale: 'r', symbol: 'A', artifactId: 4);
    final recommender = _scripted([
      _recs([noOp]), // round 1: all no-op → skip synthesis, escalate
      _recs([noOp]), // round 2: all no-op again → limit reached
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: recommender,
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project().copyWith(hookOverrides: {'A': 4}),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: const AutoTuneConfig(maxRounds: 5),
    );

    expect(reason, AutoTuneStopReason.noCoverageProgress);
    // Only the baseline ran — both LLM rounds were pure no-ops.
    expect(synth.callCount, 1);
    // Round 1 carried no feedback; round 2 got the escalation with
    // the skipped no-ops named.
    expect((recommender as _ScriptedRecommender).seenFeedback[0], isNull);
    final fb = recommender.seenFeedback[1];
    expect(fb, isNotNull);
    expect(fb!.coverageNow, 1);
    expect(fb.noOpSkipped, [noOp]);
    // No round reports beyond the baseline (no new manifest to report).
    expect(sink.roundNumbers, [0]);
  });

  test(
      'coverage stagnation across real runs escalates then stops with '
      'noCoverageProgress', () async {
    // Rounds apply real (non-no-op) changes but coverage never moves:
    // baseline {A}, round 1 {A}, round 2 {A} → stagnant, stagnant → stop.
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', success: true, executed: ['A']),
      _result(runId: 'r1', success: true, executed: ['A']),
      _result(runId: 'r2', success: true, executed: ['A']),
    ]);
    final recommender = _scripted([
      _recs([_pref('A', 3)]),
      _recs([_pref('A', 5)]),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: recommender,
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: const AutoTuneConfig(maxRounds: 5),
    );

    expect(reason, AutoTuneStopReason.noCoverageProgress);
    expect(sink.finishedRound, 2);
    // Round 2's recommend call carried the wrapper-skip escalation.
    expect((recommender as _ScriptedRecommender).seenFeedback[1],
        isNotNull);
    expect(recommender.seenFeedback[1]!.coveragePrev, 1);
    expect(recommender.seenFeedback[1]!.coverageNow, 1);
  });

  test('coverage growth resets the stagnation counter', () async {
    // Round 1 stagnant, round 2 grows, round 3 stagnant again — the
    // session must NOT stop (counter reset), ending at maxRounds.
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', success: true, executed: ['A']),
      _result(runId: 'r1', success: true, executed: ['A']),
      _result(runId: 'r2', success: true, executed: ['A', 'B']),
      _result(runId: 'r3', success: true, executed: ['A', 'B']),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 3)]),
        _recs([_pref('A', 5)]),
        _recs([_pref('B', 3)]),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B']),
      config: const AutoTuneConfig(maxRounds: 3),
    );

    expect(reason, AutoTuneStopReason.maxRounds,
        reason: 'growth at round 2 must reset the stagnant counter');
  });

  test('streams recommendation tokens through the sink', () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', success: true),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4)], prose: 'forcing A ready'),
        _recs(const []),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: config2,
    );

    expect(sink.tokens.join(), contains('forcing A ready'));
    expect(sink.phases, contains(AutoTunePhase.llmGenerating));
    expect(sink.phases, contains(AutoTunePhase.synthesizing));
  });

  test('prompt history window holds the MOST RECENT N rounds', () async {
    // 4 LLM rounds with window 2: by the round-4 call the history holds
    // rounds 0..3 and the window must be [2, 3], not the oldest [0, 1].
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', failedSymbol: 'B', triedArtifactId: 2),
      _result(runId: 'r2', failedSymbol: 'C', triedArtifactId: 3),
      _result(runId: 'r3', failedSymbol: 'D', triedArtifactId: 4),
      _result(runId: 'r4', failedSymbol: 'E', triedArtifactId: 5),
    ]);
    final client = LlmClient(host: 'localhost:11435', model: 'gemma4:e4b');
    final recommender = _ScriptedRecommender(
      [
        _recs([_pref('A', 6)]),
        _recs([_pref('B', 6)]),
        _recs([_pref('C', 6)]),
        _recs([_pref('D', 6)]),
      ],
      llmClient: client,
      insightService: LastRunInsightService(llmClient: client),
      artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
    );
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: recommender,
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B', 'C', 'D', 'E']),
      config: const AutoTuneConfig(maxRounds: 4, snapshotWindowSize: 2),
    );

    expect(reason, AutoTuneStopReason.maxRounds);
    expect(recommender.seenHistory, hasLength(4));
    expect(recommender.seenHistory[0], [0]);
    expect(recommender.seenHistory[1], [0, 1]);
    expect(recommender.seenHistory[2], [1, 2]);
    expect(recommender.seenHistory[3], [2, 3]);
  });

  test('a completer-backed review policy parks the loop until resolved',
      () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', success: true, executed: ['A', 'B']),
    ]);
    final policy = _CompleterPolicy();
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4)]),
      ]),
      artifactDb: await _db(),
      reviewPolicy: policy,
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final session = engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B']),
      config: const AutoTuneConfig(maxRounds: 1),
    );

    // Let the loop reach the review await, then verify it is parked:
    // the baseline synthesis ran, round 1's has not.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(policy.pending, isNotNull, reason: 'review must be pending');
    expect(synth.callCount, 1);
    expect(sink.phases, isNot(contains(AutoTunePhase.synthesizing)));

    // Resolve the review → the loop resumes and completes the round.
    policy.pending!.complete(AutoTuneReviewOutcome(decisions: [
      for (final rec in policy.lastResult!.recommendations)
        RecommendationDecision(original: rec, action: UserAction.accepted),
    ]));
    final reason = await session;

    expect(reason, AutoTuneStopReason.maxRounds);
    expect(synth.callCount, 2);
    expect(sink.roundNumbers, [0, 1]);
  });

  test('a Return-0 on a proven parent is WARNED and applied; a round '
      'that collapses coverage is REVERTED and remembered', () async {
    // Graph: P calls L; L carries a working override. Baseline executed
    // P and L plus more (10 symbols). The model wrapper-kills P; the
    // engine warns but applies (measure-don't-predict), the round's
    // coverage collapses, so the round is reverted: overlays restored,
    // feedback carries the poisoned move with the measured outcome.
    final db = await _db();
    final returnZeroId = await db.addArtifact(
      artifactType: 'renode_hook',
      artifactData: 'return Create(0, cpu.GetRegister(0).RawValue)',
      origin: 'default',
      name: 'return0',
      architecture: 'ARM',
    );
    final baselineExecuted = [
      'P', 'L', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h',
    ];
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', success: true, executed: baselineExecuted),
      _result(runId: 'r1', success: true, executed: ['P']), // collapse
    ]);
    final client = LlmClient(host: 'localhost:11435', model: 'gemma4:e4b');
    final recommender = _ScriptedRecommender(
      [
        _recs([
          SetForcedOverride(
              rationale: 'skip it', symbol: 'P', artifactId: returnZeroId),
        ]),
        _recs(const []), // after the revert: converge
      ],
      llmClient: client,
      insightService: LastRunInsightService(llmClient: client),
      artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
    );
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: recommender,
      artifactDb: db,
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final project = Emulator.create(name: 'test')
        .copyWith(hookOverrides: {'L': returnZeroId});
    final reason = await engine.run(
      project: project,
      elfHash: 'h',
      callGraph: _edgeGraph({
        'P': ['L'],
        'L': [],
      }),
      config: const AutoTuneConfig(maxRounds: 3),
    );

    expect(reason, AutoTuneStopReason.llmEmpty);
    expect(synth.callCount, 2, reason: 'warned move still runs — once');
    // The kill was APPLIED for round 1's synthesis — the snapshot copies
    // the overlay maps at emit time, before the rollback...
    final round1 = sink.reports[1];
    expect(round1.snapshot.hookOverrides['P'], returnZeroId);
    // ...the report is marked reverted and carries the warning...
    expect(round1.reverted, isTrue);
    expect(round1.warnings.join(' '), contains('working hooks beneath'));
    // ...and the LIVE overlays were rolled back in place (P's kill gone,
    // L's hook intact) — overlaysAt aliases the live instance.
    expect(synth.overlaysAt(1).hookOverrides.containsKey('P'), isFalse,
        reason: 'in-place restore removed the reverted override');
    expect(synth.overlaysAt(1).hookOverrides['L'], returnZeroId);
    // ...and the next round's feedback names the poisoned move + outcome.
    final fb = recommender.seenFeedback[1];
    expect(fb, isNotNull);
    expect(fb!.revertedMoves, hasLength(1));
    expect((fb.revertedMoves.single as SetForcedOverride).symbol, 'P');
    expect(fb.revertedOutcome, contains('10'));
    expect(fb.revertedOutcome, contains('1'));
  });

  test('backstop refuses overrides on entry points outright', () async {
    final db = await _db();
    final returnZeroId = await db.addArtifact(
      artifactType: 'renode_hook',
      artifactData: 'return Create(0, cpu.GetRegister(0).RawValue)',
      origin: 'default',
      name: 'return0',
      architecture: 'ARM',
    );
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', success: true, executed: ['main']),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([
          SetForcedOverride(
              rationale: 'skip main', symbol: 'main', artifactId: returnZeroId),
        ]),
        _recs(const []),
      ]),
      artifactDb: db,
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['main']),
      config: const AutoTuneConfig(maxRounds: 3),
    );

    expect(reason, AutoTuneStopReason.llmEmpty);
    expect(synth.callCount, 1, reason: 'main must never be overridden');
  });

  test('escalation batch skips are applied with a multi-skip warning; '
      'a winning batch is kept', () async {
    // Baseline + a stagnant round trigger escalation; the model answers
    // with a 3-caller batch kill. The engine warns (multi-skip) but
    // applies all three; the batch IMPROVES coverage, so it is kept.
    final db = await _db();
    final returnZeroId = await db.addArtifact(
      artifactType: 'renode_hook',
      artifactData: 'return Create(0, cpu.GetRegister(0).RawValue)',
      origin: 'default',
      name: 'return0',
      architecture: 'ARM',
    );
    final sink = _RecordingSink();
    final executed = ['P1', 'P2', 'P3'];
    final synth = _ScriptedSynth([
      _result(runId: 'r0', success: true, executed: executed),
      _result(runId: 'r1', success: true, executed: executed), // stagnant
      _result(
          runId: 'r2',
          success: true,
          executed: ['P1', 'P2', 'P3', 'x1', 'x2']), // batch wins
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('x1', 4)]),
        _recs([
          SetForcedOverride(
              rationale: 'k1', symbol: 'P1', artifactId: returnZeroId),
          SetForcedOverride(
              rationale: 'k2', symbol: 'P2', artifactId: returnZeroId),
          SetForcedOverride(
              rationale: 'k3', symbol: 'P3', artifactId: returnZeroId),
        ]),
      ]),
      artifactDb: db,
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final reason = await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _edgeGraph({
        'P1': ['x1'],
        'P2': ['x2'],
        'P3': ['x3'],
        'x1': [],
        'x2': [],
        'x3': [],
      }),
      config: const AutoTuneConfig(maxRounds: 2),
    );

    expect(reason, AutoTuneStopReason.maxRounds);
    final finalOverlays = synth.overlaysAt(synth.callCount - 1);
    expect(finalOverlays.hookOverrides['P1'], returnZeroId);
    expect(finalOverlays.hookOverrides['P2'], returnZeroId);
    expect(finalOverlays.hookOverrides['P3'], returnZeroId);
    final round2 = sink.reports.last;
    expect(round2.reverted, isFalse, reason: 'the batch improved coverage');
    expect(round2.refusedDestructive, isEmpty);
    expect(round2.warnings.join(' '), contains('3 wrapper-skips'));
  });

  test('a CONSTANT on a time reader is WARNED, not refused; both moves '
      'apply', () async {
    final db = await _db();
    final returnOneId = await db.addArtifact(
      artifactType: 'renode_hook',
      artifactData: 'return Create(1, cpu.GetRegister(0).RawValue)',
      origin: 'default',
      name: 'return1',
      architecture: 'ARM',
    );
    final incrementId = await db.addArtifact(
      artifactType: 'renode_hook',
      artifactData: "incrementVariable('value', 0)\nreturn value",
      origin: 'default',
      name: 'increment',
      architecture: 'ARM',
    );
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', success: true, executed: ['A']),
      _result(runId: 'r1', success: true, executed: ['A', 'B']),
    ]);
    final client = LlmClient(host: 'localhost:11435', model: 'gemma4:e4b');
    final recommender = _ScriptedRecommender(
      [
        _recs([
          SetForcedOverride(
              rationale: 'freeze it',
              symbol: 'LL_RADIO_TIMER_GetAbsoluteTime',
              artifactId: returnOneId),
          SetForcedOverride(
              rationale: 'advance it',
              symbol: 'HAL_GetTick',
              artifactId: incrementId),
        ]),
        _recs(const []),
      ],
      llmClient: client,
      insightService: LastRunInsightService(llmClient: client),
      artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
    );
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: recommender,
      artifactDb: db,
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(
          ['A', 'B', 'LL_RADIO_TIMER_GetAbsoluteTime', 'HAL_GetTick']),
      config: const AutoTuneConfig(maxRounds: 2),
    );

    // The constant on the time reader is WARNED but applied — the
    // measure-and-revert loop, not name patterns, is the enforcement.
    final round1 = sink.reports[1];
    expect(round1.refusedDestructive, isEmpty);
    expect(round1.warnings.join(' '), contains('frozen time/counter'));
    final applied = synth.overlaysAt(1).hookOverrides;
    expect(applied['HAL_GetTick'], incrementId);
    expect(applied['LL_RADIO_TIMER_GetAbsoluteTime'], returnOneId);
  });

  test('duplicate recommendations within one response are deduped',
      () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
      _result(runId: 'r1', success: true, executed: ['A', 'B']),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4), _pref('A', 4), _pref('A', 4)]),
        _recs(const []),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B']),
      config: config2,
    );

    expect(sink.reports[1].appliedRecommendations, hasLength(1),
        reason: 'three identical entries are one move');
  });

  test('cancel during a pending review ends the session as cancelled',
      () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 1),
    ]);
    final policy = _CompleterPolicy();
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4)]),
      ]),
      artifactDb: await _db(),
      reviewPolicy: policy,
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    final session = engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A']),
      config: const AutoTuneConfig(maxRounds: 2),
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(policy.pending, isNotNull);

    // The UI contract: engine.cancel() plus the policy unblocking its
    // pending review (the engine never unblocks it itself).
    engine.cancel();
    policy.pending!
        .complete(const AutoTuneReviewOutcome(decisions: [], cancelled: true));
    final reason = await session;

    expect(reason, AutoTuneStopReason.cancelled);
    expect(sink.finishedReason, AutoTuneStopReason.cancelled);
    expect(synth.callCount, 1, reason: 'no synthesis after cancel');
  });

  test('round reports carry advisor timing and an artifact census',
      () async {
    final sink = _RecordingSink();
    final synth = _ScriptedSynth([
      _result(runId: 'r0', failedSymbol: 'A', triedArtifactId: 7),
      _result(runId: 'r1', success: true, executed: ['A', 'B']),
    ]);
    final engine = AutoTuneEngine(
      runSynthesis: synth.call,
      recommendationService: _scripted([
        _recs([_pref('A', 4)]),
        _recs(const []),
      ]),
      artifactDb: await _db(),
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
      now: () => DateTime.utc(2026),
    );

    await engine.run(
      project: _project(),
      elfHash: 'h',
      callGraph: _callGraph(['A', 'B']),
      config: config2,
    );

    final baseline = sink.reports[0];
    final round1 = sink.reports[1];
    // The baseline runs before any advisor call — no advisor time.
    expect(baseline.advisorSeconds, isNull);
    expect(round1.advisorSeconds, isNotNull);
    expect(round1.advisorSeconds, greaterThanOrEqualTo(0));
    // Census is computed for every round from the artifact DB (an
    // in-memory DB here — the counts just have to exist, not be big).
    expect(baseline.census, isNotNull);
    expect(round1.census, isNotNull);
    // No RAG provider was wired → empty chunk counts, never a crash.
    expect(round1.census!.ragChunksByKind, isEmpty);
    // The advisor exchanges carry their wall time for the trace file.
    expect(sink.exchanges.first.durationSeconds, isNotNull);
    // The telemetry is FOLDED into the round manifest, so the written
    // round_NN_manifest.json (and any disk reader) carries it too.
    final foldedTimings = round1.result.manifest!.phaseTimings;
    expect(foldedTimings, isNotNull);
    expect(foldedTimings!.advisorSeconds, round1.advisorSeconds);
    expect(round1.result.manifest!.census, isNotNull);
    // The snapshot records the round's reverted/warnings flags (false /
    // empty on an ordinary round) so session views can read them after
    // a project reopen.
    expect(round1.snapshot.reverted, isFalse);
    expect(round1.snapshot.warnings, isEmpty);
  });

  test('enrichment records coverage numbers on the metrics', () {
    final enriched = enrichSynthesizerResult(
      result: _result(runId: 'r0', success: true),
      callGraph: _callGraph(['A', 'B', 'C', 'D']),
      executedSymbols: {'A', 'B', 'C'},
    );
    final metrics = enriched.manifest!.metrics!;
    expect(metrics.executedCount, 3);
    expect(metrics.totalSymbols, 4);
    expect(metrics.coverageRatio, closeTo(0.75, 1e-9));
  });
}

// -- Fakes -------------------------------------------------------------------

/// Scripted synthesis: returns the pre-built result for each call in
/// order, recording the overlays it was handed so tests can assert the
/// applier propagated the round's edits.
class _ScriptedSynth {
  _ScriptedSynth(this._results);
  final List<SynthesizerResult?> _results;
  final List<AutoTuneOverlays> _seenOverlays = [];
  var _i = 0;

  Future<SynthesizerResult?> call(AutoTuneOverlays overlays, int round) async {
    _seenOverlays.add(overlays);
    return _results[_i++];
  }

  /// Snapshot of the overlays as they were on the Nth synthesis call
  /// (0 = baseline). Overlays are mutated in place by the engine, so we
  /// read the map contents captured at call time — since the engine
  /// mutates then re-synthesizes, the live map already reflects the
  /// round's edits when the call is made.
  AutoTuneOverlays overlaysAt(int callIndex) => _seenOverlays[callIndex];

  /// Number of synthesis invocations — lets tests assert an all-no-op
  /// round skipped its re-synthesis.
  int get callCount => _seenOverlays.length;
}

/// Scripted recommender: subclasses the real service and overrides
/// [recommend] to pop pre-built results, driving [onToken]/[onThinking]
/// so streaming is exercised. Never touches an LLM.
class _ScriptedRecommender extends RecommendationService {
  _ScriptedRecommender(
    this._results, {
    required super.llmClient,
    required super.insightService,
    required super.artifactDb,
  });

  final List<RecommendationResult> _results;
  var _i = 0;

  /// Feedback objects the engine passed in, one entry per call
  /// (null when a round carried no feedback) — lets tests assert the
  /// stagnation escalation is threaded.
  final List<RoundFeedback?> seenFeedback = [];

  /// Round numbers of the history snapshots each call received — lets
  /// tests assert the prompt window holds the most recent N rounds.
  final List<List<int>> seenHistory = [];

  @override
  Future<RecommendationResult> recommend({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    List<RoundSnapshot> history = const [],
    OptimizationTarget? optimizationTarget,
    RecommendationMode mode = RecommendationMode.auto,
    List<FrontierEntry> frontier = const [],
    RoundFeedback? feedback,
    int maxRecommendations = RecommendationService.defaultMaxRecommendations,
    List<SymbolGroup> symbolGroups = const [],
    Map<String, GroupOverrideState> groupOverrides = const {},
    void Function(String token)? onToken,
    void Function(String chunk)? onThinking,
    void Function(String prompt)? onPromptComposed,
  }) async {
    seenFeedback.add(feedback);
    seenHistory.add([for (final s in history) s.round]);
    final r = _results[_i++];
    onPromptComposed?.call('scripted prompt for run ${currentManifest.synthesizerRunId}');
    if (r.prose.isNotEmpty) onToken?.call(r.prose);
    return r;
  }
}

RecommendationService _scripted(List<RecommendationResult> results) {
  final client = LlmClient(host: 'localhost:11435', model: 'gemma4:e4b');
  return _ScriptedRecommender(
    results,
    llmClient: client,
    insightService: LastRunInsightService(llmClient: client),
    artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
  );
}

/// Policy that parks each review on an externally-completed Completer —
/// the shape of the UI's interactive policy.
class _CompleterPolicy implements AutoTuneReviewPolicy {
  Completer<AutoTuneReviewOutcome>? pending;
  RecommendationResult? lastResult;

  @override
  Future<AutoTuneReviewOutcome> review(
      RecommendationResult result, int round) {
    lastResult = result;
    pending = Completer<AutoTuneReviewOutcome>();
    return pending!.future;
  }

  @override
  Future<bool> onParseFailure(RecommendationResult result, int round) async =>
      false;
}

/// Policy that rejects every recommendation.
class _RejectAllPolicy implements AutoTuneReviewPolicy {
  const _RejectAllPolicy();
  @override
  Future<AutoTuneReviewOutcome> review(
          RecommendationResult result, int round) async =>
      AutoTuneReviewOutcome(decisions: [
        for (final rec in result.recommendations)
          RecommendationDecision(original: rec, action: UserAction.rejected),
      ]);
  @override
  Future<bool> onParseFailure(RecommendationResult result, int round) async =>
      false;
}

/// Records everything the engine emits.
class _RecordingSink implements AutoTuneSink {
  final List<AutoTunePhase> phases = [];
  final List<String> tokens = [];
  final List<String> thinkingChunks = [];
  final List<AutoTuneLlmExchange> exchanges = [];
  final List<AutoTuneRoundReport> _reports = [];
  AutoTuneStopReason? finishedReason;
  int? finishedRound;

  List<AutoTuneRoundReport> get reports => _reports;
  List<int> get roundNumbers => [for (final r in _reports) r.round];

  @override
  void phase(AutoTunePhase phase, {int round = 0, String? symbol}) =>
      phases.add(phase);
  @override
  void token(String token) => tokens.add(token);
  @override
  void thinking(String chunk) => thinkingChunks.add(chunk);
  @override
  void llmExchange(AutoTuneLlmExchange exchange) => exchanges.add(exchange);
  @override
  void round(AutoTuneRoundReport report) => _reports.add(report);
  @override
  void finished(AutoTuneStopReason reason,
      {required int finalRound, String? errorMessage}) {
    finishedReason = reason;
    finishedRound = finalRound;
  }
}

// -- Builders ----------------------------------------------------------------

Future<ArtifactDatabase> _db() async =>
    ArtifactDatabase.forTesting(NativeDatabase.memory());

Emulator _project() => Emulator.create(name: 'test');

CallGraph _callGraph(List<String> symbols) => CallGraph(
      elfPath: '/dev/null',
      symbols: {
        for (final s in symbols)
          s: cg_sym.Symbol(name: s, numInstructions: 1, calledSymbols: const {}),
      },
    );

/// Call graph with explicit caller → callee edges.
CallGraph _edgeGraph(Map<String, List<String>> edges) => CallGraph(
      elfPath: '/dev/null',
      symbols: {
        for (final e in edges.entries)
          e.key: cg_sym.Symbol(
            name: e.key,
            numInstructions: 1,
            calledSymbols: {for (final c in e.value) c: 1},
          ),
      },
    );

RecommendationResult _recs(List<Recommendation> recs, {String prose = 'ok'}) =>
    RecommendationResult(prose: prose, recommendations: recs, parseFailure: false);

SetPreference _pref(String symbol, int id) =>
    SetPreference(rationale: 'prefer', symbol: symbol, artifactId: id);

/// Build an enriched result. When [failedSymbol] is set, a decision is
/// recorded for it carrying [triedArtifactId] as the applied hook (so
/// [triedArtifactsForFailedSymbol] reconstructs `{triedArtifactId}`).
/// [executed] feeds the stagnation guard — give successive successful
/// rounds distinct sets unless a test exercises stagnation on purpose.
SynthesizerResult _result({
  required String runId,
  bool success = false,
  String? failedSymbol,
  int? triedArtifactId,
  List<String> executed = const ['A'],
}) {
  final decisions = <ManifestDecision>[
    if (failedSymbol != null)
      ManifestDecision(
        symbol: failedSymbol,
        appliedHook: AppliedHook(bodyHash: 'h', artifactId: triedArtifactId),
        decisionKind: ManifestDecisionKind.iterationFallback,
        decisionSource: 'iteration_fallback',
      ),
  ];
  final manifest = SynthesisManifest(
    manifestVersion: 2,
    elfHash: 'a' * 64,
    elfFileName: 'test.elf',
    synthesizerRunId: runId,
    result: ManifestRunResult(
        success: success, totalIterations: 1, durationSeconds: 1),
    decisions: decisions,
    failedSymbol: failedSymbol,
    metrics: const ManifestMetrics(
      overallFidelity: 0.5,
      coverageFidelity: 0.5,
      subgraphFidelity: null,
      intactCount: 1,
      degradedCount: 0,
      hookedCount: 1,
    ),
    executedSymbols: executed,
  );
  return SynthesizerResult(
    success: success,
    totalIterations: 1,
    resolvedHooks: const {},
    totalDuration: const Duration(seconds: 1),
    failedSymbol: failedSymbol,
    manifest: manifest,
  );
}
