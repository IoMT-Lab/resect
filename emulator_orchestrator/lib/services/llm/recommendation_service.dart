import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../data/database/artifact_database.dart';
import '../../data/models/call_graph.dart';
import '../../data/models/hook_decision_state.dart';
import '../../data/models/recommendation.dart';
import '../../data/models/round_snapshot.dart';
import '../../data/models/symbol_group.dart';
import '../../data/models/synthesis_manifest.dart';
import '../analysis/coverage_frontier.dart';
import '../analysis/fidelity_delta.dart';
import '../rag/rag_index.dart';
import 'last_run_insight_service.dart';
import 'llm_client.dart';
import 'llm_profiles.dart';

/// Optimization signal the LLM should bias its recommendations
/// toward when set. Surfaced from the auto-tune configuration
/// dialog so the user can steer the loop at the start of a session
/// (improve overall fidelity vs. reach more code via coverage vs.
/// tighten the start→stop path via subgraph).
enum OptimizationTarget {
  overallFidelity,
  coverageFidelity,
  subgraphFidelity,
}

/// Which analysis job the recommendation call is framing for. The
/// orchestrator's outcome router picks this from the run result;
/// [auto] infers from the manifest (failedSymbol present ⇒ an error
/// site exists ⇒ job1; otherwise job2) so existing callers get
/// sensible behavior without passing a mode.
enum RecommendationMode {
  /// Infer from the manifest outcome.
  auto,

  /// Reactive: an error fired at an exhausted symbol; frame toward
  /// authoring/replacing a hook for that error site.
  job1Authorship,

  /// Proactive: no error, low coverage; frame toward unblocking
  /// forward progress using the coverage frontier.
  job2Coverage,
}

/// Why a [RecommendationResult] failed to parse, when `parseFailure`
/// is true. Lets the modal render a remediation message tailored to
/// the actual failure mode instead of a generic "(empty)" placeholder.
///
/// - [emptyResponse]: the LLM emitted zero response tokens. Almost
///   always means `num_predict` was consumed by the thinking phase
///   before the response phase started — surfaced with the live
///   `done_reason` / token counts so the user can confirm.
/// - [malformedJson]: the LLM emitted text but it isn't valid JSON
///   or doesn't match the contract (no `{...}` region, decode error,
///   wrong shape).
enum RecommendationParseFailureKind {
  emptyResponse,
  malformedJson,
}

/// Diagnostic payload from Ollama's final NDJSON line plus the
/// orchestrator's local thinking-chunk count. Attached to a
/// `parseFailureKind == emptyResponse` result so the modal can show
/// the user exactly why no response landed.
class RecommendationDiagnostic {
  const RecommendationDiagnostic({
    required this.doneReason,
    required this.responseTokens,
    required this.thinkingChunks,
  });

  final String doneReason;
  final int responseTokens;
  final int thinkingChunks;

  /// One-line summary for stderr / log lines. The same string the
  /// modal renders, just without the heading.
  String toLogLine() =>
      'done_reason=$doneReason responseTokens=$responseTokens '
      'thinkingChunks=$thinkingChunks';
}

/// Symbols the recommendation pipeline must never let auto-tune target
/// with a forced override, preference, or generated hook: skipping an
/// entry point deletes the entire program under it (observed live:
/// `main` forced to Return 0 left 3 executed symbols and a dead
/// session). Enforced twice — subtracted from the constrained-decoding
/// symbol enum, and dropped again at parse time because the decoder's
/// enforcement is soft. `clear_forced_override` is exempt (removing an
/// override is always safe).
const kProtectedSymbols = {'main', 'Reset_Handler', '_start'};

/// The one principle every playbook step is an instance of, stated
/// once so the steps read as applications of it rather than a rule
/// pile.
const _playbookPrinciple =
    'PRINCIPLE: a hook STANDS IN for the function it replaces — pick '
    'the behavior its callers would observe from the original: flags '
    'read as states, counters and time ADVANCE between calls, status '
    'returns use the callee\'s own convention (HAL-style success is '
    'usually 0/HAL_OK), and a skipped body means everything beneath '
    'it never happens. Every round is MEASURED: a round that makes '
    'coverage collapse is reverted wholesale and remembered.';

/// Playbook cautions rendered on BOTH normal and escalation rounds —
/// escalation used to replace the playbook wholesale, which deleted
/// exactly these rules on the rounds that did the damage.
const _playbookStepHandsOff =
    'HANDS OFF: comms-virtualized symbols (annotated `comms:*`) are '
    'already covered as a bus — never force them individually. Void '
    'register-writers (annotated "void register writes") gain nothing '
    'from a forced return value — skip them. Void enable/disable-style '
    'writers (`*_Enable`, `*_Disable`, `*_ForceReset`) must NEVER be '
    'forced to "Return 0" as a skip — the peripheral simply never gets '
    'enabled; use the stateful write artifacts if they need anything, '
    'otherwise leave them intact.';

const _playbookStepBoundary =
    'BOUNDARY ONLY: target only executed symbols or direct unreached '
    'callees on the frontier. A forced override on a symbol execution '
    'never reaches does nothing.';


/// Structured feedback the auto-tune engine threads into the NEXT
/// round's prompt after a round produced no coverage movement (or
/// every recommendation was filtered as a no-op). Rendered as a
/// short imperative "## Feedback from last round" section — the
/// escalation signal that tells the model its leaf-level fixes are
/// already in effect and the blocker is likely INLINED in an
/// executed caller, so the next move is the wrapper-skip (force the
/// caller itself to return 0).
class RoundFeedback {
  const RoundFeedback({
    required this.coveragePrev,
    required this.coverageNow,
    this.stalledCallers = const [],
    this.noOpSkipped = const [],
    this.refused = const [],
    this.revertedMoves = const [],
    this.revertedOutcome,
  });

  /// Executed-symbol count from the round before last.
  final int coveragePrev;

  /// Executed-symbol count from the last round — equal to
  /// [coveragePrev] when stagnant.
  final int coverageNow;

  /// Frontier callers (executed functions with unreached callees)
  /// where the spin is likely inlined.
  final List<String> stalledCallers;

  /// Recommendations from the last round that were dropped because
  /// they were already in effect (no-ops).
  final List<Recommendation> noOpSkipped;

  /// Recommendations the ENGINE refused outright (entry-point targets —
  /// deleting the program is never right). Rendered so the model knows
  /// they were rejected — not silently lost — and why.
  final List<Recommendation> refused;

  /// The previous round's applied moves, when that round was MEASURED,
  /// found to have collapsed coverage, and rolled back wholesale.
  /// [revertedOutcome] carries the measurement ("executed fell 39 → 15").
  final List<Recommendation> revertedMoves;
  final String? revertedOutcome;
}

/// What [RecommendationService.recommend] returns.
///
/// `prose` is the LLM's free-text summary (one sentence at most when
/// the model honored the system prompt; longer when it didn't).
/// `recommendations` is the typed action list the orchestrator's
/// review UI renders.
///
/// `parseFailure` is `true` when the LLM either emitted nothing
/// (budget exhausted mid-think) or emitted text the parser couldn't
/// decode. `parseFailureKind` distinguishes the two so the modal
/// can show a targeted remediation message; `diagnostic` carries
/// the Ollama-final-line stats on the empty-response branch.
/// `recommendations` is empty on parse failure — the orchestrator
/// treats parseFailure as terminal-for-this-round.
class RecommendationResult {
  const RecommendationResult({
    required this.prose,
    required this.recommendations,
    required this.parseFailure,
    this.parseFailureKind,
    this.diagnostic,
    this.raw,
    this.model,
  });

