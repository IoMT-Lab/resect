/// A 2D point for graph layout positions.
///
/// Pure-Dart replacement for `dart:ui` `Offset`, enabling the orchestrator
/// layer to run without Flutter dependencies (headless mode).
class GraphPoint {
  final double x;
  final double y;

  const GraphPoint(this.x, this.y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  @override
  String toString() => 'GraphPoint($x, $y)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphPoint && x == other.x && y == other.y;

  @override
  int get hashCode => x.hashCode ^ y.hashCode;
}
