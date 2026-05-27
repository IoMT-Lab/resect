import '../engine_lifecycle.dart';
import 'dart_engine.dart';

/// [EngineLifecycle] backed by the pure-Dart [DartEngine] (renode-dart).
///
/// There is no separate server process anymore — `start()` launches Renode in
/// server-mode and connects the shared client directly. `serverPort`,
/// `loggingPath` (beyond the Renode log dir), and `startupDelay` from the old
/// Python/Socket.IO world no longer apply; the client's connection retry
/// replaces the fixed startup delay.
class DartEngineLifecycle implements EngineLifecycle {
  DartEngineLifecycle(this._engine);

  final DartEngine _engine;

  @override
  bool get isRunning => _engine.isRunning;

  @override
  Future<void> start({
    String? engineDir,
    int serverPort = 12356,
    int renodePort = 5000,
    String loggingPath = '/tmp/renode_logs',
    Duration startupDelay = const Duration(seconds: 6),
  }) async {
    if (_engine.isRunning) return;
    await _engine.startProcess(
      engineDir: engineDir,
      renodePort: renodePort,
      loggingPath: loggingPath,
    );
  }

  @override
  Future<void> stop() => _engine.stopProcess();
}
