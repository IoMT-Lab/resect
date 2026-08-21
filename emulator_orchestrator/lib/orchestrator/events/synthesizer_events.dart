import '../../data/models/synthesizer_result.dart';

/// Base class for synthesizer progress events.
///
/// These events are emitted during the automated hook substitution process
/// to track progress and communicate state changes.
abstract class SynthesizerEvent {
  final DateTime timestamp;
  final int iteration;

  SynthesizerEvent({required this.iteration}) : timestamp = DateTime.now();
}

/// Emitted at the start of each synthesis iteration.
class SynthesizerIterationStarted extends SynthesizerEvent {
  /// The current accumulated hook map being applied.
  final Map<String, String> currentHookMap;

  SynthesizerIterationStarted({
    required super.iteration,
    required this.currentHookMap,
  });
}

/// Emitted when a hook is selected for a problematic symbol.
class SynthesizerHookApplied extends SynthesizerEvent {
  /// The symbol that caused an unhandled access.
  final String symbol;

  /// The hook name being applied.
  final String hookName;

  /// Index of this hook in the symbol's hook list (0-based).
  final int hookIndex;

  /// Total number of hooks available for this symbol.
  final int totalHooksForSymbol;

  SynthesizerHookApplied({
    required super.iteration,
    required this.symbol,
    required this.hookName,
    required this.hookIndex,
    required this.totalHooksForSymbol,
  });
}

/// Emitted when all hooks for a symbol have been exhausted.
///
/// This causes the synthesizer to stop immediately.
class SynthesizerSymbolExhausted extends SynthesizerEvent {
  /// The symbol where all hooks were tried and failed.
  final String symbol;

  SynthesizerSymbolExhausted({
    required super.iteration,
    required this.symbol,
  });
}

/// Emitted right before the synthesizer asks the LLM to generate a
/// hook for a symbol whose artifact-DB candidates have all been
/// exhausted. The LLM call is the on-demand fallback path — typically
/// minutes long — so the UI uses this to swap its progress indicator
/// from "iteration N waiting…" to "LLM generating for $symbol…".
class SynthesizerLlmGenerating extends SynthesizerEvent {
  /// The symbol the LLM is generating a hook for.
  final String symbol;

  /// The model tag (e.g. `gemma4:e4b`) — surfaced so the UI can show
  /// which model is doing the work.
  final String modelTag;

  SynthesizerLlmGenerating({
    required super.iteration,
    required this.symbol,
    required this.modelTag,
  });
}

/// Emitted when the on-demand LLM fallback ends WITHOUT producing a
/// hook (empty/failed generation or an error from the client). Pairs
/// with [SynthesizerLlmGenerating] so the UI can leave its "LLM
/// generating…" state instead of sticking there until the next
/// iteration event.
class SynthesizerLlmFailed extends SynthesizerEvent {
  /// The symbol the LLM was asked to hook.
  final String symbol;

  /// Short human-readable reason (e.g. `empty response`, an exception
  /// message).
  final String reason;

  SynthesizerLlmFailed({
    required super.iteration,
    required this.symbol,
    required this.reason,
  });
}

/// Emitted after the LLM call returns successfully and the resulting
/// hook has been inserted as an artifact + binding. The synthesizer
/// then re-tries iteration with the new candidate in hand.
class SynthesizerLlmGenerated extends SynthesizerEvent {
  final String symbol;
  final int artifactId;
  final double fidelity;

  SynthesizerLlmGenerated({
    required super.iteration,
    required this.symbol,
    required this.artifactId,
    required this.fidelity,
  });
}

/// Emitted when synthesis completes (success or failure).
class SynthesizerCompleted extends SynthesizerEvent {
  final SynthesizerResult result;

  SynthesizerCompleted({
    required super.iteration,
    required this.result,
  });
}
