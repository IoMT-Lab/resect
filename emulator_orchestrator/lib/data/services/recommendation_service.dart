import 'dart:async';
import 'dart:convert';

import '../database/artifact_database.dart';
import '../models/call_graph.dart';
import '../models/hook_decision_state.dart';
import '../models/recommendation.dart';
import '../models/round_snapshot.dart';
import '../models/synthesis_manifest.dart';
import 'coverage_frontier.dart';
import 'fidelity_delta.dart';
import 'last_run_insight_service.dart';
import 'llm_client.dart';
import 'llm_profiles.dart';
import 'rag_index.dart';

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
    return _parseOutput(raw, modelName, doneEvent);
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
  }) async {
    final resolvedMode = _resolveMode(mode, currentManifest);
    final buf = StringBuffer();

    // Base context — the advisor's context sections ONLY (no task
    // footer; this service appends its own job-specific task below).
    // Job 2 also gets the coverage frontier appended to the context.
    buf.writeln(insightService.composeContext(
      manifest: currentManifest,
      currentState: currentState,
      callGraph: callGraph,
      frontier:
          resolvedMode == RecommendationMode.job2Coverage ? frontier : const [],
    ));

    // Available hook artifacts — ground the model's
    // `set_forced_override.artifact_id` picks against real DB rows
    // instead of letting it invent values from the JSON contract
    // example. Without this section the LLM would pick e.g. id=12
    // for `gemma4:e4b` on this codebase, where id 12 was deleted by
    // `ArtifactLibraryService.reseedDefaults` and now points
    // nowhere.
    buf.writeln(await _renderArtifactCatalog());

    // Retrieved context — top-K hook-catalog chunks + the halt
    // symbol's decompilation chunk when the RAG index is wired.
    // Mirrors what [LlmHookGenerator] does for the new-hook flow.
    // Halt symbol comes from the shared cascade
    // (failedSymbol → lastPauseSymbol → chronological-last
    // decision) so this service and `LastRunInsightService` are
    // in lockstep.
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
      if (feedback.stalledCallers.isNotEmpty) {
        // Render each candidate with its unreached-callee count from
        // the frontier. NOTE the count is NOT a ranking: the spinning
        // wrapper is often the one with FEW unreached callees (it
        // stalls at its first internal gate), while high counts just
        // mean a big wrapper.
        String detail(String s) {
          for (final e in frontier) {
            if (e.symbol == s) {
              return '`$s` (${e.unexecutedCalleeCount} unreached '
                  'callees)';
            }
          }
          return '`$s`';
        }

        buf.writeln(
            '- Leaf-level fixes are already in effect and coverage is '
            'frozen. The blocker is an INLINED busy-wait inside one '
            'of these executed callers (no leaf function to hook): '
            '${feedback.stalledCallers.map(detail).join(', ')}.');
        buf.writeln(
            '- ESCALATE NOW: do not re-recommend leaf polls — emit '
            '`set_forced_override` with the "Return 0" artifact for '
            'EVERY stalled caller you can defend, in one batch. '
            'The callee count is NOT a ranking — do not prefer the '
            'large wrappers; the spin can hide in any of them. '
            "Skipping a wrapper's body unblocks everything after it; "
            'losing the coverage inside one wrapper to reach the code '
            'behind it is the right trade.');
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
      // Escalation replaces the playbook outright. The previous
      // round's leaf fixes are in effect and coverage is frozen — a
      // repeat is worthless, and the schema restricts symbols to the
      // stalled callers so the model cannot produce one.
      buf.writeln(
          'ESCALATION ROUND. Every leaf-level fix from the previous '
          'round is already in effect and coverage did not move — the '
          'blocker is an INLINED busy-wait inside one of the stalled '
          'callers listed in "## Feedback from last round" (the '
          'response schema only accepts those symbols this round). '
          'Emit `set_forced_override` with the "Return 0" artifact '
          'for the stalled caller(s) most likely to be spinning — '
          "skipping a wrapper's body unblocks everything after it. "
          "If a caller's behavior can't be faked by returning 0, "
          'use `generate_custom_hook` for it instead. Do NOT '
          're-recommend leaf polls.');
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
      buf.writeln(
          'The synthesizer did NOT crash, but coverage is low — the '
          'firmware is silently stuck in a busy-wait that never '
          'faults, so the reactive hook mechanism cannot see it. Your '
          'job is to force your way past it. Apply this playbook:');
      buf.writeln(
          '1. LEAF POLLS: the frontier annotations tell you what each '
          'callee IS — status poll, clock getter, counter, void '
          'writes — from its decompiled body; trust them over name '
          'guessing. A status poll busy-waits forever in emulation — '
          'force it with the RIGHT value: ready/active flags (names '
          'like `IsReady`, `IsActiveFlag_*`) → the "Return 1" '
          'artifact; busy flags → "Return 0"; clock/frequency getters '
          '→ an artifact returning a realistic core-clock frequency '
          'in Hz if the catalog has one — returning 1 breaks '
          'baud/prescaler math, so if no such artifact exists use '
          '`generate_custom_hook` with intent "return the chip\'s '
          'core clock frequency in Hz"; tick/time counters → the '
          'incrementing artifact so time advances. Annotations also '
          'carry status: promote the ones marked "NOT applied this '
          'run" to forced overrides — that is usually the single '
          'best move. Ones marked "ALREADY IN EFFECT" are done; '
          'recommending them again is a wasted round.');
      buf.writeln(
          '2. WRAPPER-SKIP: if the leaf polls are already forced and '
          'coverage still does not move, the spin is INLINED inside '
          'an executed frontier caller (an `*_Init`/`*Config` '
          'function with unreached callees). Force that CALLER itself '
          'with "Return 0" to skip its body — the code after it is '
          'worth far more than the code inside it.');
      buf.writeln(
          '3. HANDS OFF: comms-virtualized symbols (annotated '
          '`comms:*`) are already covered as a bus — never force '
          'them individually. Void register-writers (annotated '
          '"void register writes") gain nothing from a forced return '
          'value — skip them.');
      buf.writeln(
          '4. BOUNDARY ONLY: target only executed symbols or direct '
          'unreached callees on the frontier. A forced override on a '
          'symbol execution never reaches does nothing.');
      buf.writeln(
          'You may emit up to $maxRecommendations recommendations — '
          'batch every defensible fix for this round (e.g. force ALL '
          'the ready-flags on the frontier at once). Do not pad: '
          'every entry needs its own defensible rationale.');
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
  RecommendationResult _parseOutput(
    String raw,
    String model,
    LlmStreamDone? done,
  ) {
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
        if (r != null) recs.add(r);
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
  Future<Map<String, Object?>> buildRecommendationSchema({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    required RecommendationMode mode,
    required List<FrontierEntry> frontier,
    int maxRecommendations = defaultMaxRecommendations,
    RoundFeedback? feedback,
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
      final stalled = feedback.stalledCallers.toList()..sort();
      return _schemaShell(
        symbolEnum: stalled,
        catalogIds: catalogIds,
        maxRecommendations: maxRecommendations,
      );
    }

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
    // Overlay + manifest symbols are always legitimate targets.
    candidates.addAll(currentState.decisions.map((d) => d.symbol));
    candidates.addAll(currentManifest.decisions.map((d) => d.symbol));

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
    final symbolEnum = candidates.where((s) => s.isNotEmpty).toList()..sort();
    return _schemaShell(
      symbolEnum: symbolEnum,
      catalogIds: catalogIds,
      maxRecommendations: maxRecommendations,
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
    }
  }

  /// Same regex set as the Hook Database dialog's `_hookLabel` and
  /// `metadata_panel.dart`'s copy — derives a human-readable label
  /// from the hook body when the row's `name` column is unset
  /// (which is the case for every default template). Kept inline
  /// because the orchestrator package can't import UI files; the
  /// canonical labeler lives there. If a third copy shows up, the
  /// right move is to pull this into a shared util.
  static String _hookLabel(String code) {
    final trimmed = code.trim();
    final inc = RegExp(r"incrementVariable\('value',\s*(-?\d+)")
        .firstMatch(trimmed);
    if (inc != null) return 'Stateful increment (from ${inc.group(1)})';
    final set =
        RegExp(r"setVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
    if (set != null) return 'Stateful write (value ${set.group(1)})';
    final get =
        RegExp(r"getVariable\('value',\s*(-?\d+)\)").firstMatch(trimmed);
    if (get != null) return 'Stateful read (default ${get.group(1)})';
    if (trimmed.contains('Create(0,')) return 'Return 0';
    if (trimmed.contains('Create(1,')) return 'Return 1';
    final ret =
        RegExp(r'setReturnValue\(cpu,\s*(-?\d+)\)').firstMatch(trimmed);
    if (ret != null) return 'Return ${ret.group(1)}';
    final lastLine = trimmed.split('\n').last.trim();
    return lastLine.length > 40
        ? '${lastLine.substring(0, 37)}…'
        : lastLine;
  }

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
  The halt symbol named in "## Your task" is a SIGNAL of where
  the firmware is currently stuck — use it as a starting point
  for reasoning, but don't fixate on it. A classifier tag like
  `iteration_fallback` on a symbol in the "## Decisions applied"
  block does NOT make that symbol the right focus by itself;
  recommend the change you'd defend as most likely to move the
  metrics on the next run.
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