  final String prose;
  final List<Recommendation> recommendations;
  final bool parseFailure;
  final RecommendationParseFailureKind? parseFailureKind;
  final RecommendationDiagnostic? diagnostic;
  final String? raw;
  final String? model;

  bool get isEmpty => recommendations.isEmpty && !parseFailure;
}

/// Asks the local LLM for a list of structured [Recommendation]s
/// the user can review and apply between auto-tune rounds.
///
/// **Split from `LastRunInsightService`.** The advisor service is
/// tuned for a small model emitting prose under a 1–3-sentence cap.
/// This service expects strict JSON output and runs on the
/// hook-gen-sized model (constructor-configured, NOT the smallest).
/// The advisor's `composePrompt` is reused for the input context
/// section so device-class additions land in both services as soon
/// as they ship.
///
/// The closed-loop orchestrator passes a windowed slice of the
/// project's [RoundSnapshot] history (default last 3) so the LLM
/// sees the trajectory of prior rounds' metrics and per-row user
/// decisions when reasoning about the next round.
class RecommendationService {
  RecommendationService({
    required this.llmClient,
    required this.insightService,
    required this.artifactDb,
    this.ragIndex,
  });

  final LlmClient llmClient;

  /// Borrowed for its prompt composer. The advisor's input section
  /// (manifest summary, decisions, call-graph neighborhood, current
  /// overlay) is exactly the context this service needs too, plus
  /// the round-history + JSON-output additions in [composePrompt].
  final LastRunInsightService insightService;

  /// Used to enumerate the available `set_forced_override` artifact
  /// candidates into the prompt. Without this enumeration the LLM
  /// invents `artifact_id` values from the JSON-contract example,
  /// often picking IDs that were deleted by
  /// `ArtifactLibraryService.reseedDefaults` (SQLite AUTOINCREMENT
  /// leaves permanent gaps after deletes — see TODO.txt). Required
  /// — without a real catalog the recommendations are useless.
  final ArtifactDatabase artifactDb;

  /// Optional per-project RAG index. When set, the prompt also
  /// carries the top-K hook-catalog chunks + the halt symbol's
  /// decompilation (mirrors what [LlmHookGenerator] does for the
  /// new-hook flow). Null is tolerated for environments without
  /// an open project (headless tests, library-mode dumps).
  final RagIndex? ragIndex;

  /// Default cap on recommendations per round (the schema's
  /// `maxItems`). 10 — high enough for the batch name-classification
  /// a human does over a frontier (force every ready-flag at once),
  /// low enough to stay within the response-token budget.
  /// `AutoTuneConfig.maxRecommendationsPerRound` mirrors this.
  static const defaultMaxRecommendations = 10;

  /// Stream-collecting entry point.
  ///
  /// The implementation streams the LLM's output (so [onToken] can
  /// drive a live-display buffer in the modal), concatenates tokens
  /// into the full reply, and parses the final string into a
  /// [RecommendationResult]. The returned future completes when the
  /// LLM stream closes.
  ///
  /// [history] should be the project's round snapshots in
  /// chronological order, windowed by the caller (last N rounds).
  /// Empty list = first round of an auto-tune session.
  Future<RecommendationResult> recommend({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    List<RoundSnapshot> history = const [],
    OptimizationTarget? optimizationTarget,
    RecommendationMode mode = RecommendationMode.auto,
    List<FrontierEntry> frontier = const [],
    RoundFeedback? feedback,
    int maxRecommendations = defaultMaxRecommendations,
    List<SymbolGroup> symbolGroups = const [],
    Map<String, GroupOverrideState> groupOverrides = const {},
    void Function(String token)? onToken,
    void Function(String chunk)? onThinking,
    void Function(String prompt)? onPromptComposed,
  }) async {
    // The recommendation call is a DECISION, not a derivation, so it
    // runs the think-off / temp-0 `job2Coverage` profile with a
    // schema-constrained response. This is the core anti-recursion
    // change: previously this ran think-on/temp-1 with an 8192-token
    // budget, and gemma4:12b would spend the whole budget on a
    // 7600-chunk thinking spiral, emitting zero response tokens.
    // Think-off eliminates the spiral; the schema makes malformed
    // JSON unrepresentable.
    const profile = LlmProfiles.job2Coverage;
    final resolvedMode = _resolveMode(mode, currentManifest);
    final prompt = await composePrompt(
      currentManifest: currentManifest,
      currentState: currentState,
      callGraph: callGraph,
      history: history,
      optimizationTarget: optimizationTarget,
      mode: mode,
      frontier: frontier,
      feedback: feedback,
      maxRecommendations: maxRecommendations,
      symbolGroups: symbolGroups,
      groupOverrides: groupOverrides,
    );
    // Surface the composed prompt to the caller. Used by the
    // orchestrator to write the per-round debug trace file
    // (`last_recommendation_trace.txt`) without re-composing.
    onPromptComposed?.call(prompt);

    final schema = await buildRecommendationSchema(
      currentManifest: currentManifest,
      currentState: currentState,
      callGraph: callGraph,
      mode: resolvedMode,
      frontier: frontier,
      maxRecommendations: maxRecommendations,
      feedback: feedback,
      symbolGroups: symbolGroups,
    );

    final modelName = llmClient.model;
    final buf = StringBuffer();
    LlmStreamDone? doneEvent;
    // Response chunks → buf (final JSON) + onToken (live display).
    // Thinking chunks → onThinking only (with think off there will
    // be none, but the branch stays for the fallback path). The
    // LlmStreamDone is captured so the empty-response branch can
    // attach Ollama's done_reason + token counts.
    await for (final ev in llmClient.generateEvents(
      prompt,
      system: _systemPrompt,
      modelOverride: modelName,
      think: profile.think,
      temperature: profile.temperature,
      topP: profile.topP,
      topK: profile.topK,
      numCtx: profile.numCtx,
      numPredict: profile.numPredict,
      format: schema,
    )) {
      switch (ev) {
        case LlmThinkingChunk(:final text):
          onThinking?.call(text);
        case LlmResponseChunk(:final text):
          buf.write(text);
          onToken?.call(text);
        case LlmStreamDone():
          doneEvent = ev;
      }
    }
    final raw = buf.toString();
    return _parseOutput(raw, modelName, doneEvent,
        validSymbols: callGraph.symbols.keys.toSet());
  }

  /// Resolve [RecommendationMode.auto] against the manifest: a
  /// non-null `failedSymbol` means an error fired at an exhausted
  /// symbol (job 1); otherwise the run completed/timed out without
  /// an error and the work is proactive coverage (job 2).
  static RecommendationMode _resolveMode(
    RecommendationMode mode,
    SynthesisManifest manifest,
  ) {
    if (mode != RecommendationMode.auto) return mode;
    return manifest.failedSymbol != null
        ? RecommendationMode.job1Authorship
        : RecommendationMode.job2Coverage;
  }

