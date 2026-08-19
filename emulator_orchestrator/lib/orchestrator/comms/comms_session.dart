import 'dart:io';

import '../../data/models/comms_assignment.dart';
import '../../data/models/emulator.dart';
import '../../data/models/hook_decision_state.dart' show CommsProtocolStatus;
import '../../services/hooks/hook_catalog.dart';
import '../hook_spec.dart';
import 'comms_bus_service.dart';
import 'comms_config.dart';
import 'device_handler.dart';

/// Everything a synthesis/auto-tune session needs to know about its
/// comms virtualization: the per-protocol configs, the coherent hook
/// set built from the project's assignments, the status map the
/// decision-state builder and recommend prompt read, and which
/// protocols' bus servers this call actually started (so the caller
/// stops exactly those and no more).
typedef CommsSessionResult = ({
  Map<CommsClass, CommsProtocolConfig> configs,
  Map<String, HookSpec> hooks,
  Map<CommsClass, CommsProtocolStatus> status,
  Set<CommsClass> started,
});

/// The fixed-port defaults both surfaces use when nothing was
/// explicitly configured: one virtualized config per requested class,
/// zero-fill semantics, ports i2c:1234 / spi:1235 / uart:1236.
Map<CommsClass, CommsProtocolConfig> defaultCommsConfigs(
    Set<CommsClass> classes) {
  const ports = {
    CommsClass.i2c: 1234,
    CommsClass.spi: 1235,
    CommsClass.uart: 1236,
  };
  return {
    for (final c in classes)
      if (c != CommsClass.unclassified)
        c: CommsProtocolConfig(port: ports[c] ?? 1234, virtualized: true),
  };
}

/// The comms stanza every run shares — CLI `synthesize`/`autotune` and
/// the UI's session bracket all call this one function.
///
/// Builds the coherent per-protocol hooks from [emulator]'s comms
/// assignments via [buildCommsHooks], then starts a comms-bus UDP
/// server for each *virtualized* protocol in [configs]. The i2c/uart
/// read hooks send each read to `localhost:<port>` and BLOCK on the
/// reply — without a server listening, the first real read in the
/// firmware wedges Renode (and the whole synthesis loop) forever.
///
/// [handlerFor] picks the device handler per protocol; by default the
/// config's [CommsProtocolConfig.handler] kind is honored (zero-fill
/// unless configured otherwise). A port already in use is warned via
/// [log] and skipped — reads on that protocol will block until the
/// stale server is gone. The caller owns stopping the servers listed
/// in the result's `started` set.
Future<CommsSessionResult> startCommsSession({
  required Emulator emulator,
  required Map<CommsClass, CommsProtocolConfig> configs,
  required CommsBusService bus,
  required HookCatalog catalog,
  DeviceHandler Function(CommsClass cls)? handlerFor,
  void Function(String msg)? log,
}) async {
  final emit = log ?? stderr.writeln;
  final hooks = buildCommsHooks(
    emulator: emulator,
    configs: configs,
    catalog: catalog,
  );
  final status = <CommsClass, CommsProtocolStatus>{
    for (final e in configs.entries)
      e.key: (virtualized: e.value.virtualized, port: e.value.port),
  };
  final virtualized = [
    for (final e in configs.entries)
      if (e.value.virtualized) e.key,
  ];
  if (hooks.isNotEmpty) {
    emit('Comms virtualized: ${hooks.length} hooks across '
        '${virtualized.map((c) => c.name).join('/')}');
  }

  final started = <CommsClass>{};
  for (final c in virtualized) {
    final config = configs[c]!;
    final handler = handlerFor?.call(c) ??
        switch (config.handler) {
          CommsDeviceHandlerKind.zero => const ZeroDeviceHandler(),
          CommsDeviceHandlerKind.random => const RandomDeviceHandler(),
        };
    try {
      await bus.start(c, config.port, handler);
      started.add(c);
      emit('Comms bus: ${c.name} server on udp/${config.port} '
          '(${config.handler.name}-fill)');
    } on PortInUseException catch (e) {
      emit('Comms bus: ${c.name} port ${config.port} unavailable ($e); '
          'reads on this protocol will block — kill the stale server or '
          'pick another port.');
    }
  }

  return (configs: configs, hooks: hooks, status: status, started: started);
}

/// Stop exactly the servers a [startCommsSession] call started.
Future<void> stopCommsSession(
    CommsBusService bus, Set<CommsClass> started) async {
  for (final c in started) {
    await bus.stop(c);
  }
}
