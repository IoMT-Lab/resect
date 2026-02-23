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

/// Emitted when synthesis completes (success or failure).
class SynthesizerCompleted extends SynthesizerEvent {
  final SynthesizerResult result;

  SynthesizerCompleted({
    required super.iteration,
    required this.result,
  });
}
