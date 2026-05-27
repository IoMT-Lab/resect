/// Engine abstraction layer.
///
/// Defines the four capability interfaces every emulation engine must
/// implement to plug into Resect:
///   - [EngineLifecycle] — process/runtime lifecycle.
///   - [CallGraphSource] — static analysis (call graph extraction).
///   - [EmulationController] — runtime execution control + lifecycle events.
///   - [TraceSource] — runtime function entry/exit streams.
///
/// The current Renode/Python implementations live under `engine/renode/`.
/// A future Ghidra/Dart engine will provide alternate implementations of
/// the same interfaces; nothing above this layer needs to change.
library;

export 'call_graph_source.dart';
export 'emulation_controller.dart';
export 'engine_lifecycle.dart';
export 'paused_event.dart';
export 'trace_event.dart';
export 'trace_source.dart';
