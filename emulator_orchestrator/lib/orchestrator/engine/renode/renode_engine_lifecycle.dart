import '../../python_server.dart';
import '../engine_lifecycle.dart';

/// [EngineLifecycle] backed by a Python/Renode subprocess.
///
/// Owns a [PythonServer] internally. Idempotent: calling `start()` twice
/// in succession is a no-op the second time; `stop()` is safe to call when
/// not running.
class RenodeEngineLifecycle implements EngineLifecycle {
  final PythonServer _server;

  RenodeEngineLifecycle({PythonServer? server})
      : _server = server ?? PythonServer();

  @override
  bool get isRunning => _server.isRunning;

  @override
  Future<void> start({
    String? engineDir,
    int serverPort = 12356,
    int renodePort = 5000,
    String loggingPath = '/tmp/renode_logs',
    Duration startupDelay = PythonServer.defaultStartupDelay,
  }) async {
    if (_server.isRunning) return;
    await _server.start(
      engineDir: engineDir,
      serverPort: serverPort,
      renodePort: renodePort,
      loggingPath: loggingPath,
      startupDelay: startupDelay,
    );
  }

  @override
  Future<void> stop() async {
    _server.stop();
  }
}
