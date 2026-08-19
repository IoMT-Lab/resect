import 'dart:io';

import '../data/models/call_graph.dart';
import '../data/models/recommendation.dart';
import '../data/models/synthesis_manifest.dart';
import '../data/models/synthesizer_result.dart';
import '../services/analysis/coverage_frontier.dart';
import 'auto_tune_engine.dart';

/// [AutoTuneSink] that writes a self-contained report for a headless
/// auto-tune session — one set of files per round plus a summary, so a
/// run can be read back to understand every choice the LLM made and why,
/// and debugged after the fact.
///
/// Per round `N` (0 = baseline), under [reportDir]:
///   - `round_NN.md`           — the round's story: what changed going
///                                in (and why), what happened (stop log,
///                                time split), results, why it stopped,
///                                hooks in effect, frontier, census.
///   - `round_NN_manifest.json`— the enriched manifest (also copied to
///                                [manifestsDir] as `<run_id>.json` when
///                                given, matching the UI's convention).
///   - `round_NN_trace.txt`    — the full LLM exchange (prompt /
///                                thinking / response / diagnostics),
///                                identical in shape to the UI's
///                                `last_recommendation_trace.txt`.
/// And once, at the end: `summary.md`.
///
/// Streaming tokens are echoed to [log] so the operator can watch the
/// model think in real time (never buffered silently).
class AutoTuneReportSink implements AutoTuneSink {
  AutoTuneReportSink({
    required this.reportDir,
    required this.callGraph,
    required this.startedAt,
    this.manifestsDir,
    this.artifactLabels = const {},
    bool? color,
    void Function(String message)? log,
  })  : _log = log ?? stderr.writeln,
        _color = color ?? stdout.hasTerminal;

  /// Whether ANSI color is emitted. Auto-detected from the terminal;
  /// off when output is piped/redirected so logs stay clean.
  final bool _color;

  /// Directory the per-round report files are written to. Created if it
  /// doesn't exist on the first write.
  final Directory reportDir;

  /// Project call graph — used to compute each round's coverage frontier
  /// for the report (the boundary functions where execution stopped
  /// expanding).
  final CallGraph callGraph;

  /// Wall-clock start of the session, stamped into the summary. Passed
  /// in (not read from `DateTime.now`) so the value is stable across a
  /// resumed/replayed run.
  final DateTime startedAt;

  /// When set, each round's enriched manifest is also written here as
  /// `<run_id>.json` — the same location the UI persists manifests, so
  /// reopening the project in the UI finds them.
  final Directory? manifestsDir;

  /// Artifact id → human-readable effect label ("Return 1", "Stateful
  /// increment (from 0)"…), resolved once at construction via
  /// `artifactLabelsFor`. Ids missing from the map render as bare `#id`.
  final Map<int, String> artifactLabels;

  final void Function(String message) _log;

  final List<AutoTuneRoundReport> _rounds = [];

  var _dirReady = false;

  /// True while raw LLM tokens are being streamed to the console (so
  /// the next structured line knows to break the stream with a newline).
  var _streaming = false;

  void _ensureDir() {
    if (_dirReady) return;
    reportDir.createSync(recursive: true);
    manifestsDir?.createSync(recursive: true);
    _dirReady = true;
  }

  @override
  void phase(AutoTunePhase phase, {int round = 0, String? symbol}) {
    _breakStream();
    switch (phase) {
      case AutoTunePhase.baseline:
        _log(_dim('◐ round 0 · baseline synthesis…'));
      case AutoTunePhase.llmGenerating:
        _log(_dim('◑ round $round · asking the model for recommendations…'));
      case AutoTunePhase.generatingHook:
        _log(_dim('◒ round $round · authoring a hook for $symbol…'));
      case AutoTunePhase.synthesizing:
        _log(_dim('◓ round $round · synthesizing with applied overlays…'));
    }
  }

  @override
  void thinking(String chunk) => _stream(chunk);

  @override
  void token(String token) => _stream(token);

  /// Echo a raw LLM chunk, dimmed, only to an interactive terminal — a
  /// piped run keeps the full stream in the round trace file instead of
  /// flooding the log.
  void _stream(String chunk) {
    if (!stderr.hasTerminal) return;
    stderr.write(_color ? '\x1b[2m$chunk\x1b[0m' : chunk);
    _streaming = true;
  }

  void _breakStream() {
    if (_streaming) {
      stderr.write('\n');
      _streaming = false;
    }
  }

  @override
  void llmExchange(AutoTuneLlmExchange exchange) {
    _ensureDir();
    _breakStream();
    File('${reportDir.path}/round_${_pad(exchange.round)}_trace.txt')
        .writeAsStringSync(formatLlmTrace(exchange, timestamp: startedAt));
  }

