/// Quality scorer for generated hooks. Computes the layered metric
/// described in `/home/evan/.claude/plans/radiant-inventing-dream.md`
/// §Q2-answer.
///
/// **Stage 1 (this slice)**: only the gate is implemented —
/// `HookTestHarness` pass + (optional) classification invariant.
/// Score is binary: 0 if any gate sub-check fails; 1.0 otherwise.
/// Higher layers (emulator-progress, LLM-as-judge, style classifier)
/// land in subsequent slices and will weight into the final score
/// via the constants below.
///
/// The scorer is deliberately small and side-effect-free: it takes
/// the harness output + the classification (when one fired) and
/// returns a structured [HookQualityReport]. UI / telemetry callers
/// decide what to do with it.
library;

import '../hooks/hook_classifier.dart';
import 'hook_progress_runner.dart';
import 'hook_static_analyzer.dart';
import 'hook_test_harness.dart';
import 'llm_judge.dart';

/// Outcome of one gate sub-check, with a human-readable label and
/// optional violation string. The dialog renders these in the score
/// breakdown so the user sees exactly which sub-check failed.
class GateCheck {
  const GateCheck({
    required this.name,
    required this.passed,
    this.violation,
  });

  /// Short label, e.g. "harness", "invariant", "mod-set",
  /// "unmapped-access".
  final String name;

  /// True when this sub-check passed; false when it failed (and
  /// the gate-level result is therefore a failure).
  final bool passed;

  /// Human-readable explanation when `passed` is false. Surfaced
  /// verbatim in the dialog. Null when passed.
  final String? violation;
}

/// Full per-hook quality report.
class HookQualityReport {
  const HookQualityReport({
    required this.gatePassed,
    required this.gateChecks,
    required this.score,
    this.classification,
    this.harness,
    this.judgeScore,
    this.judgeJustification,
    this.progressScore,
    this.progressDetail,
  });

  /// True iff every gate sub-check passed. When false, [score] is 0.
  final bool gatePassed;

  /// Ordered list of gate sub-check outcomes. Always non-empty when
  /// scoring ran (at minimum it has the harness check).
  final List<GateCheck> gateChecks;

  /// Final 0.0–1.0 quality number. 0.0 when the gate fails. When
  /// the gate passes, this is the weighted sum of available
  /// layers — see [HookScorer.score] for the weighting policy.
  final double score;

  /// The classifier's verdict for the hook, if classification fired.
  /// Null when the LLM path produced the hook (or no target symbol
  /// was set). Surfaced so the dialog can render the rule name +
  /// template + invariant description.
  final ClassificationResult? classification;

  /// The harness result that was scored. Surfaced so the dialog can
  /// render the 10 return values + Renode log tail in the details
  /// panel.
  final HookTestResult? harness;

  /// Layer 3 score: 0.0–1.0 from the LLM-as-judge layer. Null when
  /// the judge didn't run (classifier fired → 1.0 by construction;
  /// or the gate failed → judge skipped).
  final double? judgeScore;

  /// One-line rationale from the judge. Concatenation of the two
  /// orderings' reasons. Null when the judge didn't run.
  final String? judgeJustification;

  /// Layer 2 score: 0.0–1.0 from the emulator-progress runner.
  /// Null when the runner hasn't been invoked yet or failed to
  /// produce a usable count. This is the **load-bearing**
  /// behavioural signal per the metric design — when it's
  /// available, it dominates the weighted score (weight 0.6).
  final double? progressScore;

  /// One-line summary of the progress measurement
  /// ("Δ=850000 instructions vs baseline"). Surfaced in the
  /// breakdown. Null when the runner didn't run.
  final String? progressDetail;

  /// Convenience for the dialog: the violation of the first failing
  /// check, or null if the gate passed.
  String? get firstViolation {
    for (final c in gateChecks) {
      if (!c.passed) return '${c.name}: ${c.violation ?? "<no detail>"}';
    }
    return null;
  }
}

/// Computes [HookQualityReport]s. Stateless; safe to share.
class HookScorer {
  const HookScorer();

