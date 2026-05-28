import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Built-in device handler kinds available in v1. Future handlers
/// (register-model, recorded playback, real-hardware bridge) plug in
/// behind the same DeviceHandler interface in B4 and would appear here.
enum CommsDeviceHandlerKind { zero, random }

extension CommsDeviceHandlerKindLabel on CommsDeviceHandlerKind {
  String get label {
    switch (this) {
      case CommsDeviceHandlerKind.zero:
        return 'Zero-fill';
      case CommsDeviceHandlerKind.random:
        return 'Random bytes';
    }
  }
}

/// Per-protocol bus configuration (UDP port + device handler + virtualized flag).
/// Currently session-scoped; B3/B4 will move this onto the Emulator for
/// persistence, alongside the bus-hook application and the UDP server.
class CommsProtocolConfig {
  final int port;
  final CommsDeviceHandlerKind handler;
  final bool virtualized;

  const CommsProtocolConfig({
    this.port = 1234,
    this.handler = CommsDeviceHandlerKind.zero,
    this.virtualized = false,
  });

  CommsProtocolConfig copyWith({
    int? port,
    CommsDeviceHandlerKind? handler,
    bool? virtualized,
  }) =>
      CommsProtocolConfig(
        port: port ?? this.port,
        handler: handler ?? this.handler,
        virtualized: virtualized ?? this.virtualized,
      );
}

/// Class selected in the Comms tab's top dropdown.
final selectedCommsClassProvider =
    StateProvider<CommsClass>((ref) => CommsClass.i2c);

/// Per-protocol session config. Keyed only for real protocols
/// (`unclassified` has no Python interface — see the design intent in the
/// migration plan), but we still key the map on CommsClass for symmetry.
final commsProtocolConfigProvider =
    StateProvider<Map<CommsClass, CommsProtocolConfig>>(
  (ref) => const {
    CommsClass.i2c: CommsProtocolConfig(port: 1234),
    CommsClass.spi: CommsProtocolConfig(port: 1235),
    CommsClass.uart: CommsProtocolConfig(port: 1236),
  },
);
