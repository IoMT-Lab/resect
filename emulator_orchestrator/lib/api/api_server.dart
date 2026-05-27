import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../data/services/artifact_library_service.dart';
import '../data/services/fidelity_calculator.dart';
import '../orchestrator/emulation_orchestrator.dart';
import '../orchestrator/engine/call_graph_source.dart';

/// HTTP API server wrapping the EmulationOrchestrator.
///
/// Exposes orchestrator operations as REST endpoints for programmatic access.
/// Can run alongside the Flutter GUI or headless (no UI).
class ApiServer {
  final EmulationOrchestrator orchestrator;
  final CallGraphSource callGraphSource;
  final ArtifactLibraryService artifactLibraryService;
  late final Router _router;

  HttpServer? _server;

  ApiServer({
    required this.orchestrator,
    required this.callGraphSource,
    required this.artifactLibraryService,
  }) {
    _router = Router()
      ..get('/status', _getStatus)
      ..post('/emulator', _createEmulator)
      ..get('/emulator', _getEmulator)
      ..post('/callgraph', _generateCallGraph)
      ..post('/synthesizer/run', _runSynthesizer)
      ..get('/synthesizer/events', _streamSynthesizerEvents)
      ..post('/emulation/start', _startEmulation)
      ..post('/emulation/stop', _resetEmulation)
      ..post('/fidelity', _computeFidelity);
  }

  Handler get handler => _router.call;

  /// Start the HTTP server on the given port.
  Future<HttpServer> serve({String address = 'localhost', int port = 8080}) async {
    final server = await shelf_io.serve(handler, address, port);
    _server = server;
    return server;
  }

  /// Stop the HTTP server.
  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  // ===========================================================================
  // ENDPOINTS
  // ===========================================================================

  /// GET /status — Current orchestrator state.
  Future<Response> _getStatus(Request request) async {
    final emulator = orchestrator.currentEmulator;
    return _jsonResponse({
      'state': orchestrator.state.name,
      'hasEmulator': emulator != null,
      'hasServerProcess': orchestrator.hasServerProcess,
      'hasUnsavedChanges': orchestrator.hasUnsavedChanges,
      if (emulator != null) 'emulator': {
        'id': emulator.id,
        'name': emulator.name,
        'elfFilePath': emulator.elfFilePath,
        'baseImagePath': emulator.baseImagePath,
      },
    });
  }

  /// POST /emulator — Create a new emulator.
  ///
  /// Body: {"name": "...", "elfPath": "...", "replPath": "...", "savePath": "..."}
  Future<Response> _createEmulator(Request request) async {
    final body = await _parseBody(request);
    if (body == null) return _errorResponse(400, 'Invalid JSON body');

    final name = body['name'] as String?;
    final elfPath = body['elfPath'] as String?;
    final replPath = body['replPath'] as String?;
    final savePath = body['savePath'] as String?;

    if (name == null || name.isEmpty) {
      return _errorResponse(400, 'Missing required field: name');
    }

    try {
      final emulator = await orchestrator.createEmulator(
        name: name,
        elfFilePath: elfPath,
        baseImagePath: replPath,
      );

      // Save if a path was provided
      if (savePath != null && savePath.isNotEmpty) {
        await orchestrator.saveEmulator(emulator, savePath: savePath);
      }

      return _jsonResponse(emulator.toJson(), statusCode: 201);
    } catch (e) {
      return _errorResponse(500, 'Failed to create emulator: $e');
    }
  }

  /// GET /emulator — Get the current emulator.
  Future<Response> _getEmulator(Request request) async {
    final emulator = orchestrator.currentEmulator;
    if (emulator == null) {
      return _errorResponse(404, 'No emulator loaded');
    }
    return _jsonResponse(emulator.toJson());
  }

  /// POST /callgraph — Generate call graph for an ELF file.
  ///
  /// Body: {"elfPath": "/path/to/firmware.elf"}
  Future<Response> _generateCallGraph(Request request) async {
    final body = await _parseBody(request);
    if (body == null) return _errorResponse(400, 'Invalid JSON body');

    final elfPath = body['elfPath'] as String?;
    if (elfPath == null || elfPath.isEmpty) {
      return _errorResponse(400, 'Missing required field: elfPath');
    }

    if (!await File(elfPath).exists()) {
      return _errorResponse(404, 'ELF file not found: $elfPath');
    }

    try {
      if (!callGraphSource.isConnected) {
        return _errorResponse(503, 'Callgraph service not connected. Start emulation first.');
      }

      final callGraph = await orchestrator.generateCallGraph(elfPath);
      return _jsonResponse(callGraph.toJson());
    } catch (e) {
      return _errorResponse(500, 'Failed to generate call graph: $e');
    }
  }

