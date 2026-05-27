import 'dart:async';

import 'package:renode/renode.dart';

import '../trace_event.dart';
import '../trace_source.dart';
import 'dart_engine.dart';

/// [TraceSource] backed by the shared client's `function-call` events.
///
/// `traceStream` carries every entry/exit; `filteredTraceStream` carries the
/// first entry of each symbol only (the seen-set resets on (re)connect, which
/// the workflow does at the start of each run).
class DartTraceSource implements TraceSource {
  DartTraceSource(this._engine);

  final DartEngine _engine;

  final _traceController = StreamController<TraceEvent>.broadcast();
  final _filteredController = StreamController<TraceEvent>.broadcast();
  final _seen = <String>{};

  StreamSubscription<FunctionCallEvent>? _sub;
  var _connected = false;

  @override
  Future<bool> connect() async {
    if (_engine.client == null) return false;
    _seen.clear();
    if (!_connected) {
      _sub = _engine.onFunctionCalled.listen(_onFunctionCall);
      _connected = true;
    }
    return true;
  }

  @override
  void disconnect() {
    _sub?.cancel();
    _sub = null;
    _connected = false;
    _seen.clear();
  }

  @override
  bool get isConnected => _connected;

  @override
  Stream<TraceEvent> get traceStream => _traceController.stream;

  @override
  Stream<TraceEvent> get filteredTraceStream => _filteredController.stream;

  void _onFunctionCall(FunctionCallEvent event) {
    _traceController.add(TraceEvent(symbol: event.name, isEntry: event.isEntry));
    if (event.isEntry && _seen.add(event.name)) {
      _filteredController.add(TraceEvent(symbol: event.name, isEntry: true));
    }
  }
}