  @override
  void round(AutoTuneRoundReport report) {
    _ensureDir();
    _rounds.add(report);
    final manifest = report.result.manifest!;

    File('${reportDir.path}/round_${_pad(report.round)}.md')
        .writeAsStringSync(_renderRoundMarkdown(report));

    final manifestJson = manifest.toPrettyJson();
    File('${reportDir.path}/round_${_pad(report.round)}_manifest.json')
        .writeAsStringSync(manifestJson);
    final md = manifestsDir;
    if (md != null) {
      // Match the UI's convention: ISO-8601 run ids contain `:`, which
      // isn't portable in a filename — replace with `-`.
      final safeRunId = manifest.synthesizerRunId.replaceAll(':', '-');
      File('${md.path}/$safeRunId.json').writeAsStringSync(manifestJson);
    }

    _breakStream();
    stderr.write(_consoleBlock(report));
  }

  @override
  void finished(AutoTuneStopReason reason,
      {required int finalRound, String? errorMessage}) {
    _ensureDir();
    File('${reportDir.path}/summary.md').writeAsStringSync(
        _renderSummaryMarkdown(reason, finalRound, errorMessage));
    _breakStream();
    const hard = {
      AutoTuneStopReason.baselineFailed,
      AutoTuneStopReason.synthesisError,
      AutoTuneStopReason.llmError,
      AutoTuneStopReason.parseFailed,
    };
    final head = hard.contains(reason)
        ? _red('● finished: ${reason.name}')
        : _green('● finished: ${reason.name}');
    _log('');
    _log(head + (errorMessage != null ? _dim(' — $errorMessage') : ''));
    _log(_dim('  reports → ${reportDir.path}'));
  }

  // -- Console rendering -----------------------------------------------------