  /// POST /synthesizer/run — Run the automated hook synthesizer.
  ///
  /// Body: {"elfPath": "...", "replPath": "...", "startFrom": "...",
  ///        "endAt": ["sym1"], "maxIterations": 100}
  ///
  /// The ELF hash is computed automatically. The call graph must have been
  /// generated first (so the artifact DB has symbol records).
  /// Returns the synthesizer result with fidelity metrics included.
  Future<Response> _runSynthesizer(Request request) async {
    final body = await _parseBody(request);
    if (body == null) return _errorResponse(400, 'Invalid JSON body');

    final elfPath = body['elfPath'] as String?;
    final replPath = body['replPath'] as String?;
    final startFrom = body['startFrom'] as String?;
    final endAt = (body['endAt'] as List?)?.cast<String>();
    final maxIterations = body['maxIterations'] as int? ?? 100;
    final hookPreferencesRaw = body['hookPreferences'] as Map<String, dynamic>?;
    final hookPreferences = hookPreferencesRaw?.map(
      (k, v) => MapEntry(k, v as int),
    ) ?? <String, int>{};
    final hookOverridesRaw = body['hookOverrides'] as Map<String, dynamic>?;
    final hookOverrides = hookOverridesRaw?.map(
      (k, v) => MapEntry(k, v as int),
    ) ?? <String, int>{};
    final resolvedHooksRaw = body['resolvedHooks'] as Map<String, dynamic>?;
    final resolvedHooks = resolvedHooksRaw?.map(
      (k, v) => MapEntry(k, v as String),
    ) ?? <String, String>{};
    final memoryMapPath = body['memoryMapPath'] as String?;

    if (elfPath == null || elfPath.isEmpty) {
      return _errorResponse(400, 'Missing required field: elfPath');
    }
    if (replPath == null || replPath.isEmpty) {
      return _errorResponse(400, 'Missing required field: replPath');
    }

    if (!await File(elfPath).exists()) {
      return _errorResponse(404, 'ELF file not found: $elfPath');
    }

    try {
      // Compute ELF hash
      final elfHash = await artifactLibraryService.hashElfFile(elfPath);

      // Track executed symbols via filtered trace for fidelity
      final executedSymbols = <String>{};
      final traceSubscription = orchestrator.traceSource.filteredTraceStream.listen((event) {
        if (event.isEntry) {
          executedSymbols.add(event.symbol);
        }
      });

      final result = await orchestrator.runSynthesizer(
        elfPath: elfPath,
        baseImagePath: replPath,
        elfHash: elfHash,
        startFrom: startFrom,
        endAt: endAt,
        maxIterations: maxIterations,
        hookPreferences: hookPreferences,
        hookOverrides: hookOverrides,
        resolvedHooks: resolvedHooks,
        memoryMapPath: memoryMapPath,
      );

      await traceSubscription.cancel();

      final responseJson = result.toJson();

      // Compute fidelity metrics
      try {
        final callGraph = await orchestrator.generateCallGraph(elfPath);
        Set<String> subgraphSymbols = const {};
        if (startFrom != null && endAt != null && endAt.isNotEmpty) {
          subgraphSymbols = FidelityCalculator.subgraphBetween(
            callGraph, startFrom, endAt.first,
          ).union(executedSymbols);
        }
        final fidelity = FidelityCalculator.compute(
          callGraph: callGraph,
          hookedSymbols: result.resolvedHooks.keys.toSet(),
          traversedSymbols: executedSymbols,
          subgraphSymbols: subgraphSymbols,
        );
        responseJson['fidelity'] = fidelity.toJson();
      } catch (_) {
        // Fidelity is best-effort; don't fail the whole response
      }

      return _jsonResponse(responseJson);
    } catch (e) {
      return _errorResponse(500, 'Synthesizer failed: $e');
    }
  }

