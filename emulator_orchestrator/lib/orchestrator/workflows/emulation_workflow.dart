import 'dart:async';

import '../../data/models/emulation_state.dart';
import '../engine/call_graph_source.dart';
import '../engine/emulation_controller.dart';
import '../engine/engine_lifecycle.dart';
import '../engine/paused_event.dart';
import '../engine/trace_event.dart';
import '../engine/trace_source.dart';
import '../exceptions/orchestrator_exceptions.dart';

/// Handles the complex emulation lifecycle workflow.
///
/// Coordinates the engine abstractions to:
/// 1. Start/stop the engine process
/// 2. Connect to lifecycle, callgraph, and trace channels
/// 3. Load firmware with retry logic
/// 4. Start/pause/resume/reset emulation
class EmulationWorkflow {
  final EngineLifecycle engineLifecycle;
  final EmulationController emulationController;
  final CallGraphSource callGraphSource;
  final TraceSource traceSource;
  final void Function(EmulationState) onStateChanged;
  final void Function(PausedEvent) onPauseEvent;

  static const maxLoadRetries = 3;
  static const retryDelay = Duration(seconds: 2);

  StreamSubscription? _traceSubscription;
  StreamSubscription? _filteredTraceSubscription;
  StreamSubscription? _pauseSubscription;
  StreamSubscription? _resumeSubscription;
  StreamSubscription? _resetSubscription;

  EmulationWorkflow({
    required this.engineLifecycle,
    required this.emulationController,
    required this.callGraphSource,
    required this.traceSource,
    required this.onStateChanged,
    required this.onPauseEvent,
  });

