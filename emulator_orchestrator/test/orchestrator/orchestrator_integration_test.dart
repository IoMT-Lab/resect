import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/data/services/lifecycle_service.dart';
import 'package:emulator_orchestrator/data/services/callgraph_service.dart';
import 'package:emulator_orchestrator/data/services/trace_service.dart';
import 'package:emulator_orchestrator/data/services/filtered_trace_service.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';

void main() {
  group('Orchestrator Integration Test', () {
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

    tearDown(() async {
      // Clean up: stop server if running
      if (orchestrator.hasServerProcess) {
        await orchestrator.resetEmulation();
      }
      orchestrator.dispose();
    });

    test('Orchestrator can start server and communicate with Renode', () async {
      // This test verifies the full stack works
      // Use the actual platform and firmware files
      const platformPath = '@platforms/cpus/stm32wb05_empty.repl';
      const firmwarePath = '/home/evan/Dev/emulation/emulation_engine/aya_ppg.elf';

      // Create a test emulator
      final emulator = await orchestrator.createEmulator(
        name: 'Integration Test',
        baseImagePath: platformPath,
        elfFilePath: firmwarePath,
      );

      expect(emulator, isNotNull);

      // Set up trace listener BEFORE starting emulation
      bool traceReceived = false;
      final subscription = orchestrator.traceService.onTrace.listen((event) {
        print('Test received trace event: ${event.symbol}');
        traceReceived = true;
      });

      // Start emulation (this starts server, connects services, loads firmware)
      await orchestrator.startEmulation(
        elfPath: emulator.elfFilePath!,
        baseImagePath: emulator.baseImagePath,
        pauseOnUnhandled: false,  // Don't pause on unhandled accesses
      );

      // Verify server is running
      expect(orchestrator.hasServerProcess, isTrue);
      expect(orchestrator.state.toString(), contains('running'));

      // Wait for trace events to flow
      await Future.delayed(const Duration(seconds: 5));

      expect(traceReceived, isTrue, reason: 'Should receive trace events if LogFunctionNames succeeded');

      await subscription.cancel();

      // Clean up
      await orchestrator.resetEmulation();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