  /// The scannable, color-coded per-round block: round + outcome, run
  /// metrics + timings, the symbols hooked reactively during the run
  /// (halt symbol highlighted), the LLM's recommendation + rationale,
  /// and the overlay changes applied to reach this round.
  String _consoleBlock(AutoTuneRoundReport r) {
    final manifest = r.result.manifest!;
    final m = r.metrics;
    final buf = StringBuffer();
    const width = 64;
    final bar = '━' * width;

    // Header: round + outcome badge, right-aligned.
    final label = r.round == 0
        ? ' ROUND 0  (baseline)'
        : ' ROUND ${r.round}${r.reverted ? '  [REVERTED]' : ''}';
    final o = _outcome(r.result, manifest);
    final pad = (width - label.length - o.text.length).clamp(1, width);
    buf
      ..writeln()
      ..writeln(_cyan(bar))
      ..writeln('${_bold(_cyan(label))}${' ' * pad}${o.colored}')
      ..writeln(_cyan(bar));
    if (r.reverted) {
      buf.writeln(" ${_red('REVERTED')} — coverage collapsed vs the session "
          "best; this round's overlay changes were rolled back.");
    }
    for (final w in r.warnings) {
      buf.writeln(' ${_yellow('⚠')} ${_dim(w)}');
    }

    // METRICS. Coverage comes from the recorded metrics when present
    // (single source of truth); the call-graph fallback covers old
    // manifests.
    final executedCount =
        m.executedCount ?? (manifest.executedSymbols ?? const []).length;
    final total = m.totalSymbols ?? callGraph.symbols.length;
    final pct = total == 0 ? 0.0 : executedCount / total * 100;
    final covText = '$executedCount/$total (${pct.toStringAsFixed(1)}%)';
    buf.writeln(' ${_bold('METRICS')}   '
        'fidelity ${_cyan(m.overallFidelity.toStringAsFixed(3))}  ·  '
        'coverage ${pct < 25 ? _yellow(covText) : _green(covText)}  ·  '
        'cov-fidelity ${m.coverageFidelity == null ? _dim('n/a') : _cyan(m.coverageFidelity!.toStringAsFixed(3))}');
    final firstStop = manifest.stops?.isNotEmpty == true
        ? manifest.stops!.first
        : null;
    final split = _timeSplit(r, manifest);
    buf.writeln(' ${_bold('TIME')}      '
        'synthesis ${_cyan(_secs(r.result.totalDuration.inMilliseconds / 1000.0))}'
        '${firstStop != null ? '  ·  first stop ${_yellow(_secs(firstStop.elapsedSeconds))} ${_dim('(${_stopKind(firstStop.kind)}${firstStop.symbol != null ? ' at ${firstStop.symbol}' : ''})')}' : ''}'
        '${split.isNotEmpty ? '  ·  $split' : ''}');

    // Symbols hooked reactively during the run (where execution
    // stopped and a hook was inserted). Pre-seeded overrides/comms/
    // warm-start are applied before the run and only summarized.
    final reactive =
        manifest.decisions.where((d) => _reactive(d.decisionKind)).toList();
    final preseeded = manifest.decisions.length - reactive.length;
    buf
      ..writeln()
      ..writeln(' ${_bold('HOOKS INSERTED THIS RUN')}'
          '${reactive.isEmpty ? _dim('  (none reactive)') : ''}');
    for (final d in reactive) {
      final id = d.appliedHook.artifactId;
      final isHalt = manifest.failedSymbol == d.symbol;
      final sym = isHalt ? _red(d.symbol) : _hookColor(d.decisionKind, d.symbol);
      buf.writeln('   ${_hookGlyph(d.decisionKind)} $sym'
          '  ${_dim(manifestDecisionKindShortLabel[d.decisionKind] ?? d.decisionKind.name)}'
          '${id != null ? '  ${_cyan(_labelFor(id))}' : ''}'
          '${isHalt ? _red('  ← halt (candidates exhausted)') : ''}');
    }
    if (preseeded > 0) {
      buf.writeln(_dim('   (+ $preseeded pre-seeded before the run)'));
    }
    if (manifest.failedSymbol == null && manifest.lastPauseSymbol != null) {
      buf.writeln('   ${_yellow('⏸ last pause: ${manifest.lastPauseSymbol}')}');
    }

    // The recommendation that produced this round + what changed.
    final rec = r.recommendation;
    if (rec != null) {
      buf
        ..writeln()
        ..writeln(' ${_bold('RECOMMENDATION')}');
      if (rec.prose.trim().isNotEmpty) {
        buf.writeln('   ${_dim(rec.prose.trim())}');
      }
      for (var i = 0; i < rec.recommendations.length; i++) {
        final rr = rec.recommendations[i];
        buf.writeln('   ${_bold('${i + 1}.')} ${_recLineColored(rr)}');
        if (rr.rationale.trim().isNotEmpty) {
          buf.writeln('      ${_dim(rr.rationale.trim())}');
        }
      }
      buf
        ..writeln()
        ..writeln(' ${_bold('CHANGED GOING IN')}');
      if (r.appliedRecommendations.isEmpty) {
        buf.writeln(_dim('   (none)'));
      } else {
        for (final rr in r.appliedRecommendations) {
          buf.writeln('   ${_green('+')} ${_recLineColored(rr)}');
        }
      }
      for (final rr in r.skippedNoOps) {
        buf.writeln('   ${_yellow('∅')} ${_recLineColored(rr)}'
            '${_dim('  (no-op — already in effect, skipped)')}');
      }
      for (final rr in r.refusedDestructive) {
        buf.writeln('   ${_red('✗')} ${_recLineColored(rr)}'
            '${_dim('  (REFUSED — destructive, not applied)')}');
      }
    }
    buf.writeln();
    return buf.toString();
  }

  /// `selection Xs · generation Ys · advisor Zs` — empty when nothing
  /// was measured. Generation combines the synthesizer's in-run hook
  /// authoring with the auto-tune round's custom-hook pass. The report
  /// fields are authoritative in-memory; the manifest's folded copies
  /// back them up when a report was rebuilt from disk.
  String _timeSplit(AutoTuneRoundReport r, SynthesisManifest manifest) {
    final pt = manifest.phaseTimings;
    final hookGen = r.hookGenSeconds ?? pt?.roundHookGenSeconds;
    final advisor = r.advisorSeconds ?? pt?.advisorSeconds;
    final gen = (pt?.generationSeconds ?? 0) + (hookGen ?? 0);
    final parts = <String>[
      if (pt != null) 'selection ${_cyan(_secs(pt.selectionSeconds))}',
      if (pt != null || hookGen != null) 'generation ${_cyan(_secs(gen))}',
      if (advisor != null) 'advisor ${_cyan(_secs(advisor))}',
    ];
    return parts.join('  ·  ');
  }

  ({String text, String colored}) _outcome(
      SynthesizerResult res, SynthesisManifest man) {
    if (res.success) return (text: '✓ SUCCESS', colored: _green('✓ SUCCESS'));
    if (man.failedSymbol != null) {
      return (text: '✗ FAILED', colored: _red('✗ FAILED'));
    }
    if (man.lastPauseSymbol != null) {
      return (text: '⏸ HALTED', colored: _yellow('⏸ HALTED'));
    }
    return (text: '· no-converge', colored: _dim('· no-converge'));
  }

  static bool _reactive(ManifestDecisionKind k) =>
      k == ManifestDecisionKind.binding ||
      k == ManifestDecisionKind.iterationFallback ||
      k == ManifestDecisionKind.llmOnDemand ||
      k == ManifestDecisionKind.groupOverride;

