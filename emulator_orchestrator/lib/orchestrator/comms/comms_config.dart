import '../../data/models/comms_assignment.dart';
import '../../data/models/emulator.dart';
import '../../services/hooks/hook_catalog.dart';
import '../hook_spec.dart';

/// Built-in device handler kinds available for a virtualized comms bus.
enum CommsDeviceHandlerKind { zero, random }

/// Per-protocol bus configuration (UDP port + device handler + virtualized
/// flag). Session-scoped in the UI; the CLI builds one directly.
///
/// Moved here from the UI so both the Flutter app and the headless CLI build
/// comms hooks through the identical path — virtualizing an interdependent
/// protocol like I2C as a UNIT is the whole point of this machinery, and it
/// can't be reproduced by stubbing individual symbols.
class CommsProtocolConfig {
  const CommsProtocolConfig({
    this.port = 1234,
    this.handler = CommsDeviceHandlerKind.zero,
    this.virtualized = false,
    this.fillUnmappedWithReturnZero = true,
  });

  final int port;
  final CommsDeviceHandlerKind handler;
  final bool virtualized;

  /// When [virtualized] is on, any symbol in this class with a known protocol
  /// but no read/write role gets the catalog's default return0 hook instead
  /// of being left to run the firmware's real implementation. Default on —
  /// the bus virtualization promise is "this protocol is covered."
  final bool fillUnmappedWithReturnZero;

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

/// Build the `commsHooks` map the synthesizer expects: for every comms-
/// classified-and-virtualized symbol with a known role, return a [HookSpec]
/// (code + scope) generated through the [HookCatalog].
///
/// Symbols whose protocol isn't virtualized, or whose role-specific builder
/// isn't in the catalog yet (e.g. spi), are silently skipped — they'll fall
/// through to whatever the synthesizer does for them (which for comms-
/// classified symbols is "bail out" via the overridden-symbol guard).
///
/// Symbols with no role but a known protocol get the catalog's default
/// return0 hook when [CommsProtocolConfig.fillUnmappedWithReturnZero] is on
/// (default) — so half-classified symbols (`HAL_I2C_StateGet`, MSP init/
/// deinit helpers, the `I2C_WaitOnFlag*` pollers, etc.) don't hang the
/// firmware when a protocol is virtualized. The fill-in hook has no scope; it
/// doesn't participate in the protocol's shared `globals()` context.
Map<String, HookSpec> buildCommsHooks({
  required Emulator emulator,
  required Map<CommsClass, CommsProtocolConfig> configs,
  required HookCatalog catalog,
}) {
  final hooks = <String, HookSpec>{};
  for (final entry in emulator.commsAssignments.entries) {
    final symbol = entry.key;
    final assignment = entry.value;
    if (assignment.protocol == CommsClass.unclassified) continue;

    final config = configs[assignment.protocol];
    if (config == null || !config.virtualized) continue;

    final role = assignment.role;
    if (role == null) {
      if (!config.fillUnmappedWithReturnZero) continue;
      final hook = catalog.build('return', const {'value': 0});
      hooks[symbol] = (code: hook.code, scope: hook.scope);
      continue;
    }

    final kindId = '${assignment.protocol.name}_${role.name}';
    if (catalog.descriptor(kindId) == null) continue;

    final hook = catalog.build(kindId, {'port': config.port});
    hooks[symbol] = (code: hook.code, scope: hook.scope);
  }
  return hooks;
}
