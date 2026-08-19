import '../data/models/synthesis_manifest.dart';

/// Per-symbol, per-attempt scratchpad the manifest builder consumes.
///
/// The synthesizer records one of these each time it applies a hook
/// to a symbol (pre-seeded or iteration-driven). The last entry in a
/// symbol's list becomes the manifest's `applied_hook`; earlier
/// entries become `previous_attempts`.
///
/// Extracted from `synthesizer_workflow.dart` so [buildManifest] can
/// be unit-tested against scripted attempt sets without driving Renode.
class ManifestAttempt {
  ManifestAttempt({
    required this.code,
    required this.kind,
    required this.source,
    this.artifactId,
    this.scope,
    this.fidelity,
    this.iterationIndex,
    this.llmInvocation,
  });

  final String code;
  final ManifestDecisionKind kind;
  final String source;
  final int? artifactId;
  final String? scope;
  final double? fidelity;
  final int? iterationIndex;
  final LlmInvocation? llmInvocation;
}

/// Build a [SynthesisManifest] from the recorded per-symbol attempts.
///
/// Pure function — `(workflow state) → SynthesisManifest`. The
/// synthesizer workflow calls this on every exit path (success,
/// exhausted symbol, max-iterations, cancellation, exception) so the
/// manifest is always available on the in-memory `SynthesizerResult`.
/// Unit-testable: build a [Map<String, List<ManifestAttempt>>] for
/// any synthesizer state and assert against the returned manifest.
SynthesisManifest buildManifest({
  required String elfHash,
  required String elfFileName,
  required String runId,
  required bool success,
  required int totalIterations,
  required Duration duration,
  required String? failedSymbol,
  required Map<String, List<ManifestAttempt>> attempts,
  String? lastPauseSymbol,
  SynthesisTerminationReason? terminationReason,
  String? finalExecutionSymbol,
  List<String>? recentExecutionTrace,
  List<IterationTiming>? timing,
  List<StopTiming>? stops,
  PhaseTimings? phaseTimings,
}) {
  final decisions = <ManifestDecision>[];
  final symbols = attempts.keys.toList()..sort();
  for (final symbol in symbols) {
    final list = attempts[symbol]!;
    if (list.isEmpty) continue;
    final applied = list.last;
    final priors = list.length > 1
        ? list
            .sublist(0, list.length - 1)
            .map((a) => PreviousAttempt(
                  artifactId: a.artifactId ?? -1,
                  outcome: 'unhandled_access_repeat',
                ))
            .toList()
        : null;
    decisions.add(ManifestDecision(
      symbol: symbol,
      appliedHook: AppliedHook(
        artifactId: applied.artifactId,
        bodyHash: AppliedHook.hashBody(applied.code),
        scope: applied.scope,
      ),
      decisionKind: applied.kind,
      decisionSource: applied.source,
      fidelityAtDecision: applied.fidelity,
      iterationIndex: applied.iterationIndex,
      previousAttempts: priors,
      llmInvocation: applied.llmInvocation,
    ));
  }
  return SynthesisManifest(
    manifestVersion: SynthesisManifest.currentVersion,
    elfHash: elfHash,
    elfFileName: elfFileName,
    synthesizerRunId: runId,
    result: ManifestRunResult(
      success: success,
      totalIterations: totalIterations,
      durationSeconds: duration.inMilliseconds / 1000.0,
    ),
    decisions: decisions,
    failedSymbol: failedSymbol,
    lastPauseSymbol: lastPauseSymbol,
    terminationReason: terminationReason,
    finalExecutionSymbol: finalExecutionSymbol,
    recentExecutionTrace: recentExecutionTrace,
    timing: timing,
    stops: stops,
    phaseTimings: phaseTimings,
  );
}
