import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_engine.dart';
import 'package:test/test.dart';

EmulationOrchestrator _buildOrchestrator() {
  final engine = DartEngine();
  return EmulationOrchestrator(
    engineLifecycle: engine.lifecycle,
    emulationController: engine.controller,
    callGraphSource: engine.callGraphSource,
    traceSource: engine.traceSource,
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
