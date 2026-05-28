import 'dart:async';
import 'dart:io';

import 'package:hooks/hooks.dart' as hooks;

import '../../data/models/comms_assignment.dart';
import 'device_handler.dart';

/// Manages the in-process UDP servers for virtualized comms protocols.
///
/// One server per virtualized [CommsClass] (i.e. one UDP port). Bus-level
/// identity for multiple physical buses of the same protocol is carried in
/// the wire-protocol's `HID` field, not in the port — handlers can branch
/// on `HID` to provide per-bus device behavior under a single server.
///
/// Lifecycle is owned by the caller (see the UI's
/// `commsBusControllerProvider`): call [start] when a protocol's Virtualize
/// toggle flips on, [stop] when it flips off, and [dispose] when the
/// project closes.
///
/// Port conflicts surface as [PortInUseException] — handlers should surface
/// this to the UI rather than crashing the orchestrator.
class CommsBusService {
  final Map<CommsClass, _RunningServer> _servers = {};

  /// Whether a server is currently active for [protocol].
  bool isRunning(CommsClass protocol) => _servers.containsKey(protocol);

  /// Start a UDP server for [protocol] on [port] with [handler]. If a server
  /// for that protocol is already running, it is stopped first (handles
  /// port/handler changes without leaking).
  Future<void> start(
    CommsClass protocol,
    int port,
    DeviceHandler handler,
  ) async {
    if (protocol == CommsClass.unclassified) {
      throw ArgumentError(
          'CommsClass.unclassified has no protocol; cannot start a server');
    }
    await stop(protocol);
    final StreamSubscription subscription;
    try {
      subscription = await hooks.startServer(handler.handle, port);
    } on SocketException catch (e) {
      throw PortInUseException(port, e.message);
    }
    _servers[protocol] = _RunningServer(port: port, subscription: subscription);
  }

  /// Stop the server for [protocol] if running.
  Future<void> stop(CommsClass protocol) async {
    final s = _servers.remove(protocol);
    if (s != null) {
      await s.subscription.cancel();
    }
  }

  /// Stop every running server. Call on project close.
  Future<void> dispose() async {
    for (final s in _servers.values) {
      await s.subscription.cancel();
    }
    _servers.clear();
  }

  /// Snapshot of the active servers (protocol → port). Read-only.
  Map<CommsClass, int> get runningPorts =>
      {for (final e in _servers.entries) e.key: e.value.port};
}

class _RunningServer {
  final int port;
  final StreamSubscription subscription;
  const _RunningServer({required this.port, required this.subscription});
}

class PortInUseException implements Exception {
  final int port;
  final String detail;
  const PortInUseException(this.port, this.detail);

  @override
  String toString() => 'Port $port is unavailable: $detail';
}
