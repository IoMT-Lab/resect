import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/auto_tune_session_provider.dart';
import '../llm_synthesis_orchestrator.dart';
import '../ui_auto_tune_sink.dart' show AutoTuneRoundLine;
import 'partial_llm_json.dart';
import 'recommendation_review_row.dart';

/// Inline auto-tune session panel — lives in the Synthesize tab's
/// center pane ABOVE the normal synthesis view instead of floating
/// over it, so the trace sidebar, hook lists, and progress stay
/// readable while the session runs. Replaces the old blocking
/// AutoTuneModal.
///
/// Renders the session strip, the current phase (streaming panes /
/// review rows / parse-failure diagnostics / done summary), and the
/// phase's actions in the header. The trajectory chart + metrics +
/// compact report render separately below (AutoTuneSessionView) — this
/// panel is only the live control surface.
class AutoTunePanel extends StatefulWidget {
  const AutoTunePanel({
    required this.orchestrator,
    required this.onDismiss,
    super.key,
  });

  final LlmSynthesisOrchestrator orchestrator;

  /// Called when the user closes a finished session — the owner clears
  /// the active-orchestrator provider and disposes the orchestrator.
  final VoidCallback onDismiss;

  @override
  State<AutoTunePanel> createState() => _AutoTunePanelState();
}

class _AutoTunePanelState extends State<AutoTunePanel> {
  /// Per-recommendation user decisions for the current review state.
  /// Keyed by recommendation index. Defaults to "accepted" so the
  /// happy path is one click (Apply-and-continue).
  final Map<int, UserAction> _actions = {};
  final Map<int, Recommendation> _edits = {};

