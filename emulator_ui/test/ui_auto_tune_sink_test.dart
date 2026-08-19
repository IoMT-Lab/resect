import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/data/models/hook_binding.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:emulator_orchestrator/data/models/synthesizer_result.dart';
import 'package:emulator_orchestrator/orchestrator/auto_tune_engine.dart';
import 'package:emulator_ui/presentation/screens/synthesize/llm_synthesis_orchestrator.dart';
import 'package:emulator_ui/presentation/screens/synthesize/ui_auto_tune_sink.dart';
import 'package:emulator_ui/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _metrics = ManifestMetrics(
  overallFidelity: 0.5,
  coverageFidelity: 0.5,
  subgraphFidelity: null,
  intactCount: 1,
  degradedCount: 0,
  hookedCount: 1,
);

SynthesizerResult _result({bool success = true, String? failedSymbol}) =>
    SynthesizerResult(
      success: success,
      totalIterations: 1,
      resolvedHooks: const {},
      totalDuration: const Duration(seconds: 1),
      failedSymbol: failedSymbol,
    );

RoundSnapshot _snapshot(int round, {List<String> executed = const ['A']}) =>
    RoundSnapshot(
      snapshotVersion: RoundSnapshot.currentVersion,
      round: round,
      synthesizerRunId: 'r$round',
      createdAt: DateTime.utc(2026),
      hookOverrides: const {'sym': 4},
      hookOverrideScopes: const {'sym': 'HSE'},
      hookPreferences: const {'pref': 9},
      hookBindings: {
        'bound': HookBinding(
            artifactId: 7,
            fidelity: 0.5,
            provenance: 'test',
            createdAt: DateTime.utc(2026)),
      },
      iterationCap: 42,
      metrics: _metrics,
      executedSymbols: executed,
      manifestRef: const SynthesisManifestRef(runId: 'r0'),
    );

AutoTuneRoundReport _report(int round,
        {List<String> executed = const ['A'],
        bool success = true,
        String? failedSymbol}) =>
    AutoTuneRoundReport(
      round: round,
      result: _result(success: success, failedSymbol: failedSymbol),
      metrics: _metrics,
      snapshot: _snapshot(round, executed: executed),
    );

void main() {
  late ProviderContainer container;
  late List<AutoTuneState> states;
  late List<AutoTuneRoundLine> lines;
  late UiAutoTuneSink sink;

  setUp(() {
    container = ProviderContainer();
    states = [];
    lines = [];
    sink = UiAutoTuneSink(
      container: container,
      emitState: states.add,
      onRoundLine: lines.add,
    );
  });
  tearDown(() => container.dispose());

  test('phase mapping covers all four engine phases', () {
    sink.phase(AutoTunePhase.baseline);
    sink.phase(AutoTunePhase.llmGenerating, round: 1);
    sink.phase(AutoTunePhase.generatingHook, round: 2, symbol: 'foo');
    sink.phase(AutoTunePhase.synthesizing, round: 2);
    expect(states[0], isA<AutoTuneRunningBaseline>());
    expect((states[1] as AutoTuneLlmGenerating).round, 1);
    expect((states[2] as AutoTuneGeneratingHook).symbol, 'foo');
    expect((states[3] as AutoTuneSynthesizing).round, 2);
  });

  test('token/thinking deltas accumulate and route by last phase', () {
    sink.phase(AutoTunePhase.llmGenerating, round: 1);
    sink.token('a');
    sink.token('b');
    sink.thinking('t');
    final llm = states.last as AutoTuneLlmGenerating;
    expect(llm.responseText, 'ab');
    expect(llm.thinkingText, 't');

    // A new phase resets the buffers; hook-gen tokens route to the
    // hook-gen state.
    sink.phase(AutoTunePhase.generatingHook, round: 2, symbol: 'foo');
    sink.token('x');
    final hook = states.last as AutoTuneGeneratingHook;
    expect(hook.responseText, 'x');
    expect(hook.thinkingText, isEmpty);
  });

  test('round() persists the snapshot, mirrors overlays, emits a line', () {
    container.read(currentEmulatorProvider.notifier).state =
        Emulator.create(name: 't');

    sink.round(_report(0, executed: ['A', 'B']));

    final emulator = container.read(currentEmulatorProvider)!;
    expect(emulator.roundSnapshots, hasLength(1));
    expect(emulator.roundSnapshots.single.round, 0);
    expect(container.read(hookOverridesProvider), {'sym': 4});
    expect(container.read(hookOverrideScopesProvider), {'sym': 'HSE'});
    expect(container.read(hookPreferencesProvider), {'pref': 9});
    expect(container.read(hookBindingsProvider).keys, ['bound']);
    expect(container.read(synthesisMaxIterationsProvider), 42);
    expect(container.read(emulatorDirtyProvider), isTrue);

    expect(lines.single.round, 0);
    expect(lines.single.outcome, 'success');
    expect(lines.single.executedCount, 2);
    expect(lines.single.executedDelta, 0);
  });

  test('round lines carry executed deltas and failure outcomes', () {
    container.read(currentEmulatorProvider.notifier).state =
        Emulator.create(name: 't');
    sink.round(_report(0, executed: ['A']));
    sink.round(_report(1,
        executed: ['A', 'B', 'C'], success: false, failedSymbol: 'foo'));
    expect(lines[1].outcome, 'failed @foo');
    expect(lines[1].executedCount, 3);
    expect(lines[1].executedDelta, 2);
  });

  test('snapshot cap on the project is honored', () {
    container.read(currentEmulatorProvider.notifier).state =
        Emulator.create(name: 't').copyWith(roundSnapshotCap: 1);
    sink.round(_report(0));
    sink.round(_report(1));
    final emulator = container.read(currentEmulatorProvider)!;
    expect(emulator.roundSnapshots, hasLength(1));
    expect(emulator.roundSnapshots.single.round, 1);
  });

  test('finished maps to AutoTuneFinished with the engine reason', () {
    sink.finished(AutoTuneStopReason.noCoverageProgress,
        finalRound: 3, errorMessage: null);
    final done = states.single as AutoTuneFinished;
    expect(done.reason, AutoTuneFinishReason.noCoverageProgress);
    expect(done.finalRound, 3);
  });
}
