import '../../data/models/call_graph.dart';

/// Static analysis source — fetches call graphs from an ELF binary.
///
/// Concrete implementations may talk to a remote analysis server (the current
/// Renode/Python engine over Socket.IO) or perform analysis in-process (the
/// forthcoming Ghidra/Dart engine).
abstract class CallGraphSource {
  /// Establish whatever transport the implementation needs (e.g. open a
  /// Socket.IO connection). For in-process implementations this may be a
  /// no-op. Returns true on success.
  Future<bool> connect();

  /// Tear down the transport. Idempotent.
  void disconnect();

  /// Whether the source is currently usable.
  bool get isConnected;

  /// Broadcast stream of connection state changes (for UI status indicators).
  Stream<bool> get connectionStatus;

  /// Fetch the call graph for [elfPath]. Throws on failure.
  Future<CallGraph> getCallGraph(String elfPath);
}