  /// Cancel was clicked; the engine aborts an in-flight LLM call
  /// immediately but a running synthesis finishes its current step —
  /// surface that instead of looking unresponsive.
  var _cancelRequested = false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.orchestrator,
        builder: (context, _) {
          final state = widget.orchestrator.state;
          final roundLines = widget.orchestrator.roundLines;
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.bgPanel,
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(state),
                if (roundLines.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _RoundHistoryStrip(lines: roundLines),
                ],
                const SizedBox(height: 12),
                _body(state),
              ],
            ),
          );
        },
      );

  // -- Header (title + phase actions) -----------------------------------------

  Widget _header(AutoTuneState state) {
    final status = switch (state) {
      AutoTuneIdle() => 'waiting to start',
      AutoTuneRunningBaseline() => 'baseline synthesis',
      AutoTuneSynthesizing(:final round) => 'synthesizing round $round',
      AutoTuneLlmGenerating(:final round) => 'LLM thinking (round $round)',
      AutoTuneGeneratingHook(:final round, :final symbol) =>
        'generating hook for $symbol (round $round)',
      AutoTuneReviewing(:final round) => 'review round $round',
      AutoTuneParseFailed(:final round) => 'parse failed (round $round)',
      AutoTuneFinished() => 'done',
    };
    return Row(children: [
      const Text(
        'AUTO-TUNE',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 2.5,
          color: AppTheme.textPrimary,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          _cancelRequested && state is! AutoTuneFinished
              ? '$status — cancelling…'
              : status,
          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      ..._actionsFor(state),
    ]);
  }

  List<Widget> _actionsFor(AutoTuneState state) {
    switch (state) {
      case AutoTuneIdle():
        return const [];
      case AutoTuneRunningBaseline():
      case AutoTuneSynthesizing():
      case AutoTuneLlmGenerating():
      case AutoTuneGeneratingHook():
        return [
          TextButton(
            onPressed: _cancelRequested
                ? null
                : () {
                    setState(() => _cancelRequested = true);
                    widget.orchestrator.cancel();
                  },
            child: Text(_cancelRequested ? 'Cancelling…' : 'Cancel'),
          ),
        ];
      case AutoTuneReviewing(:final result):
        return [
          TextButton(
            onPressed: () => _stop(result),
            child: const Text('Stop auto-tune'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => _applyAndContinue(result),
            child: const Text('Apply and continue'),
          ),
        ];
      case AutoTuneParseFailed():
        return [
          TextButton(
            onPressed: () => widget.orchestrator.stopAfterParseFailure(),
            child: const Text('Stop'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => widget.orchestrator.retryAfterParseFailure(),
            child: const Text('Retry'),
          ),
        ];
      case AutoTuneFinished():
        return [
          FilledButton(
            onPressed: widget.onDismiss,
            child: const Text('Close'),
          ),
        ];
    }
  }

  // -- Body ------------------------------------------------------------------

  /// Phase bodies get a bounded height so the panel composes into the
  /// tab's scrollable column (the old modal gave them the dialog's
  /// fixed height instead).
  Widget _body(AutoTuneState state) {
    final body = switch (state) {
      AutoTuneIdle() =>
        const Center(child: Text('Waiting for the auto-tune session to start…')),
      AutoTuneRunningBaseline() =>
        const _StatusBody(text: 'Running baseline synthesis…'),
      AutoTuneSynthesizing(:final round) =>
        _StatusBody(text: 'Synthesizing round $round…'),
      AutoTuneLlmGenerating(
        :final round,
        :final thinkingText,
        :final responseText,
      ) =>
        _LlmStreamingBody(
          round: round,
          thinkingText: thinkingText,
          responseText: responseText,
        ),
      AutoTuneGeneratingHook(
        :final round,
        :final thinkingText,
        :final responseText,
      ) =>
        _LlmStreamingBody(
          round: round,
          thinkingText: thinkingText,
          responseText: responseText,
          // Hook authoring streams Python, not the recommendation
          // JSON — show the code directly instead of parsing it.
          structured: false,
        ),
      AutoTuneReviewing(:final result) => _ReviewBody(
          result: result,
          actions: _actions,
          edits: _edits,
          onAction: (i, a) => setState(() => _actions[i] = a),
          onEdit: (i, edited) => setState(() {
            _edits[i] = edited;
            _actions[i] = UserAction.edited;
          }),
          onAcceptAll: () => setState(() {
            for (var i = 0; i < result.recommendations.length; i++) {
              _actions[i] = UserAction.accepted;
            }
          }),
          onRejectAll: () => setState(() {
            for (var i = 0; i < result.recommendations.length; i++) {
              _actions[i] = UserAction.rejected;
            }
          }),
        ),
      AutoTuneParseFailed(:final raw, :final kind, :final diagnostic) =>
        _ParseFailureBody(raw: raw, kind: kind, diagnostic: diagnostic),
      AutoTuneFinished() => _DoneBody(state: state),
    };
    // Done body sizes to its content; active phases get a fixed window.
    if (state is AutoTuneFinished || state is AutoTuneIdle) return body;
    return SizedBox(height: 260, child: body);
  }

  // -- Review actions --------------------------------------------------------

  void _applyAndContinue(RecommendationResult result) {
    final decisions = _buildDecisions(result);
    _actions.clear();
    _edits.clear();
    widget.orchestrator.submitReview(decisions);
  }

  void _stop(RecommendationResult result) {
    final decisions = _buildDecisions(result);
    _actions.clear();
    _edits.clear();
    widget.orchestrator.stopAfterReview(decisions);
  }

  List<RecommendationDecision> _buildDecisions(RecommendationResult result) {
    final out = <RecommendationDecision>[];
    for (var i = 0; i < result.recommendations.length; i++) {
      final original = result.recommendations[i];
      final action = _actions[i] ?? UserAction.accepted;
      final edited = action == UserAction.edited ? _edits[i] : null;
      out.add(RecommendationDecision(
        original: original,
        action: action,
        edited: edited,
      ));
    }
    return out;
  }
}

// -- Body widgets ------------------------------------------------------------

class _StatusBody extends StatelessWidget {
  const _StatusBody({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 12),
            Text(text,
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
          ],
        ),
      );
}

class _LlmStreamingBody extends ConsumerWidget {
  const _LlmStreamingBody({
    required this.round,
    required this.thinkingText,
    required this.responseText,
    this.structured = true,
  });

  final int round;
  final String thinkingText;
  final String responseText;

  /// True for the advisor's recommendation JSON (rendered styled via
  /// [parsePartialRecommendationJson], raw behind an expander); false
  /// for streams the user reads verbatim (hook-authoring Python).
  final bool structured;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labels = ref.watch(artifactLabelsProvider).valueOrNull ?? const {};
    final parsed = structured
        ? parsePartialRecommendationJson(responseText)
        : const PartialLlmParse();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(
                  structured
                      ? 'LLM is composing round $round recommendations…'
                      : 'LLM is authoring the hook…',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 10),
          // Structured view: `prose` and each recommendation render
          // styled as the model completes them; the raw JSON and the
          // reasoning stream live behind collapsed expanders below.
          if (structured && parsed.isEmpty)
            Text(
              responseText.isEmpty
                  ? (thinkingText.isEmpty
                      ? '(waiting for first tokens)'
                      : '(model is reasoning — recommendations will appear '
                          'when it starts responding)')
                  : '(composing…)',
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          if (parsed.prose != null)
            Text(parsed.prose!,
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.textPrimary,
                )),
          for (var i = 0; i < parsed.recs.length; i++) ...[
            const SizedBox(height: 8),
            _RecRow(index: i + 1, rec: parsed.recs[i], labels: labels),
          ],
          if (!structured)
            SelectableText(
              responseText.isEmpty
                  ? '(waiting for first tokens)'
                  : responseText,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: AppTheme.textPrimary,
              ),
            ),
          const SizedBox(height: 6),
          if (thinkingText.isNotEmpty)
            _CollapsedPane(
              title: 'Reasoning',
              icon: Icons.psychology_outlined,
              text: thinkingText,
              italic: true,
            ),
          if (structured && responseText.isNotEmpty)
            _CollapsedPane(
              title: 'Raw response',
              icon: Icons.code,
              text: responseText,
            ),
        ],
      ),
    );
  }
}

