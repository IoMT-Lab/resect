import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart'
    show CommsProtocolStatus;
import 'package:emulator_orchestrator/orchestrator/comms/comms_bus_service.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_config.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_session.dart';
import 'package:emulator_orchestrator/orchestrator/hook_spec.dart';
import 'package:emulator_orchestrator/services/hooks/hook_catalog.dart';
import 'package:flutter/foundation.dart';

/// Session-scoped comms bracket for UI synthesis and auto-tune runs —
/// the UI's counterpart of the CLI's comms stanza, built on the shared
/// [startCommsSession].
///
/// The default-vs-tab decision lives here: if ANY protocol in the
/// Comms tab's per-protocol configs is virtualized, the tab's configs
/// win wholesale (ports and handler kinds as configured). Otherwise
/// the CLI defaults apply — i2c/uart/spi virtualized with zero-fill
/// servers on ports 1234/1235/1236 — so an untouched project behaves
/// identically on both surfaces.
///
/// [release] stops only the servers this scope started, so it can
/// coexist with anything else driving the app-lifetime
/// [CommsBusService].
class CommsSessionScope {
  CommsSessionScope._(this._bus, this._result);

  final CommsBusService _bus;
  final CommsSessionResult _result;

  Map<CommsClass, CommsProtocolConfig> get configs => _result.configs;
  Map<String, HookSpec> get hooks => _result.hooks;
  Map<CommsClass, CommsProtocolStatus> get status => _result.status;

  static Future<CommsSessionScope> acquire({
    required Emulator emulator,
    required Map<CommsClass, CommsProtocolConfig> tabConfigs,
    required CommsBusService bus,
    required HookCatalog catalog,
  }) async {
    final tabConfigured = tabConfigs.values.any((c) => c.virtualized);
    final configs = tabConfigured
        ? tabConfigs
        : defaultCommsConfigs(
            {CommsClass.i2c, CommsClass.uart, CommsClass.spi});
    final result = await startCommsSession(
      emulator: emulator,
      configs: configs,
      bus: bus,
      catalog: catalog,
      log: debugPrint,
    );
    return CommsSessionScope._(bus, result);
  }

  /// Stop the servers this scope started (and nothing else).
  Future<void> release() => stopCommsSession(_bus, _result.started);
}
