import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:emulator_orchestrator/core/constants.dart';
import '../../providers/app_providers.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart' as cg;
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/data/models/fidelity_result.dart';
import 'package:emulator_orchestrator/data/models/trace_activity_event.dart';
import 'package:emulator_orchestrator/data/services/lifecycle_service.dart';
import 'package:emulator_orchestrator/orchestrator/events/orchestrator_events.dart';
import 'package:emulator_orchestrator/orchestrator/events/synthesizer_events.dart';

/// Main graph viewer widget that displays the call graph.
/// 
/// Uses custom canvas-based rendering with:
/// - Zoom and pan support via InteractiveViewer
/// - Simple force-directed layout algorithm
/// - Clickable nodes for selection
/// - Shift+Z to fit graph to view
/// - Shift+drag to move nodes

enum GraphLayout {
  forceDirected,
  hierarchical,
  sugiyama,
  circular,
  grid,
  executionOrder,
}

enum NodeStyle {
  circle,
  box,
  labeledBox,
  dot,
}

/// A visual ripple expanding from a node to draw attention to state changes.
class _NodeRipple {
  final String symbol;
  final Color color;
  final DateTime createdAt;
  final double maxRadius;

  _NodeRipple({
    required this.symbol,
    required this.color,
    required this.maxRadius,
  }) : createdAt = DateTime.now();

  /// Ripple duration in milliseconds.
  static const int durationMs = 1800;

  /// Progress from 0.0 (just created) to 1.0 (fully expanded).
  double get progress {
    final elapsed = DateTime.now().difference(createdAt).inMilliseconds;
    return (elapsed / durationMs).clamp(0.0, 1.0);
  }

  bool get isComplete => progress >= 1.0;
}

class GraphViewerWidget extends ConsumerStatefulWidget {
  const GraphViewerWidget({super.key});

  @override
  ConsumerState<GraphViewerWidget> createState() => _GraphViewerWidgetState();
}

class _GraphViewerWidgetState extends ConsumerState<GraphViewerWidget> with TickerProviderStateMixin {
  final TransformationController _transformationController = TransformationController();
  final FocusNode _focusNode = FocusNode();
  Map<String, Offset> _nodePositions = {};
  Map<String, Offset> _nodeVelocities = {};
  List<_Edge> _edges = [];
  cg.CallGraph? _cachedCallGraph;
  String? _draggedNode;
  Offset? _dragOffset;
  late AnimationController _animationController;
  GraphLayout _currentLayout = GraphLayout.executionOrder;
  NodeStyle _currentNodeStyle = NodeStyle.circle;
  Map<String, Size> _nodeSizeCache = {};
  bool _animationEnabled = false;
  bool _scaleByDegree = true;
  Map<String, int> _nodeDegrees = {};
  Size? _lastViewportSize;
  List<_NodeRipple> _activeRipples = [];
  Timer? _rippleTimer;
  final ValueNotifier<int> _rippleNotifier = ValueNotifier<int>(0);
  Set<String> _prevExecutedSymbols = {};
  Set<String> _prevHookedSymbols = {};
  late AnimationController _viewAnimController;
  Matrix4? _viewAnimStart;
  Matrix4? _viewAnimEnd;
  bool _focusOnSelect = true;