/// One parsed (possibly still-streaming) recommendation, rendered in
/// the same label-first vocabulary as the reports: kind chip, target,
/// artifact descriptor, rationale.
class _RecRow extends StatelessWidget {
  const _RecRow({required this.index, required this.rec, required this.labels});

  final int index;
  final PartialRec rec;
  final Map<int, String> labels;

  @override
  Widget build(BuildContext context) {
    final id = rec.artifactId;
    final artifact = id == null
        ? null
        : labels[id] == null
            ? '#$id'
            : '"${labels[id]}" (#$id)';
    final target = [
      if (rec.symbol != null) rec.symbol!,
      if (rec.scope != null && rec.kind.contains('group')) rec.scope!,
      if (artifact != null) '← $artifact',
      if (rec.newValue != null) '→ ${rec.newValue}',
    ].join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text('$index.',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMuted)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.accent),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(rec.kind,
                style: const TextStyle(fontSize: 10, color: AppTheme.accent)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(target,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: AppTheme.textPrimary,
                ),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        if (rec.rationale != null && rec.rationale!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text(rec.rationale!,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textMuted)),
          ),
      ],
    );
  }
}

/// Collapsed-by-default expander for the raw streams (reasoning / raw
/// JSON) — available on demand, never in the way.
class _CollapsedPane extends StatelessWidget {
  const _CollapsedPane({
    required this.title,
    required this.icon,
    required this.text,
    this.italic = false,
  });

  final String title;
  final IconData icon;
  final String text;
  final bool italic;

