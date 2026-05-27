import 'dart:math' as math;

import '../../data/models/call_graph.dart';
import '../../data/models/graph_point.dart';
import '../engine/call_graph_source.dart';
import '../exceptions/orchestrator_exceptions.dart';

/// Graph layout algorithm types.
enum GraphLayout {
  forceDirected,
  hierarchical,
  sugiyama,
  circular,
  grid,
  executionOrder,
}

/// Handles call graph generation and layout algorithms.
///
/// This workflow:
/// 1. Generates call graphs by requesting analysis from the backend
/// 2. Applies layout algorithms to position nodes in the graph
///
/// Layout algorithms are extracted from graph_viewer_widget.dart (700+ lines)
/// to make them testable and reusable.
class AnalysisWorkflow {
  final CallGraphSource callGraphSource;

  AnalysisWorkflow({required this.callGraphSource});

  /// Generate call graph for the given ELF file.
  ///
  /// Requests static analysis from the engine and parses the result.
  Future<CallGraph> generateCallGraph(String elfPath) async {
    try {
      if (!callGraphSource.isConnected) {
        throw AnalysisException('Call graph source not connected');
      }
      return await callGraphSource.getCallGraph(elfPath);
    } catch (e) {
      throw AnalysisException('Failed to generate call graph', e);
    }
  }

  /// Apply the selected layout algorithm to position nodes in the graph.
  ///
  /// Returns a map of symbol names to their (x, y) positions.
  Map<String, GraphPoint> applyLayout({
    required CallGraph callGraph,
    required GraphLayout layoutType,
  }) {
    final nodes = callGraph.symbols.keys.toList();

    switch (layoutType) {
      case GraphLayout.forceDirected:
        return _applyForceDirectedLayout(callGraph, nodes);
      case GraphLayout.hierarchical:
        return _applyHierarchicalLayout(callGraph, nodes);
      case GraphLayout.sugiyama:
        return _applySugiyamaLayout(callGraph, nodes);
      case GraphLayout.circular:
        return _applyCircularLayout(callGraph, nodes);
      case GraphLayout.grid:
        return _applyGridLayout(nodes);
      case GraphLayout.executionOrder:
        return _applyExecutionOrderLayout(callGraph, nodes);
    }
  }

  // =========================================================================
  // LAYOUT ALGORITHMS
  // =========================================================================
  // TODO: Extract the full 700+ lines of layout algorithms from
  // graph_viewer_widget.dart. For now, using placeholder implementations.

  Map<String, GraphPoint> _applyForceDirectedLayout(CallGraph callGraph, List<String> nodes) {
    // Placeholder: Simple random layout
    final positions = <String, GraphPoint>{};
    final random = math.Random(42); // Fixed seed for reproducibility

    for (final node in nodes) {
      positions[node] = GraphPoint(
        random.nextDouble() * 400,
        random.nextDouble() * 400,
      );
    }

    return positions;
  }

  Map<String, GraphPoint> _applyHierarchicalLayout(CallGraph callGraph, List<String> nodes) {
    // Placeholder: Grid layout
    return _applyGridLayout(nodes);
  }

  Map<String, GraphPoint> _applySugiyamaLayout(CallGraph callGraph, List<String> nodes) {
    // Placeholder: Grid layout
    return _applyGridLayout(nodes);
  }

  Map<String, GraphPoint> _applyCircularLayout(CallGraph callGraph, List<String> nodes) {
    // Placeholder: Circular arrangement
    final positions = <String, GraphPoint>{};
    const radius = 200.0;
    final angleStep = (2 * math.pi) / nodes.length;

    for (var i = 0; i < nodes.length; i++) {
      final angle = i * angleStep;
      positions[nodes[i]] = GraphPoint(
        radius + radius * math.cos(angle),
        radius + radius * math.sin(angle),
      );
    }

    return positions;
  }

  Map<String, GraphPoint> _applyGridLayout(List<String> nodes) {
    final positions = <String, GraphPoint>{};
    final gridSize = math.sqrt(nodes.length).ceil();
    const spacing = 100.0;

    for (var i = 0; i < nodes.length; i++) {
      final row = i ~/ gridSize;
      final col = i % gridSize;
      positions[nodes[i]] = GraphPoint(col * spacing, row * spacing);
    }

    return positions;
  }

  Map<String, GraphPoint> _applyExecutionOrderLayout(CallGraph callGraph, List<String> nodes) {
    // Placeholder: Grid layout
    return _applyGridLayout(nodes);
  }

  /// Clean up resources
  void dispose() {
    // No cleanup needed currently
  }
}
