import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:emulator_orchestrator/core/constants.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart' as cg;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/app_providers.dart';
import '../../providers/autosave_provider.dart';
import '../screens/synthesize/synthesis_controller.dart';

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
  static const durationMs = 1800;

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
  final _transformationController = TransformationController();
  final _focusNode = FocusNode();
  Map<String, Offset> _nodePositions = {};
  final Map<String, Offset> _nodeVelocities = {};
  List<_Edge> _edges = [];
  cg.CallGraph? _cachedCallGraph;
  String? _draggedNode;
  Offset? _dragOffset;
  late AnimationController _animationController;
  GraphLayout _currentLayout = GraphLayout.hierarchical;
  NodeStyle _currentNodeStyle = NodeStyle.circle;
  final Map<String, Size> _nodeSizeCache = {};
  var _animationEnabled = false;
  var _scaleByDegree = true;
  Map<String, int> _nodeDegrees = {};
  Size? _lastViewportSize;
  final List<_NodeRipple> _activeRipples = [];
  Timer? _rippleTimer;
  final _rippleNotifier = ValueNotifier<int>(0);
  Set<String> _prevExecutedSymbols = {};
  Set<String> _prevHookedSymbols = {};
  late AnimationController _viewAnimController;
  Matrix4? _viewAnimStart;
  Matrix4? _viewAnimEnd;
  var _focusOnSelect = true;

  /// True while either Shift key is held down anywhere in the window.
  /// Drives the Refresh / Regenerate button-label flip on the "stopped"
  /// state — Shift turns the cheap in-memory refresh into a forced
  /// artifact-DB invalidate + Ghidra re-extract.
  bool _shiftHeld = false;

  /// Mode captured when the user CLICKED the call-graph button — used
  /// for the in-flight spinner label so it doesn't flip back to
  /// "Refreshing…" if the user releases Shift mid-regeneration. Null
  /// when no operation is in flight.
  bool? _inFlightForce;

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
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _rippleTimer?.cancel();
    _rippleNotifier.dispose();
    _animationController.dispose();
    _viewAnimController.dispose();
    _transformationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Global key listener — fires for every keyboard event in the
  /// window. We only care about Shift transitions; everything else
  /// falls through (handler returns false so other listeners still
  /// see the event).
  bool _onHardwareKey(KeyEvent event) {
    final isShift = event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight;
    if (!isShift) return false;
    final held = HardwareKeyboard.instance.isLogicalKeyPressed(
            LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance
            .isLogicalKeyPressed(LogicalKeyboardKey.shiftRight);
    if (held != _shiftHeld && mounted) {
      setState(() => _shiftHeld = held);
    }
    return false;
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
    for (final entry in _cachedCallGraph!.symbols.entries) {
      final from = entry.key;
      if (from == _draggedNode) continue;
      if (!_nodePositions.containsKey(from)) continue;

      for (final to in entry.value.calledSymbols.keys) {
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
    var anyMovement = false;
    for (final node in nodes) {
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
      case GraphLayout.hierarchical:
        positions.addAll(_applyHierarchicalLayout(callGraph, nodes));
      case GraphLayout.sugiyama:
        positions.addAll(_applySugiyamaLayout(callGraph, nodes));
      case GraphLayout.circular:
        positions.addAll(_applyCircularLayout(callGraph, nodes));
      case GraphLayout.grid:
        positions.addAll(_applyGridLayout(nodes));
    }
    
    // Build edge list
    final edges = <_Edge>[];
    for (final entry in callGraph.symbols.entries) {
      for (final to in entry.value.calledSymbols.keys) {
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
    for (final node in nodes) {
      degrees[node] = 0;
    }
    for (final edge in edges) {
      degrees[edge.from] = (degrees[edge.from] ?? 0) + 1;
      degrees[edge.to] = (degrees[edge.to] ?? 0) + 1;
    }
    _nodeDegrees = degrees;

    // Precompute box sizes for labeled box style to populate cache
    if (_currentNodeStyle == NodeStyle.labeledBox) {
      _nodeSizeCache.clear();
      for (final node in nodes) {
        _getLabeledBoxSize(node);
      }
    }

    // Initialize velocities
    for (final node in nodes) {
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
      for (final entry in callGraph.symbols.entries) {
        final from = entry.key;
        if (!positions.containsKey(from)) continue;

        for (final to in entry.value.calledSymbols.keys) {
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
      for (final node in nodes) {
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
    
    for (final entry in callGraph.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (final called in entry.value.calledSymbols.keys) {
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
          for (final called in symbol.calledSymbols.keys) {
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
    for (final entry in entryPoints) {
      if (!visited.contains(entry)) {
        bfs(entry);
      }
    }
    
    // Separate connected nodes from truly isolated nodes (no edges at all)
    final isolatedNodes = nodes.where((n) => !hasConnections.contains(n)).toList();
    
    // Group nodes by depth
    final nodesByDepth = <int, List<String>>{};
    for (final entry in depths.entries) {
      nodesByDepth.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    
    // Position connected nodes in main hierarchy
    const levelSeparation = 150.0;
    const nodeSeparation = 100.0;
    
    for (final entry in nodesByDepth.entries) {
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
      for (final pos in positions.values) {
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
    
    for (final entry in callGraph.symbols.entries) {
      outDegree[entry.key] = entry.value.calledSymbols.length;
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (final called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        inDegree[called] = (inDegree[called] ?? 0) + 1;
        hasConnections.add(called);
      }
    }
    
    // Initialize in-degree for all nodes
    for (final node in nodes) {
      inDegree.putIfAbsent(node, () => 0);
    }
    
    // Topological sort with Kahn's algorithm for layer assignment
    final queue = <String>[];
    
    // Start with nodes that have no incoming edges
    for (final node in nodes) {
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
        for (final called in symbol.calledSymbols.keys) {
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
    for (final layerNum in layers.keys.toList()..sort()) {
      if (layerNum == 0) continue;
      
      final currentLayer = layers[layerNum]!;
      final positions = <String, double>{};
      
      for (final node in currentLayer) {
        // Calculate barycenter position based on connected nodes in previous layer
        final connectedInPrevLayer = <String>[];
        if (callers.containsKey(node)) {
          for (final caller in callers[node]!) {
            if (nodeLayer[caller] == layerNum - 1) {
              connectedInPrevLayer.add(caller);
            }
          }
        }
        
        if (connectedInPrevLayer.isNotEmpty) {
          double sum = 0;
          final prevLayer = layers[layerNum - 1];
          if (prevLayer != null) {
            for (final caller in connectedInPrevLayer) {
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
    
    for (final entry in layers.entries) {
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
      for (final pos in positions.values) {
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
    
    for (final entry in callGraph.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (final called in entry.value.calledSymbols.keys) {
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
          for (final called in symbol.calledSymbols.keys) {
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
    
    for (final entry in entryPoints) {
      if (!visited.contains(entry)) {
        bfs(entry);
      }
    }
    
    // Separate connected nodes from truly isolated nodes
    final isolatedNodes = nodes.where((n) => !hasConnections.contains(n)).toList();
    
    // Group connected nodes by depth and arrange in circles
    final nodesByDepth = <int, List<String>>{};
    for (final entry in depths.entries) {
      nodesByDepth.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    
    for (final entry in nodesByDepth.entries) {
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
      for (final pos in positions.values) {
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
    
    for (final entry in callGraph.symbols.entries) {
      if (entry.value.calledSymbols.isNotEmpty) {
        hasConnections.add(entry.key);
      }
      for (final called in entry.value.calledSymbols.keys) {
        callers.putIfAbsent(called, () => {}).add(entry.key);
        hasConnections.add(called);
      }
    }
    
    // 1. Identify entry points with priority scoring
    final entryPoints = <String>[];
    final priorities = <String, int>{};
    
    for (final symbol in nodes) {
      if (!hasConnections.contains(symbol)) continue;
      
      final symbolLower = symbol.toLowerCase();
      var priority = 100;
      
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
      for (final symbol in nodes) {
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
          
          for (final called in callees) {
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
    for (final entry in entryPoints) {
      if (!visited.contains(entry)) {
        bfs(entry, priorities[entry] ?? 100);
      }
    }
    
    // 3. Calculate node importance scores
    for (final symbol in nodes) {
      if (!hasConnections.contains(symbol)) continue;
      
      final instrCount = callGraph.symbols[symbol]?.numInstructions ?? 0;
      final inDegree = callers[symbol]?.length ?? 0;
      final outDegree = callGraph.symbols[symbol]?.calledSymbols.length ?? 0;
      
      // Score: larger instruction count + more callers = more important
      nodeScores[symbol] = (instrCount * 0.1) + (inDegree * 10.0) + (outDegree * 2.0);
    }
    
    // 4. Group nodes by depth and sort within each level
    final nodesByDepth = <int, List<String>>{};
    for (final entry in depths.entries) {
      nodesByDepth.putIfAbsent(entry.value, () => []).add(entry.key);
    }
    
    // Sort nodes within each depth by score (descending)
    for (final nodesAtDepth in nodesByDepth.values) {
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
    
    for (final entry in nodesByDepth.entries) {
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
      for (final pos in positions.values) {
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
      case GraphLayout.hierarchical:
        positions = _applyHierarchicalLayout(_cachedCallGraph!, nodes);
      case GraphLayout.sugiyama:
        positions = _applySugiyamaLayout(_cachedCallGraph!, nodes);
      case GraphLayout.circular:
        positions = _applyCircularLayout(_cachedCallGraph!, nodes);
      case GraphLayout.grid:
        positions = _applyGridLayout(nodes);
    }
    
    setState(() {
      _nodePositions = positions;
      for (final node in nodes) {
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
    for (var i = 0; i < 16; i++) {
      result.storage[i] = startStorage[i] + (endStorage[i] - startStorage[i]) * t;
    }
    _transformationController.value = result;
  }

  /// Compute the adjusted position offset (same as _buildGraph).
  Offset _adjustedOffset(String name) {
    double minX = 0, minY = 0;
    for (final pos in _nodePositions.values) {
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

    for (final pos in _nodePositions.values) {
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

    // Frame the viewport on any externally-driven selection change (e.g., a
    // symbols-panel click). In-viewer node taps already focus inline via
    // onTapDown, but they also flow through [selectedSymbolProvider], so this
    // listener acts as a single source of truth for the focus-on-select
    // behavior. Gated by [_focusOnSelect] (the user-toggleable preference).
    ref.listen<String?>(selectedSymbolProvider, (prev, next) {
      if (next == null || !_focusOnSelect) return;
      if (!_nodePositions.containsKey(next)) return;
      _focusOnNode(next);
    });

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
    var spawned = false;

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
  Widget _buildWelcomeMessage(BuildContext context) => Center(
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

  /// Build the actual graph visualization
  Widget _buildGraph(BuildContext context, WidgetRef ref, cg.CallGraph callGraph) {
    // Detect newly executed/hooked symbols and spawn ripple animations
    _checkForNewRipples(ref.watch(executedSymbolsProvider), ref.watch(hookedSymbolsProvider));

    // Calculate canvas size based on actual node positions
    double minX = 0, minY = 0, maxX = 0, maxY = 0;
    for (final pos in _nodePositions.values) {
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
    for (final entry in _nodePositions.entries) {
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
              // Claim keyboard focus so shortcuts (e.g. Shift+Z to reframe)
              // work — autofocus isn't reliable inside the tabbed IndexedStack.
              _focusNode.requestFocus();
              final localPos = details.localPosition;

              // Find node under tap
              var nodeWasTapped = false;
              for (final entry in adjustedPositions.entries) {
                var hit = false;
                
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
                  // The selectedSymbolProvider listener at the top of build()
                  // handles the focus-on-select behavior for any source —
                  // panel click, in-viewer tap, programmatic — so the explicit
                  // _focusOnNode call here is intentionally absent.
                  ref.read(selectedSymbolProvider.notifier).state = entry.key;
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
              for (final entry in adjustedPositions.entries) {
                var hit = false;
                
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
                          for (final node in _nodePositions.keys) {
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
      ],
    );
  }

  String _layoutLabel(GraphLayout layout) {
    switch (layout) {
      case GraphLayout.forceDirected: return 'Force-Directed';
      case GraphLayout.hierarchical: return 'Hierarchical';
      case GraphLayout.sugiyama: return 'Sugiyama';
      case GraphLayout.circular: return 'Circular';
      case GraphLayout.grid:
        return 'Grid';
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

  /// Build the run-state button. Synthesis is launched from the Synthesize
  /// tab now, so the stopped state is a CTA that switches to it; the
  /// running/paused/synthesizing states still control the live emulation
  /// via the shared [synthesisControllerProvider].
  Widget _buildRunButton(BuildContext context, WidgetRef ref) {
    final emulationState = ref.watch(emulationStateProvider);
    final synthesisProgress = ref.watch(synthesisProgressProvider);

    // Synthesis in progress — show STOP button
    if (synthesisProgress != null && !synthesisProgress.complete) {
      return _buildActionButton(
        icon: Icons.stop,
        label: 'STOP',
        color: Colors.purple,
        onPressed: () =>
            ref.read(synthesisControllerProvider).stopSynthesis(),
      );
    }

    // When running or paused, show PAUSE/RESET
    if (emulationState == EmulationState.running) {
      return _buildActionButton(
        icon: Icons.pause,
        label: 'PAUSE',
        color: Colors.orange,
        onPressed: () => ref.read(synthesisControllerProvider).pause(),
      );
    }
    if (emulationState == EmulationState.paused) {
      return _buildActionButton(
        icon: Icons.refresh,
        label: 'RESET',
        color: Colors.red,
        onPressed: () => ref.read(synthesisControllerProvider).reset(),
      );
    }

    // Stopped — two-mode CTA:
    //   - Default: "Refresh Call Graph" — drops the in-memory cache and
    //     re-reads from callgraphProvider. Fast (effectively a no-op
    //     when the Ghidra DB cache holds the same elfHash).
    //   - Shift held: "Regenerate Call Graph" — additionally deletes
    //     the artifact-DB cached row for this elfHash, forcing a
    //     fresh Ghidra extraction. Minutes of work.
    // The button's in-flight label tracks which mode is firing so the
    // user knows whether they're waiting on a refresh or a regenerate.
    final isInFlight = ref.watch(callgraphProvider).isLoading;
    final force = _shiftHeld;
    // While in-flight, use the mode captured at click time (so the
    // spinner label doesn't flip when the user releases Shift during
    // a regenerate); when idle, follow live Shift state so the user
    // sees the prospective action before they click.
    final inFlightAction =
        (_inFlightForce ?? force) ? 'Regenerate' : 'Refresh';
    final action = force ? 'Regenerate' : 'Refresh';
    if (isInFlight) {
      return ElevatedButton.icon(
        onPressed: null,
        icon: const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white,
          ),
        ),
        label: Text('${inFlightAction}ing...'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppTheme.accent.withValues(alpha: 0.6),
          disabledForegroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
    return _buildActionButton(
      icon: Icons.refresh,
      label: '$action Call Graph',
      color: AppTheme.accent,
      onPressed: () => _regenerateCallGraph(ref, force: force),
    );
  }

  /// Two modes — selected by the [force] flag:
  ///
  /// - **force=false (Refresh)**: Drop the project's in-memory cached
  ///   call graph and re-read from `callgraphProvider`. If the active
  ///   call-graph source is `GhidraCallGraphSource`, this returns the
  ///   artifact-DB cached row instantly (effectively a no-op when the
  ///   ELF hash hasn't changed). Fast.
  /// - **force=true (Regenerate)**: Before invalidating, also delete
  ///   the `ghidra_call_graphs` cache row for the current elfHash via
  ///   `CallGraphService.invalidateFor`. The next read misses the DB
  ///   cache and `SignaturesService.extractFor` runs from scratch —
  ///   minutes of work on a real ELF. Use when the cached analysis is
  ///   suspected stale or wrong.
  ///
  /// For `DartCallGraphSource` (no MODULE_GHIDRA), there's no DB
  /// cache to invalidate — every call already re-runs objdump — so
  /// [force] is a no-op there.
  ///
  /// Captures a [ProviderContainer] up-front because the widget may be
  /// rebuilt mid-await when currentEmulatorProvider changes — any
  /// post-await `ref.read` on a disposed widget throws "Cannot use ref
  /// after disposed" and gets silently swallowed without diagnostics.
  Future<void> _regenerateCallGraph(
    WidgetRef ref, {
    required bool force,
  }) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final mode = force ? 'regenerate' : 'refresh';
    // Capture the mode for the in-flight spinner label. Without this,
    // if the user releases Shift after starting a regenerate, the
    // button's live `_shiftHeld` flips to false and the spinner label
    // shows "Refreshing..." for what's actually a minutes-long
    // Ghidra re-extraction.
    if (mounted) setState(() => _inFlightForce = force);
    stderr.writeln('[$mode CallGraph] starting');
    try {
      final emu = container.read(currentEmulatorProvider);
      if (force && emu?.elfFilePath != null) {
        // Hash the ELF + drop the cached ghidra_call_graphs row so the
        // next provider read misses and SignaturesService.extractFor
        // runs fresh. extractFor delete-then-inserts all six Ghidra
        // tables, so we only need to delete the call_graphs row here.
        final service = container.read(artifactLibraryServiceProvider);
        final cgService = container.read(callGraphServiceProvider);
        try {
          final elfHash = await service.hashElfFile(emu!.elfFilePath!);
          final deleted = await cgService.invalidateFor(elfHash);
          stderr.writeln(
              '[regenerate CallGraph] invalidated artifact-DB cache: $deleted row(s) deleted for $elfHash');
        } catch (e) {
          stderr.writeln(
              '[regenerate CallGraph] artifact-DB invalidate failed (continuing): $e');
        }
      }
      if (emu != null) {
        container.read(currentEmulatorProvider.notifier).state =
            emu.copyWith(clearCachedCallGraph: true);
      }
      container.invalidate(callgraphProvider);
      stderr.writeln('[$mode CallGraph] invalidated; awaiting fresh graph');
      final result = await container.read(callgraphProvider.future);
      stderr.writeln('[$mode CallGraph] graph ready: '
          '${result?.symbols.length ?? 0} symbols');
      await container.read(autosaveControllerProvider).trigger();
      stderr.writeln('[$mode CallGraph] complete');
    } catch (e, st) {
      stderr
        ..writeln('[$mode CallGraph] FAILED: $e')
        ..writeln(st.toString());
    } finally {
      if (mounted) setState(() => _inFlightForce = null);
    }
  }

  /// Helper to build a simple action button (PAUSE, RESET)
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) => ElevatedButton.icon(
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
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw edges first
    final edgePaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.3)
      ..strokeWidth = 1.0;
    
    // Outgoing edges (calls) - orange when highlighted
    final highlightedCallsEdgePaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    
    final glowCallsEdgePaint = Paint()
      ..color = Colors.orange.withValues(alpha: 0.3)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
    
    // Incoming edges (called by) - purple when highlighted
    final highlightedCalledByEdgePaint = Paint()
      ..color = Colors.purple
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    
    final glowCalledByEdgePaint = Paint()
      ..color = Colors.purple.withValues(alpha: 0.3)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);

    // Dimmed edge paint for edges connected to hooked symbols
    final hookedEdgePaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.15)
      ..strokeWidth = 1.0;

    for (final edge in edges) {
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
          ..color = ripple.color.withValues(alpha: splashOpacity)
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
          ..color = ripple.color.withValues(alpha: o1)
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
            ..color = ripple.color.withValues(alpha: o2)
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
            ..color = ripple.color.withValues(alpha: o3)
            ..style = PaintingStyle.stroke
            ..strokeWidth = sw3,
        );
      }
    }

    // Draw nodes
    for (final entry in nodePositions.entries) {
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
              ..color = Colors.orange.withValues(alpha: 0.4)
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

        case NodeStyle.box:
          final size = nodeDegrees != null
              ? (6.0 + math.log(1 + degree) * 7.0).clamp(6.0, 36.0)
              : (isDragged ? 14.0 : 10.0);
          
          // Draw glow for selected nodes
          if (isSelected) {
            final glowPaint = Paint()
              ..color = Colors.orange.withValues(alpha: 0.4)
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

          const padding = 8.0;
          final boxWidth = textPainter.width + padding * 2;
          final boxHeight = textPainter.height + padding * 2;

          // Draw glow for selected nodes
          if (isSelected) {
            final glowPaint = Paint()
              ..color = Colors.orange.withValues(alpha: 0.4)
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
            ..color = isSelected ? Colors.orange : Colors.white.withValues(alpha: 0.3)
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

        case NodeStyle.dot:
          final dotRadius = nodeDegrees != null
              ? (1.5 + math.log(1 + degree) * 3.0).clamp(1.5, 15.0)
              : (isDragged ? 4.0 : 2.5);
          final dotGlowRadius = dotRadius + 7.5;
          final dotRingRadius = dotRadius + 3.5;

          // Draw glow for selected nodes
          if (isSelected) {
            final glowPaint = Paint()
              ..color = Colors.orange.withValues(alpha: 0.4)
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
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) => true;
}