  String _hookGlyph(ManifestDecisionKind k) {
    switch (k) {
      case ManifestDecisionKind.llmOnDemand:
        return _magenta('✦');
      case ManifestDecisionKind.groupOverride:
        return _cyan('◇');
      case ManifestDecisionKind.iterationFallback:
        return _yellow('◆');
      default:
        return _cyan('●');
    }
  }

  String _hookColor(ManifestDecisionKind k, String s) {
    switch (k) {
      case ManifestDecisionKind.llmOnDemand:
        return _magenta(s);
      case ManifestDecisionKind.iterationFallback:
        return _yellow(s);
      default:
        return s;
    }
  }

  String _recLineColored(Recommendation r) {
    switch (r) {
      case SetForcedOverride(:final symbol, :final artifactId, :final scope):
        final s = (scope == null || scope.isEmpty) ? '' : _dim(' scope=$scope');
        return '${_dim('set_forced_override')} ${_bold(symbol)} '
            '${_dim('←')} ${_cyan(_labelFor(artifactId))}$s';
      case ClearForcedOverride(:final symbol):
        return '${_dim('clear_forced_override')} ${_bold(symbol)}';
      case SetPreference(:final symbol, :final artifactId):
        return '${_dim('set_preference')} ${_bold(symbol)} '
            '${_dim('←')} ${_cyan(_labelFor(artifactId))}';
      case GenerateCustomHook(:final symbol):
        return '${_magenta('generate_custom_hook')} ${_bold(symbol)}';
      case AdjustIterationCap(:final newValue):
        return '${_dim('adjust_iteration_cap →')} ${_bold('$newValue')}';
      case SetGroupOverride(:final scope):
        return '${_cyan('set_group_override')} ${_bold(scope)}';
      case ClearGroupOverride(:final scope):
        return '${_dim('clear_group_override')} ${_bold(scope)}';
    }
  }

  // ANSI helpers — no-ops when color is disabled (piped output).
  String _paint(String s, String code) => _color ? '$code$s\x1b[0m' : s;
  String _bold(String s) => _paint(s, '\x1b[1m');
  String _dim(String s) => _paint(s, '\x1b[2m');
  String _red(String s) => _paint(s, '\x1b[1;31m');
  String _green(String s) => _paint(s, '\x1b[1;32m');
  String _yellow(String s) => _paint(s, '\x1b[33m');
  String _cyan(String s) => _paint(s, '\x1b[1;36m');
  String _magenta(String s) => _paint(s, '\x1b[35m');

  // -- Markdown rendering ------------------------------------------------------

