import '../services/lifecycle_service.dart';

/// Type of trace activity event
enum TraceActivityEventType {
  functionCall,  // Filtered trace: first call of a function
  paused,        // Emulation paused
  resumed,       // Emulation resumed
  reset,         // Emulation reset
}

/// Unified event model for the Trace Activity sidebar.
/// 
/// This represents both filtered trace events (first function calls)
/// and lifecycle events (pause, resume, reset) in a single timeline.
class TraceActivityEvent {
  final TraceActivityEventType type;
  final String? symbol;  // Function name (for functionCall and paused events)
  final DateTime timestamp;
  
  // Pause-specific fields
  final bool? userInitiated;      // true = user clicked pause, false = automatic (breakpoint/unhandled)
  final bool? unhandledAccess;    // true = paused due to unhandled memory access
  
  TraceActivityEvent._({
    required this.type,
    this.symbol,
    required this.timestamp,
    this.userInitiated,
    this.unhandledAccess,
  });

  /// Create a function call event (from filtered trace)
  factory TraceActivityEvent.functionCall(String symbol) {
    return TraceActivityEvent._(
      type: TraceActivityEventType.functionCall,
      symbol: symbol,
      timestamp: DateTime.now(),
    );
  }

  /// Create a pause event (from lifecycle service)
  factory TraceActivityEvent.paused(PausedEvent event) {
    return TraceActivityEvent._(
      type: TraceActivityEventType.paused,
      symbol: event.symbol,
      timestamp: DateTime.now(),
      userInitiated: event.user,
      unhandledAccess: event.unhandledAccess,
    );
  }

  /// Create a resume event
  factory TraceActivityEvent.resumed() {
    return TraceActivityEvent._(
      type: TraceActivityEventType.resumed,
      timestamp: DateTime.now(),
    );
  }

  /// Create a reset event
  factory TraceActivityEvent.reset() {
    return TraceActivityEvent._(
      type: TraceActivityEventType.reset,
      timestamp: DateTime.now(),
    );
  }

  /// Get a human-readable description of the event
  String get description {
    switch (type) {
      case TraceActivityEventType.functionCall:
        return symbol ?? 'Unknown';
      case TraceActivityEventType.paused:
        if (unhandledAccess == true) {
          return 'PAUSED: Unhandled access${symbol != null ? " at $symbol" : ""}';
        } else if (userInitiated == true) {
          return 'PAUSED: User requested${symbol != null ? " at $symbol" : ""}';
        } else {
          return 'PAUSED${symbol != null ? " at $symbol" : ""}';
        }
      case TraceActivityEventType.resumed:
        return 'RESUMED';
      case TraceActivityEventType.reset:
        return 'RESET';
    }
  }

  /// Get formatted time string (HH:MM:SS.mmm)
  String get timeString {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}
