import 'dart:async';

import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:flutter/foundation.dart';

import 'llm_synthesis_orchestrator.dart' show AutoTuneParseFailed,
    AutoTuneReviewing, AutoTuneState;

/// The UI's [AutoTuneReviewPolicy]: pauses the engine's loop on a
/// Completer while the auto-tune modal collects the user's verdicts,
/// then resumes it with their decisions.
///
/// The review and parse-failure states are policy-owned by design
/// (the engine's `AutoTunePhase` deliberately excludes them), so this
/// class emits [AutoTuneReviewing] / [AutoTuneParseFailed] through
/// [emitState]. The engine's `cancel()` never unblocks a pending
/// review — [cancel] here must be called alongside it.
///
/// With [interactive] false the policy accepts every recommendation
/// synchronously (the CLI's accept-all behavior); parse failures are
/// still surfaced, auto-retried once, then stop.
class UiReviewPolicy implements AutoTuneReviewPolicy {
  UiReviewPolicy({
    required this.emitState,
    this.interactive = true,
    this.maxParseRetries = 5,
  });

  final void Function(AutoTuneState state) emitState;
  final bool interactive;

  /// Hard bound on parse-failure retries per session. The engine's
  /// retry loop re-asks the SAME round without incrementing it, so an
  /// unbounded "always retry" policy would spin forever.
  final int maxParseRetries;

  Completer<AutoTuneReviewOutcome>? _reviewCompleter;
  Completer<bool>? _parseFailureCompleter;
  var _parseRetries = 0;
  var _cancelled = false;

  @override
  Future<AutoTuneReviewOutcome> review(
      RecommendationResult result, int round) {
    if (_cancelled) {
      return Future.value(
          const AutoTuneReviewOutcome(decisions: [], cancelled: true));
    }
    if (!interactive) {
      return Future.value(AutoTuneReviewOutcome(decisions: [
        for (final rec in result.recommendations)
          RecommendationDecision(original: rec, action: UserAction.accepted),
      ]));
    }
    emitState(AutoTuneReviewing(round: round, result: result));
    final c = Completer<AutoTuneReviewOutcome>();
    _reviewCompleter = c;
    return c.future;
  }

  @override
  Future<bool> onParseFailure(RecommendationResult result, int round) {
    if (_cancelled) return Future.value(false);
    _parseRetries++;
    if (_parseRetries > maxParseRetries) {
      debugPrint('[AutoTune] round $round parse failure: retry budget '
          '($maxParseRetries) exhausted — stopping.');
      return Future.value(false);
    }
    final kind = result.parseFailureKind;
    final diag = result.diagnostic;
    if (kind == RecommendationParseFailureKind.emptyResponse) {
      debugPrint('[AutoTune] round $round parse failure: emptyResponse '
          '${diag?.toLogLine() ?? '(no diagnostic captured)'}');
    } else {
      debugPrint('[AutoTune] round $round parse failure: '
          '${kind?.name ?? "unknown"} '
          '(${(result.raw ?? "").length} bytes of raw output)');
    }
    emitState(AutoTuneParseFailed(
      round: round,
      raw: result.raw ?? '',
      kind: kind,
      diagnostic: diag,
    ));
    if (!interactive) {
      // Accept-all sessions don't wait for a click: one grace retry
      // (the CLI never retries; a watching user gets one), then stop.
      return Future.value(_parseRetries <= 1);
    }
    final c = Completer<bool>();
    _parseFailureCompleter = c;
    return c.future;
  }

  // -- Resolution API, delegated from the adapter's public surface ----------

  void submitReview(List<RecommendationDecision> decisions) {
    if (_reviewCompleter == null || _reviewCompleter!.isCompleted) return;
    _reviewCompleter!.complete(AutoTuneReviewOutcome(decisions: decisions));
  }

  void stopAfterReview(List<RecommendationDecision> decisions) {
    if (_reviewCompleter == null || _reviewCompleter!.isCompleted) return;
    _reviewCompleter!.complete(
        AutoTuneReviewOutcome(decisions: decisions, userStopped: true));
  }

  void retryAfterParseFailure() {
    if (_parseFailureCompleter == null ||
        _parseFailureCompleter!.isCompleted) {
      return;
    }
    _parseFailureCompleter!.complete(true);
  }

  void stopAfterParseFailure() {
    if (_parseFailureCompleter == null ||
        _parseFailureCompleter!.isCompleted) {
      return;
    }
    _parseFailureCompleter!.complete(false);
  }

  /// Unblock any pending review/parse-failure wait with a cancel
  /// outcome. Must accompany `AutoTuneEngine.cancel()` — the engine
  /// only checks its flag at the next checkpoint and never completes
  /// a policy's pending future itself.
  void cancel() {
    _cancelled = true;
    if (_reviewCompleter != null && !_reviewCompleter!.isCompleted) {
      _reviewCompleter!.complete(
          const AutoTuneReviewOutcome(decisions: [], cancelled: true));
    }
    if (_parseFailureCompleter != null &&
        !_parseFailureCompleter!.isCompleted) {
      _parseFailureCompleter!.complete(false);
    }
  }
}
