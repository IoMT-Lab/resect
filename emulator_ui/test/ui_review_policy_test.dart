import 'dart:async';

import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:emulator_ui/presentation/screens/synthesize/llm_synthesis_orchestrator.dart';
import 'package:emulator_ui/presentation/screens/synthesize/ui_review_policy.dart';
import 'package:flutter_test/flutter_test.dart';

RecommendationResult _recs(List<Recommendation> recs) =>
    RecommendationResult(prose: 'p', recommendations: recs, parseFailure: false);

RecommendationResult _parseFailure() => const RecommendationResult(
    prose: '', recommendations: [], parseFailure: true, raw: 'garbage');

const _rec = SetPreference(rationale: 'try', symbol: 's1', artifactId: 3);

void main() {
  group('UiReviewPolicy — interactive', () {
    test('review emits AutoTuneReviewing, parks, resumes on submit',
        () async {
      final states = <AutoTuneState>[];
      final policy = UiReviewPolicy(emitState: states.add);

      final future = policy.review(_recs([_rec]), 2);
      expect(states.single, isA<AutoTuneReviewing>());
      expect((states.single as AutoTuneReviewing).round, 2);

      var resolved = false;
      unawaited(future.then((_) => resolved = true));
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse, reason: 'must park until the modal submits');

      policy.submitReview(const [
        RecommendationDecision(original: _rec, action: UserAction.accepted),
      ]);
      final outcome = await future;
      expect(outcome.userStopped, isFalse);
      expect(outcome.cancelled, isFalse);
      expect(outcome.decisions.single.action, UserAction.accepted);
    });

    test('stopAfterReview resolves with userStopped', () async {
      final policy = UiReviewPolicy(emitState: (_) {});
      final future = policy.review(_recs([_rec]), 1);
      policy.stopAfterReview(const [
        RecommendationDecision(original: _rec, action: UserAction.rejected),
      ]);
      final outcome = await future;
      expect(outcome.userStopped, isTrue);
    });

    test('cancel unblocks a pending review with cancelled=true', () async {
      final policy = UiReviewPolicy(emitState: (_) {});
      final future = policy.review(_recs([_rec]), 1);
      policy.cancel();
      final outcome = await future;
      expect(outcome.cancelled, isTrue);
      // Later reviews resolve cancelled immediately, without parking.
      final after = await policy.review(_recs([_rec]), 2);
      expect(after.cancelled, isTrue);
    });

    test('parse failure emits AutoTuneParseFailed; Retry/Stop resolve it',
        () async {
      final states = <AutoTuneState>[];
      final policy = UiReviewPolicy(emitState: states.add);

      final retry = policy.onParseFailure(_parseFailure(), 1);
      expect(states.single, isA<AutoTuneParseFailed>());
      policy.retryAfterParseFailure();
      expect(await retry, isTrue);

      final stop = policy.onParseFailure(_parseFailure(), 1);
      policy.stopAfterParseFailure();
      expect(await stop, isFalse);
    });

    test('parse-failure retries are bounded', () async {
      final policy = UiReviewPolicy(emitState: (_) {}, maxParseRetries: 2);
      for (var i = 0; i < 2; i++) {
        final f = policy.onParseFailure(_parseFailure(), 1);
        policy.retryAfterParseFailure();
        expect(await f, isTrue);
      }
      // Third failure exceeds the budget: resolves false WITHOUT a click.
      expect(await policy.onParseFailure(_parseFailure(), 1), isFalse);
    });
  });

  group('UiReviewPolicy — accept-all', () {
    test('review accepts everything synchronously, no state emitted',
        () async {
      final states = <AutoTuneState>[];
      final policy = UiReviewPolicy(emitState: states.add, interactive: false);
      final outcome = await policy.review(_recs([_rec, _rec]), 1);
      expect(outcome.decisions, hasLength(2));
      expect(outcome.decisions.every((d) => d.action == UserAction.accepted),
          isTrue);
      expect(states, isEmpty);
    });

    test('parse failure auto-retries once, then stops', () async {
      final policy = UiReviewPolicy(emitState: (_) {}, interactive: false);
      expect(await policy.onParseFailure(_parseFailure(), 1), isTrue);
      expect(await policy.onParseFailure(_parseFailure(), 1), isFalse);
    });
  });
}
