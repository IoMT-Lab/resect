import '../../data/models/emulation_state.dart';
import '../../data/models/emulator.dart';
import '../../data/services/lifecycle_service.dart';

/// Base class for all orchestration events.
///
/// Events are emitted by the orchestrator and listened to by the UI
/// to update Riverpod providers and trigger UI updates.
abstract class OrchestrationEvent {
  final DateTime timestamp;

  OrchestrationEvent() : timestamp = DateTime.now();
}

// ============================================================================
// EMULATION EVENTS
// ============================================================================

/// Emitted when emulation state changes (stopped, running, paused).
class EmulationStateChangedEvent extends OrchestrationEvent {
  final EmulationState state;

  EmulationStateChangedEvent(this.state);
}

/// Emitted when emulation is paused (with details).
class EmulationPausedEvent extends OrchestrationEvent {
  final PausedEvent pauseDetails;

  EmulationPausedEvent(this.pauseDetails);
}

// ============================================================================
// EMULATOR EVENTS
// ============================================================================

/// Emitted when the current emulator changes (loaded, created, or closed).
class EmulatorChangedEvent extends OrchestrationEvent {
  final Emulator? emulator;

  EmulatorChangedEvent(this.emulator);
}

/// Emitted when an emulator is saved.
class EmulatorSavedEvent extends OrchestrationEvent {
  final Emulator emulator;
  final String savePath;

  EmulatorSavedEvent(this.emulator, this.savePath);
}

// ============================================================================
// TRACE EVENTS
// ============================================================================

/// Emitted when a symbol is executed during emulation.
///
/// This is forwarded from TraceService/FilteredTraceService for centralized handling.
class SymbolExecutedEvent extends OrchestrationEvent {
  final String symbol;
  final bool isEntry;

  SymbolExecutedEvent(this.symbol, this.isEntry);
}
