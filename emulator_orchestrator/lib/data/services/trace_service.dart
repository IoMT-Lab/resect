import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;

import '../../orchestrator/engine/trace_event.dart';

export '../../orchestrator/engine/trace_event.dart';

/// Service for tracking function execution during emulation.
///
/// This communicates with the Python server's /trace namespace to receive
/// real-time notifications when functions are called during emulation.
class TraceService {
  /// Socket.IO client instance (null until connect() is called)
  IO.Socket? _socket;

  /// Server URL (default: http://localhost:12356)
  final String serverUrl;

  /// Stream controller for connection status changes
  final _connectionController = StreamController<bool>.broadcast();

  /// Stream controller for trace events (symbol name, isEntry)
  final _traceController = StreamController<TraceEvent>.broadcast();

  /// Whether we're currently connected to the server
  bool _isConnected = false;

  /// Completer used during connect() to wait for the connection event.
  Completer<void>? _connectCompleter;

  TraceService({this.serverUrl = 'http://localhost:12356'});

  /// Get connection status as a stream (for UI updates)
  Stream<bool> get connectionStatus => _connectionController.stream;

  /// Get trace events as a stream
  Stream<TraceEvent> get onTrace => _traceController.stream;

  /// Check if currently connected
  bool get isConnected => _isConnected;

  /// Connect to the Python server on the /trace namespace.
  ///
  /// This must be called before receiving trace events.
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

      _socket!.nsp = '/trace';

      _connectCompleter = Completer<void>();

      _socket!.onConnect((_) {
        print('Connected to trace service at $serverUrl');
        _isConnected = true;
        _connectionController.add(true);
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete();
        }
      });

      _socket!.onDisconnect((_) {
        print('Disconnected from trace service');
        _isConnected = false;
        _connectionController.add(false);
      });

      _socket!.onError((error) {
        print('Trace socket error: $error');
        _isConnected = false;
        _connectionController.add(false);
      });

      _socket!.on('trace', (data) {
        final event = TraceEvent.fromList(data as List);
        _traceController.add(event);
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
      print('Failed to connect to trace service: $e');
      _isConnected = false;
      _connectionController.add(false);
      return false;
    }
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
    _traceController.close();
  }
}