  @override
  Widget build(BuildContext context) => Theme(
        data: ThemeData.dark().copyWith(dividerColor: Colors.transparent),
        child: Material(
          color: Colors.transparent,
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            leading: Icon(icon, size: 14, color: AppTheme.textMuted),
            title: Text(title,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textMuted,
                  letterSpacing: 0.5,
                )),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      text,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontStyle:
                            italic ? FontStyle.italic : FontStyle.normal,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _ReviewBody extends StatelessWidget {
  const _ReviewBody({
    required this.result,
    required this.actions,
    required this.edits,
    required this.onAction,
    required this.onEdit,
    required this.onAcceptAll,
    required this.onRejectAll,
  });

  final RecommendationResult result;
  final Map<int, UserAction> actions;
  final Map<int, Recommendation> edits;
  final void Function(int index, UserAction action) onAction;
  final void Function(int index, Recommendation edited) onEdit;
  final VoidCallback onAcceptAll;
  final VoidCallback onRejectAll;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result.prose.isNotEmpty) ...[
            Text(result.prose,
                style: const TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: AppTheme.textMuted,
                )),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.done_all, size: 16),
                label: const Text('Accept all'),
                onPressed: onAcceptAll,
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.block, size: 16),
                label: const Text('Reject all'),
                onPressed: onRejectAll,
              ),
              const Spacer(),
              Text(
                  '${result.recommendations.length} recommendation'
                  '${result.recommendations.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              itemCount: result.recommendations.length,
              itemBuilder: (context, i) {
                final rec = result.recommendations[i];
                final action = actions[i] ?? UserAction.accepted;
                return RecommendationReviewRow(
                  recommendation: rec,
                  currentAction: action,
                  editedRecommendation: edits[i],
                  onAccept: () => onAction(i, UserAction.accepted),
                  onReject: () => onAction(i, UserAction.rejected),
                  onEdit: (edited) => onEdit(i, edited),
                );
              },
            ),
          ),
        ],
      );
}

class _ParseFailureBody extends StatelessWidget {
  const _ParseFailureBody({
    required this.raw,
    this.kind,
    this.diagnostic,
  });

  final String raw;
  final RecommendationParseFailureKind? kind;
  final RecommendationDiagnostic? diagnostic;

