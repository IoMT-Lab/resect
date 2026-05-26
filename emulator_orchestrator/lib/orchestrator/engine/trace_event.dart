/// A single function entry or exit observed during emulation.
class TraceEvent {
  final String symbol;
  final bool isEntry;

  TraceEvent({
    required this.symbol,
    required this.isEntry,
  });

  factory TraceEvent.fromList(List data) {
    return TraceEvent(
      symbol: data[0] as String,
      isEntry: data[1] as bool,
    );
  }
}
