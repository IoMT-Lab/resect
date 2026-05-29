import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/services/hook_catalog.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_bus_service.dart';
import 'package:emulator_orchestrator/orchestrator/comms/device_handler.dart';
import 'package:emulator_orchestrator/orchestrator/hook_spec.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'comms_config_providers.dart';

/// Build the `commsHooks` map the orchestrator expects: for every comms-
/// classified-and-virtualized symbol with a known role, return a [HookSpec]
/// (code + scope) generated through the [HookCatalog].
///
/// Symbols whose protocol isn't virtualized, or whose role-specific builder
/// isn't in the catalog yet (e.g. spi), are silently skipped — they'll fall
/// through to whatever the synthesizer does for them (which for comms-
/// classified symbols is "bail out" via the overridden-symbol guard).
///
/// Symbols with no role but a known protocol get the catalog's default
/// return0 hook when [CommsProtocolConfig.fillUnmappedWithReturnZero] is
/// on (default) — so half-classified symbols (`HAL_I2C_StateGet`, MSP
/// init/deinit helpers, etc.) don't crash the firmware when a protocol is
/// virtualized. The fill-in hook has no scope; it doesn't participate in
/// the protocol's shared `globals()` context.
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

/// The CommsBusService instance for the running app.
final commsBusServiceProvider = Provider<CommsBusService>((ref) {
  final service = CommsBusService();
  ref.onDispose(service.dispose);
  return service;
});

/// Shared HookCatalog for hook-source generation (catalog.build('i2c_read'...)
/// etc). Constructing it once at app boot via the provider amortizes the
/// hooks-dart `includeSystemModules()` call.
final hookCatalogProvider = Provider<HookCatalog>((ref) => HookCatalog.system());

/// Drives [CommsBusService] in response to per-protocol Virtualize toggle
/// changes in [commsProtocolConfigProvider]. Eager-instantiated from
/// `emulationOrchestratorProvider` so transitions are picked up from app
/// boot, not lazily on first widget read.
///
/// Behavior:
/// - Toggling Virtualize on → starts a UDP server on the configured port
///   with the configured device handler.
/// - Toggling Virtualize off → stops the server.
/// - Changing port or handler while virtualized → restarts the server with
///   the new settings.
/// - Port conflicts surface via [PortInUseException]; the controller logs
///   them and flips the protocol's Virtualize back to false so the UI
///   reflects reality.
class CommsBusController {
  CommsBusController(this._ref) {
    _ref.listen<Map<CommsClass, CommsProtocolConfig>>(
      commsProtocolConfigProvider,
      (prev, next) => _sync(prev, next),
      fireImmediately: true,
    );
  }

  final Ref _ref;

  Future<void> _sync(
    Map<CommsClass, CommsProtocolConfig>? prev,
    Map<CommsClass, CommsProtocolConfig> next,
  ) async {
    final service = _ref.read(commsBusServiceProvider);
    for (final cls in CommsClass.values) {
      if (cls == CommsClass.unclassified) continue;
      final prevCfg = prev?[cls];
      final nextCfg = next[cls];
      if (nextCfg == null) continue;

      final shouldRun = nextCfg.virtualized;
      final isRunning = service.isRunning(cls);

      final settingsChanged = prevCfg != null &&
          (prevCfg.port != nextCfg.port ||
              prevCfg.handler != nextCfg.handler);

      if (shouldRun && (!isRunning || settingsChanged)) {
        try {
          await service.start(cls, nextCfg.port, _makeHandler(nextCfg.handler));
        } on PortInUseException catch (e) {
          // Bounce the toggle back to false so the UI reflects reality.
          // ignore: avoid_print
          print('Comms bus ($cls): $e — disabling Virtualize.');
          final current = _ref.read(commsProtocolConfigProvider);
          final updated = Map<CommsClass, CommsProtocolConfig>.from(current);
          updated[cls] = nextCfg.copyWith(virtualized: false);
          _ref.read(commsProtocolConfigProvider.notifier).state = updated;
        }
      } else if (!shouldRun && isRunning) {
        await service.stop(cls);
      }
    }
  }

  static DeviceHandler _makeHandler(CommsDeviceHandlerKind kind) {
    switch (kind) {
      case CommsDeviceHandlerKind.zero:
        return const ZeroDeviceHandler();
      case CommsDeviceHandlerKind.random:
        return const RandomDeviceHandler();
    }
  }
}

final commsBusControllerProvider =
    Provider<CommsBusController>(CommsBusController.new);