  @override
  Widget build(BuildContext context) {
    if (kind == RecommendationParseFailureKind.emptyResponse) {
      return _BudgetExhaustedBody(diagnostic: diagnostic);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('The LLM emitted output that could not be parsed as JSON.',
            style: TextStyle(color: Color(0xFFE57373))),
        const SizedBox(height: 4),
        const Text(
          'Click Retry to ask again, or Stop to end the session.',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.bgCanvas,
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                raw.isEmpty ? '(empty)' : raw,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Body for the `emptyResponse` parse-failure variant. The LLM
/// consumed its `num_predict` budget on the thinking phase and
/// never produced a response token. Render the diagnostic stats
/// from Ollama's final NDJSON line so the user knows exactly why
/// the round produced nothing.
class _BudgetExhaustedBody extends StatelessWidget {
  const _BudgetExhaustedBody({required this.diagnostic});

  final RecommendationDiagnostic? diagnostic;

  @override
  Widget build(BuildContext context) {
    final diag = diagnostic;
    const mono = TextStyle(
        fontFamily: 'monospace', fontSize: 12, color: AppTheme.textPrimary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'LLM ran out of budget before responding.',
          style: TextStyle(color: Color(0xFFE57373)),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.bgCanvas,
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Thinking chunks: ${diag?.thinkingChunks ?? "?"}',
                  style: mono),
              Text('Response tokens: ${diag?.responseTokens ?? "?"}',
                  style: mono),
              Text('Stop reason:     ${diag?.doneReason ?? "?"}', style: mono),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'The model spent its entire output budget on reasoning. '
          'Click Retry to ask again, or Stop to end the session.',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
      ],
    );
  }
}

class _DoneBody extends StatelessWidget {
  const _DoneBody({required this.state});
  final AutoTuneFinished state;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_reasonHeadline(state.reason),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              )),
          const SizedBox(height: 6),
          Text(_reasonExplanation(state.reason),
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
          const SizedBox(height: 6),
          Text('Final round: ${state.finalRound}',
              style:
                  const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(state.errorMessage!,
                style: const TextStyle(
                  color: Color(0xFFE57373),
                  fontFamily: 'monospace',
                  fontSize: 12,
                )),
          ],
        ],
      );

  String _reasonHeadline(AutoTuneFinishReason r) {
    switch (r) {
      case AutoTuneFinishReason.llmEmpty:
        return 'Session complete — LLM has no further recommendations.';
      case AutoTuneFinishReason.userStopped:
        return 'Session stopped by user.';
      case AutoTuneFinishReason.userRejectedAll:
        return 'Session ended — every recommendation was rejected.';
      case AutoTuneFinishReason.noProgressOnSymbol:
        return 'Session ended — synthesis kept failing on the same symbol.';
      case AutoTuneFinishReason.noCoverageProgress:
        return 'Session ended — coverage stopped improving.';
      case AutoTuneFinishReason.cancelled:
        return 'Session cancelled.';
      case AutoTuneFinishReason.maxRounds:
        return 'Session ended — max rounds reached.';
      case AutoTuneFinishReason.parseFailed:
        return 'Session ended — LLM output could not be parsed.';
      case AutoTuneFinishReason.baselineFailed:
        return 'Session ended — baseline synthesis failed.';
      case AutoTuneFinishReason.synthesisError:
        return 'Session ended — synthesis errored.';
      case AutoTuneFinishReason.llmError:
        return 'Session ended — LLM call errored.';
    }
  }

  String _reasonExplanation(AutoTuneFinishReason r) {
    switch (r) {
      case AutoTuneFinishReason.llmEmpty:
        return 'The LLM returned an empty recommendations array, '
            'which is the success-termination contract.';
      case AutoTuneFinishReason.userStopped:
        return 'You clicked Stop during the review step.';
      case AutoTuneFinishReason.userRejectedAll:
        return 'Every recommendation in the last round was rejected, '
            'so no overlay changes were applied.';
      case AutoTuneFinishReason.noProgressOnSymbol:
        return 'Two consecutive synthesis runs failed at the same '
            'symbol — the orchestrator stopped to avoid wasted compute.';
      case AutoTuneFinishReason.noCoverageProgress:
        return 'Successive rounds reproduced the same executed-symbol '
            'set (or every recommendation was already in effect) even '
            'after escalated feedback, so the session stopped early '
            'instead of burning rounds.';
      case AutoTuneFinishReason.cancelled:
        return 'The session was cancelled mid-run.';
      case AutoTuneFinishReason.maxRounds:
        return 'The configured maxRounds cap was reached.';
      case AutoTuneFinishReason.parseFailed:
        return 'The LLM emitted invalid JSON and the user declined '
            'to retry.';
      case AutoTuneFinishReason.baselineFailed:
        return 'The round-0 synthesis returned no manifest — typically '
            'a configuration or environment issue (no project loaded, '
            'no call graph, etc.).';
      case AutoTuneFinishReason.synthesisError:
        return 'A mid-loop synthesis run errored. See debug logs for '
            'the cause.';
      case AutoTuneFinishReason.llmError:
        return 'A mid-loop LLM call errored. See debug logs.';
    }
  }
}

/// Compact per-round session strip: one monospace line per completed
/// round (outcome, overall fidelity, executed count/delta). The full
/// story lives below in the session view and in the report files under
/// `autotune_reports/<timestamp>/`.
class _RoundHistoryStrip extends StatelessWidget {
  const _RoundHistoryStrip({required this.lines});

  final List<AutoTuneRoundLine> lines;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 76),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.bgCanvas,
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in lines)
                  Text(
                    'R${l.round}  ${l.outcome}  '
                    'fid ${l.overallFidelity.toStringAsFixed(3)}  '
                    'exec ${l.executedCount}'
                    '${l.executedDelta != 0 ? ' (${l.executedDelta > 0 ? '+' : ''}${l.executedDelta})' : ''}'
                    '${l.reverted ? '  REVERTED' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: l.reverted
                          ? const Color(0xFFE57373)
                          : AppTheme.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}
