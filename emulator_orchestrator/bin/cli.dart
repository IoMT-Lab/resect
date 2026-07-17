import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/comms_assignment.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/data/services/artifact_library_service.dart';
import 'package:emulator_orchestrator/data/services/fidelity_calculator.dart';
import 'package:emulator_orchestrator/data/services/hook_catalog.dart';
import 'package:emulator_orchestrator/data/services/last_run_insight_service.dart';
import 'package:emulator_orchestrator/data/services/llm_client.dart';
import 'package:emulator_orchestrator/data/services/llm_hook_generator.dart';
import 'package:emulator_orchestrator/data/services/rag_index.dart';
import 'package:emulator_orchestrator/data/services/recommendation_service.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_report_writer.dart';
import 'package:emulator_orchestrator/orchestrator/comms/comms_config.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/engine/dart/dart_engine.dart';

/// CLI tool for emulator creation, call graph generation, and synthesizer.
///
/// Usage:
///   dart run bin/cli.dart <command> [options]
///
/// Commands:
///   create      Create a new emulator project
///   callgraph   Generate and output a call graph
///   synthesize  Run the synthesizer against firmware
///   fidelity    Compute fidelity metrics for a call graph
///   export      Export an emulator to a Renode .resc script
void main(List<String> args) async {
  if (args.isEmpty || args[0] == '--help' || args[0] == '-h') {
    _printUsage();
    exit(0);
  }

  final command = args[0];
  final flags = _parseFlags(args.sublist(1));

  try {
    switch (command) {
      case 'create':
        await _runCreate(flags);
      case 'callgraph':
        await _runCallgraph(flags);
      case 'synthesize':
        await _runSynthesize(flags);
      case 'autotune':
        await _runAutotune(flags);
      case 'export':
        await _runExport(flags);
      case 'fidelity':
        await _runFidelity(flags);
      default:
        stderr.writeln('Unknown command: $command');
        _printUsage();
        exit(1);
    }
  } catch (e) {
    stderr.writeln('Error: $e');
    exit(1);
  }

  // Force termination: lingering Socket.IO sockets / broadcast stream
  // controllers otherwise keep the VM alive after the command finishes.
  // exitCode is set by commands (e.g. synthesize sets 1 on non-convergence).
  exit(exitCode);
}

// =============================================================================
// COMMANDS
// =============================================================================

/// Create a new emulator project.
///
/// No engine backend needed — purely local file operations.
Future<void> _runCreate(Map<String, String> flags) async {
  if (flags.containsKey('help') || flags.containsKey('h')) {
    _printCreateUsage();
    exit(0);
  }

  final name = flags['name'];
  final elfPath = flags['elf'];
  final replPath = flags['repl'];
  final outputPath = flags['output'] ?? flags['o'];

  if (name == null || name.isEmpty) {
    stderr.writeln('Error: --name is required');
    _printCreateUsage();
    exit(1);
  }
  if (elfPath == null || elfPath.isEmpty) {
    stderr.writeln('Error: --elf is required');
    _printCreateUsage();
    exit(1);
  }
  if (replPath == null || replPath.isEmpty) {
    stderr.writeln('Error: --repl is required');
    _printCreateUsage();
    exit(1);
  }

  if (!await File(elfPath).exists()) {
    stderr.writeln('Error: ELF file not found: $elfPath');
    exit(1);
  }
  if (!await File(replPath).exists()) {
    stderr.writeln('Error: REPL file not found: $replPath');
    exit(1);
  }

  final orchestrator = _createOrchestrator();

  try {
    final emulator = await orchestrator.createEmulator(
      name: name,
      elfFilePath: elfPath,
      baseImagePath: replPath,
    );

    final savePath = outputPath ?? './$name.emu';
    await orchestrator.saveEmulator(emulator, savePath: savePath);

    stderr.writeln('Emulator created: $savePath');

    final output = emulator.toJson();
    output['savePath'] = savePath;
    stdout.writeln(jsonEncode(output));
  } finally {
    orchestrator.dispose();
  }
}

