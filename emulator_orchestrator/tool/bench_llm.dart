// Headless A/B bench for the LLM-utilization overhaul. Runs the real
// recommendation call against the saved Aya PPG project + live Ollama
// under the OLD policy (think-on / temp-1 / no schema — what produced
// the 7600-chunk spirals) vs the NEW policy (think-off / temp-0 /
// schema-constrained), and prints wall time, thinking chunks,
// response tokens, done_reason, and parse outcome for each.
//
// This is the plan's primary verification: no Resect UI involvement.
//
//   dart tool/bench_llm.dart --mode job2
//
// The same prompt (built by RecommendationService.composePrompt) is
// sent both ways; only the sampling/think/format policy differs, so
// the difference in wall time + thinking behavior is attributable to
// the policy change.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:emulator_orchestrator/data/database/artifact_database.dart';
import 'package:emulator_orchestrator/data/models/call_graph.dart';
import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/services/analysis/coverage_frontier.dart';
import 'package:emulator_orchestrator/services/llm/last_run_insight_service.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';

const _host = 'localhost:11435';
const _model = 'gemma4:12b';
const _emuPath = '/home/evan/.config/call_graph_viewer/projects/Aya PPG.emu';
const _dbPath =
    '/home/evan/.config/call_graph_viewer/artifact_library/artifacts.db';

class _RunStats {
  int thinkingChunks = 0;
  int responseChunks = 0;
  String doneReason = '(none)';
  int responseTokens = 0;
  final buf = StringBuffer();
  late Duration wall;
}

Future<_RunStats> _run({
  required LlmClient client,
  required String prompt,
  required String system,
  required bool think,
  required double temperature,
  required int numPredict,
  Map<String, Object?>? format,
}) async {
  final s = _RunStats();
  final sw = Stopwatch()..start();
  await for (final ev in client.generateEvents(
    prompt,
    system: system,
    think: think,
    temperature: temperature,
    numPredict: numPredict,
    format: format,
  )) {
    switch (ev) {
      case LlmThinkingChunk():
        s.thinkingChunks++;
      case LlmResponseChunk(:final text):
        s.responseChunks++;
        s.buf.write(text);
      case LlmStreamDone(:final doneReason, :final responseTokens):
        s.doneReason = doneReason;
        s.responseTokens = responseTokens;
    }
  }
  sw.stop();
  s.wall = sw.elapsed;
  return s;
}

String _parseOutcome(String raw) {
  final start = raw.indexOf('{');
  if (start < 0) return raw.trim().isEmpty ? 'EMPTY' : 'NO_JSON';
  try {
    jsonDecode(raw.substring(start, raw.lastIndexOf('}') + 1));
    return 'VALID_JSON';
  } catch (_) {
    return 'MALFORMED_JSON';
  }
}

void _report(String label, _RunStats s) {
  stdout.writeln('--- $label ---');
  stdout.writeln('  wall time:       ${s.wall.inMilliseconds} ms');
  stdout.writeln('  thinking chunks: ${s.thinkingChunks}');
  stdout.writeln('  response tokens: ${s.responseTokens}');
  stdout.writeln('  done_reason:     ${s.doneReason}');
  stdout.writeln('  parse outcome:   ${_parseOutcome(s.buf.toString())}');
  final preview = s.buf.toString().replaceAll('\n', ' ');
  stdout.writeln('  response[:200]:  '
      '${preview.substring(0, preview.length.clamp(0, 200))}');
}

Future<void> main(List<String> args) async {
  final raw = jsonDecode(File(_emuPath).readAsStringSync())
      as Map<String, dynamic>;
  final manifest = SynthesisManifest.fromJson(
      raw['synthesis_result']['manifest'] as Map<String, dynamic>);
  final callGraph =
      CallGraph.fromSerializedJson(raw['call_graph'] as Map<String, dynamic>);
  const state = HookDecisionState(elfHash: 'placeholder', decisions: []);

  final db = ArtifactDatabase.forTesting(
      NativeDatabase(File(_dbPath), logStatements: false));
  final client = LlmClient(host: _host, model: _model);
  final svc = RecommendationService(
    llmClient: client,
    insightService: LastRunInsightService(llmClient: client),
    artifactDb: db,
  );

  final executed = manifest.executedSymbols?.toSet() ?? <String>{};
  final frontier =
      computeFrontier(executedSymbols: executed, callGraph: callGraph);
  stdout.writeln('Frontier (top ${frontier.length}): '
      '${frontier.map((e) => "${e.symbol}(${e.unexecutedCalleeCount})").join(", ")}');

  final prompt = await svc.composePrompt(
    currentManifest: manifest,
    currentState: state,
    callGraph: callGraph,
    mode: RecommendationMode.job2Coverage,
    frontier: frontier,
  );
  final schema = await svc.buildRecommendationSchema(
    currentManifest: manifest,
    currentState: state,
    callGraph: callGraph,
    mode: RecommendationMode.job2Coverage,
    frontier: frontier,
  );

  const sys = 'You are a firmware-emulation assistant. Respond with a '
      'single JSON object.';

  stdout.writeln('\n=== OLD policy: think-on / temp-1 / numPredict 8192 / '
      'no schema ===');
  final old = await _run(
    client: client,
    prompt: prompt,
    system: sys,
    think: true,
    temperature: 1.0,
    numPredict: 8192,
  );
  _report('OLD', old);

  stdout.writeln('\n=== NEW policy: think-off / temp-0 / numPredict 1024 / '
      'schema ===');
  final neu = await _run(
    client: client,
    prompt: prompt,
    system: sys,
    think: false,
    temperature: 0.0,
    numPredict: 1024,
    format: schema,
  );
  _report('NEW', neu);

  stdout.writeln('\n=== VERDICT ===');
  stdout.writeln('thinking chunks:  ${old.thinkingChunks} → '
      '${neu.thinkingChunks}');
  stdout.writeln('wall time:        ${old.wall.inMilliseconds}ms → '
      '${neu.wall.inMilliseconds}ms');
  stdout.writeln('parse outcome:    ${_parseOutcome(old.buf.toString())} → '
      '${_parseOutcome(neu.buf.toString())}');

  await db.close();
  client.close();
}
