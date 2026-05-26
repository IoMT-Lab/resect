import 'trace_event.dart';

/// Real-time function entry/exit observation during emulation.
///
/// Two streams are exposed: a complete stream (every entry/exit) and a
/// filtered stream (first call of each function only). Some engines may
/// implement one in terms of the other.
abstract class TraceSource {
  /// Connect both trace channels. Returns true on success.
  Future<bool> connect();

  /// Disconnect both trace channels. Idempotent.
  void disconnect();

  /// Whether trace channels are open.
  bool get isConnected;

  /// Every function entry and exit.
  Stream<TraceEvent> get traceStream;

  /// First call of each function only (cheaper for execution-coverage UIs).
  Stream<TraceEvent> get filteredTraceStream;
}