/// Generate and output a call graph.
///
/// Requires the emulation engine for static ELF analysis.
Future<void> _runCallgraph(Map<String, String> flags) async {
  if (flags.containsKey('help') || flags.containsKey('h')) {
    _printCallgraphUsage();
    exit(0);
  }

  final elfPath = flags['elf'];
  final format = flags['format'] ?? 'json';
  final outputPath = flags['output'] ?? flags['o'];

  if (elfPath == null || elfPath.isEmpty) {
    stderr.writeln('Error: --elf is required');
    _printCallgraphUsage();
    exit(1);
  }
  if (!await File(elfPath).exists()) {
    stderr.writeln('Error: ELF file not found: $elfPath');
    exit(1);
  }

  // Call-graph extraction is in-process (objdump) — no engine/server needed.
  final orchestrator = _createOrchestrator();

  try {
    await orchestrator.callGraphSource.connect();

    stderr.writeln('Generating call graph for $elfPath...');
    final callGraph = await orchestrator.generateCallGraph(elfPath);

    // Process ELF in artifact DB (register symbols, create default hooks)
    final artifactService = ArtifactLibraryService(orchestrator.artifactDb);
    final symbolNames = callGraph.symbols.keys.toList();
    final firmwareRecord = await artifactService.processElfFile(
      elfFilePath: elfPath,
      symbolNames: symbolNames,
    );
    stderr.writeln('Registered firmware: ${firmwareRecord.elfHash} '
        '(${firmwareRecord.symbolNames.length} symbols)');

    String result;
    if (format == 'summary') {
      final buf = StringBuffer();
      buf.writeln('Call Graph: $elfPath');
      buf.writeln('Functions: ${callGraph.totalFunctions}');
      buf.writeln('Edges: ${callGraph.totalEdges}');
      buf.writeln('');
      for (final entry in callGraph.symbols.entries) {
        final sym = entry.value;
        buf.writeln('${sym.name} (${sym.numInstructions} instructions)');
        for (final call in sym.calledSymbols.entries) {
          buf.writeln('  → ${call.key} (${call.value}x)');
        }
      }
      result = buf.toString();
    } else {
      result = const JsonEncoder.withIndent('  ').convert(callGraph.toJson());
    }

    if (outputPath != null) {
      await File(outputPath).writeAsString(result);
      stderr.writeln('Written to $outputPath');
    } else {
      stdout.writeln(result);
    }
  } finally {
    orchestrator.dispose();
  }
}

