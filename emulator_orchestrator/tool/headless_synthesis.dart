// Headless synthesis driver. Stands up DartEngine + the synthesizer
// workflow against the user's real Aya PPG project and runs the
// iterative loop that was crashing at iteration 2 with
// `ImportException: No module named set_return_value`. Streams
// synthesizer events so progress is visible.
//
// Pass --max-iterations=N to cap the loop (default 5 — enough to get
// past the crash scenario without burning a long run for verification).
//
//   dart run tool/headless_synthesis.dart [--max-iterations=N]

import 'dart:async';
import 'dart:io';

import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/services/hooks/artifact_library_service.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_engine.dart';
import 'package:emulator_orchestrator/orchestrator/events/synthesizer_events.dart';
import 'package:emulator_orchestrator/orchestrator/hook_spec.dart';
import 'package:emulator_orchestrator/orchestrator/workflows/synthesizer_workflow.dart';

const _projectPath =
    '/home/evan/.config/call_graph_viewer/projects/Aya PPG.emu';

Future<void> main(List<String> argv) async {
  var maxIterations = 10;
  for (final a in argv) {
    if (a.startsWith('--max-iterations=')) {
      maxIterations = int.parse(a.substring('--max-iterations='.length));
    }
  }

  final db = ArtifactDatabase();
  final library = ArtifactLibraryService(db);
  final repo = EmulatorRepository();

  // 1) Load the user's project + ensure migrations have run (the
  //    synthesizer's iter-2 crash hinges on the legacy hook row at
  //    artifacts.id=13 being rewritten).
  final emu = await repo.loadEmulator(_projectPath);
  stdout.writeln('[headless] loaded project: ${emu.name}');
  stdout.writeln('[headless] elf:  ${emu.elfFilePath}');
  stdout.writeln('[headless] repl: ${emu.baseImagePath}');

  final elfHash = await library.hashElfFile(emu.elfFilePath!);
  // processElfFile is what the UI calls on open — it runs
  // ensureDefaultTemplates + ensureIntrinsicScores + migrateLegacyHookBodies.
  // Pass an empty symbol list — the symbols are already registered.
  await library.processElfFile(
    elfFilePath: emu.elfFilePath!,
    symbolNames: const [],
  );

  // 2) Stand up the engine.
  final engine = DartEngine();
  stdout.writeln('[headless] starting Renode process...');
  await engine.startProcess();
  await engine.controller.connect();
  await engine.callGraphSource.connect();
  await engine.controller.load(emu.baseImagePath!, emu.elfFilePath!);
  await engine.traceSource.connect();
  // Subscribe to lifecycle events so the synthesizer can see pauses.
  // We don't need our own forwarding — the broadcast streams on
  // DartEmulationController feed every listener.

  // 3) Build the synthesizer.
  final synth = SynthesizerWorkflow(
    emulationController: engine.controller,
    artifactDb: db,
  );

  // Stream events so iter-by-iter progress is visible.
  final eventsSub = synth.events.listen((e) {
    if (e is SynthesizerIterationStarted) {
      stdout.writeln('[headless] iter ${e.iteration} — '
          '${e.currentHookMap.length} hooks applied');
    } else if (e is SynthesizerHookApplied) {
      stdout.writeln('[headless] hook applied for ${e.symbol}: '
          '${e.hookName} (${e.hookIndex + 1}/${e.totalHooksForSymbol})');
    } else if (e is SynthesizerSymbolExhausted) {
      stdout.writeln('[headless] symbol exhausted: ${e.symbol}');
    } else if (e is SynthesizerCompleted) {
      stdout.writeln('[headless] completed iter=${e.iteration} '
          'success=${e.result.success}');
    }
  });

  // 4) Run.
  stdout.writeln('[headless] starting synthesis (maxIterations=$maxIterations)');
  try {
    final result = await synth.run(
      elfPath: emu.elfFilePath!,
      elfHash: elfHash,
      baseImagePath: emu.baseImagePath!,
      maxIterations: maxIterations,
      hookPreferences: Map<String, int>.from(emu.hookPreferences),
      hookOverrides: Map<String, int>.from(emu.hookOverrides),
      hookOverrideScopes: Map<String, String>.from(emu.hookOverrideScopes),
      resolvedHooks: Map<String, String>.from(emu.hooks),
      commsHooks: const <String, HookSpec>{},
      hookBindings: emu.hookBindings,
    );
    stdout.writeln('\n[headless] RESULT: success=${result.success} '
        'failedSymbol=${result.failedSymbol ?? '-'} '
        'hooks=${result.resolvedHooks.length}');
  } catch (e, st) {
    stderr.writeln('[headless] synthesis threw: $e');
    stderr.writeln(st);
    exitCode = 1;
  } finally {
    await eventsSub.cancel();
    await engine.stopProcess();
    await db.close();
  }
}
