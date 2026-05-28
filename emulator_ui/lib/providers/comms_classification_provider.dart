import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/services/comms_classifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';

/// The active classifier. Default = case-insensitive substring heuristic;
/// future engine-driven impls can override this in tests or in a Component.
final commsClassifierProvider = Provider<CommsClassifier>(
  (ref) => const NamePatternCommsClassifier(),
);

/// Re-runs comms classification whenever [callgraphProvider] produces a new
/// graph, merging the fresh suggestions into [Emulator.commsAssignments].
/// Behavior:
/// - Symbols already classified by the user keep their existing assignment.
/// - Symbols new to this graph receive the classifier's suggestion (if any).
/// - Symbols dropped from the graph (e.g. after Regenerate Call Graph) fall
///   out of the persisted map.
///
/// The listener is set up in the constructor. The controller is
/// eagerly instantiated from [emulationOrchestratorProvider] so its listener
/// is live from app boot, not lazily on first read.
class CommsClassificationController {
  CommsClassificationController(this._ref) {
    _ref.listen<AsyncValue<CallGraph?>>(callgraphProvider, (prev, next) {
      final graph = next.valueOrNull;
      if (graph == null) return;
      _syncForGraph(graph);
    });
  }

  final Ref _ref;

  void _syncForGraph(CallGraph graph) {
    final emulator = _ref.read(currentEmulatorProvider);
    if (emulator == null) return;
    final classifier = _ref.read(commsClassifierProvider);
    final fresh = classifier.classify(graph);
    final existing = emulator.commsAssignments;

    final merged = <String, CommsAssignment>{};
    for (final sym in graph.symbols.keys) {
      // User reassignments win for still-present symbols; otherwise take the
      // classifier's suggestion. Symbols neither in `existing` nor matched
      // by the classifier stay out of the Comms tab entirely.
      if (existing.containsKey(sym)) {
        merged[sym] = existing[sym]!;
      } else if (fresh.containsKey(sym)) {
        merged[sym] = fresh[sym]!;
      }
    }

    if (!_mapsEqual(merged, existing)) {
      _ref.read(currentEmulatorProvider.notifier).state =
          emulator.copyWith(commsAssignments: merged);
      _ref.read(emulatorDirtyProvider.notifier).state = true;
    }
  }

  static bool _mapsEqual(
    Map<String, CommsAssignment> a,
    Map<String, CommsAssignment> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

final commsClassificationControllerProvider =
    Provider<CommsClassificationController>(CommsClassificationController.new);
