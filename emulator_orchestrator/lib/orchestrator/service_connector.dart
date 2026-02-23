import 'dart:io';

import '../data/services/callgraph_service.dart';
import '../data/services/lifecycle_service.dart';
import '../data/services/trace_service.dart';
import '../data/services/filtered_trace_service.dart';

/// Connects Socket.IO services to the Python backend.
///
/// Reusable helper for both the Flutter app and headless CLI tools.
class ServiceConnector {
  /// Connect the callgraph service. Required for call graph generation.
  static Future<bool> connectCallgraph(CallgraphService service) async {
    stderr.writeln('Connecting callgraph service...');
    final connected = await service.connect();
    if (!connected) {
      stderr.writeln('Failed to connect callgraph service');
    }
    return connected;
  }

  /// Connect the lifecycle service. Required for emulation and synthesizer.
  static Future<bool> connectLifecycle(LifecycleService service) async {
    stderr.writeln('Connecting lifecycle service...');
    final connected = await service.connect();
    if (!connected) {
      stderr.writeln('Failed to connect lifecycle service');
    }
    return connected;
  }

  /// Connect trace services. Optional for CLI (needed for trace monitoring).
  static Future<bool> connectTraceServices({
    required TraceService traceService,
    required FilteredTraceService filteredTraceService,
  }) async {
    stderr.writeln('Connecting trace services...');
    final traceOk = await traceService.connect();
    final filteredOk = await filteredTraceService.connect();
    return traceOk && filteredOk;
  }

  /// Connect all services needed for full emulation + synthesizer.
  static Future<bool> connectAll({
    required CallgraphService callgraphService,
    required LifecycleService lifecycleService,
    required TraceService traceService,
    required FilteredTraceService filteredTraceService,
  }) async {
    final callgraphOk = await connectCallgraph(callgraphService);
    if (!callgraphOk) return false;

    final lifecycleOk = await connectLifecycle(lifecycleService);
    if (!lifecycleOk) return false;

    await connectTraceServices(
      traceService: traceService,
      filteredTraceService: filteredTraceService,
    );

    return true;
  }
}
