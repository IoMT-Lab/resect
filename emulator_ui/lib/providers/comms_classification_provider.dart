import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/services/comms/comms_assignment_merge.dart';
import 'package:emulator_orchestrator/services/comms/comms_classifier.dart';
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
    final merged = mergeCommsAssignments(
      graph: graph,
      existing: emulator.commsAssignments,
      suggestions: classifier.classify(graph),
    );

    if (!commsAssignmentsEqual(merged, emulator.commsAssignments)) {
      _ref.read(currentEmulatorProvider.notifier).state =
          emulator.copyWith(commsAssignments: merged);
      _ref.read(emulatorDirtyProvider.notifier).state = true;
    }
  }
}

final commsClassificationControllerProvider =
    Provider<CommsClassificationController>(CommsClassificationController.new);