  /// Round page, ordered as the round's story: what changed going in
  /// (and why) → what happened (stop log + time split) → results → why
  /// it stopped where it did → hooks in effect → frontier → census.
  String _renderRoundMarkdown(AutoTuneRoundReport report) {
    final manifest = report.result.manifest!;
    final m = report.metrics;
    final buf = StringBuffer()
      ..writeln('# Auto-tune round ${report.round}'
          '${report.round == 0 ? ' (baseline)' : ''}'
          ' — ${_outcomeLine(report.result, manifest)}'
          '${report.reverted ? ' — REVERTED' : ''}')
      ..writeln();
    if (report.reverted) {
      buf
        ..writeln("**REVERTED**: this round's coverage collapsed versus "
            'the session best; its overlay changes were measured, rolled '
            'back, and reported to the model as poisoned. The metrics below '
            'describe the run that triggered the revert.')
        ..writeln();
    }
    for (final w in report.warnings) {
      buf.writeln('> ⚠ $w');
    }
    if (report.warnings.isNotEmpty) buf.writeln();
    buf
      ..writeln('- Run ID: `${manifest.synthesizerRunId}`')
      ..writeln()
      // 1) What changed going in — the moves (and reasons) that produced
      //    this round's overlay state.
      ..writeln('## What changed going in');
    final rec = report.recommendation;
    if (rec == null) {
      buf.writeln('Nothing — baseline synthesis with the pre-seeded '
          'overlays.');
    } else {
      if (rec.prose.trim().isNotEmpty) {
        buf
          ..writeln("**Model's summary:** ${rec.prose.trim()}")
          ..writeln();
      }
      if (rec.recommendations.isEmpty) {
        buf.writeln('The model returned no recommendations.');
      }
      // The model's proposals, numbered in emission order, each with its
      // fate — so a proposal that was refused or skipped is as visible
      // as one that landed.
      final appliedLines =
          report.appliedRecommendations.map(_recLineMd).toSet();
      final skippedLines = report.skippedNoOps.map(_recLineMd).toSet();
      final refusedLines = report.refusedDestructive.map(_recLineMd).toSet();
      for (var i = 0; i < rec.recommendations.length; i++) {
        final r = rec.recommendations[i];
        final line = _recLineMd(r);
        final fate = appliedLines.contains(line)
            ? '— **applied**'
            : skippedLines.contains(line)
                ? '— skipped as a no-op (already in effect)'
                : refusedLines.contains(line)
                    ? '— REFUSED as destructive (engine backstop, not '
                        'applied)'
                    : '— not applied';
        buf.writeln('${i + 1}. $line $fate');
        if (r.rationale.trim().isNotEmpty) {
          buf.writeln('   - _why:_ ${r.rationale.trim()}');
        }
      }
      // Applied moves that match no proposal verbatim (edited during an
      // interactive review) still need to be on the record.
      final proposalLines = rec.recommendations.map(_recLineMd).toSet();
      final edited = report.appliedRecommendations
          .where((r) => !proposalLines.contains(_recLineMd(r)))
          .toList();
      if (edited.isNotEmpty) {
        buf
          ..writeln()
          ..writeln('**Also applied (edited during review):**');
        for (final r in edited) {
          buf.writeln('- ${_recLineMd(r)}');
        }
      }
    }
    buf.writeln();

    // 2) What happened — outcome, run time, the stop log, and where the
    //    run's wall time went.
    final stops = manifest.stops ?? const <StopTiming>[];
    buf
      ..writeln('## What happened')
      ..writeln('- Outcome: ${_outcomeLine(report.result, manifest)}')
      ..writeln('- Iterations: ${report.result.totalIterations}')
      ..writeln('- Synthesis time: '
          '${_secs(report.result.totalDuration.inMilliseconds / 1000.0)}');
    if (stops.isNotEmpty) {
      buf.writeln('- Time to first stop: '
          '${_secs(stops.first.elapsedSeconds)} '
          '(${_stopKind(stops.first.kind)}'
          '${stops.first.symbol != null ? ' at `${stops.first.symbol}`' : ''})');
    }
    final split = _timeSplitMd(report, manifest);
    if (split != null) buf.writeln('- Time split: $split');
    if (stops.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('Stop log (run wall time → stop condition):');
      for (final s in stops) {
        buf.writeln('- ${_secs(s.elapsedSeconds)} → ${_stopKind(s.kind)}'
            '${s.symbol != null ? ' at `${s.symbol}`' : ''}');
      }
    }
    buf.writeln();

    // 3) Results. Coverage from recorded metrics when present; the
    // call-graph fallback covers old manifests.
    final executed = manifest.executedSymbols ?? const [];
    final executedCount = m.executedCount ?? executed.length;
    final total = m.totalSymbols ?? callGraph.symbols.length;
    final pct = total == 0 ? 0.0 : (executedCount / total) * 100;
    buf
      ..writeln('## Results')
      ..writeln('- Fidelity: ${m.overallFidelity.toStringAsFixed(3)}')
      ..writeln('- Coverage fidelity: '
          '${m.coverageFidelity?.toStringAsFixed(3) ?? 'n/a'}')
      ..writeln('- Coverage: $executedCount of $total symbols executed '
          '(${pct.toStringAsFixed(1)}%)')
      ..writeln('- Hooked: ${m.hookedCount} · Intact: ${m.intactCount} · '
          'Degraded: ${m.degradedCount}')
      ..writeln()
      // 4) Why it stopped where it did.
      ..writeln('## Why it stopped where it did');
    if (report.result.success) {
      buf.writeln('The firmware ran cleanly — no unhandled accesses left.');
    } else {
      if (manifest.failedSymbol != null) {
        buf.writeln('- Halted at `${manifest.failedSymbol}` — every hook '
            'candidate for it was tried and the access repeated.');
      } else if (manifest.lastPauseSymbol != null) {
        buf.writeln('- Last pause at `${manifest.lastPauseSymbol}`.');
      }
      if (manifest.terminationReason != null) {
        buf.writeln('- Termination reason: '
            '${manifest.terminationReason!.name}');
      }
      if (manifest.finalExecutionSymbol != null) {
        buf.writeln('- Final symbol executing when the run ended: '
            '`${manifest.finalExecutionSymbol}`');
      }
      final trace = manifest.recentExecutionTrace;
      if (trace != null && trace.isNotEmpty) {
        buf
          ..writeln('- Recent call sequence (most recent last, consecutive '
              'repeats collapsed):')
          ..writeln('  ${_collapseTrace(trace).map((s) => '`$s`').join(' → ')}');
      }
    }
    buf.writeln();

    // 5) Hooks in effect during the run.
    final reactive =
        manifest.decisions.where((d) => _reactive(d.decisionKind)).toList();
    final preseeded = manifest.decisions.length - reactive.length;
    buf.writeln('## Hooks in effect');
    if (manifest.decisions.isEmpty) {
      buf.writeln('(none recorded)');
    } else {
      if (preseeded > 0) {
        buf.writeln('$preseeded hook(s) were pre-seeded before the run '
            '(overrides / comms / warm-start):');
        for (final d in manifest.decisions
            .where((d) => !_reactive(d.decisionKind))) {
          buf.writeln('- ${_decisionLineMd(d)}');
        }
        buf.writeln();
      }
      buf.writeln(reactive.isEmpty
          ? 'No hooks were inserted reactively during the run.'
          : 'Inserted reactively during the run (where execution stopped):');
      for (final d in reactive) {
        buf.writeln('- ${_decisionLineMd(d)}'
            '${manifest.failedSymbol == d.symbol ? ' ← **halt point**' : ''}');
      }
    }
    buf.writeln();

    // 6) Coverage frontier — where this run stopped expanding.
    final frontier = computeFrontier(
      executedSymbols: executed.toSet(),
      callGraph: callGraph,
    );
    buf.writeln('## Coverage frontier');
    if (frontier.isEmpty) {
      buf.writeln('(none — nothing executed, or all callees were reached)');
    } else {
      for (final e in frontier) {
        buf.writeln('- `${e.symbol}` → unexecuted callees: '
            '${e.unexecutedCallees.join(', ')}');
      }
    }
    buf.writeln();

    // 7) Artifact census — the knowledge feeding this round.
    final census = report.census ?? manifest.census;
    buf.writeln('## Artifact census');
    if (census == null) {
      buf.writeln('(not computed)');
    } else {
      _writeCensus(buf, census);
    }
    buf.writeln();
    return buf.toString();
  }

