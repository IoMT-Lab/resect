/// Engine-emitted event describing why emulation paused.
///
/// [user] is true when the user explicitly paused, false when the engine
/// paused on its own (e.g. unhandled memory access, breakpoint).
/// [symbol] is the enclosing function name at the program counter, when known.
/// [unhandledAccess] is true when the pause was caused by an unhandled memory
/// access — the signal the synthesizer uses to drive hook discovery.
class PausedEvent {
  final bool user;
  final String? symbol;
  final bool? unhandledAccess;

  PausedEvent({
    required this.user,
    this.symbol,
    this.unhandledAccess,
  });

  factory PausedEvent.fromList(List data) {
    return PausedEvent(
      user: data[0] as bool,
      symbol: data.length > 1 ? data[1] as String? : null,
      unhandledAccess: data.length > 2 ? data[2] as bool? : null,
    );
  }
}
