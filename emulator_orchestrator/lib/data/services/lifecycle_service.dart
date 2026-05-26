import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;

import '../../orchestrator/engine/paused_event.dart';

export '../../orchestrator/engine/paused_event.dart';

/// Service for managing emulation lifecycle (load, start, pause, resume, reset).
///
/// This communicates with the Python server's /lifecycle namespace to control
/// the Renode emulation engine.
class LifecycleService {
  /// Socket.IO client instance (null until connect() is called)
  IO.Socket? _socket;

  /// Server URL (default: http://localhost:12356)
  final String serverUrl;

  /// Stream controller for connection status changes
  final _connectionController = StreamController<bool>.broadcast();

  /// Stream controllers for lifecycle events
  final _startedController = StreamController<void>.broadcast();
  final _pausedController = StreamController<PausedEvent>.broadcast();
  final _resumedController = StreamController<void>.broadcast();
  final _resetController = StreamController<void>.broadcast();

  /// Whether we're currently connected to the server
  bool _isConnected = false;

  /// Completer used during connect() to wait for the connection event.
  Completer<void>? _connectCompleter;

  /// Timeout for RPC calls (emitWithAck).
  static const Duration rpcTimeout = Duration(seconds: 30);

  LifecycleService({this.serverUrl = 'http://localhost:12356'});

  /// Get connection status as a stream (for UI updates)
  Stream<bool> get connectionStatus => _connectionController.stream;

  /// Get lifecycle events
  Stream<void> get onStarted => _startedController.stream;
  Stream<PausedEvent> get onPaused => _pausedController.stream;
  Stream<void> get onResumed => _resumedController.stream;
  Stream<void> get onReset => _resetController.stream;

  /// Check if currently connected
  bool get isConnected => _isConnected;

  /// Connect to the Python server on the /lifecycle namespace.
  ///
  /// This must be called before any other methods.
  /// Returns true if connection successful.
  Future<bool> connect() async {
    try {
      _socket = IO.io(
        serverUrl,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .enableForceNew()
            .disableAutoConnect()
            .build(),
      );

      _socket!.nsp = '/lifecycle';

      // Prepare completer before registering handlers
      _connectCompleter = Completer<void>();

      _socket!.onConnect((_) {
        print('Connected to lifecycle service at $serverUrl');
        _isConnected = true;
        _connectionController.add(true);
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete();
        }
      });

      _socket!.onDisconnect((_) {
        print('Disconnected from lifecycle service');
        _isConnected = false;
        _connectionController.add(false);
      });

      _socket!.onError((error) {
        print('Lifecycle socket error: $error');
        _isConnected = false;
        _connectionController.add(false);
      });

      // Lifecycle event handlers
      _socket!.on('started', (_) {
        _startedController.add(null);
      });

      _socket!.on('paused', (data) {
        final event = PausedEvent.fromList(data as List);
        print('Emulation paused: user=${event.user}, symbol=${event.symbol}, unhandledAccess=${event.unhandledAccess}');
        _pausedController.add(event);
      });

      _socket!.on('resumed', (_) {
        _resumedController.add(null);
      });

      _socket!.on('reset', (_) {
        _resetController.add(null);
      });

      _socket!.connect();

      await _connectCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          throw TimeoutException('Connection timeout after 5 seconds');
        },
      );

      return true;
    } catch (e) {
      print('Failed to connect to lifecycle service: $e');
      _isConnected = false;
      _connectionController.add(false);
      return false;
    }
  }

  /// Load firmware into Renode.
  ///
  /// [baseImage]: Path to the Renode platform description file (.repl)
  /// [firmwarePath]: Path to the ELF firmware file
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> load(String baseImage, String firmwarePath) async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('load', [baseImage, firmwarePath]);
  }

  /// Load a memory map (snapshot) JSON file into Renode.
  ///
  /// [memoryMapPath]: Absolute path to the memory map JSON file
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> loadMemoryMap(String memoryMapPath) async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('load_memory_map', [memoryMapPath]);
  }

  /// Start emulation.
  ///
  /// [startFrom]: Optional symbol/address to start execution from
  /// [endAt]: Optional list of symbols/addresses to pause at
  /// [pauseOnUnhandled]: Whether to pause on unhandled memory access (default: true)
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> start({
    String? startFrom,
    List<String>? endAt,
    bool pauseOnUnhandled = true,
  }) async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('start', [startFrom, endAt, pauseOnUnhandled]);
  }

  /// Pause emulation.
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> pause() async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('pause', null);
  }

  /// Resume emulation.
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> resume() async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('resume', null);
  }

  /// Define a named hook with Renode-compatible code.
  ///
  /// [hookName]: Unique name for this hook (e.g. 'return_0')
  /// [hookCode]: Renode hook code (Python/C# that manipulates CPU state)
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> defineHook(String hookName, String hookCode) async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('define_hook', [hookName, hookCode]);
  }

  /// Map function symbols to hook names.
  ///
  /// [hooks]: Map of symbol name -> hook name
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> mapHooks(Map<String, String> hooks) async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('map_hooks', hooks);
  }

  /// Reset emulation.
  ///
  /// Returns [success, result/error] tuple
  Future<List<dynamic>> reset() async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    return _emitWithTimeout('reset', null);
  }

  /// Explicitly disconnect the socket.
  void disconnect() {
    if (_isConnected) {
      _socket?.disconnect();
      _isConnected = false;
      _connectionController.add(false);
    }
  }

  /// Disconnect from the server and clean up resources.
  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _connectionController.close();
    _startedController.close();
    _pausedController.close();
    _resumedController.close();
    _resetController.close();
  }

  /// Emit a Socket.IO event and wait for acknowledgement with timeout.
  ///
  /// Returns the server response as a [success, result] list.
  /// Throws [TimeoutException] if the server doesn't respond within [rpcTimeout].
  Future<List<dynamic>> _emitWithTimeout(String event, dynamic data) {
    final completer = Completer<List<dynamic>>();

    _socket!.emitWithAck(event, data, ack: ([dynamic response]) {
      if (completer.isCompleted) return;
      if (response == null) {
        completer.complete([true, 'Command sent']);
      } else if (response is List) {
        completer.complete(response);
      } else {
        completer.complete([response]);
      }
    });

    return completer.future.timeout(
      rpcTimeout,
      onTimeout: () => throw TimeoutException(
        'RPC call "$event" timed out after ${rpcTimeout.inSeconds}s',
      ),
    );
  }
}