  StreamSubscription? _traceSubscription;
  StreamSubscription? _filteredTraceSubscription;
  StreamSubscription? _pauseEventSubscription;
  StreamSubscription? _synthesizerEventSubscription;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 8), // ~120fps
    )..addListener(_updatePhysics);
    _viewAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..addListener(_onViewAnimTick);
  }

  @override
  void dispose() {
    _rippleTimer?.cancel();
    _rippleNotifier.dispose();
    _traceSubscription?.cancel();
    _filteredTraceSubscription?.cancel();
    _pauseEventSubscription?.cancel();
    _synthesizerEventSubscription?.cancel();
    _animationController.dispose();
    _viewAnimController.dispose();
    _transformationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Helper to calculate box dimensions for labeled box style
  Size _getLabeledBoxSize(String symbol) {
    if (_currentNodeStyle != NodeStyle.labeledBox) {
      return const Size(10, 10); // Default size for other styles
    }
    
    // Return cached size if available
    if (_nodeSizeCache.containsKey(symbol)) {
      return _nodeSizeCache[symbol]!;
    }
    
    // Compute and cache the size
    final textPainter = TextPainter(
      text: TextSpan(
        text: symbol,
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    
    const padding = 8.0;
    final size = Size(
      textPainter.width + padding * 2,
      textPainter.height + padding * 2,
    );
    
    _nodeSizeCache[symbol] = size;
    return size;
  }

  void _updatePhysics() {
    if (_nodePositions.isEmpty || _cachedCallGraph == null) return;

    final nodes = _nodePositions.keys.toList();
    final forces = <String, Offset>{};

    // Calculate repulsion between all nodes
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i] == _draggedNode) continue; // Skip dragged node
      
      var fx = 0.0, fy = 0.0;
      final pos1 = _nodePositions[nodes[i]]!;
      final size1 = _getLabeledBoxSize(nodes[i]);

      for (var j = 0; j < nodes.length; j++) {
        if (i == j) continue;
        final pos2 = _nodePositions[nodes[j]]!;
        final size2 = _getLabeledBoxSize(nodes[j]);
        final dx = pos1.dx - pos2.dx;
        final dy = pos1.dy - pos2.dy;
        final dist = math.sqrt(dx * dx + dy * dy) + 0.1;
        
        // Increase repulsion force if boxes would overlap
        final minDist = _currentNodeStyle == NodeStyle.labeledBox
            ? math.max(size1.width, size1.height) + math.max(size2.width, size2.height)
            : 0.0;
        
        var force = 50.0 / (dist * dist);
        
        // Add extra repulsion if boxes are overlapping
        if (dist < minDist && _currentNodeStyle == NodeStyle.labeledBox) {
          force += (minDist - dist) * 2.0;
        }
        
        fx += (dx / dist) * force;
        fy += (dy / dist) * force;
      }

      forces[nodes[i]] = Offset(fx, fy);
    }

    // Attraction for connected nodes
    for (var entry in _cachedCallGraph!.symbols.entries) {
      final from = entry.key;
      if (from == _draggedNode) continue;
      if (!_nodePositions.containsKey(from)) continue;

      for (var to in entry.value.calledSymbols.keys) {
        if (!_nodePositions.containsKey(to) || to == _draggedNode) continue;

        final pos1 = _nodePositions[from]!;
        final pos2 = _nodePositions[to]!;
        final dx = pos2.dx - pos1.dx;
        final dy = pos2.dy - pos1.dy;
        final dist = math.sqrt(dx * dx + dy * dy) + 0.1;
        final force = dist * 0.01;

        final fx = (dx / dist) * force;
        final fy = (dy / dist) * force;

        forces[from] = (forces[from] ?? Offset.zero) + Offset(fx, fy);
        forces[to] = (forces[to] ?? Offset.zero) - Offset(fx, fy);
      }
    }

    // Apply forces with damping
    bool anyMovement = false;
    for (var node in nodes) {
      if (node == _draggedNode) continue;
      
      final force = forces[node] ?? Offset.zero;
      final velocity = (_nodeVelocities[node] ?? Offset.zero) * 0.85 + force * 0.1;
      _nodeVelocities[node] = velocity;

      final newPos = _nodePositions[node]! + velocity;
      _nodePositions[node] = newPos;

      if (velocity.distance > 0.1) anyMovement = true;
    }

    if (!anyMovement && _draggedNode == null) {
      _animationController.stop();
    }

    setState(() {});
  }

  void _startAnimation() {
    if (!_animationEnabled) return;
    if (!_animationController.isAnimating) {
      _animationController.repeat();
    }
  }

  void _buildLayout(cg.CallGraph callGraph) {
    if (_cachedCallGraph == callGraph) return;
    
    print('Building layout for ${callGraph.symbols.length} symbols');
    
    final nodes = callGraph.symbols.keys.toList();
    final positions = <String, Offset>{};
    
    // Apply selected layout algorithm
    switch (_currentLayout) {
      case GraphLayout.forceDirected:
        positions.addAll(_applyForceDirectedLayout(callGraph, nodes));
        break;
      case GraphLayout.hierarchical:
        positions.addAll(_applyHierarchicalLayout(callGraph, nodes));
        break;
      case GraphLayout.sugiyama:
        positions.addAll(_applySugiyamaLayout(callGraph, nodes));
        break;
      case GraphLayout.circular:
        positions.addAll(_applyCircularLayout(callGraph, nodes));
        break;
      case GraphLayout.grid:
        positions.addAll(_applyGridLayout(nodes));
        break;
      case GraphLayout.executionOrder:
        positions.addAll(_applyExecutionOrderLayout(callGraph, nodes));
        break;
    }
    
    // Build edge list
    final edges = <_Edge>[];
    for (var entry in callGraph.symbols.entries) {
      for (var to in entry.value.calledSymbols.keys) {
        if (positions.containsKey(to)) {
          edges.add(_Edge(entry.key, to));
        }
      }
    }
    
    _nodePositions = positions;
    _edges = edges;
    _cachedCallGraph = callGraph;

    // Compute node degrees (in + out edges)
    final degrees = <String, int>{};
    for (var node in nodes) {
      degrees[node] = 0;
    }
    for (var edge in edges) {
      degrees[edge.from] = (degrees[edge.from] ?? 0) + 1;
      degrees[edge.to] = (degrees[edge.to] ?? 0) + 1;
    }
    _nodeDegrees = degrees;

    // Precompute box sizes for labeled box style to populate cache
    if (_currentNodeStyle == NodeStyle.labeledBox) {
      _nodeSizeCache.clear();
      for (var node in nodes) {
        _getLabeledBoxSize(node);
      }
    }

    // Initialize velocities
    for (var node in nodes) {
      _nodeVelocities[node] = Offset.zero;
    }
    
    print('Created ${positions.length} nodes and ${edges.length} edges');
    
    _startAnimation();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitGraphToView(animate: false));
  }

  Map<String, Offset> _applyForceDirectedLayout(cg.CallGraph callGraph, List<String> nodes) {
    final positions = <String, Offset>{};
    final random = math.Random(42);
    
    // Initialize with random positions spread across the area
    for (var i = 0; i < nodes.length; i++) {
      positions[nodes[i]] = Offset(
        (random.nextDouble() - 0.5) * 400,
        (random.nextDouble() - 0.5) * 400,
      );
    }
    
    // Simple spring layout
    for (var iter = 0; iter < 50; iter++) {
      final forces = <String, Offset>{};
      
      // Repulsion between all nodes
      for (var i = 0; i < nodes.length; i++) {
        var fx = 0.0, fy = 0.0;
        final pos1 = positions[nodes[i]]!;
        
        for (var j = 0; j < nodes.length; j++) {
          if (i == j) continue;
          final pos2 = positions[nodes[j]]!;
          final dx = pos1.dx - pos2.dx;
          final dy = pos1.dy - pos2.dy;
          final dist = math.sqrt(dx * dx + dy * dy) + 0.1;
          final force = 100.0 / (dist * dist);
          fx += (dx / dist) * force;
          fy += (dy / dist) * force;
        }
        
        forces[nodes[i]] = Offset(fx, fy);
      }
      
      // Attraction for connected nodes
      for (var entry in callGraph.symbols.entries) {
        final from = entry.key;
        if (!positions.containsKey(from)) continue;

        for (var to in entry.value.calledSymbols.keys) {
          if (!positions.containsKey(to)) continue;

          final pos1 = positions[from]!;
          final pos2 = positions[to]!;
          final dx = pos2.dx - pos1.dx;
          final dy = pos2.dy - pos1.dy;
          final dist = math.sqrt(dx * dx + dy * dy) + 0.1;
          final force = dist * 0.01;

          final fx = (dx / dist) * force;
          final fy = (dy / dist) * force;

          forces[from] = (forces[from] ?? Offset.zero) + Offset(fx, fy);
          forces[to] = (forces[to] ?? Offset.zero) - Offset(fx, fy);
        }
      }
      
      // Apply forces
      for (var node in nodes) {
        final force = forces[node] ?? Offset.zero;
        positions[node] = positions[node]! + force * 0.1;
      }
    }
    
    return positions;
  }

  Map<String, Offset> _applyHierarchicalLayout(cg.CallGraph callGraph, List<String> nodes) {
    final positions = <String, Offset>{};
    final depths = <String, int>{};
    final visited = <String>{};
    
    // Identify nodes with any connections (callers or callees)
    final callers = <String, Set<String>>{};
    final hasConnections = <String>{};
    
    for (var entry in callGraph.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (var called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        hasConnections.add(called);
      }
    }
    
    // BFS to find depth of each node
    void bfs(String start) {
      final queue = <String>[start];
      depths[start] = 0;
      visited.add(start);
      
      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        final currentDepth = depths[current]!;
        
        final symbol = callGraph.symbols[current];
        if (symbol != null) {
          for (var called in symbol.calledSymbols.keys) {
            if (!visited.contains(called) && callGraph.symbols.containsKey(called)) {
              visited.add(called);
              depths[called] = currentDepth + 1;
              queue.add(called);
            }
          }
        }
      }
    }
    
    // Find entry points (nodes with no callers or named main/reset)
    final entryPoints = nodes.where((n) => 
      hasConnections.contains(n) && (
        !callers.containsKey(n) || 
        n.toLowerCase().contains('main') || 
        n.toLowerCase().contains('reset')
      )
    ).toList();
    
    // Run BFS from entry points
    for (var entry in entryPoints) {
      if (!visited.contains(entry)) {
        bfs(entry);
      }
    }
    
    // Separate connected nodes from truly isolated nodes (no edges at all)
    final isolatedNodes = nodes.where((n) => !hasConnections.contains(n)).toList();
    
    // Group nodes by depth
    final nodesByDepth = <int, List<String>>{};
    for (var entry in depths.entries) {
      nodesByDepth.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    
    // Position connected nodes in main hierarchy
    const levelSeparation = 150.0;
    const nodeSeparation = 100.0;
    
    for (var entry in nodesByDepth.entries) {
      final depth = entry.key;
      final nodesAtDepth = entry.value;
      final y = depth * levelSeparation;
      
      for (var i = 0; i < nodesAtDepth.length; i++) {
        final x = (i - nodesAtDepth.length / 2) * nodeSeparation;
        positions[nodesAtDepth[i]] = Offset(x, y);
      }
    }
    
    // Position isolated nodes in a compact grid above the main graph
    if (isolatedNodes.isNotEmpty) {
      final gridCols = math.sqrt(isolatedNodes.length).ceil();
      const isolatedSpacing = 80.0;

      double minY = double.infinity;
      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (var pos in positions.values) {
        if (pos.dy < minY) minY = pos.dy;
        if (pos.dx < minX) minX = pos.dx;
        if (pos.dx > maxX) maxX = pos.dx;
      }
      if (minY == double.infinity) minY = 0;
      if (minX == double.infinity) minX = 0;
      if (maxX == double.negativeInfinity) maxX = 0;

      final gridRows = (isolatedNodes.length / gridCols).ceil();
      final gridHeight = gridRows * isolatedSpacing;
      final startY = minY - gridHeight - 200;
      final centerX = (minX + maxX) / 2;
      final gridWidth = gridCols * isolatedSpacing;
      final startX = centerX - gridWidth / 2;

      for (var i = 0; i < isolatedNodes.length; i++) {
        final row = i ~/ gridCols;
        final col = i % gridCols;
        final x = startX + col * isolatedSpacing;
        final y = startY + row * isolatedSpacing;
        positions[isolatedNodes[i]] = Offset(x, y);
      }
    }

    return positions;
  }

  Map<String, Offset> _applySugiyamaLayout(cg.CallGraph callGraph, List<String> nodes) {
    final positions = <String, Offset>{};
    
    // Phase 1: Cycle removal and layer assignment
    final layers = <int, List<String>>{};
    final nodeLayer = <String, int>{};
    final inDegree = <String, int>{};
    final outDegree = <String, int>{};
    
    // Build caller relationships and identify isolated nodes
    final callers = <String, Set<String>>{};
    final hasConnections = <String>{};
    
    for (var entry in callGraph.symbols.entries) {
      outDegree[entry.key] = entry.value.calledSymbols.length;
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (var called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        inDegree[called] = (inDegree[called] ?? 0) + 1;
        hasConnections.add(called);
      }
    }
    
    // Initialize in-degree for all nodes
    for (var node in nodes) {
      inDegree.putIfAbsent(node, () => 0);
    }
    
    // Topological sort with Kahn's algorithm for layer assignment
    final queue = <String>[];
    
    // Start with nodes that have no incoming edges
    for (var node in nodes) {
      if (hasConnections.contains(node) && inDegree[node] == 0) {
        queue.add(node);
        nodeLayer[node] = 0;
        layers.putIfAbsent(0, () => []).add(node);
      }
    }
    
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final currentLayer = nodeLayer[current]!;
      
      final symbol = callGraph.symbols[current];
      if (symbol != null) {
        for (var called in symbol.calledSymbols.keys) {
          if (!callGraph.symbols.containsKey(called)) continue;
          
          inDegree[called] = inDegree[called]! - 1;
          
          if (inDegree[called] == 0) {
            final newLayer = currentLayer + 1;
            nodeLayer[called] = newLayer;
            layers.putIfAbsent(newLayer, () => []).add(called);
            queue.add(called);
          } else if (!nodeLayer.containsKey(called)) {
            // Assign temporary layer for cycle detection
            final tentativeLayer = currentLayer + 1;
            if (!nodeLayer.containsKey(called) || nodeLayer[called]! < tentativeLayer) {
              if (nodeLayer.containsKey(called)) {
                final oldLayer = nodeLayer[called]!;
                layers[oldLayer]?.remove(called);
              }
              nodeLayer[called] = tentativeLayer;
              layers.putIfAbsent(tentativeLayer, () => []).add(called);
            }
          }
        }
      }
    }
    
    // Phase 2: Minimize edge crossings (simplified - use barycenter heuristic)
    for (var layerNum in layers.keys.toList()..sort()) {
      if (layerNum == 0) continue;
      
      final currentLayer = layers[layerNum]!;
      final positions = <String, double>{};
      
      for (var node in currentLayer) {
        // Calculate barycenter position based on connected nodes in previous layer
        final connectedInPrevLayer = <String>[];
        if (callers.containsKey(node)) {
          for (var caller in callers[node]!) {
            if (nodeLayer[caller] == layerNum - 1) {
              connectedInPrevLayer.add(caller);
            }
          }
        }
        
        if (connectedInPrevLayer.isNotEmpty) {
          double sum = 0;
          final prevLayer = layers[layerNum - 1];
          if (prevLayer != null) {
            for (var caller in connectedInPrevLayer) {
              sum += prevLayer.indexOf(caller);
            }
            positions[node] = sum / connectedInPrevLayer.length;
          } else {
            positions[node] = currentLayer.indexOf(node).toDouble();
          }
        } else {
          positions[node] = currentLayer.indexOf(node).toDouble();
        }
      }
      
      // Sort layer by barycenter
      currentLayer.sort((a, b) => (positions[a] ?? 0).compareTo(positions[b] ?? 0));
    }
    
    // Phase 3: Coordinate assignment
    const layerSeparation = 180.0;
    const nodeSeparation = 120.0;
    
    for (var entry in layers.entries) {
      final layerNum = entry.key;
      final layerNodes = entry.value;
      final y = layerNum * layerSeparation;
      
      for (var i = 0; i < layerNodes.length; i++) {
        final x = (i - layerNodes.length / 2) * nodeSeparation;
        positions[layerNodes[i]] = Offset(x, y);
      }
    }
    
    // Handle isolated nodes (no connections at all) — grid above main graph
    final isolatedNodes = nodes.where((n) => !hasConnections.contains(n)).toList();

    if (isolatedNodes.isNotEmpty) {
      final gridCols = math.sqrt(isolatedNodes.length).ceil();
      const isolatedSpacing = 80.0;

      double minY = double.infinity;
      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (var pos in positions.values) {
        if (pos.dy < minY) minY = pos.dy;
        if (pos.dx < minX) minX = pos.dx;
        if (pos.dx > maxX) maxX = pos.dx;
      }
      if (minY == double.infinity) minY = 0;
      if (minX == double.infinity) minX = 0;
      if (maxX == double.negativeInfinity) maxX = 0;

      final gridRows = (isolatedNodes.length / gridCols).ceil();
      final gridHeight = gridRows * isolatedSpacing;
      final startY = minY - gridHeight - 200;
      final centerX = (minX + maxX) / 2;
      final gridWidth = gridCols * isolatedSpacing;
      final startX = centerX - gridWidth / 2;

      for (var i = 0; i < isolatedNodes.length; i++) {
        final row = i ~/ gridCols;
        final col = i % gridCols;
        final x = startX + col * isolatedSpacing;
        final y = startY + row * isolatedSpacing;
        positions[isolatedNodes[i]] = Offset(x, y);
      }
    }

    return positions;
  }

  Map<String, Offset> _applyCircularLayout(cg.CallGraph callGraph, List<String> nodes) {
    final positions = <String, Offset>{};
    final depths = <String, int>{};
    final visited = <String>{};
    
    // Identify nodes with any connections
    final callers = <String, Set<String>>{};
    final hasConnections = <String>{};
    
    for (var entry in callGraph.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (var called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        hasConnections.add(called);
      }
    }
    
    // BFS to find depth of each node
    void bfs(String start) {
      final queue = <String>[start];
      depths[start] = 0;
      visited.add(start);
      
      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        final currentDepth = depths[current]!;
        
        final symbol = callGraph.symbols[current];
        if (symbol != null) {
          for (var called in symbol.calledSymbols.keys) {
            if (!visited.contains(called) && callGraph.symbols.containsKey(called)) {
              visited.add(called);
              depths[called] = currentDepth + 1;
              queue.add(called);
            }
          }
        }
      }
    }
    
    final entryPoints = nodes.where((n) => 
      hasConnections.contains(n) && (
        !callers.containsKey(n) || 
        n.toLowerCase().contains('main') || 
        n.toLowerCase().contains('reset')
      )
    ).toList();
    
    for (var entry in entryPoints) {
      if (!visited.contains(entry)) {
        bfs(entry);
      }
    }
    
    // Separate connected nodes from truly isolated nodes
    final isolatedNodes = nodes.where((n) => !hasConnections.contains(n)).toList();
    
    // Group connected nodes by depth and arrange in circles
    final nodesByDepth = <int, List<String>>{};
    for (var entry in depths.entries) {
      nodesByDepth.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    
    for (var entry in nodesByDepth.entries) {
      final depth = entry.key;
      final nodesAtDepth = entry.value;
      final radius = (depth + 1) * 150.0;
      
      for (var i = 0; i < nodesAtDepth.length; i++) {
        final angle = (i / nodesAtDepth.length) * 2 * math.pi;
        final x = math.cos(angle) * radius;
        final y = math.sin(angle) * radius;
        positions[nodesAtDepth[i]] = Offset(x, y);
      }
    }
    
    // Position isolated nodes in a compact grid above the main graph
    if (isolatedNodes.isNotEmpty) {
      final gridCols = math.sqrt(isolatedNodes.length).ceil();
      const isolatedSpacing = 80.0;

      double minY = double.infinity;
      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (var pos in positions.values) {
        if (pos.dy < minY) minY = pos.dy;
        if (pos.dx < minX) minX = pos.dx;
        if (pos.dx > maxX) maxX = pos.dx;
      }
      if (minY == double.infinity) minY = 0;
      if (minX == double.infinity) minX = 0;
      if (maxX == double.negativeInfinity) maxX = 0;

      final gridRows = (isolatedNodes.length / gridCols).ceil();
      final gridHeight = gridRows * isolatedSpacing;
      final startY = minY - gridHeight - 200;
      final centerX = (minX + maxX) / 2;
      final gridWidth = gridCols * isolatedSpacing;
      final startX = centerX - gridWidth / 2;

      for (var i = 0; i < isolatedNodes.length; i++) {
        final row = i ~/ gridCols;
        final col = i % gridCols;
        final x = startX + col * isolatedSpacing;
        final y = startY + row * isolatedSpacing;
        positions[isolatedNodes[i]] = Offset(x, y);
      }
    }

    return positions;
  }

  Map<String, Offset> _applyGridLayout(List<String> nodes) {
    final positions = <String, Offset>{};
    final gridSize = math.sqrt(nodes.length).ceil();
    const spacing = 100.0;
    
    for (var i = 0; i < nodes.length; i++) {
      final row = i ~/ gridSize;
      final col = i % gridSize;
      final x = (col - gridSize / 2) * spacing;
      final y = (row - gridSize / 2) * spacing;
      positions[nodes[i]] = Offset(x, y);
    }
    
    return positions;
  }

  Map<String, Offset> _applyExecutionOrderLayout(cg.CallGraph callGraph, List<String> nodes) {
    final positions = <String, Offset>{};
    
    // Build caller relationships
    final callers = <String, Set<String>>{};
    final hasConnections = <String>{};
    
    for (var entry in callGraph.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (var called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        hasConnections.add(called);
      }
    }
    
    // 1. Identify entry points with priority scoring
    final entryPoints = <String>[];
    final priorities = <String, int>{};
    
    for (var symbol in nodes) {
      if (!hasConnections.contains(symbol)) continue;
      
      final symbolLower = symbol.toLowerCase();
      int priority = 100;
      
      // Highest priority: main, _start, reset handlers
      if (symbolLower == 'main' || symbolLower == '_start' || 
          symbolLower == 'reset_handler' || symbolLower == 'reset') {
        priority = 0;
        entryPoints.insert(0, symbol);
      }
      // High priority: init, setup functions
      else if (symbolLower.contains('init') || symbolLower.contains('setup')) {
        priority = 10;
      }
      // Medium priority: interrupt/exception handlers
      else if (symbolLower.contains('handler') || symbolLower.contains('isr') || 
               symbolLower.contains('irq') || symbolLower.contains('exception')) {
        priority = 20;
      }
      // Low priority: utility/helper functions
      else if (symbolLower.contains('util') || symbolLower.contains('helper') ||
               symbolLower.contains('get') || symbolLower.contains('set')) {
        priority = 200;
      }
      
      priorities[symbol] = priority;
      
      // Add as entry point if no callers
      if (!callers.containsKey(symbol) && priority < 100) {
        entryPoints.add(symbol);
      }
    }
    
    // If no explicit entry points found, use nodes with no callers
    if (entryPoints.isEmpty) {
      for (var symbol in nodes) {
        if (hasConnections.contains(symbol) && !callers.containsKey(symbol)) {
          entryPoints.add(symbol);
        }
      }
    }
    
    // 2. Assign execution depths using BFS with priority consideration
    final depths = <String, int>{};
    final visited = <String>{};
    final nodeScores = <String, double>{};
    
    void bfs(String start, int startPriority) {
      final queue = <String>[start];
      depths[start] = startPriority ~/ 10; // Convert priority to initial depth
      visited.add(start);
      
      while (queue.isNotEmpty) {
        final current = queue.removeAt(0);
        final currentDepth = depths[current]!;
        
        final symbol = callGraph.symbols[current];
        if (symbol != null) {
          final callees = symbol.calledSymbols.keys.toList();
          
          // Sort callees by instruction count (larger first) and priority
          callees.sort((a, b) {
            final aInstr = callGraph.symbols[a]?.numInstructions ?? 0;
            final bInstr = callGraph.symbols[b]?.numInstructions ?? 0;
            final aPri = priorities[a] ?? 100;
            final bPri = priorities[b] ?? 100;
            
            if (aPri != bPri) return aPri.compareTo(bPri);
            return bInstr.compareTo(aInstr);
          });
          
          for (var called in callees) {
            if (!callGraph.symbols.containsKey(called)) continue;
            
            final newDepth = currentDepth + 1;
            
            if (!visited.contains(called)) {
              visited.add(called);
              depths[called] = newDepth;
              queue.add(called);
            } else if ((depths[called] ?? double.infinity.toInt()) > newDepth) {
              // Update to shallower depth (earlier execution)
              depths[called] = newDepth;
            }
          }
        }
      }
    }
    
    // Run BFS from entry points, sorted by priority
    entryPoints.sort((a, b) => (priorities[a] ?? 100).compareTo(priorities[b] ?? 100));
    for (var entry in entryPoints) {
      if (!visited.contains(entry)) {
        bfs(entry, priorities[entry] ?? 100);
      }
    }
    
    // 3. Calculate node importance scores
    for (var symbol in nodes) {
      if (!hasConnections.contains(symbol)) continue;
      
      final instrCount = callGraph.symbols[symbol]?.numInstructions ?? 0;
      final inDegree = callers[symbol]?.length ?? 0;
      final outDegree = callGraph.symbols[symbol]?.calledSymbols.length ?? 0;
      
      // Score: larger instruction count + more callers = more important
      nodeScores[symbol] = (instrCount * 0.1) + (inDegree * 10.0) + (outDegree * 2.0);
    }
    
    // 4. Group nodes by depth and sort within each level
    final nodesByDepth = <int, List<String>>{};
    for (var entry in depths.entries) {
      nodesByDepth.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    
    // Sort nodes within each depth by score (descending)
    for (var nodesAtDepth in nodesByDepth.values) {
      nodesAtDepth.sort((a, b) {
        final scoreA = nodeScores[a] ?? 0;
        final scoreB = nodeScores[b] ?? 0;
        if (scoreA != scoreB) return scoreB.compareTo(scoreA);
        return a.compareTo(b); // Alphabetical as tiebreaker
      });
    }
    
    // 5. Position nodes
    const levelSeparation = 180.0;
    const nodeSeparation = 120.0;
    
    for (var entry in nodesByDepth.entries) {
      final depth = entry.key;
      final nodesAtDepth = entry.value;
      final y = depth * levelSeparation;
      
      for (var i = 0; i < nodesAtDepth.length; i++) {
        final x = (i - nodesAtDepth.length / 2) * nodeSeparation;
        positions[nodesAtDepth[i]] = Offset(x, y);
      }
    }
    
    // 6. Handle isolated nodes — grid above main graph
    final isolatedNodes = nodes.where((n) => !hasConnections.contains(n)).toList();

    if (isolatedNodes.isNotEmpty) {
      final gridCols = math.sqrt(isolatedNodes.length).ceil();
      const isolatedSpacing = 80.0;

      double minY = double.infinity;
      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (var pos in positions.values) {
        if (pos.dy < minY) minY = pos.dy;
        if (pos.dx < minX) minX = pos.dx;
        if (pos.dx > maxX) maxX = pos.dx;
      }
      if (minY == double.infinity) minY = 0;
      if (minX == double.infinity) minX = 0;
      if (maxX == double.negativeInfinity) maxX = 0;

      final gridRows = (isolatedNodes.length / gridCols).ceil();
      final gridHeight = gridRows * isolatedSpacing;
      final startY = minY - gridHeight - 200;
      final centerX = (minX + maxX) / 2;
      final gridWidth = gridCols * isolatedSpacing;
      final startX = centerX - gridWidth / 2;

      for (var i = 0; i < isolatedNodes.length; i++) {
        final row = i ~/ gridCols;
        final col = i % gridCols;
        final x = startX + col * isolatedSpacing;
        final y = startY + row * isolatedSpacing;
        positions[isolatedNodes[i]] = Offset(x, y);
      }
    }

    return positions;
  }

  void _applyCurrentLayout() {
    if (_cachedCallGraph == null) return;
    
    final nodes = _cachedCallGraph!.symbols.keys.toList();
    Map<String, Offset> positions;
    
    switch (_currentLayout) {
      case GraphLayout.forceDirected:
        positions = _applyForceDirectedLayout(_cachedCallGraph!, nodes);
        break;
      case GraphLayout.hierarchical:
        positions = _applyHierarchicalLayout(_cachedCallGraph!, nodes);
        break;
      case GraphLayout.sugiyama:
        positions = _applySugiyamaLayout(_cachedCallGraph!, nodes);
        break;
      case GraphLayout.circular:
        positions = _applyCircularLayout(_cachedCallGraph!, nodes);
        break;
      case GraphLayout.grid:
        positions = _applyGridLayout(nodes);
        break;
      case GraphLayout.executionOrder:
        positions = _applyExecutionOrderLayout(_cachedCallGraph!, nodes);
        break;
    }
    
    setState(() {
      _nodePositions = positions;
      for (var node in nodes) {
        _nodeVelocities[node] = Offset.zero;
      }
    });
    
    _startAnimation();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitGraphToView());
  }

  /// Smoothly animate the view transform from current to [target].
  void _animateToTransform(Matrix4 target) {
    _viewAnimStart = _transformationController.value.clone();
    _viewAnimEnd = target;
    _viewAnimController.forward(from: 0.0);
  }

  /// Called each frame during a view animation — interpolates the Matrix4.
  void _onViewAnimTick() {
    if (_viewAnimStart == null || _viewAnimEnd == null) return;
    final t = Curves.easeInOut.transform(_viewAnimController.value);
    final startStorage = _viewAnimStart!.storage;
    final endStorage = _viewAnimEnd!.storage;
    final result = Matrix4.zero();
    for (int i = 0; i < 16; i++) {
      result.storage[i] = startStorage[i] + (endStorage[i] - startStorage[i]) * t;
    }
    _transformationController.value = result;
  }

  /// Compute the adjusted position offset (same as _buildGraph).
  Offset _adjustedOffset(String name) {
    double minX = 0, minY = 0;
    for (var pos in _nodePositions.values) {
      if (pos.dx < minX) minX = pos.dx;
      if (pos.dy < minY) minY = pos.dy;
    }
    final offsetX = -minX + 1000;
    final offsetY = -minY + 1000;
    final pos = _nodePositions[name];
    if (pos == null) return Offset.zero;
    return Offset(pos.dx + offsetX, pos.dy + offsetY);
  }

  /// Animate zoom/pan to frame [symbolName] and its immediate neighbors.
  void _focusOnNode(String symbolName) {
    if (_nodePositions.isEmpty || !_nodePositions.containsKey(symbolName)) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final viewportSize = renderBox.size;

    // Collect the node + its callees + callers.
    final positions = <Offset>[_adjustedOffset(symbolName)];
    final callGraph = _cachedCallGraph;
    if (callGraph != null) {
      final sym = callGraph.symbols[symbolName];
      if (sym != null) {
        for (final callee in sym.calledSymbols.keys) {
          if (_nodePositions.containsKey(callee)) {
            positions.add(_adjustedOffset(callee));
          }
        }
      }
      for (final caller in callGraph.getCallers(symbolName)) {
        if (_nodePositions.containsKey(caller)) {
          positions.add(_adjustedOffset(caller));
        }
      }
    }

    // Bounding box of neighborhood.
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in positions) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }

    final graphWidth = maxX - minX + 300;
    final graphHeight = maxY - minY + 300;
    final centerX = (minX + maxX) / 2;
    final centerY = (minY + maxY) / 2;

    final scaleX = viewportSize.width / graphWidth;
    final scaleY = viewportSize.height / graphHeight;
    // Clamp to reasonable range so single-node views aren't absurdly zoomed.
    final scale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.1, 3.0) * 0.85;

    final target = Matrix4.identity()
      ..translate(viewportSize.width / 2 - centerX * scale, viewportSize.height / 2 - centerY * scale)
      ..scale(scale);
    _animateToTransform(target);
  }

  void _fitGraphToView({bool animate = true}) {
    if (_nodePositions.isEmpty) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final viewportSize = renderBox.size;

    // Calculate bounds from original node positions
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (var pos in _nodePositions.values) {
      if (pos.dx < minX) minX = pos.dx;
      if (pos.dy < minY) minY = pos.dy;
      if (pos.dx > maxX) maxX = pos.dx;
      if (pos.dy > maxY) maxY = pos.dy;
    }

    // Calculate adjusted positions (same logic as _buildGraph)
    final offsetX = -minX + 1000;
    final offsetY = -minY + 1000;

    // Now calculate bounds of adjusted positions
    final adjustedMinX = minX + offsetX;
    final adjustedMinY = minY + offsetY;
    final adjustedMaxX = maxX + offsetX;
    final adjustedMaxY = maxY + offsetY;

    final graphWidth = adjustedMaxX - adjustedMinX + 200;
    final graphHeight = adjustedMaxY - adjustedMinY + 200;
    final centerX = (adjustedMinX + adjustedMaxX) / 2;
    final centerY = (adjustedMinY + adjustedMaxY) / 2;

    final scaleX = viewportSize.width / graphWidth;
    final scaleY = viewportSize.height / graphHeight;
    final scale = (scaleX < scaleY ? scaleX : scaleY) * 0.9;

    final target = Matrix4.identity()
      ..translate(viewportSize.width / 2 - centerX * scale, viewportSize.height / 2 - centerY * scale)
      ..scale(scale);

    if (animate) {
      _animateToTransform(target);
    } else {
      _transformationController.value = target;
    }
  }

  @override
  Widget build(BuildContext context) {
    final callgraphAsync = ref.watch(callgraphProvider);

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyZ &&
            HardwareKeyboard.instance.isShiftPressed) {
          _fitGraphToView();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final newSize = Size(constraints.maxWidth, constraints.maxHeight);
          if (_lastViewportSize != null && _lastViewportSize != newSize && _nodePositions.isNotEmpty) {
            _lastViewportSize = newSize;
            WidgetsBinding.instance.addPostFrameCallback((_) => _fitGraphToView(animate: false));
          }
          _lastViewportSize = newSize;

          return Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: callgraphAsync.when(
              data: (callGraph) {
                if (callGraph == null) {
                  return _buildWelcomeMessage(context);
                }
                _buildLayout(callGraph);
                return _buildGraph(context, ref, callGraph);
              },
          loading: () => const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Generating call graph...'),
              ],
            ),
          ),
          error: (error, stack) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text('Failed to generate call graph'),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    error.toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
          ),
        );
        },
      ),
    );
  }

  /// Detect newly executed/hooked symbols and spawn ripple animations.
  void _checkForNewRipples(Set<String> executedSymbols, Set<String> hookedSymbols) {
    bool spawned = false;

    // New executed symbols → green ripple
    for (final symbol in executedSymbols) {
      if (!_prevExecutedSymbols.contains(symbol)) {
        final degree = _nodeDegrees[symbol] ?? 0;
        _activeRipples.add(_NodeRipple(
          symbol: symbol,
          color: Colors.green,
          maxRadius: (120.0 + math.log(1 + degree) * 80.0).clamp(120.0, 400.0),
        ));
        spawned = true;
      }
    }

    // New hooked symbols → red ripple
    for (final symbol in hookedSymbols) {
      if (!_prevHookedSymbols.contains(symbol)) {
        final degree = _nodeDegrees[symbol] ?? 0;
        _activeRipples.add(_NodeRipple(
          symbol: symbol,
          color: Colors.red,
          maxRadius: (150.0 + math.log(1 + degree) * 100.0).clamp(150.0, 500.0),
        ));
        spawned = true;
      }
    }

    _prevExecutedSymbols = Set.of(executedSymbols);
    _prevHookedSymbols = Set.of(hookedSymbols);

    // Start the ripple timer if we have active ripples
    if (spawned && _rippleTimer == null) {
      _rippleTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        _activeRipples.removeWhere((r) => r.isComplete);
        if (_activeRipples.isEmpty) {
          _rippleTimer?.cancel();
          _rippleTimer = null;
        }
        // Bump the notifier to trigger CustomPaint repaint directly
        _rippleNotifier.value++;
      });
    }
  }

  /// Build welcome message when no file is loaded
  Widget _buildWelcomeMessage(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.memory,
            size: 64,
            color: Colors.grey.shade700,
          ),
          const SizedBox(height: 16),
          Text(
            'Welcome to ${AppConstants.appName}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create or open an emulator to get started',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          const Text(
            'File \u2192 New Emulator...\nFile \u2192 Open Emulator...',
            style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Build the actual graph visualization
  Widget _buildGraph(BuildContext context, WidgetRef ref, cg.CallGraph callGraph) {
    // Detect newly executed/hooked symbols and spawn ripple animations
    _checkForNewRipples(ref.watch(executedSymbolsProvider), ref.watch(hookedSymbolsProvider));

    // Calculate canvas size based on actual node positions
    double minX = 0, minY = 0, maxX = 0, maxY = 0;
    for (var pos in _nodePositions.values) {
      if (pos.dx < minX) minX = pos.dx;
      if (pos.dy < minY) minY = pos.dy;
      if (pos.dx > maxX) maxX = pos.dx;
      if (pos.dy > maxY) maxY = pos.dy;
    }
    
    final canvasWidth = math.max(4000.0, maxX - minX + 2000);
    final canvasHeight = math.max(4000.0, maxY - minY + 2000);
    final offsetX = -minX + 1000;
    final offsetY = -minY + 1000;
    
    // Adjust node positions to fit in canvas
    final adjustedPositions = <String, Offset>{};
    for (var entry in _nodePositions.entries) {
      adjustedPositions[entry.key] = Offset(
        entry.value.dx + offsetX,
        entry.value.dy + offsetY,
      );
    }
    
    return Stack(
      children: [
        InteractiveViewer(
          transformationController: _transformationController,
          constrained: false,
          boundaryMargin: EdgeInsets.all(math.max(canvasWidth, canvasHeight)),
          minScale: 0.01,
          maxScale: 10.0,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (details) {
              final localPos = details.localPosition;
              
              // Find node under tap
              bool nodeWasTapped = false;
              for (var entry in adjustedPositions.entries) {
                bool hit = false;
                
                if (_currentNodeStyle == NodeStyle.labeledBox) {
                  // For labeled boxes, check if point is inside the box
                  final boxSize = _getLabeledBoxSize(entry.key);
                  final rect = Rect.fromCenter(
                    center: entry.value,
                    width: boxSize.width,
                    height: boxSize.height,
                  );
                  hit = rect.contains(localPos);
                } else {
                  // For other styles, use distance-based hit detection
                  final dist = (entry.value - localPos).distance;
                  hit = dist < 20;
                }
                
                if (hit) {
                  ref.read(selectedSymbolProvider.notifier).state = entry.key;
                  if (_focusOnSelect) _focusOnNode(entry.key);
                  nodeWasTapped = true;
                  return;
                }
              }
              
              // If no node was tapped, deselect the current selection
              if (!nodeWasTapped) {
                ref.read(selectedSymbolProvider.notifier).state = null;
              }
            },
            onPanStart: (details) {
              // Only allow node dragging when Shift is held
              if (!HardwareKeyboard.instance.isShiftPressed) return;
              
              final localPos = details.localPosition;
              
              // Find node under drag
              for (var entry in adjustedPositions.entries) {
                bool hit = false;
                
                if (_currentNodeStyle == NodeStyle.labeledBox) {
                  // For labeled boxes, check if point is inside the box
                  final boxSize = _getLabeledBoxSize(entry.key);
                  final rect = Rect.fromCenter(
                    center: entry.value,
                    width: boxSize.width,
                    height: boxSize.height,
                  );
                  hit = rect.contains(localPos);
                } else {
                  // For other styles, use distance-based hit detection
                  final dist = (entry.value - localPos).distance;
                  hit = dist < 20;
                }
                
                if (hit) {
                  setState(() {
                    _draggedNode = entry.key;
                    _dragOffset = localPos - entry.value;
                  });
                  ref.read(selectedSymbolProvider.notifier).state = entry.key;
                  _startAnimation();
                  return;
                }
              }
            },
            onPanUpdate: (details) {
              if (_draggedNode != null && HardwareKeyboard.instance.isShiftPressed) {
                final localPos = details.localPosition;
                
                setState(() {
                  _nodePositions[_draggedNode!] = Offset(
                    localPos.dx - (_dragOffset?.dx ?? 0) - offsetX,
                    localPos.dy - (_dragOffset?.dy ?? 0) - offsetY,
                  );
                });
              }
            },
            onPanEnd: (details) {
              if (_draggedNode != null) {
                setState(() {
                  _draggedNode = null;
                  _dragOffset = null;
                });
              }
            },
            child: CustomPaint(
              size: Size(canvasWidth, canvasHeight),
              painter: _GraphPainter(
                nodePositions: adjustedPositions,
                edges: _edges,
                callGraph: callGraph,
                selectedSymbol: ref.watch(selectedSymbolProvider),
                draggedNode: _draggedNode,
                nodeStyle: _currentNodeStyle,
                executedSymbols: ref.watch(executedSymbolsProvider),
                hookedSymbols: ref.watch(hookedSymbolsProvider),
                overriddenSymbols: ref.watch(hookOverridesProvider).keys.toSet(),
                nodeDegrees: _scaleByDegree ? _nodeDegrees : null,
                ripples: _activeRipples,
                repaint: _rippleNotifier,
              ),
            ),
          ),
        ),
        // RUN button overlay (top-left)
        Positioned(
          top: 16,
          left: 16,
          child: _buildRunButton(context, ref),
        ),
        // Graph options popup menu (top-right)
        Positioned(
          top: 16,
          right: 16,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade700, width: 1),
            ),
            child: PopupMenuButton<void>(
              tooltip: 'Graph options',
              color: Colors.grey[900],
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              offset: const Offset(0, 44),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.settings, color: Colors.white, size: 20),
              ),
              itemBuilder: (context) => [
                // — Layout section —
                const PopupMenuItem<void>(
                  enabled: false,
                  height: 28,
                  child: Text('LAYOUT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                ),
                for (final layout in GraphLayout.values)
                  PopupMenuItem<void>(
                    height: 36,
                    onTap: () {
                      setState(() { _currentLayout = layout; });
                      _applyCurrentLayout();
                    },
                    child: Row(
                      children: [
                        SizedBox(width: 24, child: _currentLayout == layout ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                        Text(_layoutLabel(layout), style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                // — Node Style section —
                const PopupMenuItem<void>(
                  enabled: false,
                  height: 28,
                  child: Text('NODE STYLE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 1.2)),
                ),
                for (final style in NodeStyle.values)
                  PopupMenuItem<void>(
                    height: 36,
                    onTap: () {
                      setState(() {
                        _currentNodeStyle = style;
                        if (style == NodeStyle.labeledBox) {
                          _nodeSizeCache.clear();
                          for (var node in _nodePositions.keys) {
                            _getLabeledBoxSize(node);
                          }
                        }
                      });
                    },
                    child: Row(
                      children: [
                        SizedBox(width: 24, child: _currentNodeStyle == style ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                        Text(_nodeStyleLabel(style), style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                // — Toggles —
                PopupMenuItem<void>(
                  height: 36,
                  onTap: () {
                    setState(() {
                      _animationEnabled = !_animationEnabled;
                      if (!_animationEnabled) {
                        _animationController.stop();
                      } else {
                        _startAnimation();
                      }
                    });
                  },
                  child: Row(
                    children: [
                      SizedBox(width: 24, child: _animationEnabled ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                      const Text('Animate', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
                PopupMenuItem<void>(
                  height: 36,
                  onTap: () {
                    setState(() { _scaleByDegree = !_scaleByDegree; });
                  },
                  child: Row(
                    children: [
                      SizedBox(width: 24, child: _scaleByDegree ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                      const Text('Size by Degree', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
                PopupMenuItem<void>(
                  height: 36,
                  onTap: () {
                    setState(() { _focusOnSelect = !_focusOnSelect; });
                  },
                  child: Row(
                    children: [
                      SizedBox(width: 24, child: _focusOnSelect ? const Icon(Icons.check, size: 16, color: Colors.white) : null),
                      const Text('Focus on Select', style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // Synthesis report overlay (shown after synthesis completes)
        _buildSynthesisReportOverlay(ref),
      ],
    );
  }

  /// Build the synthesis report overlay that appears after synthesis completes.
  Widget _buildSynthesisReportOverlay(WidgetRef ref) {
    final result = ref.watch(synthesisResultProvider);
    if (result == null) return const SizedBox.shrink();

    final emulator = ref.watch(currentEmulatorProvider);
    final fidelity = ref.watch(fidelityResultProvider);

    return Positioned(
      bottom: 16,
      left: 16,
      right: 16,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Material(
            elevation: 12,
            borderRadius: BorderRadius.circular(10),
            color: Colors.grey.shade900,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: result.success ? Colors.green.withAlpha(100) : Colors.red.withAlpha(100),
                  width: 1.5,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row with title and close button
                  Row(
                    children: [
                      Icon(
                        result.success ? Icons.check_circle : Icons.error,
                        color: result.success ? Colors.green : Colors.red,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          result.success
                              ? 'Synthesis Complete'
                              : 'Synthesis Failed',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: result.success ? Colors.green.shade300 : Colors.red.shade300,
                          ),
                        ),
                      ),
                      // Close button
                      InkWell(
                        onTap: () => ref.read(synthesisResultProvider.notifier).state = null,
                        borderRadius: BorderRadius.circular(12),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close, size: 18, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Summary stats
                  Row(
                    children: [
                      _reportStat('Iterations', '${result.totalIterations}'),
                      const SizedBox(width: 16),
                      _reportStat('Hooks Applied', '${result.resolvedHooks.length}'),
                      const SizedBox(width: 16),
                      _reportStat('Duration', '${result.totalDuration.inSeconds}s'),
                    ],
                  ),

                  // Prominent fidelity score + bar
                  if (fidelity != null) ...[
                    const SizedBox(height: 12),
                    _buildFidelityDisplay(fidelity),
                  ],

                  if (!result.success && result.failedSymbol != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Failed at: ${result.failedSymbol}',
                      style: TextStyle(fontSize: 11, color: Colors.red.shade300),
                    ),
                  ],

                  // Hook substitution table
                  if (result.resolvedHooks.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'SUBSTITUTED FUNCTIONS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 160),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Scrollbar(
                        thumbVisibility: true,
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(8),
                          itemCount: result.resolvedHooks.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: Colors.grey.shade800,
                          ),
                          itemBuilder: (context, index) {
                            final symbol = result.resolvedHooks.keys.elementAt(index);
                            final hookName = result.resolvedHooks[symbol]!;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Icon(Icons.functions, size: 12, color: Colors.red.shade400),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      symbol,
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(Icons.arrow_forward, size: 10, color: Colors.grey.shade600),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      hookName,
                                      style: TextStyle(fontSize: 10, color: Colors.green.shade400),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // Export buttons
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _exportButton(
                        icon: Icons.save,
                        label: 'Save Emulator',
                        onPressed: emulator != null
                            ? () => _exportSaveEmulator(context, ref, emulator)
                            : null,
                      ),
                      _exportButton(
                        icon: Icons.code,
                        label: 'Export .resc',
                        onPressed: emulator != null && emulator.hooks.isNotEmpty
                            ? () => _exportResc(context, ref, emulator)
                            : null,
                      ),
                      _exportButton(
                        icon: Icons.data_object,
                        label: 'Export JSON',
                        onPressed: () => _exportResultJson(context, result, fidelity),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _reportStat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }

  String _layoutLabel(GraphLayout layout) {
    switch (layout) {
      case GraphLayout.forceDirected: return 'Force-Directed';
      case GraphLayout.hierarchical: return 'Hierarchical';
      case GraphLayout.sugiyama: return 'Sugiyama';
      case GraphLayout.circular: return 'Circular';
      case GraphLayout.grid: return 'Grid';
      case GraphLayout.executionOrder: return 'Execution Order';
    }
  }

  String _nodeStyleLabel(NodeStyle style) {
    switch (style) {
      case NodeStyle.circle: return 'Circle';
      case NodeStyle.box: return 'Box';
      case NodeStyle.labeledBox: return 'Labeled Box';
      case NodeStyle.dot: return 'Dot';
    }
  }

  /// Prominent fidelity display with large score, progress bar, and breakdown.
  Color _fidelityColor(double pct) {
    if (pct >= 0.8) return Colors.green;
    if (pct >= 0.5) return Colors.orange;
    return Colors.red;
  }

  Widget _buildFidelityDisplay(FidelityResult fidelity) {
    final pct = fidelity.overallFidelity;
    final pctString = (pct * 100).toStringAsFixed(1);
    final scoreColor = _fidelityColor(pct);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Primary: overall fidelity — large and prominent
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$pctString%',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: scoreColor,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'FIDELITY',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Overall progress bar (thicker for prominence)
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: pct,
                backgroundColor: Colors.grey.shade800,
                valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
              ),
            ),
          ),
          // Secondary metrics row: coverage + coverage fidelity
          if (fidelity.coverage != null || fidelity.coverageFidelity != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                // Coverage metric
                if (fidelity.coverage != null) ...[
                  _secondaryMetric(
                    value: fidelity.coverage!,
                    label: 'COVERAGE',
                    detail: '${fidelity.traversedFunctions}/${fidelity.totalFunctions}',
                  ),
                ],
                // Coverage fidelity metric
                if (fidelity.coverageFidelity != null) ...[
                  if (fidelity.coverage != null) const SizedBox(width: 20),
                  _secondaryMetric(
                    value: fidelity.coverageFidelity!,
                    label: 'COVERAGE FIDELITY',
                  ),
                ],
                // Subgraph fidelity (if available)
                if (fidelity.subgraphFidelity != null) ...[
                  const SizedBox(width: 20),
                  _secondaryMetric(
                    value: fidelity.subgraphFidelity!,
                    label: 'SUBGRAPH FIDELITY',
                    detail: '${fidelity.subgraphFunctions}',
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 6),
          // Breakdown counts
          Text(
            '${fidelity.intactFunctions} intact · '
            '${fidelity.degradedFunctions} degraded · '
            '${fidelity.hookedFunctions} hooked',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  /// A compact secondary metric (used for coverage, coverage fidelity, subgraph).
  Widget _secondaryMetric({
    required double value,
    required String label,
    String? detail,
  }) {
    final color = _fidelityColor(value);
    final pctStr = (value * 100).toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$pctStr%',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
                height: 1.0,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              detail != null ? '$label ($detail)' : label,
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        SizedBox(
          width: 100,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 3,
              child: LinearProgressIndicator(
                value: value,
                backgroundColor: Colors.grey.shade800,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _exportButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      height: 30,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.grey.shade800,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade800.withAlpha(100),
          disabledForegroundColor: Colors.grey.shade600,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }

  /// Save the emulator .emu file (with hooks baked in).
  Future<void> _exportSaveEmulator(BuildContext context, WidgetRef ref, dynamic emulator) async {
    final repository = ref.read(emulatorRepositoryProvider);

    String? savePath = emulator.emulatorPath;
    if (savePath == null) {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Emulator',
        fileName: '${emulator.name}.emu',
        allowedExtensions: ['emu'],
        type: FileType.custom,
      );
      if (result == null) return;
      savePath = result;
    }

    try {
      final updated = emulator.copyWith(emulatorPath: savePath, modifiedAt: DateTime.now());
      await repository.saveEmulator(updated, savePath);
      ref.read(currentEmulatorProvider.notifier).state = updated;
      ref.read(emulatorDirtyProvider.notifier).state = false;
      await repository.addToRecentEmulators(savePath, emulator.name);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved: $savePath'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// Export a standalone Renode .resc script.
  Future<void> _exportResc(BuildContext context, WidgetRef ref, dynamic emulator) async {
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Renode Script',
      fileName: '${emulator.name}.resc',
      allowedExtensions: ['resc'],
      type: FileType.custom,
    );
    if (result == null) return;

    try {
      final repository = ref.read(emulatorRepositoryProvider);
      await repository.exportResc(emulator, result);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported: $result'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// Export the raw SynthesizerResult as JSON.
  Future<void> _exportResultJson(BuildContext context, SynthesizerResult result, FidelityResult? fidelity) async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Synthesis Result',
      fileName: 'synthesis_result.json',
      allowedExtensions: ['json'],
      type: FileType.custom,
    );
    if (savePath == null) return;

    try {
      final exportData = <String, dynamic>{
        ...result.toJson(),
        if (fidelity != null) 'fidelity': fidelity.toJson(),
      };
      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      await File(savePath).writeAsString(jsonString);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported: $savePath'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  /// Build the EMULATE button (with STOP/PAUSE/RESET state variants).
  Widget _buildRunButton(BuildContext context, WidgetRef ref) {
    final currentEmulator = ref.watch(currentEmulatorProvider);
    final selectedElfPath = ref.watch(selectedElfPathProvider);
    final lifecycleService = ref.watch(lifecycleServiceProvider);
    final emulationState = ref.watch(emulationStateProvider);
    final synthesisProgress = ref.watch(synthesisProgressProvider);

    final bool hasElf = selectedElfPath != null && selectedElfPath.isNotEmpty;

    // Synthesis in progress — show STOP button
    if (synthesisProgress != null && !synthesisProgress.complete) {
      return _buildActionButton(
        icon: Icons.stop,
        label: 'STOP',
        color: Colors.purple,
        onPressed: () => _stopSynthesis(context, ref, lifecycleService),
      );
    }

    // When running or paused, show PAUSE/RESET
    if (emulationState == EmulationState.running) {
      return _buildActionButton(
        icon: Icons.pause,
        label: 'PAUSE',
        color: Colors.orange,
        onPressed: () => _pauseEmulation(context, ref, lifecycleService),
      );
    }
    if (emulationState == EmulationState.paused) {
      return _buildActionButton(
        icon: Icons.refresh,
        label: 'RESET',
        color: Colors.red,
        onPressed: () => _resetEmulation(context, ref, lifecycleService),
      );
    }

    // Stopped — show EMULATE button
    final bool isEnabled = hasElf
        && currentEmulator != null
        && currentEmulator.elfFilePath != null
        && currentEmulator.baseImagePath != null;

    return ElevatedButton.icon(
      onPressed: isEnabled ? () => _emulate(context, ref) : null,
      icon: const Icon(Icons.play_arrow, size: 20),
      label: const Text('EMULATE'),
      style: ElevatedButton.styleFrom(
        backgroundColor: isEnabled ? Colors.green : Colors.grey,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  /// Helper to build a simple action button (PAUSE, RESET)
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  /// Run the synthesizer workflow (EMULATE mode).
  ///
  /// Start emulation — either synthesize hooks or run with existing ones.
  ///
  /// If previous hooks exist, shows a dialog letting the user choose:
  /// - **Synthesize**: clear resolved hooks and re-run the synthesizer
  /// - **Run**: execute with all existing hooks (no synthesis loop)
  ///
  /// If no previous hooks, goes straight to synthesis.
  Future<void> _emulate(BuildContext context, WidgetRef ref) async {
    final currentEmulator = ref.read(currentEmulatorProvider);
    final selectedElfPath = ref.read(selectedElfPathProvider);

    if (currentEmulator == null ||
        selectedElfPath == null ||
        currentEmulator.elfFilePath == null ||
        currentEmulator.baseImagePath == null) {
      return;
    }

    final elfPath = currentEmulator.elfFilePath!;
    final baseImagePath = currentEmulator.baseImagePath!;
    final hookOverrides = ref.read(hookOverridesProvider);

    // Warn if starting from a specific function without a memory map
    final config = currentEmulator.emulationConfig;
    if (config.startFrom != null &&
        config.startFrom!.isNotEmpty &&
        (config.memoryMapPath == null || config.memoryMapPath!.isEmpty)) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No Memory Map'),
          content: Text(
            'Starting from "${config.startFrom}" without a memory map '
            'may cause undefined behavior — registers and memory will '
            'not be initialized.\n\n'
            'You can add a memory map in the Execution Range section '
            'of the explorer sidebar.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Go Back'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue Anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    // If previous synthesis resolved hooks, ask whether to synthesize or run
    // Returns: 'synthesize', 'run', or null (dismissed)
    String? mode;
    var resolvedHooks = <String, String>{};
    if (currentEmulator.hooks.isNotEmpty) {
      mode = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Emulation Mode'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${currentEmulator.hooks.length} hooks were resolved in a previous session.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Choose how to proceed:',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('synthesize'),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Synthesize', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    'Clears resolved hooks and re-runs the\nsynthesizer. Overrides and preferences\nare preserved.',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('run'),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Run', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    'Executes the emulator with all resolved\nhooks and forced overrides applied.\nNo synthesis.',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      if (mode == null) return; // Dialog dismissed

      if (mode == 'synthesize') {
        // Clear stale resolved hooks from the model so explorer updates
        final cleared = currentEmulator.copyWith(hooks: {}, modifiedAt: DateTime.now());
        ref.read(currentEmulatorProvider.notifier).state = cleared;
        ref.read(emulatorDirtyProvider.notifier).state = true;
      } else {
        resolvedHooks = currentEmulator.hooks;
      }
    } else {
      mode = 'synthesize'; // No previous hooks — go straight to synthesis
    }

    // =========================================================================
    // "Run" path — execute with existing hooks, no synthesis
    // =========================================================================
    if (mode == 'run') {
      try {
        // Show loading dialog
        if (!context.mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Starting emulation...'),
              ],
            ),
          ),
        );

        final orchestrator = ref.read(emulationOrchestratorProvider);

        // Clear previous visual state
        ref.read(executedSymbolsProvider.notifier).state = {};
        ref.read(synthesisResultProvider.notifier).state = null;
        ref.read(traceActivityEventsProvider.notifier).state = [];
        _activeRipples.clear();
        _prevExecutedSymbols = {};
        _prevHookedSymbols = {};
        _synthesizerEventSubscription?.cancel();

        // Pre-populate hooked symbols so they show in the graph
        final allHookedSymbols = <String>{
          ...currentEmulator.hooks.keys,
          ...hookOverrides.keys,
        };
        ref.read(hookedSymbolsProvider.notifier).state = allHookedSymbols;

        // Subscribe to trace events
        final traceService = ref.read(traceServiceProvider);
        _traceSubscription?.cancel();
        _traceSubscription = traceService.onTrace.listen((event) {
          if (event.isEntry) {
            final executedSymbols = ref.read(executedSymbolsProvider);
            if (!executedSymbols.contains(event.symbol)) {
              ref.read(executedSymbolsProvider.notifier).update((state) => {...state, event.symbol});
            }
          }
        });

        // Subscribe to filtered trace events for trace activity sidebar
        final filteredTraceService = ref.read(filteredTraceServiceProvider);
        _filteredTraceSubscription?.cancel();
        _filteredTraceSubscription = filteredTraceService.onTrace.listen((event) {
          if (event.isEntry) {
            final currentEvents = ref.read(traceActivityEventsProvider);
            ref.read(traceActivityEventsProvider.notifier).state = [
              ...currentEvents,
              TraceActivityEvent.functionCall(event.symbol),
            ];
          }
        });

        // Subscribe to pause events for banner notifications
        _pauseEventSubscription?.cancel();
        _pauseEventSubscription = orchestrator.events.listen((event) {
          if (event is EmulationPausedEvent) {
            _showPauseBanner(context, ref, event.pauseDetails);
          } else if (event is EmulationStateChangedEvent) {
            if (event.state == EmulationState.running) {
              final currentEvents = ref.read(traceActivityEventsProvider);
              ref.read(traceActivityEventsProvider.notifier).state = [
                ...currentEvents,
                TraceActivityEvent.resumed(),
              ];
            }
          }
        });

        // Start (or restart) emulation with all hooks
        await orchestrator.restartEmulation(
          elfPath: elfPath,
          baseImagePath: baseImagePath,
          startFrom: currentEmulator.emulationConfig.startFrom,
          endAt: currentEmulator.emulationConfig.endAt,
          pauseOnUnhandled: currentEmulator.emulationConfig.pauseOnUnhandled,
          hookOverrides: hookOverrides,
          resolvedHooks: resolvedHooks,
          memoryMapPath: currentEmulator.emulationConfig.memoryMapPath,
        );

        // Close loading dialog
        if (!context.mounted) return;
        Navigator.of(context).pop();

        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Emulation started with existing hooks'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      } catch (e) {
        if (context.mounted) Navigator.of(context).pop();
        if (!context.mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Emulation Error'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return; // Done — no synthesis
    }

    // =========================================================================
    // "Synthesize" path — run the synthesis loop
    // =========================================================================
    try {
      final orchestrator = ref.read(emulationOrchestratorProvider);

      // Clear previous visual state so highlights start fresh
      ref.read(executedSymbolsProvider.notifier).state = {};
      ref.read(hookedSymbolsProvider.notifier).state = {};
      ref.read(synthesisResultProvider.notifier).state = null;
      ref.read(traceActivityEventsProvider.notifier).state = [];
      _activeRipples.clear();
      _prevExecutedSymbols = {};
      _prevHookedSymbols = {};

      // Initialize synthesis progress in sidebar
      ref.read(synthesisProgressProvider.notifier).state = SynthesisProgress(
        countdownStart: DateTime.now(),
        status: 'Starting emulation...',
      );

      // Subscribe to trace events (keep trace activity populating across iterations)
      final traceService = ref.read(traceServiceProvider);
      _traceSubscription?.cancel();
      _traceSubscription = traceService.onTrace.listen((event) {
        if (event.isEntry) {
          final executedSymbols = ref.read(executedSymbolsProvider);
          if (!executedSymbols.contains(event.symbol)) {
            ref.read(executedSymbolsProvider.notifier).update((state) => {...state, event.symbol});
          }
        }
      });

      // Subscribe to filtered trace events for trace activity sidebar
      final filteredTraceService = ref.read(filteredTraceServiceProvider);
      _filteredTraceSubscription?.cancel();
      _filteredTraceSubscription = filteredTraceService.onTrace.listen((event) {
        if (event.isEntry) {
          final currentEvents = ref.read(traceActivityEventsProvider);
          ref.read(traceActivityEventsProvider.notifier).state = [
            ...currentEvents,
            TraceActivityEvent.functionCall(event.symbol),
          ];
        }
      });

      // Do NOT subscribe to pause events — synthesizer handles pauses internally
      _pauseEventSubscription?.cancel();
      _pauseEventSubscription = null;

      // Start (or restart) emulation
      await orchestrator.restartEmulation(
        elfPath: elfPath,
        baseImagePath: baseImagePath,
        startFrom: currentEmulator.emulationConfig.startFrom,
        pauseOnUnhandled: true,
        hookOverrides: hookOverrides,
        resolvedHooks: resolvedHooks,
        memoryMapPath: currentEmulator.emulationConfig.memoryMapPath,
      );

      // Get elfHash from artifact processing
      final firmwareRecord = ref.read(artifactProcessingProvider).valueOrNull;
      if (firmwareRecord == null) {
        ref.read(synthesisProgressProvider.notifier).state = null;
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error: Firmware not processed. Ensure call graph has loaded.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      final elfHash = firmwareRecord.elfHash;

      // Update progress — emulation started, countdown begins
      ref.read(synthesisProgressProvider.notifier).state = SynthesisProgress(
        countdownStart: DateTime.now(),
        status: 'Emulation running...',
      );

      // Subscribe to synthesizer events and update provider
      _synthesizerEventSubscription?.cancel();
      _synthesizerEventSubscription = orchestrator.synthesizerWorkflow.events.listen((event) {
        final current = ref.read(synthesisProgressProvider);
        if (current == null) return;

        if (event is SynthesizerIterationStarted) {
          ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
            iteration: event.iteration,
            status: 'Iteration ${event.iteration}',
            countdownStart: DateTime.now(), // reset countdown on new iteration
          );
        } else if (event is SynthesizerHookApplied) {
          ref.read(hookedSymbolsProvider.notifier).update(
            (state) => {...state, event.symbol},
          );
          ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
            hooksApplied: current.hooksApplied + 1,
            currentSymbol: event.symbol,
            status: 'Hook: ${event.hookName}',
            countdownStart: DateTime.now(), // reset countdown
          );
        } else if (event is SynthesizerSymbolExhausted) {
          ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
            currentSymbol: event.symbol,
            status: 'Exhausted: ${event.symbol}',
          );
        } else if (event is SynthesizerCompleted) {
          final result = event.result;
          ref.read(synthesisResultProvider.notifier).state = result;
          ref.read(synthesisProgressProvider.notifier).state = current.copyWith(
            complete: true,
            success: result.success,
            status: result.success
                ? 'Complete — ${result.resolvedHooks.length} hooks'
                : 'Failed at ${result.failedSymbol}',
          );

          // Update emulator with resolved hooks
          if (result.resolvedHookCode.isNotEmpty) {
            final updatedEmulator = currentEmulator.copyWith(
              hooks: result.resolvedHookCode,
              modifiedAt: DateTime.now(),
            );
            ref.read(currentEmulatorProvider.notifier).state = updatedEmulator;
            ref.read(emulatorDirtyProvider.notifier).state = true;
          }
        }
      });

      // Run the synthesizer (blocks until complete)
      final hookPreferences = ref.read(hookPreferencesProvider);
      await orchestrator.runSynthesizer(
        elfPath: elfPath,
        baseImagePath: baseImagePath,
        elfHash: elfHash,
        startFrom: currentEmulator.emulationConfig.startFrom,
        endAt: currentEmulator.emulationConfig.endAt,
        hookPreferences: hookPreferences,
        hookOverrides: hookOverrides,
        resolvedHooks: resolvedHooks,
        memoryMapPath: currentEmulator.emulationConfig.memoryMapPath,
      );
    } catch (e) {
      // If synthesis progress was already cleared (user clicked STOP), suppress error
      if (ref.read(synthesisProgressProvider) == null) return;

      ref.read(synthesisProgressProvider.notifier).state = null;

      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Synthesis Error'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  /// Stop a running synthesis cleanly.
  ///
  /// Clears synthesis progress first so the [_emulate] catch block
  /// knows this was an intentional stop (not an unexpected error).
  Future<void> _stopSynthesis(
    BuildContext context,
    WidgetRef ref,
    dynamic lifecycleService,
  ) async {
    ref.read(synthesisProgressProvider.notifier).state = null;
    final orchestrator = ref.read(emulationOrchestratorProvider);
    orchestrator.synthesizerWorkflow.cancel();
    // The synthesis loop will exit at the next iteration check.
    // Its finally block calls lifecycleService.reset() to clean up Renode state.
  }

  /// Pause the Renode emulation
  Future<void> _pauseEmulation(
    BuildContext context,
    WidgetRef ref,
    dynamic lifecycleService,
  ) async {
    try {
      // Pause emulation using orchestrator
      final orchestrator = ref.read(emulationOrchestratorProvider);
      await orchestrator.pauseEmulation();

      // Show success message
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⏸ Emulation paused'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      // Show error dialog
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pause Error'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  /// Reset the Renode emulation
  Future<void> _resetEmulation(
    BuildContext context,
    WidgetRef ref,
    dynamic lifecycleService,
  ) async {
    try {
      // Clear any existing warning banners
      if (context.mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
      }

      // Reset emulation using orchestrator
      final orchestrator = ref.read(emulationOrchestratorProvider);
      await orchestrator.resetEmulation();

      // Clear executed and hooked symbols tracking
      ref.read(executedSymbolsProvider.notifier).state = {};
      ref.read(hookedSymbolsProvider.notifier).state = {};
      ref.read(synthesisProgressProvider.notifier).state = null;
      ref.read(synthesisResultProvider.notifier).state = null;
      _traceSubscription?.cancel();
      _synthesizerEventSubscription?.cancel();

      // Clear trace activity and add reset event (clearing history)
      _filteredTraceSubscription?.cancel();
      _pauseEventSubscription?.cancel();
      ref.read(traceActivityEventsProvider.notifier).state = [
        TraceActivityEvent.reset(),
      ];

      // Show success message
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('↻ Emulation reset'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      // Show error dialog
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reset Error'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  /// Show a banner notification when emulation is paused
  void _showPauseBanner(BuildContext context, WidgetRef ref, PausedEvent pauseEvent) {
    if (!context.mounted) return;
    
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    scaffoldMessenger.clearSnackBars();
    
    String message;
    Color backgroundColor;
    
    if (pauseEvent.unhandledAccess == true) {
      message = '⚠️ PAUSED: Unhandled memory access${pauseEvent.symbol != null ? " at ${pauseEvent.symbol}" : ""}';
      backgroundColor = Colors.red;
    } else if (pauseEvent.user == true) {
      message = '⏸️ PAUSED by user${pauseEvent.symbol != null ? " at ${pauseEvent.symbol}" : ""}';
      backgroundColor = Colors.orange;
    } else {
      message = '⏸️ PAUSED${pauseEvent.symbol != null ? " at ${pauseEvent.symbol}" : ""}';
      backgroundColor = Colors.orange;
    }
    
    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'RESUME',
          textColor: Colors.white,
          onPressed: () async {
            try {
              final orchestrator = ref.read(emulationOrchestratorProvider);
              await orchestrator.resumeEmulation();
            } catch (e) {
              print('Failed to resume: $e');
            }
          },
        ),
      ),
    );
  }
}

class _Edge {
  final String from;
  final String to;
  _Edge(this.from, this.to);
}

class _GraphPainter extends CustomPainter {
  final Map<String, Offset> nodePositions;
  final List<_Edge> edges;
  final cg.CallGraph callGraph;
  final String? selectedSymbol;
  final String? draggedNode;
  final NodeStyle nodeStyle;
  final Set<String> executedSymbols;
  final Set<String> hookedSymbols;
  final Set<String> overriddenSymbols;
  final Map<String, int>? nodeDegrees;
  final List<_NodeRipple> ripples;

  _GraphPainter({
    required this.nodePositions,
    required this.edges,
    required this.callGraph,
    required this.selectedSymbol,
    required this.draggedNode,
    required this.nodeStyle,
    required this.executedSymbols,
    required this.hookedSymbols,
    required this.overriddenSymbols,
    this.nodeDegrees,
    this.ripples = const [],
    Listenable? repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // Draw edges first
    final edgePaint = Paint()
      ..color = Colors.blue.withOpacity(0.3)
      ..strokeWidth = 1.0;
    
    // Outgoing edges (calls) - orange when highlighted
    final highlightedCallsEdgePaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    
    final glowCallsEdgePaint = Paint()
      ..color = Colors.orange.withOpacity(0.3)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
    
    // Incoming edges (called by) - purple when highlighted
    final highlightedCalledByEdgePaint = Paint()
      ..color = Colors.purple
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    
    final glowCalledByEdgePaint = Paint()
      ..color = Colors.purple.withOpacity(0.3)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

    // Dimmed edge paint for edges connected to hooked symbols
    final hookedEdgePaint = Paint()
      ..color = Colors.grey.withOpacity(0.15)
      ..strokeWidth = 1.0;

    for (var edge in edges) {
      final from = nodePositions[edge.from];
      final to = nodePositions[edge.to];
      if (from != null && to != null) {
        // Check if this edge is connected to the selected node
        final isOutgoingFromSelected = selectedSymbol != null && edge.from == selectedSymbol;
        final isIncomingToSelected = selectedSymbol != null && edge.to == selectedSymbol;
        final isHookedEdge = hookedSymbols.contains(edge.from) || hookedSymbols.contains(edge.to);

        if (isOutgoingFromSelected) {
          // Outgoing edge (this node calls another) - orange
          canvas.drawLine(from, to, glowCallsEdgePaint);
          canvas.drawLine(from, to, highlightedCallsEdgePaint);
        } else if (isIncomingToSelected) {
          // Incoming edge (another node calls this one) - purple
          canvas.drawLine(from, to, glowCalledByEdgePaint);
          canvas.drawLine(from, to, highlightedCalledByEdgePaint);
        } else if (isHookedEdge) {
          // Edge connected to a hooked symbol - dimmed gray
          canvas.drawLine(from, to, hookedEdgePaint);
        } else {
          // Normal edge
          canvas.drawLine(from, to, edgePaint);
        }
      }
    }

    // Draw ripples — multi-ring "pebble in pool" effect
    for (final ripple in ripples) {
      final pos = nodePositions[ripple.symbol];
      if (pos == null) continue;

      final t = ripple.progress;

      // Center splash — faint filled circle that fades in first 30%
      if (t < 0.3) {
        final splashT = t / 0.3; // 0→1 over first 30%
        final splashRadius = ripple.maxRadius * 0.15 * splashT;
        final splashOpacity = (1.0 - splashT) * 0.25;
        final splashPaint = Paint()
          ..color = ripple.color.withOpacity(splashOpacity)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(pos, splashRadius, splashPaint);
      }

      // Ring 1 (inner) — expands immediately
      final r1 = ripple.maxRadius * t;
      final o1 = (1.0 - t) * 0.5;
      final sw1 = 3.0 * (1.0 - t) + 1.0;
      canvas.drawCircle(
        pos,
        r1,
        Paint()
          ..color = ripple.color.withOpacity(o1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw1,
      );

      // Ring 2 (middle) — staggered, starts at t=0.15
      final t2 = (t - 0.15).clamp(0.0, 1.0);
      if (t2 > 0.0) {
        final r2 = ripple.maxRadius * t2;
        final o2 = (1.0 - t) * 0.35;
        final sw2 = 2.0 * (1.0 - t) + 0.5;
        canvas.drawCircle(
          pos,
          r2,
          Paint()
            ..color = ripple.color.withOpacity(o2)
            ..style = PaintingStyle.stroke
            ..strokeWidth = sw2,
        );
      }

      // Ring 3 (outer) — staggered, starts at t=0.30
      final t3 = (t - 0.30).clamp(0.0, 1.0);
      if (t3 > 0.0) {
        final r3 = ripple.maxRadius * t3;
        final o3 = (1.0 - t) * 0.2;
        final sw3 = 1.5 * (1.0 - t) + 0.5;
        canvas.drawCircle(
          pos,
          r3,
          Paint()
            ..color = ripple.color.withOpacity(o3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = sw3,
        );
      }
    }

    // Draw nodes
    for (var entry in nodePositions.entries) {
      final symbol = entry.key;
      final pos = entry.value;
      final isSelected = symbol == selectedSymbol;
      final isDragged = symbol == draggedNode;
      final isExecuted = executedSymbols.contains(symbol);
      final isHooked = hookedSymbols.contains(symbol);
      final isOverridden = overriddenSymbols.contains(symbol);
      final degree = nodeDegrees?[symbol] ?? 0;

      // Color priority: dragged (bright red) > selected (orange) > hooked (dark red) > executed (green) > default (blue)
      final Color color;
      if (isDragged) {
        color = Colors.red;
      } else if (isSelected) {
        color = Colors.orange;
      } else if (isHooked) {
        color = Colors.red.shade700;
      } else if (isExecuted) {
        color = Colors.green;
      } else {
        color = Colors.blue;
      }

      switch (nodeStyle) {
        case NodeStyle.circle:
          final baseRadius = nodeDegrees != null
              ? (3.0 + math.log(1 + degree) * 5.0).clamp(3.0, 25.0)
              : (isDragged ? 7.0 : 5.0);
          final glowRadius = baseRadius + 7;
          final ringRadius = baseRadius + 3;

          // Draw glow for selected nodes
          if (isSelected) {
            final glowPaint = Paint()
              ..color = Colors.orange.withOpacity(0.4)
              ..style = PaintingStyle.fill
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
            canvas.drawCircle(pos, glowRadius, glowPaint);
          }

          final nodePaint = Paint()
            ..color = color
            ..style = PaintingStyle.fill;
          canvas.drawCircle(pos, baseRadius, nodePaint);

          // Draw ring around overridden node (red, sits outside the node)
          if (isOverridden) {
            final overridePaint = Paint()
              ..color = Colors.red
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0;
            canvas.drawCircle(pos, ringRadius, overridePaint);
          }

          // Draw ring around selected node (on top of override ring)
          if (isSelected && !isDragged) {
            final ringPaint = Paint()
              ..color = Colors.orange
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0;
            canvas.drawCircle(pos, isOverridden ? ringRadius + 3 : ringRadius, ringPaint);
          }
          
          // Draw label ABOVE the node so it's not obscured
          if (isSelected || isDragged) {
            final textPainter = TextPainter(
              text: TextSpan(
                text: symbol,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(color: Colors.black, offset: Offset(0, 0), blurRadius: 4),
                  ],
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            
            // Position text ABOVE the node
            textPainter.paint(
              canvas,
              Offset(pos.dx - textPainter.width / 2, pos.dy - 20),
            );
          }
          break;

        case NodeStyle.box:
          final size = nodeDegrees != null
              ? (6.0 + math.log(1 + degree) * 7.0).clamp(6.0, 36.0)
              : (isDragged ? 14.0 : 10.0);
          
          // Draw glow for selected nodes
          if (isSelected) {
            final glowPaint = Paint()
              ..color = Colors.orange.withOpacity(0.4)
              ..style = PaintingStyle.fill
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
            canvas.drawRect(
              Rect.fromCenter(center: pos, width: size + 8, height: size + 8),
              glowPaint,
            );
          }
          
          final nodePaint = Paint()
            ..color = color
            ..style = PaintingStyle.fill;
          canvas.drawRect(
            Rect.fromCenter(center: pos, width: size, height: size),
            nodePaint,
          );

          // Draw border around overridden node (red)
          if (isOverridden) {
            final overridePaint = Paint()
              ..color = Colors.red
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0;
            canvas.drawRect(
              Rect.fromCenter(center: pos, width: size + 4, height: size + 4),
              overridePaint,
            );
          }

          // Draw border around selected node (on top of override border)
          if (isSelected && !isDragged) {
            final borderPaint = Paint()
              ..color = Colors.orange
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0;
            canvas.drawRect(
              Rect.fromCenter(center: pos, width: size + (isOverridden ? 8 : 4), height: size + (isOverridden ? 8 : 4)),
              borderPaint,
            );
          }
          
          // Draw label ABOVE the node so it's not obscured
          if (isSelected || isDragged) {
            final textPainter = TextPainter(
              text: TextSpan(
                text: symbol,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(color: Colors.black, offset: Offset(0, 0), blurRadius: 4),
                  ],
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            
            // Position text ABOVE the node
            textPainter.paint(
              canvas,
              Offset(pos.dx - textPainter.width / 2, pos.dy - 20),
            );
          }
          break;

        case NodeStyle.labeledBox:
          final labelFontSize = nodeDegrees != null
              ? (8.0 + math.log(1 + degree) * 2.5).clamp(8.0, 16.0)
              : 10.0;
          final textPainter = TextPainter(
            text: TextSpan(
              text: symbol,
              style: TextStyle(
                color: Colors.white,
                fontSize: labelFontSize,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();

          final padding = 8.0;
          final boxWidth = textPainter.width + padding * 2;
          final boxHeight = textPainter.height + padding * 2;

          // Draw glow for selected nodes
          if (isSelected) {
            final glowPaint = Paint()
              ..color = Colors.orange.withOpacity(0.4)
              ..style = PaintingStyle.fill
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(center: pos, width: boxWidth + 12, height: boxHeight + 12),
                const Radius.circular(6),
              ),
              glowPaint,
            );
          }

          final boxPaint = Paint()
            ..color = color
            ..style = PaintingStyle.fill;
          
          final borderPaint = Paint()
            ..color = isSelected ? Colors.orange : Colors.white.withOpacity(0.3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isSelected ? 2.5 : 1.0;

          final rect = Rect.fromCenter(
            center: pos,
            width: boxWidth,
            height: boxHeight,
          );

          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(4)),
            boxPaint,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(4)),
            borderPaint,
          );

          textPainter.paint(
            canvas,
            Offset(pos.dx - textPainter.width / 2, pos.dy - textPainter.height / 2),
          );
          break;

        case NodeStyle.dot:
          final dotRadius = nodeDegrees != null
              ? (1.5 + math.log(1 + degree) * 3.0).clamp(1.5, 15.0)
              : (isDragged ? 4.0 : 2.5);
          final dotGlowRadius = dotRadius + 7.5;
          final dotRingRadius = dotRadius + 3.5;

          // Draw glow for selected nodes
          if (isSelected) {
            final glowPaint = Paint()
              ..color = Colors.orange.withOpacity(0.4)
              ..style = PaintingStyle.fill
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
            canvas.drawCircle(pos, dotGlowRadius, glowPaint);
          }

          final nodePaint = Paint()
            ..color = color
            ..style = PaintingStyle.fill;
          canvas.drawCircle(pos, dotRadius, nodePaint);

          // Draw ring around selected node
          if (isSelected && !isDragged) {
            final ringPaint = Paint()
              ..color = Colors.orange
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5;
            canvas.drawCircle(pos, dotRingRadius, ringPaint);
          }
          
          // Draw label ABOVE the node so it's not obscured
          if (isSelected || isDragged) {
            final textPainter = TextPainter(
              text: TextSpan(
                text: symbol,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(color: Colors.black, offset: Offset(0, 0), blurRadius: 4),
                  ],
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            
            // Position text ABOVE the node
            textPainter.paint(
              canvas,
              Offset(pos.dx - textPainter.width / 2, pos.dy - 18),
            );
          }
          break;
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) => true;
}
