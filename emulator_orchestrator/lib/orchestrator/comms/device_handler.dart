import 'package:resect_hooks/resect_hooks.dart' as hooks;

/// Models the host-side device that a virtualized firmware bus talks to.
///
/// Each virtualized protocol (i2c / spi / uart) gets one handler. The handler
/// receives every request the firmware sends over the UDP comms bus (per
/// hooks-dart's protocol) and returns a [hooks.ResponseMessage]. Handlers can
/// branch on the request's `HID` to provide per-bus-instance behavior under
/// a single server (the design intent — see Workstream B in the migration
/// plan: one server per protocol, multi-bus via HID).
///
/// v1 ships [ZeroDeviceHandler] and [RandomDeviceHandler] (wrapping
/// hooks-dart's bundled stub handlers). Richer handlers — register-model
/// mock peripheral, recorded playback, real-hardware bridge — plug in
/// behind this same interface as follow-on work.
// ignore: one_member_abstracts
abstract class DeviceHandler {
  Future<hooks.ResponseMessage> handle(hooks.RequestMessage request);
}

/// All reads return zero-filled bytes. The simplest stand-in.
class ZeroDeviceHandler implements DeviceHandler {
  const ZeroDeviceHandler();

  @override
  Future<hooks.ResponseMessage> handle(hooks.RequestMessage request) =>
      hooks.zeroHandler(request);
}

/// All reads return cryptographically-cheap random bytes. Useful for
/// stress-testing firmware behavior against unpredictable peripheral data.
class RandomDeviceHandler implements DeviceHandler {
  const RandomDeviceHandler();

  @override
  Future<hooks.ResponseMessage> handle(hooks.RequestMessage request) =>
      hooks.randomHandler(request);
}
