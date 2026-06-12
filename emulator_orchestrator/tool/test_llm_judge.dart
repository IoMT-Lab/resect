// Smoke test for LlmJudge: presents a clear-cut substitute-vs-
// replication choice and asserts the judge picks the substitute.
//
// Slow — does two Ollama calls (~60-120 s each on CPU). Skipped
// from the always-on test loop; run when the judge prompt or
// model changes.
//
// Run with:
//   cd emulator_orchestrator
//   dart run tool/test_llm_judge.dart

import 'dart:io';

import 'package:emulator_orchestrator/config/env_config.dart';
import 'package:emulator_orchestrator/data/services/llm_client.dart';
import 'package:emulator_orchestrator/data/services/llm_judge.dart';

// The original function's decompilation. A clock-enable function
// that pokes a peripheral register — exactly the case where the
// substitute should NOT replicate.
const String _decompilation = r'''
void LL_APB0_GRP1_EnableClock(uint32_t Periphs)
{
  _DAT_48400054 = Periphs | _DAT_48400054;
  return;
}
''';

// Candidate A: clean substitute. No peripheral I/O. Just returns.
const String _candidate = r'''
import set_return_value
setReturnValue(cpu, 0)
''';

// Baseline: replication attempt — reads + writes the peripheral
// register the original touches. In real emulation this would
// generate unhandled access if RCC isn't modelled. The judge
// should clearly prefer the substitute over this.
const String _baseline = r'''
import set_return_value
periphs = int(cpu.GetRegister(0).RawValue)
current = int(cpu.Bus.ReadDoubleWord(0x48400054))
cpu.Bus.WriteDoubleWord(0x48400054, current | periphs)
setReturnValue(cpu, 0)
''';

Future<void> main() async {
  stdout.writeln('=== test_llm_judge ===');
  final cfg = EnvConfig.load();
  final host = (cfg.get('LLM_OLLAMA_HOST') ?? '').trim();
  final model = (cfg.get('LLM_MODEL') ?? '').trim();
  final client = LlmClient(
    host: host.isEmpty ? 'localhost:11434' : host,
    model: model.isEmpty ? 'gemma4:12b' : model,
  );
  final judge = LlmJudge(client: client);

  stdout.writeln('model: ${client.model}');
  stdout.writeln('candidate (clean substitute, ${_candidate.split("\n").where((l) => l.trim().isNotEmpty).length} lines):');
  stdout.writeln('  ${_candidate.trim().replaceAll("\n", "\n  ")}');
  stdout.writeln('baseline (replication, ${_baseline.split("\n").where((l) => l.trim().isNotEmpty).length} lines):');
  stdout.writeln('  ${_baseline.trim().replaceAll("\n", "\n  ")}');
  stdout.writeln('');

  final start = DateTime.now();
  final result = await judge.evaluate(
    candidateHook: _candidate,
    baselineHook: _baseline,
    functionName: 'LL_APB0_GRP1_EnableClock',
    decompilation: _decompilation,
  );
  final elapsed = DateTime.now().difference(start);
  stdout.writeln('elapsed: ${elapsed.inSeconds}s');
  stdout.writeln('model used: ${result.modelUsed}');
  stdout.writeln('score:      ${result.score.toStringAsFixed(3)}');
  stdout.writeln('reason:     ${result.justification}');
  stdout.writeln('');
  stdout.writeln('--- raw responses ---');
  stdout.writeln('Order 1 (candidate=A):');
  stdout.writeln('  ${result.callA.replaceAll("\n", "\n  ")}');
  stdout.writeln('Order 2 (candidate=B):');
  stdout.writeln('  ${result.callB.replaceAll("\n", "\n  ")}');

  client.close();

  // Assertion: candidate (substitute) should win against baseline
  // (replication). Score above 0.6 = candidate clearly preferred
  // (some confidence). Below 0.4 = the model preferred the
  // replication, which would mean our rubric isn't landing.
  if (result.score < 0.6) {
    stderr.writeln('');
    stderr.writeln('!!! FAIL: judge score ${result.score} < 0.6 — the model '
        'did not clearly prefer the substitute over the replication. '
        'Either the rubric is too weak or the model is too small to '
        'distinguish the cases.');
    exit(1);
  }
  stdout.writeln('');
  stdout.writeln('=== PASS: judge picked the substitute (score=${result.score.toStringAsFixed(3)}) ===');
}
