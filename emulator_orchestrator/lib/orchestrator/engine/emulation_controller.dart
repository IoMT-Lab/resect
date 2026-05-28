import 'paused_event.dart';

/// Runtime execution control for an emulator engine.
///
/// Methods throw on failure (rather than returning success/result tuples).
/// Streams report lifecycle transitions emitted by the engine.
abstract class EmulationController {
  /// Connect the control channel. Returns true on success.
  Future<bool> connect();

  /// Disconnect the control channel. Idempotent.
  void disconnect();

  /// Whether the control channel is currently open.
  bool get isConnected;

  /// Broadcast stream of connection state changes.
  Stream<bool> get connectionStatus;

  /// Load firmware. Throws on failure.
  Future<void> load(String baseImage, String elfPath);

  /// Apply a memory map snapshot.
  Future<void> loadMemoryMap(String memoryMapPath);

  /// Begin execution. Returns once the engine acknowledges the start command;
  /// the [onStarted] stream fires when execution actually begins.
  Future<void> start({
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
  });

  Future<void> pause();
  Future<void> resume();
  Future<void> reset();

  /// Register a named hook implementation with the engine.
  ///
  /// [scope], when set, is the Renode Python execution context the hook runs
  /// in — hooks tagged with the same scope share `globals()`, which is how
  /// stateful read/write pairs and comms (i2c/spi/uart) hooks coordinate.
  /// Honored only by the patched Renode portable; stock builds drop it. Default
  /// `return0`/`return1` hooks pass `null` here and work on any build.
  Future<void> defineHook(String hookName, String hookCode, {String? scope});

  /// Replace listed symbols with previously-defined hooks.
  Future<void> mapHooks(Map<String, String> symbolToHookName);

  Stream<void> get onStarted;
  Stream<PausedEvent> get onPaused;
  Stream<void> get onResumed;
  Stream<void> get onReset;
}
