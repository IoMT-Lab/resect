import 'dart:async';
import 'dart:io';

import '../../data/services/lifecycle_service.dart';
import '../../data/services/callgraph_service.dart';
import '../../data/services/trace_service.dart';
import '../../data/services/filtered_trace_service.dart';
import '../../data/models/emulation_state.dart';
import '../exceptions/orchestrator_exceptions.dart';
import '../python_server.dart';

/// Handles the complex emulation lifecycle workflow.
///
/// Extracts the business logic from graph_viewer_widget.dart to make it testable
/// and reusable. This workflow coordinates multiple services to:
/// 1. Start/stop the Python server process
/// 2. Connect to lifecycle, callgraph, and trace services
/// 3. Load firmware with retry logic
/// 4. Start/pause/resume/reset emulation
class EmulationWorkflow {
  final LifecycleService lifecycleService;
  final CallgraphService callgraphService;
  final TraceService traceService;
  final FilteredTraceService filteredTraceService;
  final void Function(Process) onServerProcessCreated;
  final void Function(EmulationState) onStateChanged;
  final void Function(PausedEvent) onPauseEvent;

  static const int maxLoadRetries = 3;
  static const Duration retryDelay = Duration(seconds: 2);

  StreamSubscription? _traceSubscription;
  StreamSubscription? _filteredTraceSubscription;
  StreamSubscription? _pauseSubscription;
  StreamSubscription? _resumeSubscription;
  StreamSubscription? _resetSubscription;

  EmulationWorkflow({
    required this.lifecycleService,
    required this.callgraphService,
    required this.traceService,
    required this.filteredTraceService,
    required this.onServerProcessCreated,
    required this.onStateChanged,
    required this.onPauseEvent,
  });

  /// Start the full emulation workflow.
  ///
  /// This method coordinates the entire startup sequence:
  /// 1. Disconnect all services
  /// 2. Start new Python server process
  /// 3. Connect to lifecycle service
  /// 4. Reconnect callgraph service
  /// 5. Load firmware (with retry logic)
  /// 6. Setup trace services and subscriptions
  /// 7. Start emulation
  ///
  /// Throws [EmulationException] on any failure.
  Future<void> start({
    required String elfPath,
    String? baseImagePath,
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
    Map<String, String> resolvedOverrides = const {},
    String? memoryMapPath,
  }) async {
    Process? serverProcess;

    try {
      // Step 1: Disconnect all services
      _disconnectAllServices();

      // Step 2: Start new Python server process
      final pythonServer = PythonServer();
      await pythonServer.start();
      serverProcess = pythonServer.process;
      onServerProcessCreated(serverProcess!);

      // Step 3: Connect to lifecycle service
      await _connectLifecycleService();

      // Step 4: Reconnect callgraph service
      await _connectCallgraphService();

      // Step 5: Validate base image path
      if (baseImagePath == null || baseImagePath.isEmpty) {
        throw EmulationException('No base image (.repl) file specified in emulator');
      }

      // Step 6: Load firmware with retry logic
      await _loadFirmwareWithRetry(baseImagePath, elfPath);

      // Step 6a: Apply memory map (if specified)
      await _applyMemoryMap(memoryMapPath);

      // Step 6b: Apply forced hook overrides (if any)
      if (resolvedOverrides.isNotEmpty) {
        for (final entry in resolvedOverrides.entries) {
          final hookName = '${entry.key}_override';
          await lifecycleService.defineHook(hookName, entry.value);
        }
        await lifecycleService.mapHooks({
          for (final key in resolvedOverrides.keys) key: '${key}_override',
        });
        print('Applied ${resolvedOverrides.length} forced hook overrides');
      }

      // Step 7: Setup trace services and subscriptions
      await _setupTraceServices();

      // Step 8: Setup lifecycle event listeners
      await _setupLifecycleListeners();

      // Step 9: Start emulation
      await _startEmulation(
        startFrom: startFrom,
        endAt: endAt,
        pauseOnUnhandled: pauseOnUnhandled,
      );

      onStateChanged(EmulationState.running);
    } catch (e) {
      // Kill server process if startup failed partway through
      serverProcess?.kill();
      throw EmulationException('Failed to start emulation', e);
    }
  }

