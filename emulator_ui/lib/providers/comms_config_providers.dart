import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// `CommsProtocolConfig` + `CommsDeviceHandlerKind` moved into the orchestrator
// package so the headless CLI builds comms hooks through the identical path.
// Re-export them so existing UI imports of this file keep resolving.
export 'package:emulator_orchestrator/orchestrator/comms/comms_config.dart'
    show CommsDeviceHandlerKind, CommsProtocolConfig;

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
