import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;

/// Service for communicating with the Python emulation_engine server.
///
/// This handles the Socket.IO connection and provides methods to request
/// call graph data from the backend.
class CallgraphService {
  /// Socket.IO client instance (null until connect() is called)
  IO.Socket? _socket;

  /// Server URL (default: http://localhost:12356)
  final String serverUrl;

  /// Stream controller for connection status changes
  final _connectionController = StreamController<bool>.broadcast();

  /// Whether we're currently connected to the server
  bool _isConnected = false;

  /// Completer used during connect() to wait for the connection event.
  Completer<void>? _connectCompleter;

  /// Timeout for RPC calls (emitWithAck).
  static const Duration rpcTimeout = Duration(seconds: 120);

  CallgraphService({this.serverUrl = 'http://localhost:12356'});

  /// Get connection status as a stream (for UI updates)
  Stream<bool> get connectionStatus => _connectionController.stream;

  /// Check if currently connected
  bool get isConnected => _isConnected;

  /// Connect to the Python server on the /callgraph namespace.
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

      _socket!.nsp = '/callgraph';

      _connectCompleter = Completer<void>();

      _socket!.onConnect((_) {
        print('Connected to callgraph service at $serverUrl');
        _isConnected = true;
        _connectionController.add(true);
        if (_connectCompleter != null && !_connectCompleter!.isCompleted) {
          _connectCompleter!.complete();
        }
      });

      _socket!.onDisconnect((_) {
        print('Disconnected from callgraph service');
        _isConnected = false;
        _connectionController.add(false);
      });

      _socket!.onError((error) {
        print('Callgraph socket error: $error');
        _isConnected = false;
        _connectionController.add(false);
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
      print('Failed to connect to callgraph service: $e');
      _isConnected = false;
      _connectionController.add(false);
      return false;
    }
  }

  /// Request full call graph from an ELF file.
  ///
  /// Returns [success, result] where:
  /// - If success: result is Map<String, dynamic> of call graph data
  /// - If failed: result is error message string
  Future<List<dynamic>> getCallgraph(String elfPath) async {
    if (!_isConnected) {
      throw Exception('Not connected to server. Call connect() first.');
    }

    final completer = Completer<List<dynamic>>();

    _socket!.emitWithAck('get_callgraph', elfPath, ack: (response) {
      if (!completer.isCompleted) {
        completer.complete(response as List<dynamic>);
      }
    });

    return completer.future.timeout(
      rpcTimeout,
      onTimeout: () => throw TimeoutException(
        'Call graph request timed out after ${rpcTimeout.inSeconds}s',
      ),
    );
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
  }
}