  /// Start the full emulation workflow.
  ///
  /// This method coordinates the entire startup sequence:
  /// 1. Disconnect all channels
  /// 2. Start the engine process
  /// 3. Connect emulation control + callgraph
  /// 4. Load firmware (with retry logic)
  /// 5. Apply memory map + forced hook overrides
  /// 6. Connect trace channels + subscribe to lifecycle events
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
    try {
      _disconnectAllChannels();

      await engineLifecycle.start();

      await _connectEmulationController();
      await _connectCallGraphSource();

      if (baseImagePath == null || baseImagePath.isEmpty) {
        throw EmulationException('No base image (.repl) file specified in emulator');
      }

      await _loadFirmwareWithRetry(baseImagePath, elfPath);
      await _applyMemoryMap(memoryMapPath);
      await _applyForcedOverrides(resolvedOverrides);
      await _setupTraceChannels();
      await _setupLifecycleListeners();
      await _startEmulation(
        startFrom: startFrom,
        endAt: endAt,
        pauseOnUnhandled: pauseOnUnhandled,
      );

      onStateChanged(EmulationState.running);
    } catch (e) {
      // Tear down the engine if startup failed partway through.
      await engineLifecycle.stop();
      throw EmulationException('Failed to start emulation', e);
    }
  }

  /// Restart emulation using the existing engine process.
  ///
  /// Instead of tearing down and recreating the engine, this resets state,
  /// reloads firmware, reapplies hooks, and restarts.
  /// Falls back to full [start] if the control channel isn't connected.
  Future<void> restart({
    required String elfPath,
    String? baseImagePath,
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
    Map<String, String> resolvedOverrides = const {},
    String? memoryMapPath,
  }) async {
    if (!emulationController.isConnected) {
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
      await _traceSubscription?.cancel();
      await _filteredTraceSubscription?.cancel();
      await _pauseSubscription?.cancel();
      await _resumeSubscription?.cancel();
      await _resetSubscription?.cancel();

      await emulationController.reset();
      await Future.delayed(const Duration(milliseconds: 500));

      if (baseImagePath == null || baseImagePath.isEmpty) {
        throw EmulationException('No base image (.repl) file specified');
      }

      await _loadFirmwareWithRetry(baseImagePath, elfPath);
      await _applyMemoryMap(memoryMapPath);
      await _applyForcedOverrides(resolvedOverrides);

      // Reconnect trace channels for a clean slate.
      traceSource.disconnect();
      await _setupTraceChannels();

      await _setupLifecycleListeners();
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
      await emulationController.pause();
      onStateChanged(EmulationState.paused);
    } catch (e) {
      throw EmulationException('Failed to pause emulation', e);
    }
  }

  /// Resume paused emulation.
  Future<void> resume() async {
    try {
      await emulationController.resume();
      onStateChanged(EmulationState.running);
    } catch (e) {
      throw EmulationException('Failed to resume emulation', e);
    }
  }

  /// Cancel all subscriptions and disconnect channels.
  ///
  /// The orchestrator is responsible for stopping the engine process.
  Future<void> reset() async {
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

    _disconnectAllChannels();

    onStateChanged(EmulationState.stopped);
  }

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

  void _disconnectAllChannels() {
    callGraphSource.disconnect();
    emulationController.disconnect();
    traceSource.disconnect();
  }

  Future<void> _connectEmulationController() async {
    print('Connecting emulation control channel...');
    final connected = await emulationController.connect();
    if (!connected) {
      throw EmulationException('Failed to connect emulation control channel');
    }
    print('Emulation control channel connected');
  }

  Future<void> _connectCallGraphSource() async {
    await callGraphSource.connect();
    print('Reconnected to callgraph channel');
  }

  Future<void> _applyMemoryMap(String? memoryMapPath) async {
    if (memoryMapPath == null || memoryMapPath.isEmpty) return;
    print('Applying memory map: $memoryMapPath');
    await emulationController.loadMemoryMap(memoryMapPath);
    print('Memory map applied successfully');
  }

  Future<void> _applyForcedOverrides(Map<String, String> overrides) async {
    if (overrides.isEmpty) return;
    for (final entry in overrides.entries) {
      final hookName = '${entry.key}_override';
      await emulationController.defineHook(hookName, entry.value);
    }
    await emulationController.mapHooks({
      for (final key in overrides.keys) key: '${key}_override',
    });
    print('Applied ${overrides.length} forced hook overrides');
  }

  Future<void> _loadFirmwareWithRetry(String baseImagePath, String elfPath) async {
    print('Loading firmware: $baseImagePath and $elfPath');

    Object? lastError;
    for (var attempt = 0; attempt < maxLoadRetries; attempt++) {
      try {
        await emulationController.load(baseImagePath, elfPath);
        return;
      } catch (e) {
        lastError = e;
        print('Load failed (attempt ${attempt + 1}): $e');
        if (attempt < maxLoadRetries - 1) {
          print('Waiting ${retryDelay.inSeconds} seconds before retry...');
          await Future.delayed(retryDelay);
        }
      }
    }

    throw EmulationException(
      'Failed to load firmware after $maxLoadRetries attempts: $lastError',
    );
  }

  Future<void> _setupTraceChannels() async {
    if (!traceSource.isConnected) {
      print('Connecting trace channels...');
      await traceSource.connect();
      print('Trace channels connected: ${traceSource.isConnected}');
    }

    _traceSubscription?.cancel();
    _traceSubscription = traceSource.traceStream.listen((_) {
      // Forwarded by the orchestrator's own subscription.
    });

    _filteredTraceSubscription?.cancel();
    _filteredTraceSubscription = traceSource.filteredTraceStream.listen((_) {
      // Forwarded by the orchestrator's own subscription.
    });
  }

  Future<void> _setupLifecycleListeners() async {
    print('Setting up lifecycle event listeners...');

    _pauseSubscription?.cancel();
    _pauseSubscription = emulationController.onPaused.listen((event) {
      print('Pause event received: ${event.symbol}, user=${event.user}, unhandled=${event.unhandledAccess}');
      onStateChanged(EmulationState.paused);
      onPauseEvent(event);
    });

    _resumeSubscription?.cancel();
    _resumeSubscription = emulationController.onResumed.listen((_) {
      print('Resume event received');
      onStateChanged(EmulationState.running);
    });

    _resetSubscription?.cancel();
    _resetSubscription = emulationController.onReset.listen((_) {
      print('Reset event received');
      onStateChanged(EmulationState.stopped);
    });

    print('Lifecycle event listeners subscribed');
  }

  Future<void> _startEmulation({
    required bool pauseOnUnhandled, String? startFrom,
    List<String>? endAt,
  }) async {
    print('Starting emulation...');
    await emulationController.start(
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
    );
  }

  /// Trace event streams from the underlying [TraceSource], exposed for
  /// callers that want to listen externally.
  Stream<TraceEvent> get traceEvents => traceSource.traceStream;
  Stream<TraceEvent> get filteredTraceEvents => traceSource.filteredTraceStream;
}