  /// Build the report from a harness result + (optional)
  /// classification + (optional) static-check result + (optional)
  /// judge result. Sub-checks run in order; any gate-level failure
  /// flips `gatePassed` to false and the final score becomes 0.
  ///
  /// When the gate passes:
  /// - Classifier-fired hooks default to score 1.0 (the catalog
  ///   template is correct by construction; no judge needed).
  /// - LLM-path hooks scale the score by the judge's 0–1 verdict
  ///   when [judgeResult] is provided. When the judge didn't run
  ///   (still in flight, Ollama unreachable, etc.), the score
  ///   defaults to the gate-pass baseline of 1.0 — the dialog can
  ///   refresh the report once the judge completes.
  HookQualityReport score({
    required HookTestResult harness,
    ClassificationResult? classification,
    StaticCheckResult? staticResult,
    LlmJudgeResult? judgeResult,
    HookProgressResult? progressResult,
  }) {
    final checks = <GateCheck>[];

    // Sub-check 1: harness ran cleanly.
    final harnessPassed =
        harness.ranToCompletion && harness.errorMessage == null;
    checks.add(GateCheck(
      name: 'harness',
      passed: harnessPassed,
      violation: harnessPassed
          ? null
          : (harness.errorMessage ??
              'Bootstrap did not reach halt_loop.'),
    ));

    // Sub-check 2: classification invariant. Only fires when the
    // classifier produced a verdict; LLM-path hooks skip this check
    // until the LLM-path invariant feature lands (plan §Rule 8/9).
    if (classification != null) {
      final inv = classification.invariant.evaluate(harness.returnValues);
      checks.add(GateCheck(
        name: 'invariant',
        passed: inv.passed,
        violation: inv.violation,
      ));
    }

    // Sub-checks 3 + 4: static-analysis signals. The dialog runs
    // `HookStaticAnalyzer.evaluate(...)` against the candidate's
    // Python AST + the original function's decompilation + the
    // project's .repl, then passes the StaticCheckResult here.
    // Catalog-materialised hooks (returnHook, incrementHook, ...)
    // trivially pass both (empty mod-set, no literal address
    // accesses). The checks exist for the LLM-path hooks where
    // hallucinated writes / unmapped accesses are the real risk.
    if (staticResult != null) {
      checks.add(GateCheck(
        name: 'mod-set',
        passed: staticResult.modSetContained,
        violation: staticResult.modSetContained
            ? null
            : 'hallucinated writes: '
                '${staticResult.hallucinatedWrites.join(", ")} '
                '(original mod-set: '
                '${staticResult.originalWrites.isEmpty ? "<empty>" : staticResult.originalWrites.join(", ")})',
      ));
      checks.add(GateCheck(
        name: 'unmapped-access',
        passed: staticResult.unmappedAccessOk,
        violation: staticResult.unmappedAccessOk
            ? null
            : 'addresses outside any .repl-mapped region: '
                '${staticResult.unmappedAccesses.map((a) => "0x${a.toRadixString(16)}").join(", ")}',
      ));
    }

    final gatePassed = checks.every((c) => c.passed);

    // Layer 3 contribution. Classifier-fired hooks short-circuit
    // to 1.0 (catalog template = correct by construction). LLM-
    // path hooks use the judge's 0-1 score when available.
    double? judgeScore;
    String? judgeJustification;
    if (gatePassed) {
      if (classification != null) {
        judgeScore = 1.0;
        judgeJustification =
            'classifier-fired (catalog template; judge skipped)';
      } else if (judgeResult != null) {
        judgeScore = judgeResult.score;
        judgeJustification = judgeResult.justification;
      }
    }

    // Layer 2 contribution: emulator-progress score from
    // HookProgressRunner. The load-bearing behavioural signal —
    // dominates the weighting when present (per plan §Q2-answer:
    // weight 0.6).
    double? progressScore;
    String? progressDetail;
    if (gatePassed && progressResult != null &&
        progressResult.errorMessage == null) {
      progressScore = progressResult.score;
      final delta = progressResult.withHookInstructions -
          progressResult.baselineInstructions;
      progressDetail = 'Δ=$delta instructions vs baseline '
          '(with=${progressResult.withHookInstructions}, '
          'baseline=${progressResult.baselineInstructions})';
    }

    // Final weighting per plan §Q2-answer:
    //   gate × (0.6·progress + 0.3·judge + 0.1·style)
    // Style isn't wired yet. When a layer isn't available we
    // *renormalise* the remaining weights so a partial picture
    // doesn't artificially penalise a hook. Concretely:
    //   - Both present: 0.6·progress + 0.3·judge + 0.1·1.0 = 0.7·progress + 0.3·judge + 0.1
    //     (style baseline 1.0 until L4 lands; equivalent to
    //      adding 0.1 floor when gate passes)
    //   - Only judge: judge weight rescaled to 1.0
    //   - Only progress: progress weight rescaled to 1.0
    //   - Neither (classifier-fired skips both): 1.0
    final double finalScore;
    if (!gatePassed) {
      finalScore = 0.0;
    } else if (progressScore != null && judgeScore != null) {
      finalScore = 0.6 * progressScore + 0.3 * judgeScore + 0.1;
    } else if (progressScore != null) {
      finalScore = progressScore;
    } else if (judgeScore != null) {
      finalScore = judgeScore;
    } else {
      finalScore = 1.0;
    }
    return HookQualityReport(
      gatePassed: gatePassed,
      gateChecks: checks,
      score: finalScore,
      classification: classification,
      harness: harness,
      judgeScore: judgeScore,
      judgeJustification: judgeJustification,
      progressScore: progressScore,
      progressDetail: progressDetail,
    );
  }
}
