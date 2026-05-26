import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/data/services/callgraph_service.dart';
import 'package:emulator_orchestrator/data/services/filtered_trace_service.dart';
import 'package:emulator_orchestrator/data/services/lifecycle_service.dart';
import 'package:emulator_orchestrator/data/services/trace_service.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_call_graph_source.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_emulation_controller.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_engine_lifecycle.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_trace_source.dart';

EmulationOrchestrator _buildOrchestrator() {
  return EmulationOrchestrator(
    engineLifecycle: RenodeEngineLifecycle(),
    emulationController: RenodeEmulationController(LifecycleService()),
    callGraphSource: RenodeCallGraphSource(CallgraphService()),
    traceSource: RenodeTraceSource(
      traceService: TraceService(),
      filteredTraceService: FilteredTraceService(),
    ),
    emulatorRepository: EmulatorRepository(),
    artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
  );
}

void main() {
  test('Orchestrator can be instantiated', () {
    final orchestrator = _buildOrchestrator();

    expect(orchestrator, isNotNull);
    expect(orchestrator.events, isNotNull);
    expect(orchestrator.state.toString(), contains('stopped'));
    expect(orchestrator.currentEmulator, isNull);
    expect(orchestrator.hasServerProcess, isFalse);

    orchestrator.dispose();
  });

  test('Orchestrator can create an emulator (in-memory)', () async {
    final orchestrator = _buildOrchestrator();

    final emulator = await orchestrator.createEmulator(
      name: 'Test Emulator',
      elfFilePath: '/tmp/test.elf',
      baseImagePath: '/tmp/test.repl',
    );

    expect(emulator, isNotNull);
    expect(emulator.name, equals('Test Emulator'));
    expect(emulator.elfFilePath, equals('/tmp/test.elf'));
    expect(emulator.baseImagePath, equals('/tmp/test.repl'));
    expect(orchestrator.hasUnsavedChanges, isTrue);

    orchestrator.dispose();
  });

  test('Orchestrator tracks emulator dirty state', () async {
    final orchestrator = _buildOrchestrator();

    expect(orchestrator.hasUnsavedChanges, isFalse);

    await orchestrator.createEmulator(name: 'Test Emulator');

    expect(orchestrator.hasUnsavedChanges, isTrue);

    orchestrator.markEmulatorDirty();
    expect(orchestrator.hasUnsavedChanges, isTrue);

    orchestrator.dispose();
  });
}