  void _writeCensus(StringBuffer buf, ArtifactCensus c) {
    buf
      ..writeln('- Hook artifacts in the catalog: ${c.hookArtifacts} '
          '(whole catalog — not yet firmware-scoped)')
      ..writeln('- Hook bindings: ${c.hookBindings}')
      ..writeln('- Forced overrides: ${c.forcedOverrides}')
      ..writeln('- Comms assignments: ${c.commsAssignments}')
      ..writeln('- Symbols in recognized groups: ${c.groupMembers}')
      ..writeln('- Ghidra signatures: ${c.signatures} · '
          'decompilations: ${c.decompilations}');
    if (c.ragChunksByKind.isEmpty) {
      buf.writeln('- RAG chunks: 0 (no index)');
    } else {
      final kinds = c.ragChunksByKind.entries
          .map((e) => '${e.key} ${e.value}')
          .join(', ');
      buf.writeln('- RAG chunks: ${c.ragChunksTotal} ($kinds)');
    }
    buf.writeln('- Total artifacts feeding synthesis: ${c.total}');
  }

  String _decisionLineMd(ManifestDecision d) {
    final id = d.appliedHook.artifactId;
    final kindLabel =
        manifestDecisionKindShortLabel[d.decisionKind] ?? d.decisionKind.name;
    return '`${d.symbol}` ← ${id != null ? '${_labelFor(id)} ' : ''}'
        '($kindLabel, ${d.decisionSource})';
  }

  String? _timeSplitMd(AutoTuneRoundReport r, SynthesisManifest manifest) {
    final pt = manifest.phaseTimings;
    final hookGen = r.hookGenSeconds ?? pt?.roundHookGenSeconds;
    final advisor = r.advisorSeconds ?? pt?.advisorSeconds;
    if (pt == null && advisor == null && hookGen == null) {
      return null;
    }
    final gen = (pt?.generationSeconds ?? 0) + (hookGen ?? 0);
    final parts = <String>[
      if (pt != null) 'hook selection ${_secs(pt.selectionSeconds)}',
      if (pt != null || hookGen != null) 'hook generation ${_secs(gen)}',
      if (advisor != null) 'advisor ${_secs(advisor)}',
    ];
    return parts.join(' · ');
  }

