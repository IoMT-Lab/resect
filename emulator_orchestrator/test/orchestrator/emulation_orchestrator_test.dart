import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/events/orchestrator_events.dart';
import 'package:emulator_orchestrator/data/services/lifecycle_service.dart';
import 'package:emulator_orchestrator/data/services/callgraph_service.dart';
import 'package:emulator_orchestrator/data/services/trace_service.dart';
import 'package:emulator_orchestrator/data/services/filtered_trace_service.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';

void main() {
  group('EmulationOrchestrator', () {
    late EmulationOrchestrator orchestrator;
    late LifecycleService lifecycleService;
    late CallgraphService callgraphService;
    late TraceService traceService;
    late FilteredTraceService filteredTraceService;
    late EmulatorRepository emulatorRepository;

    setUp(() {
      // Create real service instances for basic integration test
      lifecycleService = LifecycleService();
      callgraphService = CallgraphService();
      traceService = TraceService();
      filteredTraceService = FilteredTraceService();
      emulatorRepository = EmulatorRepository();

      orchestrator = EmulationOrchestrator(
        lifecycleService: lifecycleService,
        callgraphService: callgraphService,
        traceService: traceService,
        filteredTraceService: filteredTraceService,
        emulatorRepository: emulatorRepository,
        artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
      );
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
      // Listen for events
      final events = <OrchestrationEvent>[];
      orchestrator.events.listen((event) {
        events.add(event);
      });

      // Create emulator
      await orchestrator.createEmulator(
        name: 'Test Emulator',
        elfFilePath: '/tmp/test.elf',
        baseImagePath: '/tmp/test.repl',
      );

      // Wait for event processing
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify event was emitted
      expect(events.length, greaterThan(0));
      expect(events.first, isA<EmulatorChangedEvent>());
      final emulatorEvent = events.first as EmulatorChangedEvent;
      expect(emulatorEvent.emulator?.name, equals('Test Emulator'));
    });

    test('orchestrator tracks unsaved changes', () async {
      await orchestrator.createEmulator(
        name: 'Test Emulator',
      );

      // Emulator should have unsaved changes after creation
      expect(orchestrator.hasUnsavedChanges, isTrue);

      // After saving, should have no unsaved changes
      // (We'll skip actually saving to disk for this test)
    });

    test('orchestrator can mark emulator as dirty', () async {
      await orchestrator.createEmulator(name: 'Test Emulator');

      // Mark dirty
      orchestrator.markEmulatorDirty();

      expect(orchestrator.hasUnsavedChanges, isTrue);
    });
  });

  group('EmulationOrchestrator - Emulator Workflow', () {
    late EmulationOrchestrator orchestrator;

    setUp(() {
      orchestrator = EmulationOrchestrator(
        lifecycleService: LifecycleService(),
        callgraphService: CallgraphService(),
        traceService: TraceService(),
        filteredTraceService: FilteredTraceService(),
        emulatorRepository: EmulatorRepository(),
        artifactDb: ArtifactDatabase.forTesting(NativeDatabase.memory()),
      );
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
