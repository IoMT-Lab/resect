import 'dart:io';

import 'package:emulator_orchestrator/api/api_server.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/data/services/artifact_library_service.dart';
import 'package:emulator_orchestrator/data/services/callgraph_service.dart';
import 'package:emulator_orchestrator/data/services/filtered_trace_service.dart';
import 'package:emulator_orchestrator/data/services/lifecycle_service.dart';
import 'package:emulator_orchestrator/data/services/trace_service.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';

/// Headless API server for the emulation orchestrator.
///
/// Usage:
///   dart run bin/server.dart [--port 8080] [--backend-url http://localhost:12356]
///
/// This starts an HTTP API server without the Flutter GUI, enabling
/// programmatic control of emulator creation, call graph generation,
/// and synthesizer runs.
void main(List<String> args) async {
  final config = _parseArgs(args);

  print('Emulation API Server');
  print('====================');

  // Instantiate services (same as app_providers.dart but without Riverpod)
  final lifecycleService = LifecycleService(serverUrl: config.backendUrl);
  final callgraphService = CallgraphService(serverUrl: config.backendUrl);
  final traceService = TraceService(serverUrl: config.backendUrl);
  final filteredTraceService = FilteredTraceService(serverUrl: config.backendUrl);
  final emulatorRepository = EmulatorRepository();
  final artifactDb = ArtifactDatabase();
  final artifactLibraryService = ArtifactLibraryService(artifactDb);

  final orchestrator = EmulationOrchestrator(
    lifecycleService: lifecycleService,
    callgraphService: callgraphService,
    traceService: traceService,
    filteredTraceService: filteredTraceService,
    emulatorRepository: emulatorRepository,
    artifactDb: artifactDb,
  );

  // Create and start API server
  final apiServer = ApiServer(
    orchestrator: orchestrator,
    callgraphService: callgraphService,
    lifecycleService: lifecycleService,
    artifactLibraryService: artifactLibraryService,
  );

  final server = await apiServer.serve(
    address: config.address,
    port: config.port,
  );

  print('Listening on http://${server.address.host}:${server.port}');
  print('Backend URL: ${config.backendUrl}');
  print('');
  print('Endpoints:');
  print('  GET  /status              — Current state');
  print('  POST /emulator            — Create emulator');
  print('  GET  /emulator            — Get current emulator');
  print('  POST /callgraph           — Generate call graph');
  print('  POST /synthesizer/run     — Run synthesizer');
  print('  GET  /synthesizer/events  — SSE event stream');
  print('  POST /emulation/start     — Start emulation');
  print('  POST /emulation/stop      — Stop emulation');
  print('  POST /fidelity            — Compute fidelity metrics');
  print('');
  print('Press Ctrl+C to stop.');

  // Handle shutdown (SIGINT from Ctrl+C, SIGTERM from process managers)
  void shutdown() async {
    print('\nShutting down...');
    await apiServer.stop();
    orchestrator.dispose();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());
  ProcessSignal.sigterm.watch().listen((_) => shutdown());
}

class _ServerConfig {
  final String address;
  final int port;
  final String backendUrl;

  _ServerConfig({
    required this.address,
    required this.port,
    required this.backendUrl,
  });
}

_ServerConfig _parseArgs(List<String> args) {
  var port = 8080;
  var address = 'localhost';
  var backendUrl = 'http://localhost:12356';

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
      case '-p':
        if (i + 1 < args.length) {
          port = int.tryParse(args[++i]) ?? port;
        }
        break;
      case '--address':
      case '-a':
        if (i + 1 < args.length) {
          address = args[++i];
        }
        break;
      case '--backend-url':
      case '-b':
        if (i + 1 < args.length) {
          backendUrl = args[++i];
        }
        break;
      case '--help':
      case '-h':
        print('Usage: dart run bin/server.dart [options]');
        print('');
        print('Options:');
        print('  -p, --port <port>            HTTP port (default: 8080)');
        print('  -a, --address <address>      Bind address (default: localhost)');
        print('  -b, --backend-url <url>      Python backend URL (default: http://localhost:12356)');
        print('  -h, --help                   Show this help');
        exit(0);
    }
  }

  return _ServerConfig(
    address: address,
    port: port,
    backendUrl: backendUrl,
  );
}