/// Run the synthesizer against firmware.
///
/// Full lifecycle: start engine, connect, generate call graph, register
/// artifacts, load firmware, run synthesizer.
Future<void> _runSynthesize(Map<String, String> flags) async {
  if (flags.containsKey('help') || flags.containsKey('h')) {
    _printSynthesizeUsage();
    exit(0);
  }

  final elfPath = flags['elf'];
  final replPath = flags['repl'];
  final startFrom = flags['start-from'];
  final endAtRaw = flags['end-at'];
  final endAt = endAtRaw?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  final maxIterations = int.tryParse(flags['max-iterations'] ?? '') ?? 100;
  final outputPath = flags['output'] ?? flags['o'];
  final saveEmulatorPath = flags['save-emulator'];
  final emulatorName = flags['name'];
  final engineDir = flags['engine-dir'];

  if (elfPath == null || elfPath.isEmpty) {
    stderr.writeln('Error: --elf is required');
    _printSynthesizeUsage();
    exit(1);
  }
  if (replPath == null || replPath.isEmpty) {
    stderr.writeln('Error: --repl is required');
    _printSynthesizeUsage();
    exit(1);
  }
  if (!await File(elfPath).exists()) {
    stderr.writeln('Error: ELF file not found: $elfPath');
    exit(1);
  }
  if (!await File(replPath).exists()) {
    stderr.writeln('Error: REPL file not found: $replPath');
    exit(1);
  }

  final orchestrator = _createOrchestrator();

  try {
    await orchestrator.engineLifecycle.start(engineDir: engineDir);

    // Connect every channel the synthesizer needs.
    if (!await orchestrator.callGraphSource.connect()) {
      stderr.writeln('Error: Could not connect callgraph source');
      exit(1);
    }
    if (!await orchestrator.emulationController.connect()) {
      stderr.writeln('Error: Could not connect emulation control channel');
      exit(1);
    }
    await orchestrator.traceSource.connect();

    stderr.writeln('Generating call graph...');
    final callGraph = await orchestrator.generateCallGraph(elfPath);
    stderr.writeln('Found ${callGraph.totalFunctions} functions');

    final artifactService = ArtifactLibraryService(orchestrator.artifactDb);
    final symbolNames = callGraph.symbols.keys.toList();
    final firmwareRecord = await artifactService.processElfFile(
      elfFilePath: elfPath,
      symbolNames: symbolNames,
    );
    final elfHash = firmwareRecord.elfHash;
    stderr.writeln('ELF hash: $elfHash');

    stderr.writeln('Loading firmware...');
    await orchestrator.emulationController.load(replPath, elfPath);

    orchestrator.synthesizerWorkflow.events.listen((event) {
      stderr.writeln('[synthesizer] ${event.runtimeType} '
          '(iteration ${event.iteration})');
    });

    // Track executed symbols via filtered trace for fidelity computation.
    final executedSymbols = <String>{};
    final traceSubscription = orchestrator.traceSource.filteredTraceStream.listen((event) {
      if (event.isEntry) {
        executedSymbols.add(event.symbol);
      }
    });

    stderr.writeln('Starting synthesizer (max $maxIterations iterations)...');
    final result = await orchestrator.runSynthesizer(
      elfPath: elfPath,
      baseImagePath: replPath,
      elfHash: elfHash,
      startFrom: startFrom,
      endAt: endAt,
      maxIterations: maxIterations,
    );

    await traceSubscription.cancel();

    stderr.writeln('');
    if (result.success) {
      stderr.writeln('SUCCESS: Firmware runs cleanly with '
          '${result.resolvedHooks.length} hooks applied');
    } else {
      stderr.writeln('FAILED: Symbol "${result.failedSymbol}" '
          'exhausted all hooks after ${result.totalIterations} iterations');
      exitCode = 1;
    }
    stderr.writeln('Duration: ${result.totalDuration.inSeconds}s');

    final outputMap = result.toJson();
    if (callGraph.symbols.isNotEmpty) {
      Set<String> subgraphSymbols = const {};
      if (startFrom != null && endAt != null && endAt.isNotEmpty) {
        subgraphSymbols = FidelityCalculator.subgraphBetween(
          callGraph, startFrom, endAt.first,
        ).union(executedSymbols);
      }

      final fidelity = FidelityCalculator.compute(
        callGraph: callGraph,
        hookedSymbols: result.resolvedHooks.keys.toSet(),
        traversedSymbols: executedSymbols,
        subgraphSymbols: subgraphSymbols,
      );
      outputMap['fidelity'] = fidelity.toJson();
      stderr.writeln('Fidelity: $fidelity');
    }

    final resultJson = const JsonEncoder.withIndent('  ').convert(outputMap);
    if (outputPath != null) {
      await File(outputPath).writeAsString(resultJson);
      stderr.writeln('Result written to $outputPath');
    } else {
      stdout.writeln(resultJson);
    }

    if (saveEmulatorPath != null && result.resolvedHookCode.isNotEmpty) {
      final name = emulatorName ?? File(elfPath).uri.pathSegments.last.replaceAll('.elf', '');
      final emulator = Emulator.create(
        name: name,
        elfFilePath: elfPath,
        baseImagePath: replPath,
      ).copyWith(hooks: result.resolvedHookCode);

      await orchestrator.saveEmulator(emulator, savePath: saveEmulatorPath);
      stderr.writeln('Emulator saved to $saveEmulatorPath');
    }
  } finally {
    try {
      await orchestrator.resetEmulation();
    } catch (_) {}
    await orchestrator.engineLifecycle.stop();
    orchestrator.dispose();
  }
}