  String _renderSummaryMarkdown(
      AutoTuneStopReason reason, int finalRound, String? errorMessage) {
    final buf = StringBuffer()
      ..writeln('# Auto-tune session summary')
      ..writeln()
      ..writeln('- Started: ${startedAt.toIso8601String()}')
      ..writeln('- Rounds reported: ${_rounds.length} '
          '(0..${_rounds.isEmpty ? '-' : _rounds.last.round})')
      ..writeln('- Last completed round: $finalRound')
      ..writeln('- Termination: ${reason.name}'
          '${errorMessage != null ? ' — $errorMessage' : ''}')
      ..writeln('- Report directory: `${reportDir.path}`')
      ..writeln()
      ..writeln('## Per-round trajectory')
      ..writeln()
      ..writeln('| Round | Outcome | Overall fid | Coverage fid | Executed '
          '| Time | First stop |')
      ..writeln('|------:|---------|------------:|-------------:|---------:'
          '|-----:|-----------|');
    // The session's BEST round by executed count (reverted rounds can't
    // be best — their changes were rolled back).
    var bestRound = -1;
    var bestExecuted = -1;
    for (final r in _rounds) {
      final executed = r.result.manifest!.executedSymbols?.length ?? 0;
      if (!r.reverted && executed > bestExecuted) {
        bestExecuted = executed;
        bestRound = r.round;
      }
    }
    for (final r in _rounds) {
      final manifest = r.result.manifest!;
      final executed = manifest.executedSymbols?.length ?? 0;
      final marks = [
        if (r.round == bestRound) 'BEST',
        if (r.reverted) 'REVERTED',
      ].join(', ');
      final firstStop = manifest.stops?.isNotEmpty == true
          ? manifest.stops!.first
          : null;
      buf.writeln('| ${r.round}${marks.isEmpty ? '' : ' ($marks)'} '
          '| ${_outcomeShort(r.result, manifest)} '
          '| ${r.metrics.overallFidelity.toStringAsFixed(3)} '
          '| ${r.metrics.coverageFidelity?.toStringAsFixed(3) ?? 'n/a'} '
          '| $executed '
          '| ${_secs(r.result.totalDuration.inMilliseconds / 1000.0)} '
          '| ${firstStop == null ? '—' : '${_secs(firstStop.elapsedSeconds)} ${_stopKind(firstStop.kind)}${firstStop.symbol != null ? ' at `${firstStop.symbol}`' : ''}'} |');
    }
    if (bestRound >= 0) {
      buf
        ..writeln()
        ..writeln("The session finished holding round $bestRound's overlays "
            "(best: $bestExecuted executed). Reverted rounds' changes are "
            'NOT in effect.');
    }

    // Cumulative time — where the whole session's wall clock went.
    var synth = 0.0, selection = 0.0, generation = 0.0, advisor = 0.0;
    var haveSplit = false;
    for (final r in _rounds) {
      synth += r.result.totalDuration.inMilliseconds / 1000.0;
      final pt = r.result.manifest!.phaseTimings;
      if (pt != null) {
        selection += pt.selectionSeconds;
        generation += pt.generationSeconds;
        haveSplit = true;
      }
      final hookGen = r.hookGenSeconds ?? pt?.roundHookGenSeconds;
      if (hookGen != null) {
        generation += hookGen;
        haveSplit = true;
      }
      final adv = r.advisorSeconds ?? pt?.advisorSeconds;
      if (adv != null) {
        advisor += adv;
        haveSplit = true;
      }
    }
    buf
      ..writeln()
      ..writeln('## Cumulative time')
      ..writeln()
      ..writeln('- Total synthesis (emulation) time: ${_secs(synth)} across '
          '${_rounds.length} round(s)');
    if (haveSplit) {
      buf
        ..writeln('- Hook selection: ${_secs(selection)}')
        ..writeln('- Hook generation (LLM authoring): ${_secs(generation)}')
        ..writeln('- Advisor (recommendation) calls: ${_secs(advisor)}');
    }

    // Census — the final round's counts stand for the session's
    // cumulative knowledge (the catalog and index only grow).
    final lastCensus = _rounds.isEmpty
        ? null
        : (_rounds.last.census ?? _rounds.last.result.manifest!.census);
    if (lastCensus != null) {
      buf
        ..writeln()
        ..writeln('## Artifact census (final round — cumulative: these '
            'stores only grow during a session)')
        ..writeln();
      _writeCensus(buf, lastCensus);
    }

    buf
      ..writeln()
      ..writeln('## Files');
    for (final r in _rounds) {
      final n = _pad(r.round);
      // Only rounds with an LLM call produce a trace file (the baseline
      // has none).
      final trace = r.recommendation == null ? '' : ', `round_${n}_trace.txt`';
      buf.writeln('- Round ${r.round}: `round_$n.md`, '
          '`round_${n}_manifest.json`$trace');
    }
    buf.writeln();
    return buf.toString();
  }

  static String _outcomeLine(SynthesizerResult result, SynthesisManifest manifest) {
    if (result.success) return 'SUCCESS — firmware ran cleanly';
    if (manifest.failedSymbol != null) {
      return 'FAILED — exhausted hooks at `${manifest.failedSymbol}`';
    }
    if (manifest.lastPauseSymbol != null) {
      return 'halted — last pause at `${manifest.lastPauseSymbol}`';
    }
    return 'did not converge';
  }

