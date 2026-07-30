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

  /// The most recent function the firmware *entered* (via function-call
  /// tracing), regardless of whether a pause occurred. Unlike the
  /// paused-event symbol, this survives a clean run that ends on the
  /// observation-window timeout — it is "where execution actually got
  /// to." Null before any entry or after a reset. Requires function
  /// tracing to be on (it is, via [load]'s `enableTracing`).
  String? get lastExecutedSymbol;

  /// The last N functions the firmware entered, oldest→newest (a
  /// bounded ring buffer), ending at [lastExecutedSymbol]. Lets a
  /// consumer see the PATH into where execution stopped — e.g.
  /// `[SystemClock_Config, HAL_RCC_OscConfig, Error_Handler]` — so the
  /// call that led to a sink is visible, not just the sink. Entries
  /// only (no exits); cleared on reset. Empty before any entry.
  List<String> get recentExecutionTrace;
}
