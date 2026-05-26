import '../../../data/services/filtered_trace_service.dart';
import '../../../data/services/trace_service.dart';
import '../trace_source.dart';

/// [TraceSource] backed by the Renode/Python `/trace` and `/trace_filtered`
/// Socket.IO namespaces.
class RenodeTraceSource implements TraceSource {
  final TraceService _trace;
  final FilteredTraceService _filtered;

  RenodeTraceSource({
    required TraceService traceService,
    required FilteredTraceService filteredTraceService,
  })  : _trace = traceService,
        _filtered = filteredTraceService;

  @override
  Future<bool> connect() async {
    final a = await _trace.connect();
    final b = await _filtered.connect();
    return a && b;
  }

  @override
  void disconnect() {
    _trace.disconnect();
    _filtered.disconnect();
  }

  @override
  bool get isConnected => _trace.isConnected && _filtered.isConnected;

  @override
  Stream<TraceEvent> get traceStream => _trace.onTrace;

  @override
  Stream<TraceEvent> get filteredTraceStream => _filtered.onTrace;
}