  /// Restart emulation using the existing server process.
  ///
  /// Instead of tearing down and recreating the server, this:
  /// 1. Resets Renode state via lifecycleService.reset()
  /// 2. Reloads firmware
  /// 3. Applies hook overrides
  /// 4. Reconnects trace services and subscriptions
  /// 5. Starts emulation
  ///
  /// Use this when the server process is already running (e.g., after synthesis).
  /// Falls back to full start() if the lifecycle service is not connected.
  Future<void> restart({
    required String elfPath,
    String? baseImagePath,
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
    Map<String, String> resolvedOverrides = const {},
    String? memoryMapPath,
  }) async {
    // If lifecycle service isn't connected, fall back to full start
    if (!lifecycleService.isConnected) {
      return start(
        elfPath: elfPath,
        baseImagePath: baseImagePath,
        startFrom: startFrom,
        endAt: endAt,
        pauseOnUnhandled: pauseOnUnhandled,
        resolvedOverrides: resolvedOverrides,
        memoryMapPath: memoryMapPath,
      );
    }

    try {
      // Cancel existing subscriptions (will re-create them)
      await _traceSubscription?.cancel();
      await _filteredTraceSubscription?.cancel();
      await _pauseSubscription?.cancel();
      await _resumeSubscription?.cancel();
      await _resetSubscription?.cancel();

      // Step 1: Reset Renode state
      await lifecycleService.reset();
      await Future.delayed(const Duration(milliseconds: 500));

      // Step 2: Validate base image path
      if (baseImagePath == null || baseImagePath.isEmpty) {
        throw EmulationException('No base image (.repl) file specified');
      }

      // Step 3: Reload firmware
      await _loadFirmwareWithRetry(baseImagePath, elfPath);

      // Step 3a: Apply memory map (if specified)
      await _applyMemoryMap(memoryMapPath);

      // Step 4: Apply forced hook overrides (if any)
      if (resolvedOverrides.isNotEmpty) {
        for (final entry in resolvedOverrides.entries) {
          final hookName = '${entry.key}_override';
          await lifecycleService.defineHook(hookName, entry.value);
        }
        await lifecycleService.mapHooks({
          for (final key in resolvedOverrides.keys) key: '${key}_override',
        });
        print('Applied ${resolvedOverrides.length} forced hook overrides');
      }

      // Step 5: Reconnect trace services (disconnect first for clean state)
      traceService.disconnect();
      filteredTraceService.disconnect();
      await _setupTraceServices();

      // Step 6: Setup lifecycle event listeners
      await _setupLifecycleListeners();

      // Step 7: Start emulation
      await _startEmulation(
        startFrom: startFrom,
        endAt: endAt,
        pauseOnUnhandled: pauseOnUnhandled,
      );

      onStateChanged(EmulationState.running);
    } catch (e) {
      throw EmulationException('Failed to restart emulation', e);
    }
  }

  /// Pause the running emulation.
  Future<void> pause() async {
    try {
      final result = await lifecycleService.pause();
      if (result[0] != true) {
        throw EmulationException('Failed to pause: ${result[1]}');
      }
      onStateChanged(EmulationState.paused);
    } catch (e) {
      throw EmulationException('Failed to pause emulation', e);
    }
  }

  /// Resume paused emulation.
  Future<void> resume() async {
    try {
      final result = await lifecycleService.start();
      if (result[0] != true) {
        throw EmulationException('Failed to resume: ${result[1]}');
      }
      onStateChanged(EmulationState.running);
    } catch (e) {
      throw EmulationException('Failed to resume emulation', e);
    }
  }

  /// Cancel all subscriptions and disconnect services.
  ///
  /// The orchestrator is responsible for killing the server process.
  Future<void> reset() async {
    // Cancel trace subscriptions
    await _traceSubscription?.cancel();
    await _filteredTraceSubscription?.cancel();
    await _pauseSubscription?.cancel();
    await _resumeSubscription?.cancel();
    await _resetSubscription?.cancel();

    _traceSubscription = null;
    _filteredTraceSubscription = null;
    _pauseSubscription = null;
    _resumeSubscription = null;
    _resetSubscription = null;

    // Disconnect services
    _disconnectAllServices();

    onStateChanged(EmulationState.stopped);
  }

  /// Clean up all subscriptions
  void dispose() {
    _traceSubscription?.cancel();
    _filteredTraceSubscription?.cancel();
    _pauseSubscription?.cancel();
    _resumeSubscription?.cancel();
    _resetSubscription?.cancel();
  }

  // =========================================================================
  // PRIVATE WORKFLOW STEPS
  // =========================================================================

