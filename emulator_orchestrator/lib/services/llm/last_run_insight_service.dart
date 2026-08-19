import '../../data/models/call_graph.dart';
import '../../data/models/hook_decision_state.dart';
import '../../data/models/synthesis_manifest.dart';
import '../analysis/coverage_frontier.dart';
import '../analysis/fidelity_calculator.dart';
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
    // Prefer, in order: a genuine unhooked fault (run failed); then
    // where execution ACTUALLY got to (finalExecutionSymbol) — this
    // beats lastPauseSymbol, which is a fault the firmware was already
    // hooked PAST and ran on from (stale); then that stale pause; and
    // only then the last-decision fallback (a synthesizer action, not
    // an execution location). Centering the region/neighborhood on the
    // real end point — e.g. `Error_Handler` — instead of a hooked-past
    // pause is the whole point of finalExecutionSymbol.
    return manifest.failedSymbol ??
        manifest.finalExecutionSymbol ??
        manifest.lastPauseSymbol ??
        fallback;
  }

  /// Render a recent-call-sequence trace, collapsing consecutive
  /// repeats to `` `sym` (×N) `` so a busy-wait spin is visible and the
  /// path stays readable. Symbols are backtick-quoted, joined with ` → `.
  static String _collapseTrace(List<String> trace) {
    final parts = <String>[];
    var i = 0;
    while (i < trace.length) {
      final sym = trace[i];
      var count = 1;
      while (i + count < trace.length && trace[i + count] == sym) {
        count++;
      }
      parts.add(count > 1 ? '`$sym` (×$count)' : '`$sym`');
      i += count;
    }
    return parts.join(' → ');
  }

  /// Name heuristic for an error/fault sink — a symbol where landing
  /// means an upstream check failed, so the fix is upstream, not a hook
  /// on the sink itself. Public so [RecommendationService] shares one
  /// definition (task framing + schema restriction).
  static bool looksLikeErrorSink(String symbol) {
    final s = symbol.toLowerCase();
    return s.contains('error_handler') ||
        s.contains('fault') || // HardFault_Handler, MemManage_Fault, …
        s.contains('assert') ||
        s == 'abort' ||
        s.contains('panic') ||
        s.contains('_exit');
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
    Map<int, String> artifactLabels = const {},
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
          : manifest.finalExecutionSymbol != null
              ? 'last function entered before the run ended'
              : manifest.lastPauseSymbol != null
                  ? 'last unhandled-access pause (run completed)'
                  : 'last decision (no pause recorded)';
      buf.writeln('- Halt point: `$haltSymbol` ($source)');
    }
    // Where execution actually got to, surfaced explicitly when it
    // differs from the fault/pause site above — e.g. the firmware was
    // hooked past its last fault and ran on before going quiescent.
    // This is the symbol to reason about for "why did forward progress
    // stop here", not the stale fault site.
    final finalExec = manifest.finalExecutionSymbol;
    if (finalExec != null && finalExec != haltSymbol) {
      buf.writeln('- Execution last reached: `$finalExec` '
          '(most recent function entered before the run ended)');
    }
    // The PATH into where execution stopped — so the model can reason
    // about WHY it got there (e.g. which call led into an error
    // handler), not just where. Consecutive repeats are collapsed with
    // a count, which also exposes a busy-wait spin.
    final trace = manifest.recentExecutionTrace;
    if (trace != null && trace.isNotEmpty) {
      buf.writeln('- Recent call sequence (last ${trace.length} entered, '
          'oldest→newest): ${_collapseTrace(trace)}');
      final endSym = trace.last;
      if (looksLikeErrorSink(endSym)) {
        buf.writeln('  ↳ `$endSym` looks like an error/fault handler. The '
            'real failure is the call JUST BEFORE it in the sequence — '
            '$kValueForSuccessGuidance. Do NOT '
            'hook the handler itself; that hides the failure without '
            'advancing coverage.');
      }
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
        // Reachable-denominator coverage + headroom. The raw
        // executed/total (above) counts unreachable library & dead code
        // in the denominator, so coverage looks catastrophic even when
        // most reachable code ran. Compute the universe reachable from
        // what actually executed so the model can tell "genuinely done"
        // (little headroom) from "blocked but reachable" (large
        // headroom) — the improvability signal. NOTE: the call graph is
        // built from objdump DIRECT calls only (indirect calls through
        // function pointers / vtables are not represented), so this set
        // UNDER-approximates — it is a supplementary signal; the raw
        // executed/total above stays the honest, cross-version baseline.
        final executedSet = executed.toSet();
        final reachable =
            FidelityCalculator.reachableFromEntries(callGraph, executed);
        if (reachable.isNotEmpty) {
          final headroom = reachable.difference(executedSet).length;
          final coveredReachable = reachable.length - headroom;
          final reachPct = (coveredReachable / reachable.length) * 100.0;
          buf.writeln(
              '- Reachable-code coverage: $coveredReachable of '
              '${reachable.length} reachable (${reachPct.toStringAsFixed(1)}%)'
              ' — $headroom reachable-but-unexecuted symbol(s) remain (the '
              'realistic room to improve; near 0 means coverage of the '
              'reachable code is essentially complete). Reachable set is '
              'from direct calls only (objdump), so it under-counts — treat '
              'the raw executed/total above as the baseline.');
        }
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

    // Center the neighborhood on the SAME symbol as the halt point /
    // region — the fault site, else where execution got to. (Previously
    // this used `decisions.last`, the alphabetically-last decision,
    // which diverged from the halt point — e.g. neighborhood of
    // `SystemInit` while the halt point was `HAL_I2C_Init`.)
    final focus = haltSymbol;
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
    final inRegion = [
      for (final d in currentState.decisions)
        if (region.contains(d.symbol)) d,
    ];
    // Render the halt / final-execution symbol's overlay FIRST so its
    // hook line is never dropped by the line cap below — that symbol is
    // where execution stopped, so the model must always see what hook
    // (if any) is in effect there in order to reconsider it.
    final regionDecisions = [
      ...inRegion.where((d) => d.symbol == haltSymbol),
      ...inRegion.where((d) => d.symbol != haltSymbol),
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
        var line = _overlayLine(d, appliedThisRun, artifactLabels);
        // The symbol where execution stopped is the one most likely to
        // have the WRONG hook. Counter the "ALREADY IN EFFECT = done"
        // bias right on its line so the model reconsiders it.
        if (haltSymbol != null && d.symbol == haltSymbol) {
          line += '  ← EXECUTION STOPPED HERE: if this hook is wrong '
              '(e.g. a ready/busy flag forced to the wrong value, or a '
              'Return-0 that masks forward progress), replace it.';
        }
        buf.writeln(line);
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
      // Facts the model needs before it considers skipping a frontier
      // CALLER: every one of these executed, and some carry working
      // overrides in their subtree that a Return-0 skip would disable.
      final overrideSymbols = {
        for (final d in currentState.decisions)
          if (d.kind == HookDecisionKind.override) d.symbol,
      };
      for (final e in frontier) {
        final beneath =
            overriddenHooksBeneath(callGraph, e.symbol, overrideSymbols);
        final cost = beneath.isEmpty
            ? ''
            : '; working hooks beneath it: ${beneath.take(3).join(', ')}'
                '${beneath.length > 3 ? ', …' : ''} — a Return-0 skip '
                'disables them';
        buf.writeln('- `${e.symbol}` (executed cleanly$cost) → '
            '${e.unexecutedCalleeCount} unreached callee(s):');
        for (final callee in e.unexecutedCallees.take(6)) {
          final note = _frontierAnnotation(
              currentState.forSymbol(callee), appliedThisRun);
          // A callee that isn't itself a call-graph node is an
          // unresolved import / PLT stub — not a hookable function, so
          // forcing it can't advance coverage. Flag it so the model
          // doesn't chase it.
          final suffix = note != null
              ? ' — $note'
              : !callGraph.symbols.containsKey(callee)
                  ? ' — (unresolved: not a call-graph function — cannot '
                      'be hooked to advance coverage)'
                  : '';
          buf.writeln('  - $callee$suffix');
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
  static String _overlayLine(HookDecision d, Map<String, int?> appliedThisRun,
      Map<int, String> artifactLabels) {
    final pref = d.preferredArtifactId != null
        ? ', pref #${d.preferredArtifactId}'
        : '';
    // The hook's EFFECT ("Return 0" / "Return 1" / "increment" …), so
    // the model can judge whether the applied hook is correct without
    // cross-joining the id to the catalog by hand. Empty when unknown.
    String effect(int? id) {
      final label = id == null ? null : artifactLabels[id];
      return (label == null || label.isEmpty) ? '' : ', "$label"';
    }

    switch (d.kind) {
      case HookDecisionKind.override:
        return '- `${d.symbol}` ← #${d.artifactId} (forced override'
            '${effect(d.artifactId)}$pref)';
      case HookDecisionKind.comms:
        final role = d.role != null ? ' ${d.role}' : '';
        return '- `${d.symbol}` (comms:${d.protocol}$role — virtualized '
            'as a bus$pref)';
      case HookDecisionKind.resolved:
        return '- `${d.symbol}` (carryover hook from a previous run$pref)';
      case HookDecisionKind.binding:
        final status = _bindingStatus(d, appliedThisRun);
        return '- `${d.symbol}` ← #${d.artifactId} (binding, '
            '${d.provenance ?? 'unknown'}${effect(d.artifactId)} — '
            '$status$pref)';
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
      SynthesisManifest manifest) => manifest.decisions.toList()
      ..sort((a, b) {
        final ai = a.iterationIndex;
        final bi = b.iterationIndex;
        if (ai == null && bi == null) return a.symbol.compareTo(b.symbol);
        if (ai == null) return -1;
        if (bi == null) return 1;
        return ai.compareTo(bi);
      });

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

/// The one shared phrasing for "make the failing call succeed" — every
/// prompt site uses this instead of the bare words "return success",
/// which name no number and which the model resolved to Return 1 (the
/// dominant pattern in its history). Observed damage: Return 1 on a
/// time reader froze the clock; and for HAL-style status functions
/// success is 0 (HAL_OK), so a blind 1 is wrong there too.
const kValueForSuccessGuidance =
    'force THAT call to return the value its CALLER needs to proceed — '
    'for a status-returning init/check that is the success STATUS '
    '(HAL-style status codes: success is usually 0/HAL_OK → "Return '
    '0"); for an `Is*`/`*Ready*` check → "Return 1"; for a `Get*` '
    'value reader → the value it reads (an advancing count for time, '
    'never a constant) — a blind "Return 1" is almost always wrong';

/// Transitive callees of [root] (BFS over direct-call edges) that are
/// in [overridden] — the working hooks a Return-0 skip of [root] would
/// disable. Rendered on wrapper-skip candidates (the coverage frontier
/// here, the stalled-caller feedback in RecommendationService) so the
/// model sees the cost of skipping a caller before it chooses to.
List<String> overriddenHooksBeneath(
    CallGraph g, String root, Set<String> overridden) {
  final hits = <String>[];
  final visited = <String>{root};
  final queue = [root];
  while (queue.isNotEmpty) {
    final node = g.symbols[queue.removeLast()];
    if (node == null) continue;
    for (final callee in node.calledSymbols.keys) {
      if (!visited.add(callee)) continue;
      if (overridden.contains(callee)) hits.add(callee);
      queue.add(callee);
    }
  }
  return hits;
}
