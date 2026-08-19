import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_bus_service.dart';
import 'package:emulator_orchestrator/orchestrator/comms/device_handler.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'comms_config_providers.dart';

// `buildCommsHooks` moved into the orchestrator package (shared with the
// headless CLI). Re-exported so existing UI imports keep resolving.
export 'package:emulator_orchestrator/orchestrator/comms/comms_config.dart'
    show buildCommsHooks;

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
      _sync,
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
        // Deliberately no start here: bus servers are SESSION-scoped
        // now — CommsSessionScope (comms_session_scope.dart) starts
        // them around each synthesis/auto-tune run through the shared
        // startCommsSession, honoring the tab's configs when any
        // protocol is virtualized. This controller only reconciles
        // stops when a toggle turns off outside a run.
      } else if (!shouldRun && isRunning) {
        await service.stop(cls);
      }
    }
  }
}

final commsBusControllerProvider =
    Provider<CommsBusController>(CommsBusController.new);
