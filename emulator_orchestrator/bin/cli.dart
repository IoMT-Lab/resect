import 'dart:convert';
import 'dart:io';

import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/repositories/emulator_repository.dart';
import 'package:emulator_orchestrator/data/services/artifact_library_service.dart';
import 'package:emulator_orchestrator/data/services/callgraph_service.dart';
import 'package:emulator_orchestrator/data/services/fidelity_calculator.dart';
import 'package:emulator_orchestrator/data/services/filtered_trace_service.dart';
import 'package:emulator_orchestrator/data/services/lifecycle_service.dart';
import 'package:emulator_orchestrator/data/services/trace_service.dart';
import 'package:emulator_orchestrator/orchestrator/emulation_orchestrator.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_call_graph_source.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_emulation_controller.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_engine_lifecycle.dart';
import 'package:emulator_orchestrator/orchestrator/engine/renode/renode_trace_source.dart';

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
  final backendUrl = flags['backend-url'];
  final engineDir = flags['engine-dir'];

  if (elfPath == null || elfPath.isEmpty) {
    stderr.writeln('Error: --elf is required');
    _printCallgraphUsage();
    exit(1);
  }
  if (!await File(elfPath).exists()) {
    stderr.writeln('Error: ELF file not found: $elfPath');
    exit(1);
  }

  final serverUrl = backendUrl ?? 'http://localhost:12356';
  final orchestrator = _createOrchestrator(serverUrl: serverUrl);
  final ownsEngine = backendUrl == null;

  try {
    if (ownsEngine) {
      await orchestrator.engineLifecycle.start(engineDir: engineDir);
    }

    final connected = await orchestrator.callGraphSource.connect();
    if (!connected) {
      stderr.writeln('Error: Could not connect to backend at $serverUrl');
      exit(1);
    }

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
    if (ownsEngine) {
      await orchestrator.engineLifecycle.stop();
    }
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
  final backendUrl = flags['backend-url'];
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

  final serverUrl = backendUrl ?? 'http://localhost:12356';
  final orchestrator = _createOrchestrator(serverUrl: serverUrl);
  final ownsEngine = backendUrl == null;

  try {
    if (ownsEngine) {
      await orchestrator.engineLifecycle.start(engineDir: engineDir);
    }

    // Connect every channel the synthesizer needs.
    if (!await orchestrator.callGraphSource.connect()) {
      stderr.writeln('Error: Could not connect callgraph at $serverUrl');
      exit(1);
    }
    if (!await orchestrator.emulationController.connect()) {
      stderr.writeln('Error: Could not connect emulation control at $serverUrl');
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
    if (ownsEngine) {
      await orchestrator.engineLifecycle.stop();
    }
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
  final backendUrl = flags['backend-url'];
  final engineDir = flags['engine-dir'];

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

    final serverUrl = backendUrl ?? 'http://localhost:12356';
    final orchestrator = _createOrchestrator(serverUrl: serverUrl);
    final ownsEngine = backendUrl == null;

    try {
      if (ownsEngine) {
        await orchestrator.engineLifecycle.start(engineDir: engineDir);
      }

      final connected = await orchestrator.callGraphSource.connect();
      if (!connected) {
        stderr.writeln('Error: Could not connect to backend at $serverUrl');
        exit(1);
      }

      stderr.writeln('Generating call graph for $elfPath...');
      callGraph = await orchestrator.generateCallGraph(elfPath);
      stderr.writeln('Found ${callGraph.totalFunctions} functions');
    } finally {
      if (ownsEngine) {
        await orchestrator.engineLifecycle.stop();
      }
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

EmulationOrchestrator _createOrchestrator({String serverUrl = 'http://localhost:12356'}) {
  final lifecycleService = LifecycleService(serverUrl: serverUrl);
  final callgraphService = CallgraphService(serverUrl: serverUrl);
  final traceService = TraceService(serverUrl: serverUrl);
  final filteredTraceService = FilteredTraceService(serverUrl: serverUrl);

  return EmulationOrchestrator(
    engineLifecycle: RenodeEngineLifecycle(),
    emulationController: RenodeEmulationController(lifecycleService),
    callGraphSource: RenodeCallGraphSource(callgraphService),
    traceSource: RenodeTraceSource(
      traceService: traceService,
      filteredTraceService: filteredTraceService,
    ),
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
