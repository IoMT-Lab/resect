import 'dart:io';

/// Manages the Python emulation engine server process.
///
/// Extracted from EmulationWorkflow to be reusable by both the Flutter app
/// and headless CLI tools.
class PythonServer {
  Process? _process;
  bool _serverError = false;

  static const Duration defaultStartupDelay = Duration(seconds: 6);

  /// Whether the server process is currently running.
  bool get isRunning => _process != null;

  /// The underlying process (for advanced use).
  Process? get process => _process;

  /// Start the Python emulation engine server.
  ///
  /// [engineDir]: Path to the emulation_engine directory.
  ///   If null, attempts to find it relative to cwd (sibling directory).
  /// [serverPort]: Port for the Socket.IO server (default: 12356).
  /// [renodePort]: Port for Renode (default: 5000).
  /// [loggingPath]: Directory for Renode logs.
  /// [startupDelay]: How long to wait for the server to boot.
  Future<void> start({
    String? engineDir,
    int serverPort = 12356,
    int renodePort = 5000,
    String loggingPath = '/tmp/renode_logs',
    Duration startupDelay = defaultStartupDelay,
  }) async {
    if (_process != null) {
      throw PythonServerException('Server is already running');
    }

    final workingDir = engineDir ?? _findEngineDir();
    final renodePath = '$workingDir/renode_1.16.0-dotnet_portable/renode';

    stderr.writeln('Starting Python server from $workingDir...');

    try {
      _serverError = false;
      final process = await Process.start(
        'pipenv',
        ['run', 'python', '-m', 'emulation_engine.engine'],
        workingDirectory: workingDir,
        environment: {
          'RENODE_EXECUTABLE': renodePath,
          'RENODE_PORT': renodePort.toString(),
          'SERVER_PORT': serverPort.toString(),
          'LOGGING_PATH': loggingPath,
          'PIPENV_IGNORE_VIRTUALENVS': '1',
        },
      );

      // Monitor output
      process.stdout.transform(const SystemEncoding().decoder).listen((data) {
        stderr.write('[server] $data');
      });
      process.stderr.transform(const SystemEncoding().decoder).listen((data) {
        stderr.write('[server:err] $data');
        if (data.contains('ModuleNotFoundError') || data.contains('ImportError')) {
          _serverError = true;
        }
      });

      // Wait for server to be ready
      await Future.delayed(startupDelay);

      if (_serverError) {
        process.kill();
        throw PythonServerException(
          'Python server failed to start.\n'
          'Common issues:\n'
          '  - Missing dependencies (run: pipenv install)\n'
          '  - Renode not found at $renodePath',
        );
      }

      _process = process;
      stderr.writeln('Python server started on port $serverPort');
    } catch (e) {
      if (e is PythonServerException) rethrow;
      throw PythonServerException('Failed to start Python server: $e');
    }
  }

  /// Stop the server process.
  void stop() {
    if (_process != null) {
      _process!.kill();
      _process = null;
      stderr.writeln('Python server stopped');
    }
  }

  /// Find the emulation_engine directory relative to cwd.
  ///
  /// emulation_engine lives inside the workspace root. Checks:
  /// 1. ./emulation_engine   (cwd is the workspace root)
  /// 2. ../emulation_engine  (cwd is a package subdir like emulator_ui/)
  String _findEngineDir() {
    final candidates = [
      '${Directory.current.path}/emulation_engine',
      '${Directory.current.parent.path}/emulation_engine',
    ];

    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    throw PythonServerException(
      'Could not find emulation_engine directory.\n'
      'Searched: ${candidates.join(', ')}\n'
      'Use --engine-dir to specify the path explicitly.',
    );
  }
}

/// Exception thrown when Python server operations fail.
class PythonServerException implements Exception {
  final String message;
  PythonServerException(this.message);

  @override
  String toString() => 'PythonServerException: $message';
}