  static String _outcomeShort(SynthesizerResult result, SynthesisManifest manifest) {
    if (result.success) return 'success';
    if (manifest.failedSymbol != null) return 'failed @ ${manifest.failedSymbol}';
    if (manifest.lastPauseSymbol != null) {
      return 'halted @ ${manifest.lastPauseSymbol}';
    }
    return 'no-converge';
  }

  /// Plain-markdown recommendation line, label-first with the artifact
  /// id retained for tooling: `` set_forced_override `sym` ← "Return 1" (#2) ``.
  String _recLineMd(Recommendation r) {
    switch (r) {
      case SetForcedOverride(:final symbol, :final artifactId, :final scope):
        final s = (scope == null || scope.isEmpty) ? '' : ' scope=$scope';
        return 'set_forced_override `$symbol` ← ${_labelFor(artifactId)}$s';
      case ClearForcedOverride(:final symbol):
        return 'clear_forced_override `$symbol`';
      case SetPreference(:final symbol, :final artifactId):
        return 'set_preference `$symbol` ← ${_labelFor(artifactId)}';
      case GenerateCustomHook(:final symbol, :final intent):
        final i = (intent == null || intent.isEmpty) ? '' : ' intent="$intent"';
        return 'generate_custom_hook `$symbol`$i';
      case AdjustIterationCap(:final newValue):
        return 'adjust_iteration_cap → $newValue';
      case SetGroupOverride(:final scope):
        return 'set_group_override `$scope`';
      case ClearGroupOverride(:final scope):
        return 'clear_group_override `$scope`';
    }
  }

  /// `"Return 1" (#2)` when the id has a known label, `#2` otherwise.
  String _labelFor(int id) {
    final label = artifactLabels[id];
    return label == null ? '#$id' : '"$label" (#$id)';
  }

  static String _secs(double s) => '${s.toStringAsFixed(1)}s';

  static String _stopKind(String kind) {
    switch (kind) {
      case 'unhandled_access':
        return 'unhandled access';
      case 'clean_exit':
        return 'clean exit';
      default:
        return kind;
    }
  }

  /// Collapse consecutive repeats: `[a, b, b, b, c]` → `[a, b ×3, c]`.
  static List<String> _collapseTrace(List<String> trace) {
    final out = <String>[];
    String? prev;
    var count = 0;
    for (final s in trace) {
      if (s == prev) {
        count++;
        continue;
      }
      if (prev != null) out.add(count > 1 ? '$prev ×$count' : prev);
      prev = s;
      count = 1;
    }
    if (prev != null) out.add(count > 1 ? '$prev ×$count' : prev);
    return out;
  }

  static String _pad(int round) => round.toString().padLeft(2, '0');
}

/// Format one recommendation exchange as the plain-text trace both the
/// CLI (`round_NN_trace.txt`) and the UI (`last_recommendation_trace.txt`)
/// write. Shape matches the UI's original `_persistLlmTrace` body so the
/// two produce identical files.
String formatLlmTrace(AutoTuneLlmExchange e, {DateTime? timestamp}) {
  final modelTag = e.model ?? '(unknown)';
  final ts = (timestamp ?? DateTime.now()).toIso8601String();
  final buf = StringBuffer()
    ..writeln('=== Auto-tune round ${e.round} | $ts | model: $modelTag ===')
    ..writeln()
    ..writeln('--- Prompt ---')
    ..writeln(e.prompt)
    ..writeln()
    ..writeln('--- Thinking ---')
    ..writeln(e.thinking.isEmpty ? '(no thinking emitted)' : e.thinking)
    ..writeln()
    ..writeln('--- Response ---')
    ..writeln(e.response.isEmpty ? '(no response emitted)' : e.response)
    ..writeln()
    ..writeln('--- Result ---');
  final err = e.errorMessage;
  final result = e.result;
  if (err != null) {
    buf.writeln('exception: $err');
  } else if (result == null) {
    buf.writeln('result: null (no result returned)');
  } else {
    final diag = result.diagnostic;
    buf
      ..writeln('done_reason: ${diag?.doneReason ?? "(unknown)"}')
      ..writeln('response_tokens: ${diag?.responseTokens ?? "(unknown)"}')
      ..writeln('thinking_chunks: ${diag?.thinkingChunks ?? "(unknown)"}')
      ..writeln(
          'parse_failure_kind: ${result.parseFailureKind?.name ?? "(none)"}')
      ..writeln('recommendations_count: ${result.recommendations.length}');
  }
  return buf.toString();
}
