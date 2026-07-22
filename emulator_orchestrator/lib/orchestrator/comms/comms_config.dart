import '../../data/models/comms_assignment.dart';
import '../../data/models/emulator.dart';
import '../../data/services/hook_catalog.dart';
import '../../data/services/signatures_service.dart';
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
  Map<String, int?> argCounts = const {},
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

    // Only forward-hook functions that actually take the arguments the
    // extractor reads. The stm32_glue I2C extractor reads the 6th argument
    // (Size, at [SP+4]); UART reads the 3rd (r2). A function with fewer args
    // — e.g. `get_i2c`, a zero-arg accessor that just returns the bus handle —
    // would make the extractor read register/stack leftovers and forward a
    // bogus, out-of-spec request. Skip it and let it run natively (do NOT fall
    // through to the return-0 fill, which would clobber the accessor's real
    // return value). An unknown arg count (no signature cached) → attach, so
    // the gate only removes hooks it can prove are misapplied.
    final argCount = argCounts[symbol];
    if (argCount != null &&
        argCount < _minExtractorArgs(assignment.protocol)) {
      continue;
    }

    final hook = catalog.build(kindId, {'port': config.port});
    hooks[symbol] = (code: hook.code, scope: hook.scope);
  }
  return hooks;
}

/// Minimum argument count a symbol must have for the `stm32_glue` extractor to
/// read genuine arguments rather than register/stack leftovers. Coupled to the
/// extractor's fixed ABI assumptions (see hooks-dart `stm32_glue.py`):
/// - I2C read/write read up to the 6th arg (`Size` at `[SP+4]`) → need ≥6.
/// - UART read/write read up to the 3rd arg (`r2`) → need ≥3.
/// SPI has no forwarding extractor, so no gate applies.
int _minExtractorArgs(CommsClass protocol) {
  switch (protocol) {
    case CommsClass.i2c:
      return 6;
    case CommsClass.uart:
      return 3;
    case CommsClass.spi:
    case CommsClass.unclassified:
      return 0;
  }
}

/// Pre-fetch each comms-classified symbol's argument count from the signatures
/// cache, so [buildCommsHooks] can gate forwarding-hook attachment on a
/// function actually having the arguments the extractor reads. Values are the
/// parameter count, or `null` when no signature is cached (Ghidra module off,
/// or the symbol isn't in the ELF) — [buildCommsHooks] treats `null` as
/// "unknown, attach". Async (DB reads); call once before [buildCommsHooks].
Future<Map<String, int?>> fetchCommsArgCounts({
  required Emulator emulator,
  required SignaturesService signatures,
  required String elfHash,
}) async {
  final out = <String, int?>{};
  for (final symbol in emulator.commsAssignments.keys) {
    final sig =
        await signatures.signatureFor(elfHash: elfHash, symbolName: symbol);
    out[symbol] = sig?.parameters.length;
  }
  return out;
}
