import '../models/call_graph.dart';
import '../models/hook_decision_state.dart';
import '../models/synthesis_manifest.dart';
import 'llm_client.dart';

/// Composes a recommendation prompt from a synthesis run's manifest +
/// the project's current [HookDecisionState] + a small call-graph
/// neighborhood, and streams the LLM's reply.
///
/// The advisory is meant to be 1–3 sentences (the system prompt
/// constrains it to that shape) suggesting a single concrete next
/// action — e.g. *"Synthesis stalled after clock init because
/// HAL_Delay runs the full timeout; consider adding a forced override
/// to short-circuit it."*
///
/// Cheap, on-demand, user-triggered. Reuses the shared [LlmClient]
/// configured via `LLM_OLLAMA_HOST` / `LLM_MODEL` env vars.
class LastRunInsightService {
  LastRunInsightService({required this.llmClient});

  final LlmClient llmClient;

  /// Stream the LLM's recommendation as it arrives. Callers append
  /// tokens to a buffer; the stream ends when the model emits its
  /// stop sequence or hits the predict cap. Cancellable.
  ///
  /// Picks the smallest model the user has installed on Ollama rather
  /// than reusing the hook-gen model — the advisory is ≤3 sentences,
  /// so a 1B-param model is plenty and runs an order of magnitude
  /// faster. Falls back to the constructor-configured model when
  /// `/api/tags` is unreachable or returns no usable model.
  ///
  /// Yields `('!model', name)` as a synthetic first sentinel so the
  /// caller can record which model wrote the cached insight. Real
  /// tokens follow. The sentinel uses a leading null byte so it can't
  /// collide with any model name Ollama actually emits.
  Stream<String> generate({
    required SynthesisManifest manifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
  }) async* {
    final prompt = composePrompt(
      manifest: manifest,
      currentState: currentState,
      callGraph: callGraph,
    );
    final installed = await llmClient.listModels();
    final modelName =
        installed.isEmpty ? llmClient.model : installed.first.name;
    yield '$_modelSentinelPrefix$modelName';
    yield* llmClient.generate(
      prompt,
      system: _systemPrompt,
      modelOverride: modelName,
      // Short reply — recommendation is meant to fit in a panel, not
      // a doc. Think still on so the model can reason about which
      // symbol/decision to call out.
      numPredict: 384,
    );
  }

  /// Sentinel prefix the first stream entry uses to communicate the
  /// chosen model tag back to the caller. Public so the UI can strip
  /// it before appending to the visible buffer.
  static const modelSentinelPrefix = _modelSentinelPrefix;
  static const _modelSentinelPrefix = '\x00!model:';

  /// Public for headless testing — `tool/dump_last_run_insight.dart`
  /// reuses this to print the composed prompt without invoking the LLM.
  String composePrompt({
    required SynthesisManifest manifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
  }) {
    final buf = StringBuffer();
    buf.writeln('## Run outcome');
    buf.writeln('- ELF: ${manifest.elfFileName}');
    buf.writeln('- Iterations: ${manifest.result.totalIterations}');
    buf.writeln('- Duration: ${manifest.result.durationSeconds}s');
    buf.writeln('- Success: ${manifest.result.success}');
    if (manifest.failedSymbol != null) {
      buf.writeln('- Failed at: `${manifest.failedSymbol}`');
    }
    buf.writeln();

    buf.writeln('## Decisions applied during this run');
    if (manifest.decisions.isEmpty) {
      buf.writeln('(none — firmware ran clean without any hooks)');
    } else {
      for (final d in manifest.decisions) {
        buf.writeln(
          '- iter ${d.iterationIndex}: `${d.symbol}` ← '
          '${d.decisionKind.jsonName} (${d.decisionSource}'
          '${d.fidelityAtDecision != null ? ', fid '
              '${d.fidelityAtDecision!.toStringAsFixed(2)}' : ''})',
        );
      }
    }
    buf.writeln();

    final focus = manifest.failedSymbol ??
        (manifest.decisions.isEmpty ? null : manifest.decisions.last.symbol);
    if (focus != null) {
      buf.writeln('## Call-graph neighborhood of `$focus`');
      final node = callGraph.symbols[focus];
      if (node == null) {
        buf.writeln('(symbol not present in call graph)');
      } else {
        final callers = callGraph.getCallers(focus);
        buf.writeln('- Callers: '
            '${callers.isEmpty ? '(none)' : callers.take(8).join(', ')}');
        final callees = node.calledSymbols.keys.toList();
        buf.writeln('- Calls: '
            '${callees.isEmpty ? '(none)' : callees.take(8).join(', ')}');
      }
      buf.writeln();
    }

    buf.writeln('## Current project overlay');
    final overrides = currentState.decisions
        .where((d) => d.kind == HookDecisionKind.override)
        .toList();
    final bindings = currentState.decisions
        .where((d) => d.kind == HookDecisionKind.binding)
        .toList();
    final resolved = currentState.decisions
        .where((d) => d.kind == HookDecisionKind.resolved)
        .toList();
    buf.writeln('- Forced overrides: ${overrides.length}');
    buf.writeln('- Carryover (resolved) hooks: ${resolved.length}');
    buf.writeln('- Fidelity-scored bindings: ${bindings.length}');
    buf.writeln();

    // Drift signal: decisions present in the manifest whose
    // bound-artifact differs from the current overlay (e.g., the user
    // removed an override since the run). LLM is told to weigh this
    // when deciding what to recommend.
    final manifestSymbols = {for (final d in manifest.decisions) d.symbol};
    final currentSymbols = {for (final d in currentState.decisions) d.symbol};
    final removedSinceRun =
        manifestSymbols.difference(currentSymbols).toList()..sort();
    final addedSinceRun =
        currentSymbols.difference(manifestSymbols).toList()..sort();
    if (removedSinceRun.isNotEmpty || addedSinceRun.isNotEmpty) {
      buf.writeln('## Configuration drift since this run');
      if (removedSinceRun.isNotEmpty) {
        buf.writeln(
            '- Hooks removed from project: '
            '${removedSinceRun.take(8).join(', ')}'
            '${removedSinceRun.length > 8 ? ', …' : ''}');
      }
      if (addedSinceRun.isNotEmpty) {
        buf.writeln(
            '- Hooks added to project: '
            '${addedSinceRun.take(8).join(', ')}'
            '${addedSinceRun.length > 8 ? ', …' : ''}');
      }
      buf.writeln();
    }

    buf.writeln('## Your task');
    buf.writeln(
        'Given the above, suggest ONE concrete action the user could '
        'take to improve the next synthesis run. 1–3 sentences. No '
        'code. No headers. Plain prose only.');
    return buf.toString();
  }

  static const _systemPrompt = '''
You are a firmware-emulation assistant inside Resect, a desktop tool
that iteratively replaces hardware-dependent functions in firmware
with Python hooks so the firmware can run in Renode. After each
synthesis run, you give the user one concrete piece of advice about
what to try next.

Rules:
- Output 1–3 sentences. Nothing more.
- No markdown headers, no code blocks, no bullet lists.
- Recommend exactly ONE next action. Be specific (name the symbol,
  the override, or the config knob).
- If the run succeeded with high fidelity, you can confirm that and
  suggest a stretch goal (e.g. lower the iteration cap, virtualize
  comms, etc).
- If the run failed, explain in one phrase why, then suggest the
  fix.
- Do not restate the input. Don't say "Based on the manifest…".
  Get to the recommendation.
''';
}