/// Run the closed-loop auto-tune session headlessly against a saved
/// `.emu` project, auto-accepting every LLM recommendation and writing
/// a per-round report for reading + debugging.
///
/// Drives the SAME [AutoTuneEngine] the UI drives — the only difference
/// is the injected review policy ([AcceptAllReviewPolicy]) and sink
/// ([AutoTuneReportSink]). Firmware is reloaded before each round so
/// every round is a clean synthesis process, matching the
/// one-report-per-process ask.
Future<void> _runAutotune(Map<String, String> flags) async {
  if (flags.containsKey('help') || flags.containsKey('h')) {
    _printAutotuneUsage();
    exit(0);
  }

  final emuPath = flags['emu'];
  if (emuPath == null || emuPath.isEmpty) {
    stderr.writeln('Error: --emu is required');
    _printAutotuneUsage();
    exit(1);
  }
  if (!await File(emuPath).exists()) {
    stderr.writeln('Error: .emu file not found: $emuPath');
    exit(1);
  }

  final maxRounds = int.tryParse(flags['max-rounds'] ?? '') ??
      AutoTuneConfig.defaultMaxRounds;
  final maxIterations = int.tryParse(flags['max-iterations'] ?? '') ?? 10;
  final maxRecs = int.tryParse(flags['max-recs'] ?? '') ??
      AutoTuneConfig.defaultMaxRecommendationsPerRound;
  final stagnantLimit = int.tryParse(flags['stagnant-limit'] ?? '') ??
      AutoTuneConfig.defaultStagnantRoundLimit;
  // Comms protocols to virtualize as a UNIT (default: all classified). An
  // interdependent bus like I2C can't be stubbed symbol-by-symbol — the
  // comms mapping applies coherent per-protocol hooks. `--comms none` opts out.
  final commsFlag = (flags['comms'] ?? 'i2c,uart,spi').toLowerCase();
  final commsClasses = commsFlag == 'none'
      ? const <CommsClass>{}
      : {
          for (final c in commsFlag.split(','))
            for (final v in CommsClass.values)
              if (v.name == c.trim()) v,
        };
  // Color: auto (TTY-detect, default) / always / never.
  final colorFlag = (flags['color'] ?? 'auto').toLowerCase();
  final bool? useColor = switch (colorFlag) {
    'always' => true,
    'never' => false,
    _ => null,
  };
  final engineDir = flags['engine-dir'];
  final startFromFlag = flags['start-from'];
  final endAtFlag = flags['end-at']
      ?.split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  // Load the project — carries elf, repl, cached call graph, and the
  // seeded overlays/bindings.
  final emulator = await EmulatorRepository().loadEmulator(emuPath);
  final elfPath = emulator.elfFilePath;
  final replPath = emulator.baseImagePath;
  if (elfPath == null || replPath == null) {
    stderr.writeln('Error: project is missing its ELF or .repl path');
    exit(1);
  }
  if (!await File(elfPath).exists()) {
    stderr.writeln('Error: ELF file not found: $elfPath');
    exit(1);
  }
  if (!await File(replPath).exists()) {
    stderr.writeln('Error: .repl file not found: $replPath');
    exit(1);
  }

  final projectDir = File(emuPath).parent.path;
  final startedAt = DateTime.now();
  final reportDir = Directory(flags['report-dir'] ??
      '$projectDir/autotune_reports/'
          '${startedAt.toIso8601String().replaceAll(':', '-')}');
  final startFrom = startFromFlag ?? emulator.emulationConfig.startFrom;
  final endAt = endAtFlag ??
      (emulator.emulationConfig.endAt.isEmpty
          ? null
          : emulator.emulationConfig.endAt);

  // LLM stack — same construction the UI providers use, reading host +
  // model from resect.config with per-invocation overrides.
  final cfg = EnvConfig.load();
  final host = (flags['host'] ?? cfg.get('LLM_OLLAMA_HOST') ?? '').trim();
  final model = (flags['model'] ?? cfg.get('LLM_MODEL') ?? '').trim();
  final client = LlmClient(
    host: host.isEmpty ? 'localhost:11434' : host,
    model: model.isEmpty ? 'gemma4:e4b' : model,
  );

  final orchestrator = _createOrchestrator();

  try {
    await orchestrator.engineLifecycle.start(engineDir: engineDir);
    if (!await orchestrator.callGraphSource.connect()) {
      stderr.writeln('Error: Could not connect callgraph source');
      exit(1);
    }
    if (!await orchestrator.emulationController.connect()) {
      stderr.writeln('Error: Could not connect emulation control channel');
      exit(1);
    }
    await orchestrator.traceSource.connect();

    // Call graph — prefer the project's cached one (what the UI reasons
    // over); regenerate if absent.
    final callGraph = emulator.cachedCallGraph ??
        await orchestrator.generateCallGraph(elfPath);
    stderr.writeln('Call graph: ${callGraph.totalFunctions} functions');

    // Register the firmware → elfHash + default hooks + symbol rows.
    final artifactService = ArtifactLibraryService(orchestrator.artifactDb);
    final firmwareRecord = await artifactService.processElfFile(
      elfFilePath: elfPath,
      symbolNames: callGraph.symbols.keys.toList(),
    );
    final elfHash = firmwareRecord.elfHash;
    stderr.writeln('ELF hash: $elfHash');

    // RAG index + hook generator + recommender — same wiring as the UI.
    final ragIndex = RagIndex(
      projectDir: projectDir,
      client: client,
      artifactDb: orchestrator.artifactDb,
    );
    final hookGenerator = LlmHookGenerator(
      index: ragIndex,
      client: client,
      artifactDb: orchestrator.artifactDb,
    );
    final recommendationService = RecommendationService(
      llmClient: client,
      insightService: LastRunInsightService(llmClient: client),
      artifactDb: orchestrator.artifactDb,
      ragIndex: ragIndex,
    );

    // Comms virtualization — apply coherent per-protocol hooks for every
    // classified symbol of each requested protocol, instead of stubbing the
    // interdependent bus symbol-by-symbol (which can't work for I2C et al).
    const commsPorts = {CommsClass.i2c: 1234, CommsClass.spi: 1235, CommsClass.uart: 1236};
    final commsConfigs = <CommsClass, CommsProtocolConfig>{
      for (final c in commsClasses)
        c: CommsProtocolConfig(port: commsPorts[c] ?? 1234, virtualized: true),
    };
    final commsHooks = buildCommsHooks(
      emulator: emulator,
      configs: commsConfigs,
      catalog: HookCatalog.system(),
    );
    // Status map the decision-state builder + recommend prompt read.
    final commsStatus = <CommsClass, CommsProtocolStatus>{
      for (final e in commsConfigs.entries)
        e.key: (virtualized: e.value.virtualized, port: e.value.port),
    };
    if (commsHooks.isNotEmpty) {
      stderr.writeln('Comms virtualized: ${commsHooks.length} hooks across '
          '${commsClasses.map((c) => c.name).join('/')}');
    }

    // One synthesis per round: reset + reload for a clean machine, run
    // the synthesizer with the round's overlays, then enrich the result
    // with metrics + executed symbols (the engine reads those back).
    Future<SynthesizerResult?> runSynthesis(
        AutoTuneOverlays overlays, int round) async {
      // Fresh machine per round: `load` re-creates the Renode machine
      // (createMachine clears any prior state) and reloads firmware, so
      // each round is a clean synthesis process. NOT resetEmulation() —
      // that stops the whole engine process.
      await orchestrator.emulationController.load(replPath, elfPath);

      // Collect executed symbols from the RAW trace stream, deduping
      // per-round locally. `filteredTraceStream` can't be used across
      // rounds: its seen-set only resets on (re)connect, so once round 0
      // observed a symbol, later rounds would see zero new entries and
      // report 0% coverage.
      final executed = <String>{};
      final sub = orchestrator.traceSource.traceStream.listen((e) {
        if (e.isEntry) executed.add(e.symbol);
      });
      try {
        final result = await orchestrator.runSynthesizer(
          elfPath: elfPath,
          baseImagePath: replPath,
          elfHash: elfHash,
          startFrom: startFrom,
          endAt: endAt,
          maxIterations: overlays.iterationCap,
          hookPreferences: overlays.hookPreferences,
          hookOverrides: overlays.hookOverrides,
          hookOverrideScopes: overlays.hookOverrideScopes,
          hookBindings: overlays.hookBindings,
          commsHooks: commsHooks,
          llmGenerator: hookGenerator,
        );
        var subgraph = const <String>{};
        if (startFrom != null && endAt != null && endAt.isNotEmpty) {
          subgraph = FidelityCalculator.subgraphBetween(
            callGraph, startFrom, endAt.first,
          ).union(executed);
        }
        return enrichSynthesizerResult(
          result: result,
          callGraph: callGraph,
          executedSymbols: executed,
          subgraphSymbols: subgraph,
        );
      } finally {
        await sub.cancel();
      }
    }

    final sink = AutoTuneReportSink(
      reportDir: reportDir,
      callGraph: callGraph,
      startedAt: startedAt,
      manifestsDir: Directory('$projectDir/manifests'),
      color: useColor,
    );

    final engine = AutoTuneEngine(
      runSynthesis: runSynthesis,
      recommendationService: recommendationService,
      artifactDb: orchestrator.artifactDb,
      hookGenerator: hookGenerator,
      reviewPolicy: const AcceptAllReviewPolicy(),
      sink: sink,
    );

    stderr.writeln('Starting auto-tune: max $maxRounds rounds, '
        '$maxIterations iterations/run, model ${client.model}');
    stderr.writeln('Reports → ${reportDir.path}');

    // Quiet the synthesizer's verbose stdout so the sink's structured,
    // color-coded round blocks stand out: drop the multi-line hook-body
    // echoes entirely, and dim the remaining `[Synthesizer] …` lines to
    // recede behind the key events. The sink writes to stderr directly
    // (not `print`), so it is unaffected by this override.
    final dimNoise = useColor ?? stdout.hasTerminal;
    final reason = await runZoned(
      () => engine.run(
        project: emulator,
        elfHash: elfHash,
        callGraph: callGraph,
        config: AutoTuneConfig(
          maxRounds: maxRounds,
          maxRecommendationsPerRound: maxRecs,
          stagnantRoundLimit: stagnantLimit,
        ),
        commsConfigs: commsStatus,
        iterationCap: maxIterations,
      ),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          if (line.startsWith('[Hook applied]')) return;
          stderr.writeln(dimNoise ? '\x1b[2m$line\x1b[0m' : line);
        },
      ),
    );

    stderr.writeln('');
    stderr.writeln('Auto-tune finished: ${reason.name}');
    stderr.writeln('Reports written to ${reportDir.path}');
    stdout.writeln(reportDir.path);

    // Non-zero for hard failures a validation harness should catch;
    // normal terminations (llmEmpty, maxRounds, no-progress, stopped)
    // exit 0.
    const hardFailures = {
      AutoTuneStopReason.baselineFailed,
      AutoTuneStopReason.synthesisError,
      AutoTuneStopReason.llmError,
      AutoTuneStopReason.parseFailed,
    };
    if (hardFailures.contains(reason)) exitCode = 1;

    ragIndex.close();
  } finally {
    client.close();
    try {
      await orchestrator.resetEmulation();
    } catch (_) {}
    await orchestrator.engineLifecycle.stop();
    orchestrator.dispose();
  }
}

