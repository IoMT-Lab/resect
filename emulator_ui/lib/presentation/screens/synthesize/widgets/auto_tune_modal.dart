import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/services/recommendation_service.dart';
import 'package:flutter/material.dart';

import '../llm_synthesis_orchestrator.dart';
import 'recommendation_review_row.dart';

/// Blocking modal dialog that hosts an active auto-tune session.
///
/// The orchestrator is passed in by the caller (the Auto-tune
/// button) along with a Future representing the session's
/// completion. The modal watches the orchestrator's [state] and
/// renders one of three states:
///
/// - **Running**: baseline / synthesizing / LLM streaming —
///   shows progress text + a Cancel button.
/// - **Reviewing**: per-row Accept / Reject / Edit + bulk
///   Accept-all / Reject-all + Apply-and-continue / Stop.
/// - **Parse failed**: raw text + Retry / Stop.
/// - **Done**: final summary card + Close.
///
/// The dialog cannot be dismissed via the system back button or
/// barrier tap; the user must use a footer button to terminate.
class AutoTuneModal extends StatefulWidget {
  const AutoTuneModal({
    required this.orchestrator,
    required this.sessionFuture,
    super.key,
  });

  final LlmSynthesisOrchestrator orchestrator;

  /// Resolves when `runAutoTune` completes (any termination
  /// reason). The modal closes itself once this future resolves
  /// AND the user has clicked Close on the Done card.
  final Future<void> sessionFuture;

  static Future<void> show({
    required BuildContext context,
    required LlmSynthesisOrchestrator orchestrator,
    required Future<void> sessionFuture,
  }) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AutoTuneModal(
          orchestrator: orchestrator,
          sessionFuture: sessionFuture,
        ),
      );

  @override
  State<AutoTuneModal> createState() => _AutoTuneModalState();
}

class _AutoTuneModalState extends State<AutoTuneModal> {
  /// Per-recommendation user decisions for the current review state.
  /// Keyed by recommendation index. Defaults to "accepted" so the
  /// happy path is one click (Apply-and-continue).
  final Map<int, UserAction> _actions = {};
  final Map<int, Recommendation> _edits = {};

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 720,
        height: 600,
        child: AnimatedBuilder(
          animation: widget.orchestrator,
          builder: (context, _) {
            final state = widget.orchestrator.state;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(state),
                const Divider(height: 1),
                Expanded(child: _body(state)),
                const Divider(height: 1),
                _footer(state),
              ],
            );
          },
        ),
      ),
    );
  }

  // -- Header ----------------------------------------------------------------

  Widget _header(AutoTuneState state) {
    final title = switch (state) {
      AutoTuneIdle() => 'Auto-tune — idle',
      AutoTuneRunningBaseline() => 'Auto-tune — baseline synthesis',
      AutoTuneSynthesizing(:final round) =>
        'Auto-tune — synthesizing round $round',
      AutoTuneLlmGenerating(:final round) =>
        'Auto-tune — LLM thinking (round $round)',
      AutoTuneReviewing(:final round) => 'Auto-tune — review round $round',
      AutoTuneParseFailed(:final round) =>
        'Auto-tune — parse failed (round $round)',
      AutoTuneFinished() => 'Auto-tune — done',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Text(title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              )),
    );
  }

  // -- Body ------------------------------------------------------------------

  Widget _body(AutoTuneState state) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: switch (state) {
        AutoTuneIdle() => const _IdleBody(),
        AutoTuneRunningBaseline() =>
          const _StatusBody(text: 'Running baseline synthesis…'),
        AutoTuneSynthesizing(:final round) =>
          _StatusBody(text: 'Synthesizing round $round…'),
        AutoTuneLlmGenerating(:final round, :final streamedText) =>
          _LlmStreamingBody(round: round, streamedText: streamedText),
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
        AutoTuneParseFailed(:final raw) => _ParseFailureBody(raw: raw),
        AutoTuneFinished() => _DoneBody(state: state),
      },
    );
  }

  // -- Footer ----------------------------------------------------------------

  Widget _footer(AutoTuneState state) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ..._footerButtons(state),
        ],
      ),
    );
  }

  List<Widget> _footerButtons(AutoTuneState state) {
    switch (state) {
      case AutoTuneIdle():
        return const [];
      case AutoTuneRunningBaseline():
      case AutoTuneSynthesizing():
      case AutoTuneLlmGenerating():
        return [
          TextButton(
            onPressed: () => widget.orchestrator.cancel(),
            child: const Text('Cancel'),
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
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ];
    }
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

class _IdleBody extends StatelessWidget {
  const _IdleBody();

  @override
  Widget build(BuildContext context) => const Center(
        child: Text('Waiting for the auto-tune session to start…'),
      );
}

class _StatusBody extends StatelessWidget {
  const _StatusBody({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      );
}

class _LlmStreamingBody extends StatelessWidget {
  const _LlmStreamingBody({
    required this.round,
    required this.streamedText,
  });

  final int round;
  final String streamedText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('LLM is composing round $round recommendations…',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            child: SelectableText(
              streamedText.isEmpty
                  ? '(waiting for first tokens)'
                  : streamedText,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
        ),
      ],
    );
  }
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
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (result.prose.isNotEmpty) ...[
          Text(result.prose,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                  )),
          const SizedBox(height: 12),
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
            Text('${result.recommendations.length} recommendation'
                '${result.recommendations.length == 1 ? '' : 's'}'),
          ],
        ),
        const SizedBox(height: 12),
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
}

class _ParseFailureBody extends StatelessWidget {
  const _ParseFailureBody({required this.raw});
  final String raw;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('The LLM emitted output that could not be parsed as JSON.',
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 4),
        const Text(
          'Click Retry to ask again, or Stop to end the session.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                raw.isEmpty ? '(empty)' : raw,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DoneBody extends StatelessWidget {
  const _DoneBody({required this.state});
  final AutoTuneFinished state;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_reasonHeadline(state.reason),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  )),
          const SizedBox(height: 8),
          Text(_reasonExplanation(state.reason),
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Text('Final round: ${state.finalRound}',
              style: Theme.of(context).textTheme.bodySmall),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(state.errorMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontFamily: 'monospace',
                  fontSize: 12,
                )),
          ],
        ],
      ),
    );
  }

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
      case AutoTuneFinishReason.cancelled:
        return 'Session cancelled.';
      case AutoTuneFinishReason.maxRounds:
        return 'Session ended — max rounds reached.';
      case AutoTuneFinishReason.budgetExhausted:
        return 'Session ended — wall-clock budget exhausted.';
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
      case AutoTuneFinishReason.cancelled:
        return 'The session was cancelled mid-run.';
      case AutoTuneFinishReason.maxRounds:
        return 'The configured maxRounds cap was reached.';
      case AutoTuneFinishReason.budgetExhausted:
        return 'The wall-clock budget elapsed before the loop could '
            'reach a terminal state.';
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
