import 'synthesis_manifest.dart';

/// Result of a synthesizer run.
///
/// Contains the outcome of the automated hook substitution process,
/// including which hooks were successfully applied and whether the
/// firmware was able to run without unhandled access errors.
class SynthesizerResult {
  /// Whether the firmware ran without unhandled access errors.
  final bool success;

  /// Total number of iterations the synthesizer performed.
  final int totalIterations;

  /// Map of symbol name → hook name for hooks that resolved issues.
  final Map<String, String> resolvedHooks;

  /// Map of symbol name → hook code for all resolved hooks.
  ///
  /// This is the exportable form — contains the actual Python hook code
  /// rather than internal hook names.
  final Map<String, String> resolvedHookCode;

  /// The symbol that exhausted all hook candidates (if !success).
  final String? failedSymbol;

  /// The LAST symbol the firmware tried to call (via an unhandled
  /// access) before the synthesizer terminated, regardless of
  /// [success]. Mirrors [SynthesisManifest.lastPauseSymbol]. Useful
  /// when `success == true` but the firmware was still spinning on
  /// a busy-ready flag at the end — that's the symbol the LLM
  /// advisor should focus on.
  final String? lastPauseSymbol;

  /// Why the run stopped. Carries control-flow outcomes
  /// (`maxIterations`, `cancelled`) so they are never written into
  /// [failedSymbol] — which is reserved for a real call-graph symbol.
  /// Null on legacy results that pre-date the field.
  final SynthesisTerminationReason? terminationReason;

  /// The most recent function the firmware ENTERED before the run
  /// ended — "where execution actually got to." Unlike [failedSymbol]
  /// (last fault) and [lastPauseSymbol] (last unhandled-access pause),
  /// this is populated even on a clean-timeout success, where it is the
  /// symbol the firmware was in when it went quiescent. Null when
  /// function tracing produced no entry. See
  /// [EmulationController.lastExecutedSymbol].
  final String? finalExecutionSymbol;

  /// The last N functions entered before the run ended, oldest→newest
  /// (ends at [finalExecutionSymbol]). Shows the PATH into where
  /// execution stopped — e.g. the call that led to an error handler —
  /// so a consumer can reason about WHY, not just where. Null on legacy
  /// results. See [EmulationController.recentExecutionTrace].
  final List<String>? recentExecutionTrace;

  /// Total time the synthesis process took.
  final Duration totalDuration;

  /// Per-run decision record — populated by the synthesizer when an
  /// elfHash + elfFileName were available. Captures what hook was
  /// applied to each symbol, the decision kind (override / comms /
  /// warm-start / binding / iteration-fallback / llm-on-demand),
  /// provenance, fidelity, prior failed attempts, and any LLM
  /// telemetry. Null on synth runs that aren't carrying a firmware
  /// context (e.g. legacy tests).
  final SynthesisManifest? manifest;

  const SynthesizerResult({
    required this.success,
    required this.totalIterations,
    required this.resolvedHooks,
    required this.totalDuration, this.resolvedHookCode = const {},
    this.failedSymbol,
    this.lastPauseSymbol,
    this.terminationReason,
    this.finalExecutionSymbol,
    this.recentExecutionTrace,
    this.manifest,
  });

  factory SynthesizerResult.fromJson(Map<String, dynamic> json) => SynthesizerResult(
      success: json['success'] as bool,
      totalIterations: json['totalIterations'] as int,
      resolvedHooks: (json['resolvedHooks'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {},
      resolvedHookCode: (json['resolvedHookCode'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {},
      failedSymbol: json['failedSymbol'] as String?,
      lastPauseSymbol: json['lastPauseSymbol'] as String?,
      terminationReason:
          terminationReasonFromName(json['terminationReason'] as String?),
      finalExecutionSymbol: json['finalExecutionSymbol'] as String?,
      recentExecutionTrace: (json['recentExecutionTrace'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      totalDuration: Duration(milliseconds: json['totalDurationMs'] as int? ?? 0),
      manifest: json['manifest'] == null
          ? null
          : SynthesisManifest.fromJson(json['manifest'] as Map<String, dynamic>),
    );

  Map<String, dynamic> toJson() => {
      'success': success,
      'totalIterations': totalIterations,
      'resolvedHooks': resolvedHooks,
      'resolvedHookCode': resolvedHookCode,
      if (failedSymbol != null) 'failedSymbol': failedSymbol,
      if (lastPauseSymbol != null) 'lastPauseSymbol': lastPauseSymbol,
      if (terminationReason != null)
        'terminationReason': terminationReason!.name,
      if (finalExecutionSymbol != null)
        'finalExecutionSymbol': finalExecutionSymbol,
      if (recentExecutionTrace != null)
        'recentExecutionTrace': recentExecutionTrace,
      'totalDurationMs': totalDuration.inMilliseconds,
      if (manifest != null) 'manifest': manifest!.toJson(),
    };

  @override
  String toString() {
    if (success) {
      return 'SynthesizerResult: SUCCESS in $totalIterations iterations, '
          '${resolvedHooks.length} hooks applied';
    }
    return 'SynthesizerResult: FAILED at symbol "$failedSymbol" '
        'after $totalIterations iterations, '
        '${resolvedHooks.length} hooks applied before failure';
  }
}