/// Export an emulator to a Renode .resc script.
///
/// No engine backend needed — purely local file operations.
Future<void> _runExport(Map<String, String> flags) async {
  if (flags.containsKey('help') || flags.containsKey('h')) {
    _printExportUsage();
    exit(0);
  }

  final emulatorPath = flags['emulator'];
  final outputPath = flags['output'] ?? flags['o'];

  if (emulatorPath == null || emulatorPath.isEmpty) {
    stderr.writeln('Error: --emulator is required');
    _printExportUsage();
    exit(1);
  }
  if (outputPath == null || outputPath.isEmpty) {
    stderr.writeln('Error: --output is required');
    _printExportUsage();
    exit(1);
  }

  final repository = EmulatorRepository();

  try {
    final emulator = await repository.loadEmulator(emulatorPath);

    if (emulator.hooks.isEmpty) {
      stderr.writeln('Error: Emulator has no hooks to export');
      exit(1);
    }
    if (emulator.elfFilePath == null || emulator.baseImagePath == null) {
      stderr.writeln('Error: Emulator is missing ELF or platform description paths');
      exit(1);
    }

    await repository.exportResc(emulator, outputPath);
    stderr.writeln('Exported Renode script to $outputPath');
  } catch (e) {
    stderr.writeln('Error: $e');
    exit(1);
  }
}

