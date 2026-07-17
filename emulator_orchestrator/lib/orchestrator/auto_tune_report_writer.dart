import 'dart:io';

import '../data/models/call_graph.dart';
import '../data/models/recommendation.dart';
import '../data/models/synthesis_manifest.dart';
import '../data/models/synthesizer_result.dart';
import '../data/services/coverage_frontier.dart';
import 'auto_tune_engine.dart';

/// [AutoTuneSink] that writes a self-contained report for a headless
/// auto-tune session — one set of files per round plus a summary, so a
/// run can be read back to understand every choice the LLM made and why,
/// and debugged after the fact.
///
/// Per round `N` (0 = baseline), under [reportDir]:
///   - `round_NN.md`           — human-readable outcome + metrics +
///                                coverage frontier + synthesizer
///                                decisions + the LLM's recommendations
///                                and rationale + what was applied.
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
  /// metrics, the symbols hooked reactively during the run (halt symbol
  /// highlighted), the LLM's recommendation + rationale, and the overlay
  /// changes applied to reach this round.
  String _consoleBlock(AutoTuneRoundReport r) {
    final manifest = r.result.manifest!;
    final m = r.metrics;
    final buf = StringBuffer();
    const width = 64;
    final bar = '━' * width;

    // Header: round + outcome badge, right-aligned.
    final label = r.round == 0 ? ' ROUND 0  (baseline)' : ' ROUND ${r.round}';
    final o = _outcome(r.result, manifest);
    final pad = (width - label.length - o.text.length).clamp(1, width);
    buf
      ..writeln()
      ..writeln(_cyan(bar))
      ..writeln('${_bold(_cyan(label))}${' ' * pad}${o.colored}')
      ..writeln(_cyan(bar));

    // 3) METRICS.
    final executed = manifest.executedSymbols ?? const [];
    final total = callGraph.symbols.length;
    final pct = total == 0 ? 0.0 : executed.length / total * 100;
    final covText = '${executed.length}/$total (${pct.toStringAsFixed(1)}%)';
    buf.writeln(' ${_bold('METRICS')}   '
        'fidelity ${_cyan(m.overallFidelity.toStringAsFixed(3))}  ·  '
        'coverage ${pct < 25 ? _yellow(covText) : _green(covText)}  ·  '
        'cov-fidelity ${m.coverageFidelity == null ? _dim('n/a') : _cyan(m.coverageFidelity!.toStringAsFixed(3))}');

    // 2) Symbols hooked reactively during the run (where execution
    //    stopped and a hook was inserted). Pre-seeded overrides/comms/
    //    warm-start are applied before the run and only summarized.
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
          '  ${_dim(d.decisionKind.name)}${id != null ? _dim('  #$id') : ''}'
          '${isHalt ? _red('  ← halt (candidates exhausted)') : ''}');
    }
    if (preseeded > 0) {
      buf.writeln(_dim('   (+ $preseeded pre-seeded before the run)'));
    }
    if (manifest.failedSymbol == null && manifest.lastPauseSymbol != null) {
      buf.writeln('   ${_yellow('⏸ last pause: ${manifest.lastPauseSymbol}')}');
    }

    // 4 + 5) The recommendation that produced this round + what changed.
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
    }
    buf.writeln();
    return buf.toString();
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
      k == ManifestDecisionKind.llmOnDemand;

  String _hookGlyph(ManifestDecisionKind k) {
    switch (k) {
      case ManifestDecisionKind.llmOnDemand:
        return _magenta('✦');
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
            '${_dim('←')} ${_cyan('#$artifactId')}$s';
      case ClearForcedOverride(:final symbol):
        return '${_dim('clear_forced_override')} ${_bold(symbol)}';
      case SetPreference(:final symbol, :final artifactId):
        return '${_dim('set_preference')} ${_bold(symbol)} '
            '${_dim('←')} ${_cyan('#$artifactId')}';
      case GenerateCustomHook(:final symbol):
        return '${_magenta('generate_custom_hook')} ${_bold(symbol)}';
      case AdjustIterationCap(:final newValue):
        return '${_dim('adjust_iteration_cap →')} ${_bold('$newValue')}';
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

  // -- Rendering -------------------------------------------------------------

  String _renderRoundMarkdown(AutoTuneRoundReport report) {
    final manifest = report.result.manifest!;
    final m = report.metrics;
    final buf = StringBuffer()
      ..writeln('# Auto-tune round ${report.round}'
          '${report.round == 0 ? ' (baseline)' : ''}')
      ..writeln()
      ..writeln('- Run ID: `${manifest.synthesizerRunId}`')
      ..writeln('- Outcome: ${_outcomeLine(report.result, manifest)}')
      ..writeln('- Iterations: ${report.result.totalIterations}')
      ..writeln('- Duration: ${report.result.totalDuration.inSeconds}s')
      ..writeln();

    // Metrics.
    final executed = manifest.executedSymbols ?? const [];
    final total = callGraph.symbols.length;
    final pct = total == 0 ? 0.0 : (executed.length / total) * 100;
    buf
      ..writeln('## Metrics')
      ..writeln('- Overall fidelity: ${m.overallFidelity.toStringAsFixed(3)}')
      ..writeln('- Coverage fidelity: '
          '${m.coverageFidelity?.toStringAsFixed(3) ?? 'n/a'}')
      ..writeln('- Symbols executed: ${executed.length} of $total '
          '(${pct.toStringAsFixed(1)}%)')
      ..writeln('- Hooked: ${m.hookedCount} · Intact: ${m.intactCount} · '
          'Degraded: ${m.degradedCount}')
      ..writeln();

    // Coverage frontier — where this run stopped expanding.
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

    // Synthesizer decisions taken during the run.
    buf
      ..writeln()
      ..writeln('## Synthesizer decisions this run');
    if (manifest.decisions.isEmpty) {
      buf.writeln('(none recorded)');
    } else {
      for (final d in manifest.decisions) {
        final id = d.appliedHook.artifactId;
        buf.writeln('- `${d.symbol}` ← ${d.decisionKind.name} '
            '(${d.decisionSource})${id != null ? ' applied=#$id' : ''}');
      }
    }

    // LLM recommendations that produced THIS round (empty on baseline).
    buf
      ..writeln()
      ..writeln('## LLM recommendations');
    final rec = report.recommendation;
    if (rec == null) {
      buf.writeln('No LLM call — baseline run.');
    } else {
      if (rec.prose.trim().isNotEmpty) {
        buf
          ..writeln('**Summary:** ${rec.prose.trim()}')
          ..writeln();
      }
      if (rec.recommendations.isEmpty) {
        buf.writeln('(model returned no recommendations)');
      } else {
        for (var i = 0; i < rec.recommendations.length; i++) {
          final r = rec.recommendations[i];
          buf.writeln('${i + 1}. ${_recLine(r)}');
          if (r.rationale.trim().isNotEmpty) {
            buf.writeln('   - _${r.rationale.trim()}_');
          }
        }
      }
      buf
        ..writeln()
        ..writeln('**Applied this round (auto-accepted):**');
      if (report.appliedRecommendations.isEmpty) {
        buf.writeln('(none)');
      } else {
        for (final r in report.appliedRecommendations) {
          buf.writeln('- ${_recLine(r)}');
        }
      }
      if (report.skippedNoOps.isNotEmpty) {
        buf
          ..writeln()
          ..writeln('**Skipped as no-ops (already in effect):**');
        for (final r in report.skippedNoOps) {
          buf.writeln('- ${_recLine(r)}');
        }
      }
    }
    buf.writeln();
    return buf.toString();
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
      ..writeln('| Round | Outcome | Overall fid | Coverage fid | Executed |')
      ..writeln('|------:|---------|------------:|-------------:|---------:|');
    for (final r in _rounds) {
      final manifest = r.result.manifest!;
      final executed = manifest.executedSymbols?.length ?? 0;
      buf.writeln('| ${r.round} '
          '| ${_outcomeShort(r.result, manifest)} '
          '| ${r.metrics.overallFidelity.toStringAsFixed(3)} '
          '| ${r.metrics.coverageFidelity?.toStringAsFixed(3) ?? 'n/a'} '
          '| $executed |');
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

  static String _recLine(Recommendation r) {
    switch (r) {
      case SetForcedOverride(:final symbol, :final artifactId, :final scope):
        final s = (scope == null || scope.isEmpty) ? '' : ' scope=$scope';
        return 'set_forced_override `$symbol` ← #$artifactId$s';
      case ClearForcedOverride(:final symbol):
        return 'clear_forced_override `$symbol`';
      case SetPreference(:final symbol, :final artifactId):
        return 'set_preference `$symbol` ← #$artifactId';
      case GenerateCustomHook(:final symbol, :final intent):
        final i = (intent == null || intent.isEmpty) ? '' : ' intent="$intent"';
        return 'generate_custom_hook `$symbol`$i';
      case AdjustIterationCap(:final newValue):
        return 'adjust_iteration_cap → $newValue';
    }
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
