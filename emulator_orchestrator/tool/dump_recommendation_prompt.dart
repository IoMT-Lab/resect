// Dump the prompt the RecommendationService would send to the LLM
// for the saved Aya PPG project. No Ollama call — just renders the
// composed prompt so a human can read it and verify the new
// sections (Current run metrics, Halt point, reversed decisions,
// Available hook artifacts, Retrieved context) actually land with
// real manifest data.
//
// Run with: dart tool/dump_recommendation_prompt.dart

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/services/last_run_insight_service.dart';
import 'package:emulator_orchestrator/data/services/llm_client.dart';
import 'package:emulator_orchestrator/data/services/recommendation_service.dart';

Future<void> main() async {
  final emuFile = File(
      '/home/evan/.config/call_graph_viewer/projects/Aya PPG.emu');
  final raw = jsonDecode(emuFile.readAsStringSync()) as Map<String, dynamic>;

  final manifest = SynthesisManifest.fromJson(
      raw['synthesis_result']['manifest'] as Map<String, dynamic>);
  final callGraph = CallGraph.fromSerializedJson(
      raw['call_graph'] as Map<String, dynamic>);

  const state = HookDecisionState(elfHash: 'placeholder', decisions: []);

  final artifactDbFile = File(
      '/home/evan/.config/call_graph_viewer/artifact_library/artifacts.db');
  final artifactDb = ArtifactDatabase.forTesting(
      NativeDatabase(artifactDbFile, logStatements: false));

  final client = LlmClient(host: 'localhost:11435', model: 'gemma4:e4b');
  final insightService = LastRunInsightService(llmClient: client);
  final recService = RecommendationService(
    llmClient: client,
    insightService: insightService,
    artifactDb: artifactDb,
    // ragIndex left null intentionally — exercising the catalog
    // section in isolation. The full Aya PPG flow gets RAG too.
  );

  final prompt = await recService.composePrompt(
    currentManifest: manifest,
    currentState: state,
    callGraph: callGraph,
  );

  stdout.writeln('=' * 70);
  stdout.writeln('COMPOSED PROMPT FOR AYA PPG (real saved manifest + real DB)');
  stdout.writeln('=' * 70);
  stdout.writeln(prompt);
  stdout.writeln('=' * 70);
  stdout.writeln('VERIFICATION:');
  stdout.writeln('- Total call-graph symbols: ${callGraph.totalFunctions}');
  stdout.writeln('- Executed: ${manifest.executedSymbols?.length ?? 0}');
  stdout.writeln(
      '- Coverage %: ${((manifest.executedSymbols?.length ?? 0) / callGraph.totalFunctions * 100).toStringAsFixed(1)}%');
  stdout.writeln('- Halt symbol (from manifest.failedSymbol): '
      '${manifest.failedSymbol ?? "(null — fallback to last decision)"}');
  stdout.writeln('- Last decision (would be halt fallback): '
      '${manifest.decisions.isEmpty ? "(none)" : manifest.decisions.last.symbol}');
  final all = await artifactDb.getAllArtifacts();
  stdout.writeln('- Artifact catalog rows enumerated: ${all.length}');
  stdout.writeln('- Artifact IDs in catalog: '
      '${all.map((a) => a.id).toList()}');

  await artifactDb.close();
}