/// Compute fidelity metrics for a call graph.
Future<void> _runFidelity(Map<String, String> flags) async {
  if (flags.containsKey('help') || flags.containsKey('h')) {
    _printFidelityUsage();
    exit(0);
  }

  final elfPath = flags['elf'];
  final callgraphPath = flags['callgraph'];
  final hooksRaw = flags['hooks'];
  final startFrom = flags['start-from'];
  final endAtRaw = flags['end-at'];
  final traversedRaw = flags['traversed'];
  final format = flags['format'] ?? 'json';
  final outputPath = flags['output'] ?? flags['o'];
  if (elfPath == null && callgraphPath == null) {
    stderr.writeln('Error: Either --elf or --callgraph is required');
    _printFidelityUsage();
    exit(1);
  }

  final hookedSymbols = hooksRaw
      ?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet()
      ?? <String>{};
  final endAt = endAtRaw
      ?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  final traversedSymbols = traversedRaw
      ?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet()
      ?? <String>{};

  CallGraph callGraph;

  if (callgraphPath != null) {
    final file = File(callgraphPath);
    if (!await file.exists()) {
      stderr.writeln('Error: Call graph file not found: $callgraphPath');
      exit(1);
    }
    final jsonStr = await file.readAsString();
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    callGraph = CallGraph.fromSerializedJson(json);
    stderr.writeln('Loaded call graph: ${callGraph.totalFunctions} functions');
  } else {
    if (!await File(elfPath!).exists()) {
      stderr.writeln('Error: ELF file not found: $elfPath');
      exit(1);
    }

    // In-process call-graph extraction — no engine/server needed.
    final orchestrator = _createOrchestrator();

    try {
      await orchestrator.callGraphSource.connect();
      stderr.writeln('Generating call graph for $elfPath...');
      callGraph = await orchestrator.generateCallGraph(elfPath);
      stderr.writeln('Found ${callGraph.totalFunctions} functions');
    } finally {
      orchestrator.dispose();
    }
  }

  Set<String> subgraphSymbols = const {};
  if (startFrom != null && endAt != null && endAt.isNotEmpty) {
    subgraphSymbols = FidelityCalculator.subgraphBetween(
      callGraph, startFrom, endAt.first,
    ).union(traversedSymbols);
  }

  final fidelity = FidelityCalculator.compute(
    callGraph: callGraph,
    hookedSymbols: hookedSymbols,
    traversedSymbols: traversedSymbols,
    subgraphSymbols: subgraphSymbols,
  );

  String result;
  if (format == 'summary') {
    result = fidelity.toString();
  } else {
    result = const JsonEncoder.withIndent('  ').convert(fidelity.toJson());
  }

  if (outputPath != null) {
    await File(outputPath).writeAsString(result);
    stderr.writeln('Written to $outputPath');
  } else {
    stdout.writeln(result);
  }
}

