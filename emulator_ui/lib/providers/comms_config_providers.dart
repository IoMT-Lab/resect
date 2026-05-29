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

  /// When [virtualized] is on, any symbol in this class with a known protocol
  /// but no read/write role gets the catalog's default return0 hook instead
  /// of being left to run the firmware's real implementation. Default on —
  /// the bus virtualization promise is "this protocol is covered."
  final bool fillUnmappedWithReturnZero;

  const CommsProtocolConfig({
    this.port = 1234,
    this.handler = CommsDeviceHandlerKind.zero,
    this.virtualized = false,
    this.fillUnmappedWithReturnZero = true,
  });

  CommsProtocolConfig copyWith({
    int? port,
    CommsDeviceHandlerKind? handler,
    bool? virtualized,
    bool? fillUnmappedWithReturnZero,
  }) =>
      CommsProtocolConfig(
        port: port ?? this.port,
        handler: handler ?? this.handler,
        virtualized: virtualized ?? this.virtualized,
        fillUnmappedWithReturnZero:
            fillUnmappedWithReturnZero ?? this.fillUnmappedWithReturnZero,
      );
}

/// Class selected in the Comms tab's top dropdown.
final selectedCommsClassProvider =
    StateProvider<CommsClass>((ref) => CommsClass.i2c);

/// Symbols whose subtree is collapsed in the Comms tab's functions tree,
/// keyed by class. Pure UI state — not persisted to `.emu`. Per-class
/// keying means collapsing a node under i2c doesn't affect its display
/// under uart if it ever appeared in both (it can't today, but the
/// scoping keeps the contract clean).
final collapsedCommsSymbolsProvider =
    StateProvider<Map<CommsClass, Set<String>>>((ref) => const {});

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