  void _disconnectAllServices() {
    callgraphService.disconnect();
    lifecycleService.disconnect();
    traceService.disconnect();
    filteredTraceService.disconnect();
  }

  Future<void> _connectLifecycleService() async {
    print('Connecting to lifecycle service...');
    final connected = await lifecycleService.connect();
    if (!connected) {
      throw EmulationException('Failed to connect to Renode lifecycle service');
    }
    print('Connected to lifecycle service');
  }

  Future<void> _connectCallgraphService() async {
    await callgraphService.connect();
    print('Reconnected to callgraph service');
  }

  Future<void> _applyMemoryMap(String? memoryMapPath) async {
    if (memoryMapPath == null || memoryMapPath.isEmpty) return;
    print('Applying memory map: $memoryMapPath');
    final result = await lifecycleService.loadMemoryMap(memoryMapPath);
    if (result[0] != true) {
      throw EmulationException('Failed to load memory map: ${result[1]}');
    }
    print('Memory map applied successfully');
  }

  Future<void> _loadFirmwareWithRetry(String baseImagePath, String elfPath) async {
    print('Loading firmware: $baseImagePath and $elfPath');

    List<dynamic> loadResult = [false, 'Not attempted'];
    for (int attempt = 0; attempt < maxLoadRetries; attempt++) {
      loadResult = await lifecycleService.load(baseImagePath, elfPath);
      print('Load result (attempt ${attempt + 1}): $loadResult');

      if (loadResult[0] == true) {
        return; // Success!
      }

      if (attempt < maxLoadRetries - 1) {
        print('Load failed, waiting ${retryDelay.inSeconds} seconds before retry...');
        await Future.delayed(retryDelay);
      }
    }

    throw EmulationException('Failed to load firmware after $maxLoadRetries attempts: ${loadResult[1]}');
  }

  Future<void> _setupTraceServices() async {
    // Connect to trace service
    if (!traceService.isConnected) {
      print('Connecting to trace service...');
      await traceService.connect();
      print('Trace service connected: ${traceService.isConnected}');
    }

    // Subscribe to trace events
    _traceSubscription?.cancel();
    _traceSubscription = traceService.onTrace.listen((event) {
      // Event will be forwarded by orchestrator
    });

    // Connect to filtered trace service
    if (!filteredTraceService.isConnected) {
      print('Connecting to filtered trace service...');
      await filteredTraceService.connect();
      print('Filtered trace service connected: ${filteredTraceService.isConnected}');
    }

    // Subscribe to filtered trace events
    _filteredTraceSubscription?.cancel();
    _filteredTraceSubscription = filteredTraceService.onTrace.listen((event) {
      // Event will be forwarded by orchestrator
    });
  }

  /// Setup lifecycle event listeners
  Future<void> _setupLifecycleListeners() async {
    print('Setting up lifecycle event listeners...');

    // Subscribe to pause events
    _pauseSubscription?.cancel();
    _pauseSubscription = lifecycleService.onPaused.listen((event) {
      print('Pause event received: ${event.symbol}, user=${event.user}, unhandled=${event.unhandledAccess}');
      onStateChanged(EmulationState.paused);
      onPauseEvent(event);
    });

    // Subscribe to resume events
    _resumeSubscription?.cancel();
    _resumeSubscription = lifecycleService.onResumed.listen((_) {
      print('Resume event received');
      onStateChanged(EmulationState.running);
    });

    // Subscribe to reset events
    _resetSubscription?.cancel();
    _resetSubscription = lifecycleService.onReset.listen((_) {
      print('Reset event received');
      onStateChanged(EmulationState.stopped);
    });

    print('Lifecycle event listeners subscribed');
  }

  Future<void> _startEmulation({
    String? startFrom,
    List<String>? endAt,
    required bool pauseOnUnhandled,
  }) async {
    print('Starting emulation...');

    final result = await lifecycleService.start(
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
    );

    print('Start result: $result');
    if (result[0] != true) {
      throw EmulationException('Failed to start emulation: ${result[1]}');
    }
  }

  /// Get the trace subscription stream for external listening.
  Stream<TraceEvent>? get traceEvents => _traceSubscription != null ? traceService.onTrace : null;

  /// Get the filtered trace subscription stream for external listening.
  Stream<TraceEvent>? get filteredTraceEvents => _filteredTraceSubscription != null ? filteredTraceService.onTrace : null;
}