// =============================================================================
// HELPERS
// =============================================================================

EmulationOrchestrator _createOrchestrator() {
  // Stale-port reclaim for the Renode server-mode port is handled inside
  // DartEngine.startProcess(), so no pre-launch cleanup is needed here.
  final engine = DartEngine();
  return EmulationOrchestrator(
    engineLifecycle: engine.lifecycle,
    emulationController: engine.controller,
    callGraphSource: engine.callGraphSource,
    traceSource: engine.traceSource,
    emulatorRepository: EmulatorRepository(),
    artifactDb: ArtifactDatabase(),
  );
}

Map<String, String> _parseFlags(List<String> args) {
  final flags = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      final key = args[i].substring(2);
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
        flags[key] = args[++i];
      } else {
        flags[key] = 'true';
      }
    } else if (args[i].startsWith('-') && args[i].length == 2) {
      final key = args[i].substring(1);
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
        flags[key] = args[++i];
      } else {
        flags[key] = 'true';
      }
    }
  }
  return flags;
}

// =============================================================================
// USAGE
// =============================================================================

void _printUsage() {
  stderr.writeln('''
Emulation CLI Tool

Usage: dart run bin/cli.dart <command> [options]

Commands:
  create      Create a new emulator project
  callgraph   Generate and output a call graph
  synthesize  Run the synthesizer against firmware
  autotune    Run the closed-loop LLM auto-tune session with per-round reports
  fidelity    Compute fidelity metrics for a call graph
  export      Export an emulator to a Renode .resc script

Run 'dart run bin/cli.dart <command> --help' for command-specific help.

Global options:
  --backend-url <url>   Connect to existing emulation engine (skips auto-start)
  --engine-dir <path>   Path to emulation_engine directory
  -h, --help            Show this help''');
}

