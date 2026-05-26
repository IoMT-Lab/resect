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
import 'package:emulator_orchestrator/orchestrator/events/orchestrator_events.dart';

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
  group('EmulationOrchestrator', () {
    late EmulationOrchestrator orchestrator;

    setUp(() {
      orchestrator = _buildOrchestrator();
    });

    tearDown(() {
      orchestrator.dispose();
    });

    test('orchestrator is created successfully', () {
      expect(orchestrator, isNotNull);
      expect(orchestrator.events, isNotNull);
    });

    test('orchestrator has correct initial state', () {
      expect(orchestrator.state.toString(), contains('stopped'));
      expect(orchestrator.currentEmulator, isNull);
      expect(orchestrator.hasServerProcess, isFalse);
    });

    test('orchestrator can create an emulator', () async {
      final emulator = await orchestrator.createEmulator(
        name: 'Test Emulator',
        elfFilePath: '/tmp/test.elf',
        baseImagePath: '/tmp/test.repl',
      );

      expect(emulator, isNotNull);
      expect(emulator.name, equals('Test Emulator'));
      expect(emulator.elfFilePath, equals('/tmp/test.elf'));
      expect(emulator.baseImagePath, equals('/tmp/test.repl'));
    });

    test('orchestrator emits EmulatorChangedEvent when emulator is created', () async {
      final events = <OrchestrationEvent>[];
      orchestrator.events.listen((event) {
        events.add(event);
      });

      await orchestrator.createEmulator(
        name: 'Test Emulator',
        elfFilePath: '/tmp/test.elf',
        baseImagePath: '/tmp/test.repl',
      );

      await Future.delayed(const Duration(milliseconds: 100));

      expect(events.length, greaterThan(0));
      expect(events.first, isA<EmulatorChangedEvent>());
      final emulatorEvent = events.first as EmulatorChangedEvent;
      expect(emulatorEvent.emulator?.name, equals('Test Emulator'));
    });

    test('orchestrator tracks unsaved changes', () async {
      await orchestrator.createEmulator(
        name: 'Test Emulator',
      );

      expect(orchestrator.hasUnsavedChanges, isTrue);
    });

    test('orchestrator can mark emulator as dirty', () async {
      await orchestrator.createEmulator(name: 'Test Emulator');

      orchestrator.markEmulatorDirty();

      expect(orchestrator.hasUnsavedChanges, isTrue);
    });
  });

  group('EmulationOrchestrator - Emulator Workflow', () {
    late EmulationOrchestrator orchestrator;

    setUp(() {
      orchestrator = _buildOrchestrator();
    });

    tearDown(() {
      orchestrator.dispose();
    });

    test('createEmulator returns a valid emulator', () async {
      final emulator = await orchestrator.createEmulator(
        name: 'Integration Test Emulator',
        elfFilePath: '/path/to/firmware.elf',
        baseImagePath: '/path/to/platform.repl',
      );

      expect(emulator.name, equals('Integration Test Emulator'));
      expect(emulator.elfFilePath, equals('/path/to/firmware.elf'));
      expect(emulator.baseImagePath, equals('/path/to/platform.repl'));
      expect(emulator.id, isNotEmpty);
    });
  });
}
