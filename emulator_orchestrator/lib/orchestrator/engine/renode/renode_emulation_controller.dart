import '../../../data/services/lifecycle_service.dart';
import '../emulation_controller.dart';

/// [EmulationController] backed by the Renode/Python `/lifecycle` Socket.IO
/// namespace.
///
/// Translates the underlying `[success, result]` tuple responses into
/// [EmulationControllerException]s on failure.
class RenodeEmulationController implements EmulationController {
  final LifecycleService _service;

  RenodeEmulationController(this._service);

  @override
  Future<bool> connect() => _service.connect();

  @override
  void disconnect() => _service.disconnect();

  @override
  bool get isConnected => _service.isConnected;

  @override
  Stream<bool> get connectionStatus => _service.connectionStatus;

  @override
  Future<void> load(String baseImage, String elfPath) async {
    _check(await _service.load(baseImage, elfPath), 'load');
  }

  @override
  Future<void> loadMemoryMap(String memoryMapPath) async {
    _check(await _service.loadMemoryMap(memoryMapPath), 'loadMemoryMap');
  }

  @override
  Future<void> start({
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
  }) async {
    _check(
      await _service.start(
        startFrom: startFrom,
        endAt: endAt,
        pauseOnUnhandled: pauseOnUnhandled,
      ),
      'start',
    );
  }

  @override
  Future<void> pause() async {
    _check(await _service.pause(), 'pause');
  }

  /// Note: the underlying Renode service uses `start` (with no args) to
  /// resume a paused machine — that's an idiosyncrasy of the wire protocol.
  @override
  Future<void> resume() async {
    _check(await _service.start(), 'resume');
  }

  @override
  Future<void> reset() async {
    _check(await _service.reset(), 'reset');
  }

  @override
  Future<void> defineHook(String hookName, String hookCode) async {
    _check(await _service.defineHook(hookName, hookCode), 'defineHook');
  }

  @override
  Future<void> mapHooks(Map<String, String> symbolToHookName) async {
    _check(await _service.mapHooks(symbolToHookName), 'mapHooks');
  }

  @override
  Stream<void> get onStarted => _service.onStarted;

  @override
  Stream<PausedEvent> get onPaused => _service.onPaused;

  @override
  Stream<void> get onResumed => _service.onResumed;

  @override
  Stream<void> get onReset => _service.onReset;

  void _check(List<dynamic> response, String op) {
    if (response.isEmpty || response[0] != true) {
      final detail = response.length > 1 ? response[1] : 'unknown error';
      throw EmulationControllerException('$op failed: $detail');
    }
  }
}

class EmulationControllerException implements Exception {
  final String message;
  EmulationControllerException(this.message);
  @override
  String toString() => 'EmulationControllerException: $message';
}
