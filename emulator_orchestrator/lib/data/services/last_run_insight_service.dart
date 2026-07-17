import '../models/call_graph.dart';
import '../models/hook_decision_state.dart';
import '../models/synthesis_manifest.dart';
import 'coverage_frontier.dart';
import 'llm_client.dart';
import 'llm_profiles.dart';

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

  /// Stream the advisor's 1–3 sentence prose recommendation as it
  /// arrives, as discriminated [LlmStreamEvent]s so the Last Run
  /// card can surface the reasoning trace alongside the final
  /// advisory. The chosen model tag is reported via
  /// [onModelSelected].
  ///
  /// Runs the `advisor` profile (think-off / temp-0 / 384 tokens) on
  /// the smallest installed model — the advisory is ≤3 sentences, so
  /// a 1B-param model is plenty and runs an order of magnitude
  /// faster. Falls back to the constructor-configured model when
  /// `/api/tags` is unreachable.
  Stream<LlmStreamEvent> generateEvents({
    required SynthesisManifest manifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    void Function(String modelTag)? onModelSelected,
  }) async* {
    final prompt = composePrompt(
      manifest: manifest,
      currentState: currentState,
      callGraph: callGraph,
    );
    const p = LlmProfiles.advisor;
    final installed = await llmClient.listModels();
    final modelName = (p.modelPolicy == LlmModelPolicy.smallestInstalled &&
            installed.isNotEmpty)
        ? installed.first.name
        : llmClient.model;
    onModelSelected?.call(modelName);
    yield* llmClient.generateEvents(
      prompt,
      system: _systemPrompt,
      modelOverride: modelName,
      think: p.think,
      temperature: p.temperature,
      topP: p.topP,
      topK: p.topK,
      numCtx: p.numCtx,
      numPredict: p.numPredict,
    );
  }

  /// Resolve the run's halt symbol — the function the firmware was
  /// last paused at — using the priority cascade:
  ///   1. `manifest.failedSymbol` — set only on `result.success == false`
  ///   2. `manifest.lastPauseSymbol` — last unhandled-access pause
  ///      observed during the run, set regardless of success
  ///   3. The chronologically-last decision the synthesizer made,
  ///      using `iterationIndex` order (NOT the manifest's
  ///      alphabetical storage order — that would return whatever
  ///      symbol sorts last by name, e.g. `SystemInit`).
  /// Returns null only when none of the three is available
  /// (empty-decisions, never-paused — typically a fully clean
  /// baseline run that has nothing to recommend).
  ///
  /// Both this service and [RecommendationService] need this
  /// cascade — sharing one helper keeps them in lockstep.
  static String? computeHaltSymbol(SynthesisManifest manifest) {
    final fallback = manifest.decisions.isEmpty
        ? null
        : _decisionsChronological(manifest).last.symbol;
    return manifest.failedSymbol ?? manifest.lastPauseSymbol ?? fallback;
  }

  /// Context sections only — no task framing. Shared by this
  /// service's own [composePrompt] AND by [RecommendationService], so
  /// the advisor's prose-task footer never leaks into the JSON
  /// recommendation prompt (that dual-task contradiction was a
  /// recursion driver). When [frontier] is non-empty a
  /// "## Coverage frontier" section is appended — Job 2's proactive
  /// coverage signal; callers that don't have/need it pass nothing
  /// and the section is omitted (advisor output unchanged).
  String composeContext({
    required SynthesisManifest manifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
    List<FrontierEntry> frontier = const [],
  }) {
    final haltSymbol = computeHaltSymbol(manifest);
    final buf = StringBuffer();
    buf.writeln('## Run outcome');
    buf.writeln('- ELF: ${manifest.elfFileName}');
    buf.writeln('- Iterations: ${manifest.result.totalIterations}');
    buf.writeln('- Duration: ${manifest.result.durationSeconds}s');
    // Relabel `Success` — the synthesizer's success flag means
    // "no unhandled access remained at end of run", which is
    // satisfied even when the synthesizer just bound a placeholder
    // hook at the halt symbol and the firmware barely executed.
    // The legacy "Success: true" label caused the recommendation
    // LLM to conclude "nothing's wrong" on runs with 2% coverage.
    // Pair it with the Halt point line below + the Current run
    // metrics block so the model sees the full picture.
    buf.writeln(
        '- Synthesizer completed without throwing: '
        '${manifest.result.success}');
    if (haltSymbol != null) {
      final source = manifest.failedSymbol != null
          ? 'unhandled-access pause (run failed)'
          : manifest.lastPauseSymbol != null
              ? 'last unhandled-access pause (run completed)'
              : 'last decision (no pause recorded)';
      buf.writeln('- Halt point: `$haltSymbol` ($source)');
    }
    buf.writeln();

    // Current run metrics. Sourced from `manifest.metrics` (v2+
    // field), which `RecommendationService` and the advisor card
    // both receive. The coverage percentage — symbols actually
    // reached divided by the firmware's total call-graph size —
    // is the signal that does the heavy lifting here: tells the
    // LLM at a glance whether the firmware ran broadly or barely
    // executed, without anyone instructing it to think that way.
    final metrics = manifest.metrics;
    final executed = manifest.executedSymbols;
    if (metrics != null || (executed != null && callGraph.totalFunctions > 0)) {
      buf.writeln('## Current run metrics');
      if (metrics != null) {
        buf.writeln(
            '- Overall fidelity: ${metrics.overallFidelity.toStringAsFixed(3)} '
            '(averaged across the entire call graph)');
        if (metrics.coverageFidelity != null) {
          buf.writeln(
              '- Coverage fidelity: '
              '${metrics.coverageFidelity!.toStringAsFixed(3)} '
              '(averaged over only executed symbols)');
        }
      }
      if (executed != null && callGraph.totalFunctions > 0) {
        final pct = (executed.length / callGraph.totalFunctions) * 100.0;
        buf.writeln(
            '- Symbols executed: ${executed.length} of '
            '${callGraph.totalFunctions} (${pct.toStringAsFixed(1)}%)');
      }
      if (metrics != null) {
        buf.writeln(
            '- Symbols hooked: ${metrics.hookedCount} '
            '(intact ${metrics.intactCount}, '
            'degraded ${metrics.degradedCount})');
      }
      buf.writeln();
    }

    buf.writeln('## Decisions applied during this run');
    if (manifest.decisions.isEmpty) {
      buf.writeln('(none — firmware ran clean without any hooks)');
    } else {
      // `manifest.decisions` comes out of `buildManifest`
      // alphabetically sorted by symbol (deterministic on-disk
      // order for snapshot/diff stability). Reorder
      // chronologically and reverse so the latest iteration sits
      // on top — without editorialization markers. The LLM should
      // be reading the Halt point line + the task framing for
      // focus, not "(most recent)" tags on a context list (which
      // it kept treating as authoritative focus indicators).
      //
      // Comms pre-seeds are summarized as a count, not rendered
      // row-by-row: a comms-virtualized firmware adds ~46 identical
      // rows the model is explicitly told to keep hands off, and on
      // a CPU-bound host every prompt token is round latency.
      final commsCount = manifest.decisions
          .where((d) => d.decisionKind == ManifestDecisionKind.comms)
          .length;
      if (commsCount > 0) {
        buf.writeln('($commsCount comms-virtualized pre-seeds omitted '
            '— covered as a bus, hands off)');
      }
      final orderedDecisions = _decisionsChronological(manifest)
          .where((d) => d.decisionKind != ManifestDecisionKind.comms)
          .toList();
      final decisions = orderedDecisions.reversed.toList();
      for (final d in decisions) {
        // `applied=#N` lets the LLM cross-reference the catalog
        // enumeration (the `## Available hook artifacts` block) to
        // see WHICH artifact is currently bound to each symbol —
        // e.g. is `LL_RCC_HSE_IsReady`'s override Return 0 (broken)
        // or Return 1 (correct). Without this, the model knew the
        // override existed but not its semantic value, and the CoT
        // explicitly flagged "I don't see the value it was set to."
        final appliedId = d.appliedHook.artifactId;
        final applied = appliedId != null ? ' applied=#$appliedId' : '';
        buf.writeln(
          '- iter ${d.iterationIndex}: `${d.symbol}` ← '
          '${d.decisionKind.jsonName} (${d.decisionSource}'
          '${d.fidelityAtDecision != null ? ', fid '
              '${d.fidelityAtDecision!.toStringAsFixed(2)}' : ''})'
          '$applied',
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
    final comms = currentState.decisions
        .where((d) => d.kind == HookDecisionKind.comms)
        .toList();
    buf.writeln('- Totals: ${overrides.length} forced overrides, '
        '${bindings.length} fidelity-scored bindings, '
        '${resolved.length} carryover hooks, '
        '${comms.length} comms-virtualized symbols');

    // Per-symbol overlay state for the region the model reasons
    // about — halt-symbol neighborhood + coverage frontier. Counts
    // alone hid the single most important fact from the model:
    // WHICH artifact each nearby symbol already resolves to. Without
    // it the model re-recommended overrides that were already in
    // effect, round after round. The binding caveat matters just as
    // much: a binding applies only when the symbol faults, and a
    // silent busy-wait never faults — so classifier knowledge sits
    // inert until promoted to a forced override.
    final region = <String>{};
    if (haltSymbol != null) {
      region.add(haltSymbol);
      final node = callGraph.symbols[haltSymbol];
      if (node != null) {
        region
          ..addAll(node.calledSymbols.keys.take(8))
          ..addAll(callGraph.getCallers(haltSymbol).take(8));
      }
    }
    for (final e in frontier) {
      region
        ..add(e.symbol)
        ..addAll(e.unexecutedCallees);
    }
    final regionDecisions = [
      for (final d in currentState.decisions)
        if (region.contains(d.symbol)) d,
    ];
    // Symbols the run's manifest shows a hook was actually applied to,
    // with the applied artifact id. This is what separates "bound but
    // inert" (worth promoting) from "already in effect" (re-forcing it
    // changes nothing) — without it the model re-recommended in-effect
    // hooks off the "applies only on fault" caveat alone.
    final appliedThisRun = <String, int?>{
      for (final d in manifest.decisions) d.symbol: d.appliedHook.artifactId,
    };
    if (regionDecisions.isNotEmpty) {
      buf.writeln(
          'Per-symbol state near the halt point / frontier. NOTE: a '
          '"binding" is applied only when the symbol causes an '
          'unhandled access; a silent busy-wait never does, so a '
          'bound hook takes effect there only if promoted to a '
          'forced override. Entries marked ALREADY IN EFFECT were '
          'applied during this run — re-forcing the same artifact '
          'changes nothing.');
      for (final d in regionDecisions.take(_kOverlayLineCap)) {
        buf.writeln(_overlayLine(d, appliedThisRun));
      }
      if (regionDecisions.length > _kOverlayLineCap) {
        buf.writeln(
            '(+${regionDecisions.length - _kOverlayLineCap} more '
            'overlays in this region)');
      }
    }
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

    // Coverage frontier (Job 2 signal) — the executed functions
    // sitting on the boundary where progress stopped expanding. Only
    // emitted when the caller supplies it; the advisor's own
    // composePrompt passes none, so its output is unchanged. Each
    // callee is annotated with what the classifier already knows
    // about it (ready-flag / clock getter / counter / void writes /
    // comms-covered) so the model can tell a forceable status poll
    // from a setter where forcing a return value is meaningless.
    if (frontier.isNotEmpty) {
      buf.writeln('## Coverage frontier');
      buf.writeln('Executed functions whose callees were never reached — '
          'the boundary where forward progress stopped. A silent '
          'blocker is likely at or below one of these:');
      for (final e in frontier) {
        buf.writeln('- `${e.symbol}` → ${e.unexecutedCalleeCount} '
            'unreached callee(s):');
        for (final callee in e.unexecutedCallees.take(6)) {
          final note = _frontierAnnotation(
              currentState.forSymbol(callee), appliedThisRun);
          buf.writeln('  - $callee${note != null ? ' — $note' : ''}');
        }
        if (e.unexecutedCallees.length > 6) {
          buf.writeln('  (+${e.unexecutedCallees.length - 6} more)');
        }
      }
      buf.writeln();
    }

    return buf.toString();
  }

  /// Cap on per-symbol overlay lines rendered in the "Current project
  /// overlay" region block — keeps a dense frontier from flooding the
  /// prompt.
  static const _kOverlayLineCap = 30;

  /// One per-symbol overlay line for the region block. Format is
  /// stable so tests can assert on it: symbol ← #id (kind, detail).
  /// [appliedThisRun] maps symbol → applied artifact id from the run's
  /// manifest; a binding whose artifact matches was actually applied
  /// (the symbol faulted) and is flagged ALREADY IN EFFECT so the
  /// model doesn't re-force it.
  static String _overlayLine(
      HookDecision d, Map<String, int?> appliedThisRun) {
    final pref = d.preferredArtifactId != null
        ? ', pref #${d.preferredArtifactId}'
        : '';
    switch (d.kind) {
      case HookDecisionKind.override:
        return '- `${d.symbol}` ← #${d.artifactId} (forced override$pref)';
      case HookDecisionKind.comms:
        final role = d.role != null ? ' ${d.role}' : '';
        return '- `${d.symbol}` (comms:${d.protocol}$role — virtualized '
            'as a bus$pref)';
      case HookDecisionKind.resolved:
        return '- `${d.symbol}` (carryover hook from a previous run$pref)';
      case HookDecisionKind.binding:
        final status = _bindingStatus(d, appliedThisRun);
        return '- `${d.symbol}` ← #${d.artifactId} (binding, '
            '${d.provenance ?? 'unknown'} — $status$pref)';
      case HookDecisionKind.none:
        return '- `${d.symbol}` (preference only: '
            '#${d.preferredArtifactId})';
    }
  }

  /// Whether a binding was actually applied during the run.
  static String _bindingStatus(
      HookDecision d, Map<String, int?> appliedThisRun) {
    final applied = appliedThisRun[d.symbol];
    return applied != null && applied == d.artifactId
        ? 'ALREADY IN EFFECT this run'
        : 'NOT applied this run — takes effect only on fault or if '
            'promoted to a forced override';
  }

  /// Classifier-knowledge annotation for a frontier callee, derived
  /// from the symbol's overlay decision. Null when the symbol has no
  /// overlay (unclassified — usually no decompilation was available).
  ///
  /// The rule-name → semantics mapping mirrors [HookClassifier]'s
  /// rules; provenance strings are written by HookBindingSeeder as
  /// `classifier:<ruleName>`. Bindings are suffixed with whether they
  /// were ALREADY applied this run (re-forcing changes nothing) or are
  /// inert (promoting them is the move).
  static String? _frontierAnnotation(
      HookDecision? d, Map<String, int?> appliedThisRun) {
    if (d == null) return null;
    switch (d.kind) {
      case HookDecisionKind.comms:
        return 'comms:${d.protocol} — virtualized, do not force '
            'individually';
      case HookDecisionKind.override:
        return 'already forced → #${d.artifactId}';
      case HookDecisionKind.resolved:
        return 'carryover hook from a previous run';
      case HookDecisionKind.binding:
        final p = d.provenance ?? '';
        final id = d.artifactId;
        final applied = appliedThisRun[d.symbol];
        final status = applied != null && applied == id
            ? 'ALREADY IN EFFECT this run — re-forcing #$id changes '
                'nothing'
            : 'bound but NOT applied this run — promote to a forced '
                'override to take effect';
        if (p.contains('rule-5')) {
          return 'ready/busy flag → #$id; $status';
        }
        if (p.contains('rule-4')) {
          return 'clock getter → #$id (64 MHz); $status';
        }
        if (p.contains('rule-3')) {
          return 'counter → #$id (increment); $status';
        }
        if (p.contains('rule-7')) {
          return 'HAL polling loop → #$id (HAL_OK); $status';
        }
        if (p.contains('rule-6')) {
          return 'void register writes — forcing a return value '
              "won't help";
        }
        return 'bound → #$id ($p); $status';
      case HookDecisionKind.none:
        return null;
    }
  }

  /// Advisor prompt = [composeContext] + the 1–3-sentence prose task
  /// footer. Kept as the advisor's public entry point (and the
  /// headless dump tool's) so existing callers/tests are unaffected
  /// by the context/task split.
  String composePrompt({
    required SynthesisManifest manifest,
    required HookDecisionState currentState,
    required CallGraph callGraph,
  }) {
    final haltSymbol = computeHaltSymbol(manifest);
    final buf = StringBuffer();
    buf.write(composeContext(
      manifest: manifest,
      currentState: currentState,
      callGraph: callGraph,
    ));
    buf.writeln('## Your task');
    if (haltSymbol != null) {
      // State the question, not just "do something." Naming the
      // halt symbol here — at the bottom, in the task framing
      // itself — is what redirects the model's attention away
      // from loud classifier tags in the decisions block above.
      // The halt symbol is the SIGNAL of where the firmware is
      // stuck; the goal is improving coverage/fidelity, not
      // necessarily targeting that exact symbol.
      buf.writeln(
          'The synthesizer stopped with the firmware paused at '
          '`$haltSymbol`. Based on where it stopped — together with '
          'the current run metrics and the decisions list above — '
          'suggest a small change to the overlay that would improve '
          'coverage and fidelity on the next run. 1–3 sentences. '
          'Plain prose only — no code, no headers.');
    } else {
      buf.writeln(
          'Given the above, suggest ONE concrete action the user '
          'could take to improve the next synthesis run. 1–3 '
          'sentences. No code. No headers. Plain prose only.');
    }
    return buf.toString();
  }

  /// Order [manifest.decisions] chronologically — pre-seeded
  /// decisions (`iterationIndex == null`: forced overrides, comms,
  /// warm-start) come first, in their stable alphabetical order;
  /// iterated decisions follow by ascending `iterationIndex`. Used
  /// by the prompt composer so "(most recent)" lands on the actual
  /// last iteration, not on whichever symbol happens to sort last
  /// by name in the manifest's storage order.
  static List<ManifestDecision> _decisionsChronological(
      SynthesisManifest manifest) {
    return manifest.decisions.toList()
      ..sort((a, b) {
        final ai = a.iterationIndex;
        final bi = b.iterationIndex;
        if (ai == null && bi == null) return a.symbol.compareTo(b.symbol);
        if (ai == null) return -1;
        if (bi == null) return 1;
        return ai.compareTo(bi);
      });
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
- The goal is to improve the run's coverage and fidelity metrics.
  The halt symbol named in "## Your task" is a SIGNAL of where the
  firmware is currently stuck — use it as a starting point for
  reasoning, but don't fixate on it. A classifier tag like
  `iteration_fallback` on a symbol in the "## Decisions applied"
  block does NOT make that symbol the right focus by itself.
- A run that "completed without throwing" can still have low
  coverage — check the Current run metrics block (executed-symbols
  percentage, coverage fidelity) before deciding whether the run
  actually went well.
- If coverage and fidelity are both high, you can confirm that and
  suggest a stretch goal (e.g. lower the iteration cap, virtualize
  comms, etc).
- If after one pass through the context no defensible single
  recommendation comes to mind (metrics already plateau'd, the
  halt symbol's behavior isn't expressible by templates, etc.),
  it is more useful to say "templates exhausted; this symbol
  likely needs a custom hook authored from the Hook Database
  dialog" than to loop in self-doubt.
- Do not restate the input. Don't say "Based on the manifest…".
  Get to the recommendation.
''';
}
