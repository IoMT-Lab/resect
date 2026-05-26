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

void main() {
  group('Orchestrator Integration Test', () {
    late EmulationOrchestrator orchestrator;

    setUp(() {
      orchestrator = EmulationOrchestrator(
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
    });

    tearDown(() async {
      if (orchestrator.hasServerProcess) {
        await orchestrator.resetEmulation();
      }
      orchestrator.dispose();
    });

    test('Orchestrator can start server and communicate with Renode', () async {
      const platformPath = '@platforms/cpus/stm32wb05_empty.repl';
      const firmwarePath = '/home/evan/Dev/emulation/emulation_engine/aya_ppg.elf';

      final emulator = await orchestrator.createEmulator(
        name: 'Integration Test',
        baseImagePath: platformPath,
        elfFilePath: firmwarePath,
      );

      expect(emulator, isNotNull);

      // Subscribe via the trace abstraction.
      bool traceReceived = false;
      final subscription = orchestrator.traceSource.traceStream.listen((event) {
        print('Test received trace event: ${event.symbol}');
        traceReceived = true;
      });

      await orchestrator.startEmulation(
        elfPath: emulator.elfFilePath!,
        baseImagePath: emulator.baseImagePath,
        pauseOnUnhandled: false,
      );

      expect(orchestrator.hasServerProcess, isTrue);
      expect(orchestrator.state.toString(), contains('running'));

      await Future.delayed(const Duration(seconds: 5));

      expect(traceReceived, isTrue, reason: 'Should receive trace events if LogFunctionNames succeeded');

      await subscription.cancel();

      await orchestrator.resetEmulation();
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