  /// Compose the LLM prompt. Async because the artifact catalog and
  /// the optional RAG retrieval are both DB-backed.
  Future<String> composePrompt({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    List<RoundSnapshot> history = const [],
    OptimizationTarget? optimizationTarget,
    RecommendationMode mode = RecommendationMode.auto,
    List<FrontierEntry> frontier = const [],
    RoundFeedback? feedback,
    int maxRecommendations = defaultMaxRecommendations,
    List<SymbolGroup> symbolGroups = const [],
    Map<String, GroupOverrideState> groupOverrides = const {},
  }) async {
    final resolvedMode = _resolveMode(mode, currentManifest);
    final buf = StringBuffer();

    // Artifact id → human-readable effect ("Return 0" / "Return 1" /
    // "increment" …). Lets the overlay show what each applied hook DOES
    // at its symbol, so the model can judge whether a hook is wrong
    // without hand-joining ids to the catalog.
    final artifactLabels = await _artifactLabels();

    // Base context — the advisor's context sections ONLY (no task
    // footer; this service appends its own job-specific task below).
    // Job 2 also gets the coverage frontier appended to the context.
    buf.writeln(insightService.composeContext(
      manifest: currentManifest,
      currentState: currentState,
      callGraph: callGraph,
      frontier:
          resolvedMode == RecommendationMode.job2Coverage ? frontier : const [],
      artifactLabels: artifactLabels,
    ));

    // Available hook artifacts — ground the model's
    // `set_forced_override.artifact_id` picks against real DB rows
    // instead of letting it invent values from the JSON contract
    // example. Without this section the LLM would pick e.g. id=12
    // for `gemma4:e4b` on this codebase, where id 12 was deleted by
    // `ArtifactLibraryService.reseedDefaults` and now points
    // nowhere.
    buf.writeln(await _renderArtifactCatalog());

    // Object groups relevant this round — so the model can act on a whole
    // peripheral (set/clear_group_override) instead of scattered symbols.
    if (symbolGroups.isNotEmpty) {
      final candidates = _candidateSymbols(
        currentManifest: currentManifest,
        currentState: currentState,
        callGraph: callGraph,
        mode: resolvedMode,
        frontier: frontier,
      );
      final relevant = _relevantGroups(symbolGroups, candidates);
      if (relevant.isNotEmpty) {
        buf.writeln();
        buf.writeln(_renderObjectGroups(relevant, groupOverrides));
      }
    }

    // Retrieved context — top-K hook-catalog chunks + the halt
    // symbol's decompilation chunk when the RAG index is wired.
    // Mirrors what [LlmHookGenerator] does for the new-hook flow.
    // Halt symbol comes from the shared cascade
    // (failedSymbol → finalExecutionSymbol → lastPauseSymbol →
    // chronological-last decision) so this service and
    // `LastRunInsightService` are in lockstep.
    final haltSymbol =
        LastRunInsightService.computeHaltSymbol(currentManifest);
    final retrieved = await _renderRetrievedContext(haltSymbol);
    if (retrieved.isNotEmpty) {
      buf.writeln(retrieved);
    }

    // Auto-tune history — trajectory of prior rounds (if any).
    if (history.isNotEmpty) {
      buf.writeln();
      buf.writeln('## Auto-tune round history');
      for (var i = 0; i < history.length; i++) {
        final s = history[i];
        buf.writeln('### Round ${s.round}');
        buf.writeln(
            '- Overall fidelity: ${s.metrics.overallFidelity.toStringAsFixed(3)}'
            '${s.metrics.coverageFidelity != null ? ', coverage '
                '${s.metrics.coverageFidelity!.toStringAsFixed(3)}' : ''}'
            '${s.metrics.subgraphFidelity != null ? ', subgraph '
                '${s.metrics.subgraphFidelity!.toStringAsFixed(3)}' : ''}');
        buf.writeln(
            '- Executed symbols: ${s.executedSymbols.length}');
        if (i > 0) {
          final delta = FidelityDelta.compute(
            prior: history[i - 1].metrics,
            current: s.metrics,
            priorExecutedCount: history[i - 1].executedSymbols.length,
            currentExecutedCount: s.executedSymbols.length,
          );
          buf.writeln(
              '- Δ since prior round: overall '
              '${delta.overallFidelityDelta.toStringAsFixed(3)}, '
              'executed ${delta.executedSymbolsDelta}');
        }
        final decisions = s.userDecisions ?? const [];
        if (decisions.isNotEmpty) {
          final accepted =
              decisions.where((d) => d.action == UserAction.accepted).length;
          final rejected =
              decisions.where((d) => d.action == UserAction.rejected).length;
          final edited =
              decisions.where((d) => d.action == UserAction.edited).length;
          buf.writeln(
              '- User decisions: $accepted accepted, $rejected rejected, '
              '$edited edited (out of ${decisions.length})');
          // Render each recommendation in compact form so the model
          // can see WHAT was tried — not just how many were
          // accepted. Without this the model has no way to know
          // "force the IsReady flag" was tried twice already with
          // zero metric movement, and it spirals trying to find a
          // similar template that hasn't been used yet.
          buf.writeln('- Recommendations applied:');
          for (final d in decisions) {
            buf.writeln(
                '  - ${_formatRecommendationCompact(d.original)} '
                '(${d.action.name})');
          }
        }
      }
    }

    // Feedback from the engine after a stagnant round — imperative
    // escalation, not more context. Placed after the round history so
    // it reads as the latest word on what to do differently.
    if (feedback != null) {
      buf.writeln();
      buf.writeln('## Feedback from last round');
      buf.writeln(
          '- Coverage did NOT move: ${feedback.coveragePrev} → '
          '${feedback.coverageNow} executed symbols.');
      if (feedback.noOpSkipped.isNotEmpty) {
        buf.writeln(
            '- These recommendations were SKIPPED because they were '
            'already in effect (do not repeat them):');
        for (final r in feedback.noOpSkipped) {
          buf.writeln('  - ${_formatRecommendationCompact(r)}');
        }
      }
      if (feedback.refused.isNotEmpty) {
        buf.writeln(
            '- These recommendations were REFUSED and NOT applied '
            '(entry points are never overridable — skipping them '
            'deletes the program). Do not re-emit them:');
        for (final r in feedback.refused) {
          buf.writeln('  - ${_formatRecommendationCompact(r)}');
        }
      }
      if (feedback.revertedMoves.isNotEmpty) {
        buf.writeln(
            '- These moves were APPLIED, MEASURED, and REVERTED — '
            '${feedback.revertedOutcome ?? 'coverage collapsed'} — so '
            'they are NO LONGER in effect. Do not re-emit them as-is; '
            'if a TARGET was right, try a different artifact/value on '
            'it (e.g. a value that advances instead of a constant):');
        for (final r in feedback.revertedMoves) {
          buf.writeln('  - ${_formatRecommendationCompact(r)}');
        }
      }
      if (feedback.stalledCallers.isNotEmpty) {
        // Render each candidate with its unreached-callee count from
        // the frontier PLUS the facts the model needs to weigh the
        // skip's cost: whether the caller ran cleanly, and which
        // working overrides live beneath it (a Return-0 skip disables
        // them). NOTE the callee count is NOT a ranking: the spinning
        // wrapper is often the one with FEW unreached callees (it
        // stalls at its first internal gate), while high counts just
        // mean a big wrapper.
        final executedSet =
            currentManifest.executedSymbols?.toSet() ?? <String>{};
        final overrideSymbols = {
          for (final d in currentState.decisions)
            if (d.kind == HookDecisionKind.override) d.symbol,
        };
        String detail(String s) {
          final notes = <String>[];
          for (final e in frontier) {
            if (e.symbol == s) {
              notes.add('${e.unexecutedCalleeCount} unreached callees');
              break;
            }
          }
          if (executedSet.contains(s)) notes.add('ran cleanly this round');
          final beneath = overriddenHooksBeneath(callGraph, s, overrideSymbols);
          if (beneath.isNotEmpty) {
            notes.add('working hooks beneath it: '
                '${beneath.take(3).join(', ')}'
                '${beneath.length > 3 ? ', …' : ''} — a Return-0 skip '
                'disables them');
          }
          return notes.isEmpty ? '`$s`' : '`$s` (${notes.join('; ')})';
        }

        buf.writeln(
            '- Leaf-level fixes are already in effect and coverage is '
            'frozen. The blocker may be an INLINED busy-wait inside one '
            'of these executed callers (no leaf function to hook): '
            '${feedback.stalledCallers.map(detail).join(', ')}.');
        buf.writeln(
            '- ESCALATE: skip the stalled caller(s) most consistent '
            'with the halt evidence (prefer ones at or near the end of '
            'the "Recent call sequence") via `set_forced_override` with '
            'the "Return 0" artifact. Skipping a caller deletes its '
            'whole body: every function and working hook beneath it '
            'stops executing — so prefer starting with ONE and batch '
            'more only when each is individually defensible. The round '
            'is MEASURED: if coverage collapses it is reverted '
            'wholesale and remembered. Do not re-recommend leaf polls.');
      }
    }

