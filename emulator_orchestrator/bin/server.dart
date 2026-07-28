import 'dart:io';

import 'package:emulator_orchestrator/api/api_server.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/services/hooks/artifact_library_service.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_engine.dart';

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

  // Pure-Dart engine (renode-dart + callgraph-dart); no external backend.
  final engine = DartEngine();
  final emulatorRepository = EmulatorRepository();
  final artifactDb = ArtifactDatabase();
  final artifactLibraryService = ArtifactLibraryService(artifactDb);

  final orchestrator = EmulationOrchestrator(
    engineLifecycle: engine.lifecycle,
    emulationController: engine.controller,
    callGraphSource: engine.callGraphSource,
    traceSource: engine.traceSource,
    emulatorRepository: emulatorRepository,
    artifactDb: artifactDb,
  );

  // Call-graph extraction is in-process; mark the source ready so the
  // /callgraph endpoint's connection gate passes.
  await engine.callGraphSource.connect();

  // Create and start API server
  final apiServer = ApiServer(
    orchestrator: orchestrator,
    callGraphSource: engine.callGraphSource,
    artifactLibraryService: artifactLibraryService,
  );

  final server = await apiServer.serve(
    address: config.address,
    port: config.port,
  );

  print('Listening on http://${server.address.host}:${server.port}');
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
  Future<void> shutdown() async {
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

  _ServerConfig({
    required this.address,
    required this.port,
  });
}

_ServerConfig _parseArgs(List<String> args) {
  var port = 8080;
  var address = 'localhost';

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
      case '-p':
        if (i + 1 < args.length) {
          port = int.tryParse(args[++i]) ?? port;
        }
      case '--address':
      case '-a':
        if (i + 1 < args.length) {
          address = args[++i];
        }
      case '--help':
      case '-h':
        print('Usage: dart run bin/server.dart [options]');
        print('');
        print('Options:');
        print('  -p, --port <port>            HTTP port (default: 8080)');
        print('  -a, --address <address>      Bind address (default: localhost)');
        print('  -h, --help                   Show this help');
        exit(0);
    }
  }

  return _ServerConfig(
    address: address,
    port: port,
  );
}
