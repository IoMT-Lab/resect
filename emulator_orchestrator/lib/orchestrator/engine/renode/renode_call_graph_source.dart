import '../../../data/models/call_graph.dart';
import '../../../data/services/callgraph_service.dart';
import '../call_graph_source.dart';

/// [CallGraphSource] backed by the Renode/Python `/callgraph` Socket.IO
/// namespace.
class RenodeCallGraphSource implements CallGraphSource {
  final CallgraphService _service;

  RenodeCallGraphSource(this._service);

  @override
  Future<bool> connect() => _service.connect();

  @override
  void disconnect() => _service.disconnect();

  @override
  bool get isConnected => _service.isConnected;

  @override
  Stream<bool> get connectionStatus => _service.connectionStatus;

  @override
  Future<CallGraph> getCallGraph(String elfPath) async {
    final response = await _service.getCallgraph(elfPath);
    return CallGraph.fromJson(elfPath, response);
  }
}