void _printCreateUsage() {
  stderr.writeln('''
Usage: dart run bin/cli.dart create [options]

Create a new emulator project.

Required:
  --name <name>         Emulator name
  --elf <path>          Path to ELF firmware file
  --repl <path>         Path to .repl platform description

Optional:
  -o, --output <path>   Save path (default: ./<name>.emu)''');
}

void _printCallgraphUsage() {
  stderr.writeln('''
Usage: dart run bin/cli.dart callgraph [options]

Generate and output a call graph for an ELF file.

Required:
  --elf <path>            Path to ELF firmware file

Optional:
  --format <json|summary> Output format (default: json)
  -o, --output <path>     Write to file instead of stdout
  --backend-url <url>     Connect to existing backend (skips auto-start)
  --engine-dir <path>     Path to emulation_engine directory''');
}

void _printExportUsage() {
  stderr.writeln('''
Usage: dart run bin/cli.dart export [options]

Export an emulator to a standalone Renode .resc script.

Required:
  --emulator <path.emu>   Path to emulator file
  -o, --output <path>     Output .resc file path''');
}

void _printFidelityUsage() {
  stderr.writeln('''
Usage: dart run bin/cli.dart fidelity [options]

Compute fidelity metrics for a call graph.

Sources (one required):
  --elf <path>              Path to ELF file (generates call graph via backend)
  --callgraph <path>        Path to saved call graph JSON file (no backend needed)

Options:
  --hooks <symbols>         Comma-separated hooked symbol names
  --start-from <symbol>     Start symbol for subgraph analysis
  --end-at <symbols>        Comma-separated end symbols for subgraph
  --traversed <symbols>     Comma-separated traversed symbol names
  --format <json|summary>   Output format (default: json)
  -o, --output <path>       Write to file instead of stdout
  --backend-url <url>       Connect to existing backend (for --elf mode)
  --engine-dir <path>       Path to emulation_engine directory''');
}

void _printAutotuneUsage() {
  stderr.writeln('''
Usage: dart run bin/cli.dart autotune [options]

Run the closed-loop LLM auto-tune session headlessly against a saved
project, auto-accepting every recommendation. Writes a per-round report
(recommendations + rationale + manifest + trace) plus a summary.

Required:
  --emu <path.emu>          Saved project (carries ELF, .repl, call graph, overlays)

Optional:
  --max-rounds <n>          LLM rounds after the baseline (default: ${AutoTuneConfig.defaultMaxRounds})
  --max-iterations <n>      Synthesizer iteration cap per round (default: 10)
  --max-recs <n>            Max recommendations per round (default: ${AutoTuneConfig.defaultMaxRecommendationsPerRound})
  --stagnant-limit <n>      Consecutive stagnant rounds before stopping (default: ${AutoTuneConfig.defaultStagnantRoundLimit})
  --report-dir <path>       Report output dir
                            (default: <projectDir>/autotune_reports/<timestamp>/)
  --start-from <symbol>     Override the project's start symbol
  --end-at <symbols>        Override the project's stop symbols (comma-separated)
  --comms <csv|none>        Protocols to virtualize as a unit (default: i2c,uart,spi)
  --model <tag>             Ollama model tag (default: resect.config LLM_MODEL)
  --host <host:port>        Ollama host (default: resect.config LLM_OLLAMA_HOST)
  --color <auto|always|never>  Colorize the console output (default: auto)
  --engine-dir <path>       Path to emulation_engine directory''');
}

void _printSynthesizeUsage() {
  stderr.writeln('''
Usage: dart run bin/cli.dart synthesize [options]

Run the automated hook synthesizer against firmware.

Required:
  --elf <path>            Path to ELF firmware file
  --repl <path>           Path to .repl platform description

Optional:
  --start-from <symbol>       Symbol to start execution from
  --end-at <symbols>          Comma-separated stop symbols (for subgraph fidelity)
  --max-iterations <n>        Safety limit (default: 100)
  -o, --output <path>         Write JSON result to file instead of stdout
  --save-emulator <path.emu>  Save emulator with resolved hooks
  --name <name>               Emulator name (for --save-emulator; default: ELF filename)
  --backend-url <url>         Connect to existing backend (skips auto-start)
  --engine-dir <path>         Path to emulation_engine directory''');
}