    if (optimizationTarget != null) {
      buf.writeln();
      buf.writeln('## Optimization target');
      buf.writeln(
          'Bias your recommendations toward improving: '
          '${_targetLabel(optimizationTarget)}.');
    }

    buf.writeln();
    buf.writeln('## Your task');
    final escalating = feedback != null && feedback.stalledCallers.isNotEmpty;
    if (escalating) {
      // Escalation AUGMENTS the playbook rather than replacing it: the
      // batch-kill instruction this section used to carry produced the
      // observed self-destruction (working init callers force-returned
      // 0, their subtree overrides dead, coverage collapsing round over
      // round). One skip per round, chosen against the halt evidence,
      // with the playbook's cautions still in force.
      buf.writeln(
          'ESCALATION ROUND. Every leaf-level fix from the previous '
          'round is already in effect and coverage did not move. The '
          'response schema only accepts the stalled callers listed in '
          '"## Feedback from last round" this round; the likely blocker '
          'is a busy-wait INLINED inside one of them. Skipping a caller '
          'with "Return 0" deletes its whole body — every function it '
          'calls, including working hooks beneath it, stops executing, '
          'and a caller that completed cleanly is NOT proof it contains '
          'the spin. Prefer the caller most consistent with the halt '
          'evidence (at or near the end of the "Recent call sequence"); '
          'start with one, and batch more skips only when each is '
          'individually defensible — the round is MEASURED, and a '
          'coverage collapse reverts the whole round and is remembered. '
          "If a caller's behavior cannot be faked by returning 0, use "
          '`generate_custom_hook` for it instead. Do not re-recommend '
          'leaf polls. These cautions still apply:');
      buf.writeln(_playbookStepHandsOff);
      buf.writeln(_playbookStepBoundary);
    } else if (resolvedMode == RecommendationMode.job1Authorship &&
        haltSymbol != null) {
      // Job 1 — reactive. An unhandled access fired at `$haltSymbol`
      // and every catalog template for it was exhausted. Frame
      // toward authoring a replacement for that error site.
      buf.writeln(
          'The synthesizer FAILED: the firmware hit an unhandled '
          'access at `$haltSymbol` and every catalog template tried '
          'for it was exhausted. Recommend the change most likely to '
          'get execution past this symbol — usually a '
          '`generate_custom_hook` for `$haltSymbol` (the loop will '
          'author the body), or a not-yet-tried override if one fits.');
    } else if (resolvedMode == RecommendationMode.job2Coverage) {
      // Job 2 — proactive. No error; the run completed/timed out but
      // covered little. The playbook below encodes the manual
      // session that took this exact firmware from 25 to 136
      // executed symbols: value-typed leaf forces, wrapper-skips for
      // inlined spins, comms left to the bus virtualization, and
      // boundary-only targeting.
      if (haltSymbol != null &&
          LastRunInsightService.looksLikeErrorSink(haltSymbol)) {
        // Error-sink framing — an init/check failed and the firmware
        // diverted to a handler; that is NOT a busy-wait. Point the
        // model at the failing upstream call, not the sink.
        buf.writeln(
            'The synthesizer did NOT crash, but execution ended in '
            '`$haltSymbol`, which looks like an error/fault handler — an '
            'init or check FAILED and the firmware bailed to it. Do NOT '
            'hook the handler. In the "Recent call sequence", the call '
            'just before `$haltSymbol` is the one that failed — '
            '$kValueForSuccessGuidance — so execution continues instead '
            'of diverting to the handler. Then apply this playbook:');
      } else {
        buf.writeln(
            'The synthesizer did NOT crash, but coverage is low — the '
            'firmware is silently stuck in a busy-wait that never '
            'faults, so the reactive hook mechanism cannot see it. Your '
            'job is to force your way past it. Apply this playbook:');
      }
      buf.writeln(
          '0. STALL POINT FIRST: the "Halt point" / "Execution last '
          'reached" symbol is where forward progress stopped. If it is '
          'ALREADY hooked (its overlay line is marked EXECUTION STOPPED '
          'HERE), the applied hook itself may be WRONG — a ready/busy '
          'flag forced to the wrong value, or a Return-0 that masks '
          'progress. Re-evaluate and replace it (`set_forced_override` '
          'with a different artifact_id, or `generate_custom_hook`). '
          'This is the one case where re-touching an ALREADY IN EFFECT '
          'hook is NOT a wasted round. And if the stall symbol is an '
          'error/fault handler (e.g. `Error_Handler`, `*Fault*`), do NOT '
          'hook it — read the "Recent call sequence" line, find the call '
          'that ran just before it (that call failed), and '
          '$kValueForSuccessGuidance.');
      buf.writeln(_playbookPrinciple);
      buf.writeln(
          '1. SPIN RULE: if the "Recent call sequence" line shows the '
          'SAME function repeated (rendered `(×N)`) and that function '
          'is NOT already hooked, the firmware is parked in a wait '
          'loop polling it. Force THAT function first — this beats '
          'every other move when it applies. The loop exits on the '
          'ANSWER you make the function give, so pick the value per '
          'step 2.');
      buf.writeln(
          '2. VALUE CHOICE: decide what a function RETURNS before '
          'picking its artifact. `Is*`/`*ActiveFlag*`/`*Ready*` '
          'checks → "Return 1" for ready/active, "Return 0" for '
          'busy. `Get*`/`Read*` names return a VALUE, never a '
          'success code: time/tick/count readers → the "Stateful '
          'increment" artifact (the value must ADVANCE between '
          'calls); clock/frequency getters → a realistic Hz value '
          '(via `generate_custom_hook` if the catalog lacks one); '
          'unsure what it reads → `generate_custom_hook`, never a '
          'guessed constant. Frontier annotations (present only when '
          'Ghidra extraction ran — headless sessions usually have '
          'none) come from decompiled bodies and outrank the name; '
          'with no annotation the NAME is your only evidence — '
          'reason from it. Promote annotations marked "NOT applied '
          'this run" to forced overrides; ones marked "ALREADY IN '
          'EFFECT" are done (except the step-0 stall point) — '
          'repeating them wastes the round.');
      buf.writeln(
          '3. WRAPPER-SKIP — AN EXPERIMENT, PAID FOR BY REVERT: when '
          'steps 1-2 are exhausted and coverage still does not move, '
          'the spin may be INLINED inside an executed frontier '
          'caller. Skipping a caller with "Return 0" deletes its '
          'whole body — everything beneath it, including working '
          'hooks, stops happening. Prefer the caller the halt '
          'evidence places the stall INSIDE (at or near the end of '
          'the "Recent call sequence"). Batch only skips you can '
          'individually defend: the round is MEASURED, and if '
          'coverage collapses the whole round is reverted and '
          'remembered.');
      buf.writeln(_playbookStepHandsOff);
      buf.writeln(_playbookStepBoundary);
      buf.writeln(
          'You may emit up to $maxRecommendations recommendations — '
          'batch every defensible fix for this round (e.g. force ALL '
          'the ready-flags on the frontier at once), never more than '
          'one recommendation for the same symbol. Do not pad: every '
          'entry needs its own defensible rationale.');
    } else {
      buf.writeln(
          'Based on the run metrics, decisions, and available hook '
          'artifacts above, recommend up to $maxRecommendations '
          'overlay changes most likely to improve coverage and '
          'fidelity on the next run. Do not pad the list — every '
          'entry needs its own defensible rationale.');
    }
    buf.writeln();
    buf.writeln(
        'Respond with a single JSON object (no markdown fences, no '
        'commentary outside the JSON). Shape:');
    buf.writeln(_jsonContractExample);
    buf.writeln();
    buf.writeln(
        'If no further action is warranted, return an empty '
        'recommendations array with a one-sentence summary in '
        '`prose`. The user reviews each recommendation individually, '
        'so emit only changes you would defend.');
    return buf.toString();
  }

  /// Parse the LLM's raw output into a [RecommendationResult].
  ///
  /// Robust to wrapping (markdown fences, leading/trailing prose,
  /// `<think>...</think>` blocks, extra braces). Distinguishes
  /// two failure modes:
  ///   - `emptyResponse`: [raw] is empty/whitespace. The LLM never
  ///     reached the response phase — typically budget exhausted.
  ///     `done` (when present) carries Ollama's done_reason + token
  ///     counts as a diagnostic.
  ///   - `malformedJson`: [raw] has content but doesn't decode to
  ///     the expected shape.
  /// Test seam for the parse-time filters (call-graph membership,
  /// protected entry points) without a live LLM stream. Tests only.
  RecommendationResult parseOutputForTest(
    String raw, {
    Set<String> validSymbols = const {},
  }) =>
      _parseOutput(raw, 'test', null, validSymbols: validSymbols);

  RecommendationResult _parseOutput(
    String raw,
    String model,
    LlmStreamDone? done, {
    Set<String> validSymbols = const {},
  }) {
    if (raw.trim().isEmpty) {
      return RecommendationResult(
        prose: '',
        recommendations: const [],
        parseFailure: true,
        parseFailureKind: RecommendationParseFailureKind.emptyResponse,
        diagnostic: done == null
            ? null
            : RecommendationDiagnostic(
                doneReason: done.doneReason,
                responseTokens: done.responseTokens,
                thinkingChunks: done.thinkingChunks,
              ),
        raw: raw,
        model: model,
      );
    }
    final jsonRegion = _extractJsonObject(raw);
    if (jsonRegion == null) {
      return RecommendationResult(
        prose: raw.trim(),
        recommendations: const [],
        parseFailure: true,
        parseFailureKind: RecommendationParseFailureKind.malformedJson,
        raw: raw,
        model: model,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonRegion);
    } catch (_) {
      return RecommendationResult(
        prose: raw.trim(),
        recommendations: const [],
        parseFailure: true,
        parseFailureKind: RecommendationParseFailureKind.malformedJson,
        raw: raw,
        model: model,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      return RecommendationResult(
        prose: raw.trim(),
        recommendations: const [],
        parseFailure: true,
        parseFailureKind: RecommendationParseFailureKind.malformedJson,
        raw: raw,
        model: model,
      );
    }
    final prose = (decoded['prose'] as String?) ?? '';
    final recsRaw = decoded['recommendations'] as List<dynamic>? ?? const [];
    final recs = <Recommendation>[];
    for (final entry in recsRaw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        final r = Recommendation.fromJson(entry);
        if (r == null) continue;
        // Defense-in-depth: a symbol-targeting recommendation must name
        // a REAL call-graph symbol. Drop anything else (a hallucinated
        // name, or a control-flow sentinel like MAX_ITERATIONS_REACHED
        // that leaked past the schema enum) so it can never be authored
        // or overlaid. Recommendations with no symbol target (group /
        // iteration-cap kinds) are unaffected.
        final target = _recommendationTargetSymbol(r);
        if (target != null &&
            validSymbols.isNotEmpty &&
            !validSymbols.contains(target)) {
          stderr.writeln('[recommendation] dropping ${r.kind} for '
              'non-call-graph symbol "$target"');
          continue;
        }
        // Entry points are never a legal target for an override,
        // preference, or generated hook — skipping one deletes the
        // whole program beneath it. Clears remain allowed.
        if (target != null &&
            r is! ClearForcedOverride &&
            kProtectedSymbols.contains(target)) {
          stderr.writeln('[recommendation] dropping ${r.kind} targeting '
              'protected entry point "$target"');
          continue;
        }
        recs.add(r);
      } catch (_) {
        // Per-recommendation parse failures don't poison the whole
        // batch — drop the bad entry, keep going. The modal logs the
        // raw text so the user / a maintainer can investigate.
      }
    }
    // The model emitted recommendations but NONE survived decoding
    // (missing per-kind fields, unknown kinds). That is a malformed
    // response, not a deliberate "no further action" — reporting it as
    // empty terminated live sessions with a false `llmEmpty` while the
    // model was actively (if invalidly) recommending.
    if (recsRaw.isNotEmpty && recs.isEmpty) {
      return RecommendationResult(
        prose: prose,
        recommendations: const [],
        parseFailure: true,
        parseFailureKind: RecommendationParseFailureKind.malformedJson,
        raw: raw,
        model: model,
      );
    }
    return RecommendationResult(
      prose: prose,
      recommendations: recs,
      parseFailure: false,
      raw: raw,
      model: model,
    );
  }

  /// The call-graph symbol a recommendation targets, or null for kinds
  /// that don't name a symbol (group overrides, iteration-cap). Used to
  /// validate targets against the call graph at parse time.
  static String? _recommendationTargetSymbol(Recommendation r) => switch (r) {
        SetForcedOverride(:final symbol) => symbol,
        ClearForcedOverride(:final symbol) => symbol,
        SetPreference(:final symbol) => symbol,
        GenerateCustomHook(:final symbol) => symbol,
        _ => null,
      };

  /// Build the Ollama constrained-decoding schema for the response.
  /// Dynamic so invalid choices are unrepresentable at the decoder,
  /// not merely discouraged in prose:
  ///   - `kind` enum = the wired action kinds.
  ///   - `artifact_id` enum = the real catalog ids (so the model
  ///     cannot invent an id like #12 that was deleted).
  ///   - `symbol` enum = the candidate set for the mode (halt symbol
  ///     + frontier + neighbourhood), when non-empty — a fraction of
  ///     the 856-symbol graph, which is the "constrain the
  ///     information" ask applied to the output side.
  /// Per Ollama's guidance the same shape is also rendered in the
  /// prompt body (`_jsonContractExample`); the schema is the
  /// enforcement layer on top.
  ///
  /// Public for unit testing — asserts the enums reflect the real
  /// catalog ids / candidate symbols and that invalid picks are
  /// unrepresentable.
  /// The adjacency-derived candidate symbol set for a round: the halt symbol,
  /// (job2) the coverage frontier + its unexecuted callees, the halt symbol's
  /// callers/callees, and every overlay/manifest symbol. Shared by the schema
  /// (which then excludes comms) and the prompt's object-group relevance.
  Set<String> _candidateSymbols({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    required RecommendationMode mode,
    required List<FrontierEntry> frontier,
  }) {
    final candidates = <String>{};
    final halt = LastRunInsightService.computeHaltSymbol(currentManifest);
    if (halt != null) candidates.add(halt);
    if (mode == RecommendationMode.job2Coverage) {
      for (final e in frontier) {
        candidates.add(e.symbol);
        candidates.addAll(e.unexecutedCallees);
      }
    }
    if (halt != null) {
      final node = callGraph.symbols[halt];
      if (node != null) {
        candidates.addAll(node.calledSymbols.keys);
        candidates.addAll(callGraph.getCallers(halt));
      }
    }
    candidates.addAll(currentState.decisions.map((d) => d.symbol));
    candidates.addAll(currentManifest.decisions.map((d) => d.symbol));
    return candidates;
  }

  /// Object groups with at least one member in [candidates] — the groups
  /// worth showing the model this round.
  static List<SymbolGroup> _relevantGroups(
    List<SymbolGroup> symbolGroups,
    Set<String> candidates,
  ) =>
      symbolGroups
          .where((g) => g.members.keys.any(candidates.contains))
          .toList();

  /// Render the `## Object groups` prompt section: each relevant object, its
  /// current override state, and its members with roles.
  static String _renderObjectGroups(
    List<SymbolGroup> groups,
    Map<String, GroupOverrideState> groupOverrides,
  ) {
    final buf = StringBuffer()
      ..writeln('## Object groups (this round)')
      ..writeln('Peripheral objects whose members are in play. Act on a whole '
          'object with `set_group_override` (force its coherent enable/disable/'
          'read hooks together) or `clear_group_override` (stop it being '
          'applied, freeing its members for per-symbol handling). Prefer a '
          'group action when a fault sits inside one of these objects.');
    for (final g in groups) {
      final state = groupOverrides[g.scope];
      final tag = state == GroupOverrideState.forced
          ? ' [forced]'
          : state == GroupOverrideState.suppressed
              ? ' [suppressed]'
              : ' [auto]';
      final members = g.members.entries
          .map((e) => '${e.key}(${e.value.role.name})')
          .join(', ');
      buf.writeln('- `${g.scope}`$tag: $members');
    }
    return buf.toString();
  }

  Future<Map<String, Object?>> buildRecommendationSchema({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    required RecommendationMode mode,
    required List<FrontierEntry> frontier,
    int maxRecommendations = defaultMaxRecommendations,
    RoundFeedback? feedback,
    List<SymbolGroup> symbolGroups = const [],
  }) async {
    final catalogIds =
        (await artifactDb.getAllArtifacts()).map((a) => a.id).toList()..sort();

    // Escalation round: the previous round's leaf-level fixes were all
    // in effect and coverage stayed frozen, so the ONLY defensible
    // targets are the stalled callers (wrapper-skip). Restricting the
    // symbol enum makes repeating the previous answer UNREPRESENTABLE
    // — observed failure: at temp 0 the model reproduced its prior
    // round's recommendations token-for-token, straight past an
    // imperative do-not-repeat instruction. Constrained decoding is
    // the lever prose isn't.
    if (feedback != null && feedback.stalledCallers.isNotEmpty) {
      final stalled = feedback.stalledCallers
          .where((s) => !kProtectedSymbols.contains(s))
          .toList()
        ..sort();
      final groupScopes = _relevantGroups(symbolGroups, stalled.toSet())
          .map((g) => g.scope)
          .toList()
        ..sort();
      return _schemaShell(
        symbolEnum: stalled,
        catalogIds: catalogIds,
        maxRecommendations: maxRecommendations,
        groupScopeEnum: groupScopes,
      );
    }

    // Error-sink round: execution ended in an error/fault handler, so
    // the actionable targets are the calls on the recent path INTO the
    // sink (one of them failed and diverted execution) — NOT the sink
    // itself, and NOT unrelated frontier ready-flags. Restricting the
    // enum to that path makes an off-path override UNREPRESENTABLE.
    // Prose guidance alone was ignored last round; constrained decoding
    // is the lever. Placed after escalation (which never fires on an
    // error-sink manifest) and before the generic candidate path.
    final haltSink = LastRunInsightService.computeHaltSymbol(currentManifest);
    final recentTrace = currentManifest.recentExecutionTrace ?? const [];
    if (haltSink != null &&
        LastRunInsightService.looksLikeErrorSink(haltSink) &&
        recentTrace.isNotEmpty) {
      final pathSymbols = recentTrace
          .where((s) =>
              s != haltSink &&
              !kProtectedSymbols.contains(s) &&
              callGraph.symbols.containsKey(s))
          .toSet()
          .toList()
        ..sort();
      if (pathSymbols.isNotEmpty) {
        final groupScopes = _relevantGroups(symbolGroups, pathSymbols.toSet())
            .map((g) => g.scope)
            .toList()
          ..sort();
        return _schemaShell(
          symbolEnum: pathSymbols,
          catalogIds: catalogIds,
          maxRecommendations: maxRecommendations,
          groupScopeEnum: groupScopes,
        );
      }
    }

    final halt = LastRunInsightService.computeHaltSymbol(currentManifest);
    final candidates = _candidateSymbols(
      currentManifest: currentManifest,
      currentState: currentState,
      callGraph: callGraph,
      mode: mode,
      frontier: frontier,
    );

    // Comms-virtualized symbols are covered as a bus — an individual
    // force on one produces incoherent protocol state, so make them
    // unrepresentable. The halt symbol is always retained (job 1 must
    // be able to target the error site), and if exclusion would empty
    // a non-empty candidate set, keep the pre-exclusion set — the
    // empty-enum fallback below unconstrains `symbol` entirely, which
    // is strictly worse than allowing comms symbols.
    final commsSymbols = {
      for (final d in currentState.decisions)
        if (d.kind == HookDecisionKind.comms) d.symbol,
    };
    if (commsSymbols.isNotEmpty && candidates.isNotEmpty) {
      final excluded = candidates.difference(commsSymbols);
      if (halt != null) excluded.add(halt);
      if (excluded.isNotEmpty) {
        candidates
          ..clear()
          ..addAll(excluded);
      }
    }
    // The enum offered to constrained decoding must contain ONLY real
    // call-graph symbols — never a control-flow sentinel or a candidate
    // that isn't a function. This is what makes a pick like
    // `MAX_ITERATIONS_REACHED` unrepresentable at the decoder.
    final symbolEnum = candidates
        .where((s) =>
            s.isNotEmpty &&
            !kProtectedSymbols.contains(s) &&
            callGraph.symbols.containsKey(s))
        .toList()
      ..sort();
    final groupScopes = _relevantGroups(symbolGroups, candidates)
        .map((g) => g.scope)
        .toList()
      ..sort();
    return _schemaShell(
      symbolEnum: symbolEnum,
      catalogIds: catalogIds,
      maxRecommendations: maxRecommendations,
      groupScopeEnum: groupScopes,
    );
  }

  /// The response-schema shape shared by the normal and escalation
  /// paths; only the symbol enum differs.
  ///
  /// Items are a per-kind `anyOf` so each kind's payload fields are
  /// REQUIRED at the decoder: a `set_forced_override` without an
  /// `artifact_id` is unrepresentable. Before this, the flat schema
  /// only required kind+rationale — the model emitted id-less
  /// overrides, every entry failed `Recommendation.fromJson`, and the
  /// round terminated as a false `llmEmpty`. (anyOf/const/enum support
  /// verified against the installed Ollama, 2026-07-16.)
  static Map<String, Object?> _schemaShell({
    required List<String> symbolEnum,
    required List<int> catalogIds,
    required int maxRecommendations,
    List<String> groupScopeEnum = const [],
  }) {
    final symbolSchema = symbolEnum.isEmpty
        ? {'type': 'string'}
        : {'type': 'string', 'enum': symbolEnum};
    final artifactSchema = catalogIds.isEmpty
        ? {'type': 'integer'}
        : {'type': 'integer', 'enum': catalogIds};

    Map<String, Object?> branch(
      String kindName,
      Map<String, Object?> props,
      List<String> required,
    ) =>
        {
          'type': 'object',
          'properties': {
            'kind': {'const': kindName},
            'rationale': {'type': 'string'},
            ...props,
          },
          'required': ['kind', 'rationale', ...required],
        };

    return <String, Object?>{
      'type': 'object',
      'properties': {
        'prose': {'type': 'string'},
        'recommendations': {
          'type': 'array',
          'maxItems': maxRecommendations,
          'items': {
            'anyOf': [
              branch(SetForcedOverride.kindName, {
                'symbol': symbolSchema,
                'artifact_id': artifactSchema,
                'scope': {'type': 'string'},
              }, [
                'symbol',
                'artifact_id',
              ]),
              branch(ClearForcedOverride.kindName, {
                'symbol': symbolSchema,
              }, [
                'symbol',
              ]),
              branch(SetPreference.kindName, {
                'symbol': symbolSchema,
                'artifact_id': artifactSchema,
              }, [
                'symbol',
                'artifact_id',
              ]),
              branch(GenerateCustomHook.kindName, {
                'symbol': symbolSchema,
                'intent': {'type': 'string'},
              }, [
                'symbol',
              ]),
              branch(AdjustIterationCap.kindName, {
                'new_value': {'type': 'integer'},
              }, [
                'new_value',
              ]),
              // Group actions only when there ARE relevant groups — never emit
              // a branch with an empty scope enum (unconstrained scope would
              // let the model invent a non-existent object).
              if (groupScopeEnum.isNotEmpty)
                branch(SetGroupOverride.kindName, {
                  'scope': {'type': 'string', 'enum': groupScopeEnum},
                }, [
                  'scope',
                ]),
              if (groupScopeEnum.isNotEmpty)
                branch(ClearGroupOverride.kindName, {
                  'scope': {'type': 'string', 'enum': groupScopeEnum},
                }, [
                  'scope',
                ]),
            ],
          },
        },
      },
      'required': ['prose', 'recommendations'],
    };
  }

  /// Render the available-artifacts section the LLM uses to pick
  /// real `artifact_id` values. One row per artifact, ordered by
  /// origin (defaults first) then id. Labels come from `name` when
  /// set, otherwise from the first non-empty line of the body —
  /// matches what the Hook Database dialog shows. Empty rows are
  /// rare but skipped to keep the section terse.
  /// Artifact id → human-readable effect label for every row in the DB.
  /// Same derivation as the catalog block: the `name` column if set,
  /// else derived from the hook body via [_hookLabel]. Used to annotate
  /// the overlay so applied hooks show what they DO at their symbol.
  Future<Map<int, String>> _artifactLabels() => artifactLabelsFor(artifactDb);

  Future<String> _renderArtifactCatalog() async {
    final all = await artifactDb.getAllArtifacts();
    final buf = StringBuffer();
    buf.writeln('## Available hook artifacts');
    buf.writeln('Each row is a row in the artifact DB. When emitting '
        '`set_forced_override` or `set_preference`, the `artifact_id` '
        'field MUST be one of the integer IDs in this list. There are '
        'gaps in the sequence (deleted templates leave permanent '
        'AUTOINCREMENT holes); do not invent IDs.');
    if (all.isEmpty) {
      buf.writeln('(no artifacts registered)');
      return buf.toString();
    }
    for (final a in all) {
      final label = (a.name != null && a.name!.trim().isNotEmpty)
          ? a.name!.trim()
          : _hookLabel(a.artifactData);
      // Note: the row's `intrinsic_score` column is deliberately
      // omitted from the prompt. It's a property of the hook body
      // (how broadly useful the template is across symbols), not
      // a measure of how well the artifact fits any specific
      // symbol — the LLM was conflating the two before. The
      // per-symbol "fit" signal lives in the "Decisions applied"
      // block as the binding's contextual fidelity instead.
      final parts = <String>[
        'id=${a.id}',
        a.origin,
        if (label.isNotEmpty) '"${_truncate(label, 80)}"',
        if (a.targetSymbolName != null) 'target=${a.targetSymbolName}',
      ];
      buf.writeln('- ${parts.join('  ')}');
    }
    return buf.toString();
  }

  /// Render one prior-round recommendation as a single compact line
  /// for the round history block. Stable shape: kind + the
  /// per-kind salient fields. Used to surface "what was tried"
  /// across rounds so the model can avoid re-recommending
  /// approaches that already failed.
  static String _formatRecommendationCompact(Recommendation r) {
    switch (r) {
      case SetForcedOverride(:final symbol, :final artifactId, :final scope):
        final scopePart = (scope == null || scope.isEmpty) ? '' : ' scope=$scope';
        return 'set_forced_override $symbol ← #$artifactId$scopePart';
      case ClearForcedOverride(:final symbol):
        return 'clear_forced_override $symbol';
      case SetPreference(:final symbol, :final artifactId):
        return 'set_preference $symbol ← #$artifactId';
      case GenerateCustomHook(:final symbol, :final intent):
        final intentPart = (intent == null || intent.isEmpty)
            ? ''
            : ' intent="${_truncate(intent, 60)}"';
        return 'generate_custom_hook $symbol$intentPart';
      case AdjustIterationCap(:final newValue):
        return 'adjust_iteration_cap → $newValue';
      case SetGroupOverride(:final scope):
        return 'set_group_override $scope';
      case ClearGroupOverride(:final scope):
        return 'clear_group_override $scope';
    }
  }

  /// Delegates to the top-level [hookArtifactLabel] so the prompt
  /// catalog, the auto-tune engine's destructive-override backstop, and
  /// any future consumer share one labeler.
  static String _hookLabel(String code) => hookArtifactLabel(code);

  static String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n - 1)}…';

  /// Render the RAG-retrieved context block. Mirrors the
  /// hook-generator's retrieval: top-K hook chunks for the halt
  /// symbol's name + a pinned decompilation chunk for that symbol.
  /// Returns an empty string when [ragIndex] is null OR the index
  /// has no hits for this query (typical for projects without
  /// Ghidra installed).
  Future<String> _renderRetrievedContext(String? haltSymbol) async {
    final index = ragIndex;
    if (index == null) return '';
    if (haltSymbol == null) return '';
    // Same K as LlmHookGenerator's hook-example slice. Cosine
    // ranking against the halt-symbol name surfaces the most
    // relevant hook bodies — that's the "what other hooks have we
    // written for symbols like this" signal the LLM needs to pick
    // a sensible artifact_id.
    final hookHits = await index.retrieve(
      haltSymbol,
      topK: 5,
      kinds: {'hook'},
    );
    final decompHits = await index.retrieve(
      haltSymbol,
      topK: 1,
      kinds: {'decompilation'},
    );
    if (hookHits.isEmpty && decompHits.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln('## Retrieved context for `$haltSymbol`');
    if (decompHits.isNotEmpty) {
      buf.writeln('### Decompilation');
      buf.writeln('```');
      buf.writeln(_truncate(decompHits.first.text, 1200));
      buf.writeln('```');
    }
    if (hookHits.isNotEmpty) {
      buf.writeln('### Related hooks (top ${hookHits.length} by cosine)');
      for (final h in hookHits) {
        buf.writeln('- (score ${h.score.toStringAsFixed(2)}) '
            '${_truncate(h.text, 280)}');
      }
    }
    return buf.toString();
  }

  /// Find the first balanced `{...}` JSON object in [raw]. Returns
  /// the substring or null if none. Handles wrapping by markdown
  /// fences (` ```json ... ``` `), `<think>` blocks Gemma sometimes
  /// emits, and leading "Here is the result:" prose.
  static String? _extractJsonObject(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < raw.length; i++) {
      final c = raw[i];
      if (escape) {
        escape = false;
        continue;
      }
      if (c == r'\') {
        escape = true;
        continue;
      }
      if (c == '"') {
        inString = !inString;
        continue;
      }
      if (inString) continue;
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) {
          return raw.substring(start, i + 1);
        }
      }
    }
    return null;
  }

  String _targetLabel(OptimizationTarget t) {
    switch (t) {
      case OptimizationTarget.overallFidelity:
        return 'overall fidelity (whole-call-graph average)';
      case OptimizationTarget.coverageFidelity:
        return 'coverage fidelity (executed-functions average) — '
            'i.e. reach more code';
      case OptimizationTarget.subgraphFidelity:
        return 'subgraph fidelity (start→end path average) — '
            'i.e. tighten the configured path';
    }
  }

  static const _jsonContractExample = '''
{
  "prose": "Short summary of what these changes will do.",
  "recommendations": [
    {
      "kind": "set_forced_override",
      "rationale": "RCC_HSE_IsReady is masking the ready bit; pin to returnHook(1).",
      "symbol": "LL_RCC_HSE_IsReady",
      "artifact_id": 4,
      "scope": "HSE"
    }
  ]
}

Valid `kind` values: `set_forced_override` (with `symbol`,
`artifact_id`, optional `scope`); `clear_forced_override` (with
`symbol`); `set_preference` (with `symbol`, `artifact_id`);
`generate_custom_hook` (with `symbol`, optional `intent`);
`adjust_iteration_cap` (with `new_value`).

Every recommendation MUST carry a `rationale` (one sentence
explaining why).
''';

  static const _systemPrompt = '''
You are a firmware-emulation assistant inside Resect, a desktop
tool that iteratively replaces hardware-dependent functions in
firmware with Python hooks so the firmware can run in Renode.
After each synthesis run, you propose a set of structured
overlay edits the user reviews and applies.

Rules:
- Your entire reply MUST be a single JSON object. No markdown
  fences. No prose outside the JSON.
- Include a short `prose` field summarizing the batch in one
  sentence.
- Include a `recommendations` array — possibly empty when no
  changes are warranted. Empty array means "synthesis is done /
  no further action."
- Each recommendation has a `kind` discriminator and the
  per-kind fields documented in the prompt. Carry a `rationale`
  on every recommendation.
- Be specific. Name symbols. Don't recommend a category of
  change; recommend a concrete one.
- Prefer `set_forced_override` referencing an existing
  `artifact_id` from the "Available hook artifacts" catalog
  whenever a template would accomplish the goal (e.g. forcing a
  busy-ready flag to 1 → use the catalog's "Return 1" row).
- If no template from the catalog fits the symbol's actual
  behavior (e.g. it's a write whose effect can't be expressed as
  Return 0/1 or stateful read/write/increment), recommend
  `generate_custom_hook` with a concise `intent` describing what
  the hook needs to do (e.g. "clear the busy bit AND set the
  ready bit on the next call"). The auto-tune loop will invoke a
  separate LLM to author the hook body and seed it as a binding
  for the next synthesis run.
- The goal is to improve the run's coverage and fidelity metrics.
- SIGNALS & PRIORITY. Reason in this order:
  1. WHERE execution actually stopped — the "Halt point" /
     "Execution last reached" symbol and the "Recent call
     sequence" line (the path into it). These are real runtime
     positions, not guesses. If execution ended in an error/fault
     handler (e.g. `Error_Handler`, `*Fault*`), the real failure
     is the call JUST BEFORE it in the recent sequence — force
     THAT call to return the value its CALLER needs to proceed
     (status-returning init/check → the success STATUS, usually
     0/HAL_OK; `Is*` check → 1; `Get*` reader → the value it
     reads, never a blind 1). Do NOT hook the handler; that
     hides the failure without advancing coverage.
  2. WHETHER improvement is even possible — the "Reachable-code
     coverage" headroom. Near-zero headroom means little is left
     to win; a large headroom means real room.
  3. Only THEN the coverage frontier (executed functions with
     unreached callees). The frontier is a fallback, not the
     first move — do not default to forcing frontier ready-flags
     when the recent sequence points at a concrete failing call.
  A classifier tag like `iteration_fallback` on a symbol in the
  "## Decisions applied" block does NOT make that symbol the
  right focus by itself; recommend the change you'd defend as
  most likely to move the metrics on the next run.
- If after one pass through the context you cannot identify a
  defensible recommendation (e.g. metrics have plateau'd, prior
  rounds tried similar approaches without effect AND a custom
  hook isn't obviously warranted), return an empty
  `recommendations` array with a one-sentence `prose` field
  explaining why. Committing to "no action" is more useful than
  looping in self-doubt; the user reads your reasoning and can
  escalate manually from the Hook Database dialog.
- The user will review each recommendation individually. Quality
  over volume.
- Do not narrate. Get to the JSON.
''';
}

