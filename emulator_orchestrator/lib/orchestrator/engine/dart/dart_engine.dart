import 'dart:async';

import 'package:renode/renode.dart';

import '../../../config/env_config.dart';
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

  RenodeClient? _client;

  RenodeClient? get client => _client;
  bool get isRunning => _client != null;

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
    if (_client != null) return;

    // resect.config overrides the passed defaults when present.
    final cfg = EnvConfig.load();
    final port = int.tryParse(cfg.get('RENODE_PORT') ?? '') ?? renodePort;


    _client = await RenodeClient.connect(
      host,
      port,
      retryCount: 60,
      retryDelay: const Duration(milliseconds: 500),
    );

    _stateSub = _client?.onStateChanged.listen(_stateController.add);
    _fcSub = _client?.onFunctionCalled.listen(_functionCallController.add);
    _uaSub = _client?.onUnhandledAccess.listen(_unhandledController.add);
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
  }
}