  /// GET /synthesizer/events — Server-Sent Events stream for synthesizer progress.
  Future<Response> _streamSynthesizerEvents(Request request) async {
    final controller = StreamController<List<int>>();

    final subscription = orchestrator.synthesizerWorkflow.events.listen((event) {
      final data = jsonEncode({
        'type': event.runtimeType.toString(),
        'iteration': event.iteration,
        'timestamp': event.timestamp.toIso8601String(),
      });
      controller.add(utf8.encode('data: $data\n\n'));
    });

    // Clean up when client disconnects
    controller.onCancel = subscription.cancel;

    return Response.ok(
      controller.stream,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      },
    );
  }

  /// POST /emulation/start — Start emulation with the Python backend.
  ///
  /// Body: {"elfPath": "...", "replPath": "...", "startFrom": "...",
  ///        "endAt": ["sym1"], "pauseOnUnhandled": true}
  Future<Response> _startEmulation(Request request) async {
    final body = await _parseBody(request);
    if (body == null) return _errorResponse(400, 'Invalid JSON body');

    final elfPath = body['elfPath'] as String?;
    final replPath = body['replPath'] as String?;
    final startFrom = body['startFrom'] as String?;
    final endAt = (body['endAt'] as List?)?.cast<String>();
    final pauseOnUnhandled = body['pauseOnUnhandled'] as bool? ?? true;
    final hookOverridesRaw = body['hookOverrides'] as Map<String, dynamic>?;
    final hookOverrides = hookOverridesRaw?.map(
      (k, v) => MapEntry(k, v as int),
    ) ?? <String, int>{};
    final resolvedHooksRaw = body['resolvedHooks'] as Map<String, dynamic>?;
    final resolvedHooks = resolvedHooksRaw?.map(
      (k, v) => MapEntry(k, v as String),
    ) ?? <String, String>{};
    final memoryMapPath = body['memoryMapPath'] as String?;

    if (elfPath == null || elfPath.isEmpty) {
      return _errorResponse(400, 'Missing required field: elfPath');
    }

    try {
      if (orchestrator.hasServerProcess) {
        await orchestrator.resetEmulation();
      }
      await orchestrator.startEmulation(
        elfPath: elfPath,
        baseImagePath: replPath,
        startFrom: startFrom,
        endAt: endAt,
        pauseOnUnhandled: pauseOnUnhandled,
        hookOverrides: hookOverrides,
        resolvedHooks: resolvedHooks,
        memoryMapPath: memoryMapPath,
      );
      return _jsonResponse({'success': true, 'state': orchestrator.state.name});
    } catch (e) {
      return _errorResponse(500, 'Failed to start emulation: $e');
    }
  }

  /// POST /emulation/stop — Reset/stop emulation.
  Future<Response> _resetEmulation(Request request) async {
    try {
      await orchestrator.resetEmulation();
      return _jsonResponse({'success': true, 'state': orchestrator.state.name});
    } catch (e) {
      return _errorResponse(500, 'Failed to stop emulation: $e');
    }
  }

  /// POST /fidelity — Compute fidelity metrics for a call graph.
  ///
  /// Body: {"elfPath": "/path/to/firmware.elf",
  ///        "hookedSymbols": ["sym1", "sym2"],
  ///        "startFrom": "main",
  ///        "endAt": ["target_func"],
  ///        "traversedSymbols": ["sym1", "sym3"]}
  Future<Response> _computeFidelity(Request request) async {
    final body = await _parseBody(request);
    if (body == null) return _errorResponse(400, 'Invalid JSON body');

    final elfPath = body['elfPath'] as String?;
    final hookedSymbols = (body['hookedSymbols'] as List?)
        ?.cast<String>().toSet() ?? <String>{};
    final startFrom = body['startFrom'] as String?;
    final endAt = (body['endAt'] as List?)?.cast<String>();
    final traversedSymbols = (body['traversedSymbols'] as List?)
        ?.cast<String>().toSet() ?? <String>{};

    if (elfPath == null || elfPath.isEmpty) {
      return _errorResponse(400, 'Missing required field: elfPath');
    }
    if (!await File(elfPath).exists()) {
      return _errorResponse(404, 'ELF file not found: $elfPath');
    }

    try {
      if (!callGraphSource.isConnected) {
        return _errorResponse(503,
            'Callgraph service not connected. Start emulation first.');
      }

      final callGraph = await orchestrator.generateCallGraph(elfPath);

      Set<String> subgraphSymbols = const {};
      if (startFrom != null && endAt != null && endAt.isNotEmpty) {
        subgraphSymbols = FidelityCalculator.subgraphBetween(
          callGraph, startFrom, endAt.first,
        ).union(traversedSymbols);
      }

      final fidelity = FidelityCalculator.compute(
        callGraph: callGraph,
        hookedSymbols: hookedSymbols,
        traversedSymbols: traversedSymbols,
        subgraphSymbols: subgraphSymbols,
      );

      return _jsonResponse(fidelity.toJson());
    } catch (e) {
      return _errorResponse(500, 'Failed to compute fidelity: $e');
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  Future<Map<String, dynamic>?> _parseBody(Request request) async {
    try {
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) return {};
      return jsonDecode(bodyStr) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Response _jsonResponse(Map<String, dynamic> data, {int statusCode = 200}) => Response(
      statusCode,
      body: jsonEncode(data),
      headers: {'Content-Type': 'application/json'},
    );

  Response _errorResponse(int statusCode, String message) => Response(
      statusCode,
      body: jsonEncode({'error': message}),
      headers: {'Content-Type': 'application/json'},
    );

}
