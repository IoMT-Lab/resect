/// Engine process lifecycle — start/stop the underlying emulation engine
/// (today: a Python/Renode subprocess; tomorrow: an in-process Ghidra/Dart
/// engine).
///
/// Connecting individual capability streams (call graph, emulation control,
/// trace) is each capability's own responsibility — `EngineLifecycle` only
/// owns the process/runtime itself.
abstract class EngineLifecycle {
  /// True when the engine process/runtime is alive.
  bool get isRunning;

  /// Start the engine. Implementations should be a no-op if already running,
  /// or throw an engine-specific exception.
  Future<void> start({
    String? engineDir,
    int serverPort,
    int renodePort,
    String loggingPath,
    Duration startupDelay,
  });

  /// Stop the engine. Idempotent.
  Future<void> stop();
}
