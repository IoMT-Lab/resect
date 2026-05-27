import 'dart:async';
import 'dart:io';

import 'package:renode/renode.dart';

import '../../../config/env_config.dart';
import '../../../core/app_paths.dart';
import 'dart_call_graph_source.dart';
import 'dart_emulation_controller.dart';
import 'dart_engine_lifecycle.dart';
import 'dart_trace_source.dart';

/// Composition root for the pure-Dart engine (renode-dart + callgraph-dart).
///
/// Owns the [RenodeProcess] and a single shared [RenodeClient]; the lifecycle,
/// emulation-control, and trace capabilities all read events off this one
/// client. The client's single-subscription event streams are subscribed once
/// here and re-emitted on broadcast controllers so multiple capabilities can
/// observe them.
class DartEngine {
  DartEngine({this.host = 'localhost'});

  final String host;

  RenodeProcess? _process;
  RenodeClient? _client;
  IOSink? _logSink;

  RenodeClient? get client => _client;
  bool get isRunning => _process?.isRunning ?? false;

  // Stable broadcast re-emitters — survive client restarts so capabilities can
  // subscribe once and keep receiving across reset/relaunch cycles.
  final _stateController = StreamController<StateChangeEvent>.broadcast();
  final _functionCallController = StreamController<FunctionCallEvent>.broadcast();
  final _unhandledController = StreamController<UnhandledAccessEvent>.broadcast();

  Stream<StateChangeEvent> get onStateChanged => _stateController.stream;
  Stream<FunctionCallEvent> get onFunctionCalled => _functionCallController.stream;
  Stream<UnhandledAccessEvent> get onUnhandledAccess => _unhandledController.stream;

  StreamSubscription<StateChangeEvent>? _stateSub;
  StreamSubscription<FunctionCallEvent>? _fcSub;
  StreamSubscription<UnhandledAccessEvent>? _uaSub;

  late final lifecycle = DartEngineLifecycle(this);
  late final controller = DartEmulationController(this);
  late final traceSource = DartTraceSource(this);
  late final callGraphSource = DartCallGraphSource();

  /// Launch Renode in server-mode and connect the shared client. No-op if
  /// already running.
  Future<void> startProcess({
    String? engineDir,
    int renodePort = 5000,
    String loggingPath = '/tmp/renode_logs',
  }) async {
    if (_process != null) return;

    // resect.config overrides the passed defaults when present.
    final cfg = EnvConfig.load();
    engineDir ??= cfg.get('ENGINE_DIR');
    final port = int.tryParse(cfg.get('RENODE_PORT') ?? '') ?? renodePort;
    final logPath = cfg.get('RENODE_LOG_PATH') ?? loggingPath;
    final renodeBin = _resolveRenodeBin(engineDir, cfg);
    await _freeStalePort(port);

    await Directory(logPath).create(recursive: true);
    final sink = File('$logPath/renode.log').openWrite();
    sink.done.ignore();
    _logSink = sink;

    final process = RenodeProcess(renodeBin, port, sink, sink);
    await process.start();
    _process = process;

    final client = await RenodeClient.connect(
      host,
      port,
      retryCount: 60,
      retryDelay: const Duration(milliseconds: 500),
    );
    _client = client;

    _stateSub = client.onStateChanged.listen(_stateController.add);
    _fcSub = client.onFunctionCalled.listen(_functionCallController.add);
    _uaSub = client.onUnhandledAccess.listen(_unhandledController.add);
  }

  /// Tear down the client and process. Idempotent.
  Future<void> stopProcess() async {
    await _stateSub?.cancel();
    await _fcSub?.cancel();
    await _uaSub?.cancel();
    _stateSub = null;
    _fcSub = null;
    _uaSub = null;

    try {
      await _client?.dispose();
    } catch (_) {}
    _client = null;

    try {
      await _process?.stop();
    } catch (_) {}
    _process = null;

    try {
      await _logSink?.flush();
      await _logSink?.close();
    } catch (_) {}
    _logSink = null;
  }

  String _resolveRenodeBin(String? engineDir, EnvConfig cfg) {
    final configured = cfg.get('RENODE_BIN') ?? Platform.environment['RENODE_BIN'];
    if (configured != null && configured.isNotEmpty) return configured;
    final dir = engineDir ?? AppPaths.findEngineDir();
    final portable = cfg.get('RENODE_PORTABLE') ??
        Platform.environment['RENODE_PORTABLE'] ??
        'renode_1.16.0-dotnet_portable';
    return '$dir/$portable/renode';
  }

  /// Reclaim the Renode port if a prior run left a server listening on it.
  Future<void> _freeStalePort(int port) async {
    try {
      final result =
          await Process.run('lsof', ['-t', '-i:$port', '-sTCP:LISTEN']);
      final pids = (result.stdout as String)
          .split('\n')
          .where((s) => s.trim().isNotEmpty);
      for (final pid in pids) {
        stderr.writeln('Freeing stale process $pid on port $port');
        Process.killPid(int.parse(pid.trim()), ProcessSignal.sigterm);
      }
    } catch (_) {
      // lsof absent or nothing listening — nothing to free.
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }
}
