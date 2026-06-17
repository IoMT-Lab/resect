import 'dart:async';
import 'dart:convert';

import '../models/call_graph.dart';
import '../models/hook_decision_state.dart';
import '../models/recommendation.dart';
import '../models/round_snapshot.dart';
import '../models/synthesis_manifest.dart';
import 'fidelity_delta.dart';
import 'last_run_insight_service.dart';
import 'llm_client.dart';

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

/// What [RecommendationService.recommend] returns.
///
/// `prose` is the LLM's free-text summary (one sentence at most when
/// the model honored the system prompt; longer when it didn't).
/// `recommendations` is the typed action list the orchestrator's
/// review UI renders.
///
/// `parseFailure` is `true` when the LLM emitted text the parser
/// couldn't decode (invalid JSON, missing required fields,
/// non-string `kind`, etc.). When set, `raw` carries the verbatim
/// LLM output so the modal can show it in a "parse failed" notice
/// with a Retry button. `recommendations` is empty on parse
/// failure — the orchestrator treats parseFailure as terminal-for-
/// this-round.
class RecommendationResult {
  const RecommendationResult({
    required this.prose,
    required this.recommendations,
    required this.parseFailure,
    this.raw,
    this.model,
  });

  final String prose;
  final List<Recommendation> recommendations;
  final bool parseFailure;
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
  });

  final LlmClient llmClient;

  /// Borrowed for its prompt composer. The advisor's input section
  /// (manifest summary, decisions, call-graph neighborhood, current
  /// overlay) is exactly the context this service needs too, plus
  /// the round-history + JSON-output additions in [composePrompt].
  final LastRunInsightService insightService;

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
    int numPredict = 1024,
    void Function(String token)? onToken,
  }) async {
    final prompt = composePrompt(
      currentManifest: currentManifest,
      currentState: currentState,
      callGraph: callGraph,
      history: history,
      optimizationTarget: optimizationTarget,
    );

    final modelName = llmClient.model;
    final buf = StringBuffer();
    await for (final tok in llmClient.generate(
      prompt,
      system: _systemPrompt,
      modelOverride: modelName,
      numPredict: numPredict,
    )) {
      buf.write(tok);
      onToken?.call(tok);
    }
    final raw = buf.toString();
    return _parseOutput(raw, modelName);
  }

  /// Compose the LLM prompt. Public for headless dump tools (mirrors
  /// the advisor service's pattern).
  String composePrompt({
    required SynthesisManifest currentManifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    List<RoundSnapshot> history = const [],
    OptimizationTarget? optimizationTarget,
  }) {
    final buf = StringBuffer();

    // Base context — same shape the advisor uses (manifest summary,
    // decisions, call-graph neighborhood, current overlay).
    buf.writeln(insightService.composePrompt(
      manifest: currentManifest,
      currentState: currentState,
      callGraph: callGraph,
    ));

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
        }
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
    buf.writeln(
        'Respond with a single JSON object on one line (no markdown '
        'fences, no commentary outside the JSON). Shape:');
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
  /// `<think>...</think>` blocks, extra braces). On any parse error
  /// returns a failure record with `parseFailure: true` and the
  /// verbatim raw text so the UI can surface it.
  RecommendationResult _parseOutput(String raw, String model) {
    final jsonRegion = _extractJsonObject(raw);
    if (jsonRegion == null) {
      return RecommendationResult(
        prose: raw.trim(),
        recommendations: const [],
        parseFailure: true,
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
        raw: raw,
        model: model,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      return RecommendationResult(
        prose: raw.trim(),
        recommendations: const [],
        parseFailure: true,
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
    return RecommendationResult(
      prose: prose,
      recommendations: recs,
      parseFailure: false,
      raw: raw,
      model: model,
    );
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
- The user will review each recommendation individually. Quality
  over volume.
- Do not narrate. Get to the JSON.
''';
}