/// Canonical human label for a hook artifact body ("Return 0",
/// "Return 1", "Stateful increment (from N)", …). Same regex set as the
/// Hook Database dialog's `_hookLabel` and `metadata_panel.dart`'s copy
/// — derives the label from the body when the row's `name` column is
/// unset (which is the case for every default template). The label IS
/// the semantic identity of a template: the prompt catalog renders it
/// and the auto-tune engine's destructive-override backstop keys off it
/// ("Return 0" = a body-deleting skip), so there is exactly one
/// implementation.
/// Artifact id → human-readable effect label for every row in the DB:
/// the `name` column if set, else derived from the hook body via
/// [hookArtifactLabel]. Shared by the prompt catalog/overlay and the
/// report writer (so reports say "Stateful read (default 0)" instead
/// of a bare #id).
Future<Map<int, String>> artifactLabelsFor(ArtifactDatabase db) async {
  final all = await db.getAllArtifacts();
  return {
    for (final a in all)
      a.id: (a.name != null && a.name!.trim().isNotEmpty)
          ? a.name!.trim()
          : hookArtifactLabel(a.artifactData),
  };
}

String hookArtifactLabel(String code) {
  final trimmed = code.trim();
  final inc =
      RegExp(r"incrementVariable\('value',\s*(-?\d+)").firstMatch(trimmed);
  if (inc != null) return 'Stateful increment (from ${inc.group(1)})';
  final set = RegExp(r"setVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
  if (set != null) return 'Stateful write (value ${set.group(1)})';
  final get = RegExp(r"getVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
  if (get != null) return 'Stateful read (default ${get.group(1)})';
  if (trimmed.contains('Create(0,')) return 'Return 0';
  if (trimmed.contains('Create(1,')) return 'Return 1';
  final ret = RegExp(r'setReturnValue\(cpu,\s*(-?\d+)\)').firstMatch(trimmed);
  if (ret != null) return 'Return ${ret.group(1)}';
  final lastLine = trimmed.split('\n').last.trim();
  return lastLine.length > 40 ? '${lastLine.substring(0, 37)}…' : lastLine;
}
