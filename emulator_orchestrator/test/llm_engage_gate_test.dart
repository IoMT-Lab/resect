import 'package:emulator_orchestrator/orchestrator/workflows/synthesizer_workflow.dart';
import 'package:test/test.dart';

/// The synthesizer engages the LLM once a symbol's specialized
/// candidates (score >= minScore) run out — not after the whole DB is
/// exhausted (which was unreachable under the iteration cap). These
/// lock the handoff predicate: specialized candidates are tried first;
/// the moment only generics (< minScore) remain, it's time to author.
void main() {
  group('specializedCandidatesExhausted', () {
    const t = 0.5; // matches _kLlmEngageMinScore (specialized = 0.5)

    test('specialized candidate still available → false (try it, no LLM)', () {
      expect(
        specializedCandidatesExhausted(
          nextIndex: 0,
          scoresDesc: [0.5, 0.2, 0.0],
          minScore: t,
        ),
        isFalse,
      );
    });

    test('only generics left → true (engage LLM)', () {
      expect(
        specializedCandidatesExhausted(
          nextIndex: 1, // 0.5 already tried; next is 0.2
          scoresDesc: [0.5, 0.2, 0.0],
          minScore: t,
        ),
        isTrue,
      );
    });

    test('no specialized candidate at all → true immediately (aggressive)', () {
      expect(
        specializedCandidatesExhausted(
          nextIndex: 0,
          scoresDesc: [0.2, 0.1, 0.0],
          minScore: t,
        ),
        isTrue,
      );
    });

    test('past the end of the list (full exhaustion) → true', () {
      expect(
        specializedCandidatesExhausted(
          nextIndex: 3,
          scoresDesc: [0.5, 0.2, 0.0],
          minScore: t,
        ),
        isTrue,
      );
    });

    test('empty candidate list → true', () {
      expect(
        specializedCandidatesExhausted(
          nextIndex: 0,
          scoresDesc: const [],
          minScore: t,
        ),
        isTrue,
      );
    });

    test('a score exactly at the threshold counts as specialized', () {
      // 0.5 is a binding/user artifact — must be tried, not skipped.
      expect(
        specializedCandidatesExhausted(
          nextIndex: 0,
          scoresDesc: [0.5],
          minScore: t,
        ),
        isFalse,
      );
    });
  });
}
