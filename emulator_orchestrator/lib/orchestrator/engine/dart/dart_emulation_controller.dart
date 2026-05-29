import 'dart:async';
import 'dart:io';

import 'package:renode/renode.dart';

import '../emulation_controller.dart';
import '../paused_event.dart';
import 'dart_engine.dart';

/// [EmulationController] backed by the shared [RenodeClient] in [DartEngine].
///
/// Reconstructs the legacy `PausedEvent` (which the synthesizer depends on) by
/// combining the client's separate state-change, function-call, and
/// unhandled-access streams — mirroring what the old Python `_process_machine_paused`
/// did:
///   * `lastSymbol`          — most recent function entry (needs tracing on)
///   * `lastUnhandledSymbol` — symbol of the most recent unhandled access
///   * `pendingPause`        — set when the user explicitly pauses
/// On pause: `unhandledAccess = lastUnhandledSymbol == lastSymbol`.
///
/// Hooks are applied via raw monitor commands (`set name """code"""` +
/// `AddHookAtSymbol "sym" $name`) — the exact sequence the Python backend used —
/// rather than the client's inline-quoted `AddHookAtSymbol "sym" "code"`, so
/// multi-line hook bodies with quotes survive intact.
class DartEmulationController implements EmulationController {
  DartEmulationController(this._engine);

  final DartEngine _engine;

  final _connectionController = StreamController<bool>.broadcast();
  final _startedController = StreamController<void>.broadcast();
  final _pausedController = StreamController<PausedEvent>.broadcast();
  final _resumedController = StreamController<void>.broadcast();
  final _resetController = StreamController<void>.broadcast();

  StreamSubscription<StateChangeEvent>? _stateSub;
  StreamSubscription<FunctionCallEvent>? _fcSub;
  StreamSubscription<UnhandledAccessEvent>? _uaSub;

  var _connected = false;
  String? _lastSymbol;
  String? _lastUnhandledSymbol;
  var _pendingPause = false;

  // hookName -> (hookCode, optional Renode Python execution scope).
  // Scope is honored only by the patched Renode portable; null elsewhere is
  // equivalent to today's no-scope behavior.
  final _hooks = <String, ({String code, String? scope})>{};
  final _hookMap = <String, String>{}; // symbol -> hookName

  RenodeClient get _client {
    final c = _engine.client;
    if (c == null) {
      throw EmulationControllerException('Engine not started');
    }
    return c;
  }

  @override
  Future<bool> connect() async {
    if (_engine.client == null) return false;
    if (!_connected) {
      _stateSub = _engine.onStateChanged.listen(_onState);
      _fcSub = _engine.onFunctionCalled.listen(_onFunctionCall);
      _uaSub = _engine.onUnhandledAccess.listen(_onUnhandled);
      _connected = true;
      _connectionController.add(true);
    }
    return true;
  }

  @override
  void disconnect() {
    if (!_connected) return;
    _stateSub?.cancel();
    _fcSub?.cancel();
    _uaSub?.cancel();
    _stateSub = null;
    _fcSub = null;
    _uaSub = null;
    _connected = false;
    _connectionController.add(false);
  }

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionStatus => _connectionController.stream;

  @override
  Future<void> load(String baseImage, String elfPath) async {
    final repl = Base64Data.fromBytes(await File(baseImage).readAsBytes());
    final elf = Base64Data.fromBytes(await File(elfPath).readAsBytes());
    await _client.createMachine(repl);
    await _client.loadFirmware(elf);
    // Enable function-name logging so function-call events populate lastSymbol
    // (the paused-event symbol) and feed the trace source.
    await _client.enableTracing();
  }

  @override
  Future<void> loadMemoryMap(String memoryMapPath) async {
    // The legacy Python backend never implemented this; the memory-map format
    // is owned by the forthcoming Memory Map Initialization module. No-op for
    // now to preserve current behavior.
  }

  @override
  Future<void> start({
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
  }) async {
    await _applyHooks();
    _pendingPause = false;
    _lastUnhandledSymbol = null; // fresh run — detect new unhandled accesses
    await _client.run(
      startFrom: startFrom,
      endAt: endAt,
      pauseOnUnhandled: pauseOnUnhandled,
    );
  }

