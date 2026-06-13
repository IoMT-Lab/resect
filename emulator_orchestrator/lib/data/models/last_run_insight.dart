/// LLM-generated advisory text from the user's last synthesis run.
///
/// Generated on demand by [LastRunInsightService] off the run's
/// [SynthesisManifest] + the project's current [HookDecisionState].
/// Cached on the [Emulator] so reopening the project re-renders the
/// advisory without re-running the LLM.
///
/// The cache is keyed by [runIdAtGeneration]: when the next synthesis
/// produces a new `synthesizerRunId`, the cached insight goes stale.
/// Callers (the recommendation panel) compare `runIdAtGeneration`
/// against the live manifest's `synthesizerRunId` to decide whether to
/// show the cached text as-is or dim it with a "regenerate" badge.
class LastRunInsight {
  const LastRunInsight({
    required this.text,
    required this.runIdAtGeneration,
    required this.generatedAt,
    required this.modelTag,
  });

  /// The LLM's advisory text. Typically 1–3 sentences, no code blocks.
  final String text;

  /// `SynthesisManifest.synthesizerRunId` of the run this insight was
  /// generated from. Used by the UI to detect staleness.
  final String runIdAtGeneration;

  /// Wall-clock timestamp the insight was produced. Surfaced in the
  /// UI as "generated 2 minutes ago" / etc.
  final DateTime generatedAt;

  /// Model tag the LLM client used (e.g. `gemma4:e4b`). Surfaced in
  /// the UI as a small label so the user knows which model wrote it.
  final String modelTag;

  factory LastRunInsight.fromJson(Map<String, dynamic> json) =>
      LastRunInsight(
        text: json['text'] as String,
        runIdAtGeneration: json['run_id_at_generation'] as String,
        generatedAt: DateTime.parse(json['generated_at'] as String),
        modelTag: json['model_tag'] as String,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'run_id_at_generation': runIdAtGeneration,
        'generated_at': generatedAt.toIso8601String(),
        'model_tag': modelTag,
      };
}