  @override
  Future<void> pause() async {
    _pendingPause = true;
    await _client.pause();
  }

  @override
  Future<void> resume() async {
    _pendingPause = false;
    _lastUnhandledSymbol = null;
    await _client.resume();
  }

  @override
  Future<void> reset() async {
    _pendingPause = false;
    _lastSymbol = null;
    _lastUnhandledSymbol = null;
    _hookMap.clear();
    await _client.reset();
  }

  @override
  Future<void> defineHook(String hookName, String hookCode, {String? scope}) async {
    _hooks[hookName] = (code: hookCode, scope: scope);
  }

  @override
  Future<void> mapHooks(Map<String, String> symbolToHookName) async {
    _hookMap.addAll(symbolToHookName);
  }

  Future<void> _applyHooks() async {
    if (_hooks.isEmpty && _hookMap.isEmpty) return;

    // Log every hook being applied (symbol → hook name + scope + code body)
    // so it's possible to verify *what* actually got installed without
    // shimming through Renode. One block per symbol; indented code body.
    for (final entry in _hookMap.entries) {
      final symbol = entry.key;
      final hookName = entry.value;
      final hook = _hooks[hookName];
      if (hook == null) continue;
      final scope = hook.scope ?? '(none)';
      final indented = hook.code
          .split('\n')
          .map((line) => '    $line')
          .join('\n');
      print('[Hook applied] $symbol → $hookName (scope: $scope)\n$indented');
    }

    final cmds = <String>[];
    for (final entry in _hooks.entries) {
      cmds.add('set ${entry.key} \n"""\n${entry.value.code}\n"""');
    }
    for (final entry in _hookMap.entries) {
      final scope = _hooks[entry.value]?.scope;
      cmds.add(addHookAtSymbolCommand(entry.key, entry.value, scope));
    }
    await _client.callMany(cmds);
  }

  /// Build the `sysbus AddHookAtSymbol` line for the variable-reference form
  /// (a previously-`set` hook variable referenced by `$name`). Public so it
  /// can be unit-tested without spinning up an engine; see comment in this
  /// class's header on why we keep the two-step `set var """..."""` strategy.
  static String addHookAtSymbolCommand(String symbol, String hookName, String? scope) =>
      'sysbus AddHookAtSymbol "$symbol" \$$hookName${scope != null ? ' "$scope"' : ''}';

  @override
  Stream<void> get onStarted => _startedController.stream;
  @override
  Stream<PausedEvent> get onPaused => _pausedController.stream;
  @override
  Stream<void> get onResumed => _resumedController.stream;
  @override
  Stream<void> get onReset => _resetController.stream;

  void _onFunctionCall(FunctionCallEvent event) {
    if (event.isEntry) _lastSymbol = event.name;
  }

  void _onUnhandled(UnhandledAccessEvent event) {
    _lastUnhandledSymbol = event.name;
  }

  void _onState(StateChangeEvent event) {
    switch (event.state) {
      case State.started:
        _startedController.add(null);
      case State.resumed:
        _resumedController.add(null);
      case State.paused:
        // Renode emits the unhandled-access event (carrying the enclosing
        // symbol) immediately before the pause. Prefer that symbol — it's
        // authoritative and doesn't depend on function-call tracing being on.
        // A user-requested pause always takes precedence and is never flagged
        // as an unhandled access.
        final unhandled = _lastUnhandledSymbol != null && !_pendingPause;
        _pausedController.add(PausedEvent(
          user: _pendingPause,
          symbol: unhandled ? _lastUnhandledSymbol : _lastSymbol,
          unhandledAccess: unhandled,
        ));
      case State.reset:
        _lastSymbol = null;
        _lastUnhandledSymbol = null;
        _pendingPause = false;
        _resetController.add(null);
    }
  }
}

class EmulationControllerException implements Exception {
  final String message;
  EmulationControllerException(this.message);
  @override
  String toString() => 'EmulationControllerException: $message';
}
