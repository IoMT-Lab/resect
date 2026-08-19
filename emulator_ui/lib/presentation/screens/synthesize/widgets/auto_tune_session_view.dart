import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/auto_tune_session_provider.dart';
import '../../../widgets/metric_trajectory_chart.dart';
import '../../../widgets/synthesis_visuals.dart';

/// The session's chart series, derived once from the per-round records.
/// Shared by [AutoTuneSessionView] and the modal's live chart.
List<TrajectoryRound> sessionTrajectory(AutoTuneSessionState session) {
  final best = session.bestRound;
  return [
    for (final r in session.rounds)
      TrajectoryRound(
        round: r.round,
        fidelity: r.manifest.metrics?.overallFidelity ?? 0,
        coverageFidelity: r.manifest.metrics?.coverageFidelity,
        coverage: r.manifest.metrics?.coverageRatio,
        reverted: r.reverted,
        best: r.round == best,
      ),
  ];
}

/// The auto-tune session results view — everything below comes from the
/// generated per-round records (manifests + project snapshots), never
/// recomputed in the UI:
///   1. line chart of Fidelity / Coverage fidelity / Coverage per round
///   2. the session metric band (cumulative times, time split, first
///      stop, artifact census)
///   3. a compact per-round report (expandable tiles)
/// Rendered live in the auto-tune modal as rounds arrive, and in the
/// Synthesize tab after (and across reopens — sessions rehydrate from
/// `autotune_reports/`).
class AutoTuneSessionView extends ConsumerWidget {
  const AutoTuneSessionView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(autoTuneSessionProvider);
    if (session == null || session.rounds.isEmpty) {
      return const SizedBox.shrink();
    }
    final labels = ref.watch(artifactLabelsProvider).valueOrNull ?? const {};
    final best = session.bestRound;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(session),
          const SizedBox(height: 12),
          MetricTrajectoryChart(
            rounds: sessionTrajectory(session),
            maxRound: session.maxRounds,
          ),
          const SizedBox(height: 16),
          _metricsBand(session),
          const SizedBox(height: 16),
          _compactReport(session, labels, best),
        ],
      ),
    );
  }

  Widget _header(AutoTuneSessionState session) {
    final status = session.live
        ? 'running · round ${session.rounds.last.round}'
        : [
            if (session.stopReason != null) session.stopReason!,
            if (session.bestRound != null)
              'holding round ${session.bestRound} overlays',
          ].join(' · ');
    return Row(children: [
      const Text(
        'AUTO-TUNE SESSION',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 2.5,
          color: AppTheme.textPrimary,
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          status,
          style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }

  // Old manifests carry no recorded total — null ratio, gap in the
  // series.
  static double? _coverage(SynthesisManifest m) => m.metrics?.coverageRatio;

  // -- Metrics band ----------------------------------------------------------

  Widget _metricsBand(AutoTuneSessionState session) {
    var synth = 0.0, selection = 0.0, generation = 0.0, advisor = 0.0;
    for (final r in session.rounds) {
      synth += r.manifest.result.durationSeconds;
      final pt = r.manifest.phaseTimings;
      if (pt != null) {
        selection += pt.selectionSeconds;
        generation += pt.generationSeconds + (pt.roundHookGenSeconds ?? 0);
        advisor += pt.advisorSeconds ?? 0;
      }
    }
    final lastStops = session.rounds.last.manifest.stops;
    final firstStop =
        (lastStops != null && lastStops.isNotEmpty) ? lastStops.first : null;
    ArtifactCensus? census;
    for (final r in session.rounds.reversed) {
      census = r.manifest.census;
      if (census != null) break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 28,
          runSpacing: 12,
          alignment: WrapAlignment.spaceEvenly,
          children: [
            SummaryStat(label: 'SYNTHESIS TIME', value: _secs(synth)),
            SummaryStat(label: 'HOOK SELECTION', value: _secs(selection)),
            SummaryStat(label: 'HOOK GENERATION', value: _secs(generation)),
            SummaryStat(label: 'ADVISOR', value: _secs(advisor)),
            SummaryStat(
              label: 'FIRST STOP (LAST ROUND)',
              value: firstStop == null ? '—' : _secs(firstStop.elapsedSeconds),
              valueColor:
                  firstStop == null ? AppTheme.textMuted : AppTheme.textPrimary,
            ),
          ],
        ),
        if (census != null) ...[
          const SizedBox(height: 12),
          Text(
            'Artifacts feeding synthesis: ${census.total} — '
            '${census.hookArtifacts} hooks (whole catalog) · '
            '${census.commsAssignments} comms · '
            '${census.groupMembers} grouped · '
            '${census.signatures} signatures · '
            '${census.decompilations} decompilations · '
            '${census.ragChunksTotal} RAG chunks',
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ],
      ],
    );
  }

  // -- Compact report ----------------------------------------------------------

  Widget _compactReport(AutoTuneSessionState session, Map<int, String> labels,
          int? best) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in session.rounds)
            _roundTile(r, labels, r.round == best),
        ],
      );

  Widget _roundTile(
      AutoTuneSessionRoundRecord r, Map<int, String> labels, bool best) {
    final m = r.manifest;
    final metrics = m.metrics;
    final cov = _coverage(m);
    final stops = m.stops ?? const <StopTiming>[];
    final headerParts = [
      _outcome(m),
      if (metrics != null) 'fid ${metrics.overallFidelity.toStringAsFixed(3)}',
      if (cov != null) 'cov ${(cov * 100).toStringAsFixed(1)}%',
      _secs(m.result.durationSeconds),
      if (stops.isNotEmpty) 'first stop ${_secs(stops.first.elapsedSeconds)}',
    ].join('  ·  ');

    return Theme(
      // Kill the ExpansionTile's dividers so tiles read as one list.
      data: ThemeData.dark().copyWith(dividerColor: Colors.transparent),
      // The tile paints ink on the nearest Material — give it a
      // transparent one so the panel's decorated background stays.
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
        title: Row(children: [
          Text(
            'R${r.round}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(width: 10),
          if (best) _badge('BEST', const Color(0xFF66BB6A)),
          if (r.reverted) _badge('REVERTED', const Color(0xFFE57373)),
          if (r.warnings.isNotEmpty)
            _badge('⚠ ${r.warnings.length}', const Color(0xFFFFA726)),
          Expanded(
            child: Text(
              headerParts,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AppTheme.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
          children: [_roundBody(r, labels)],
        ),
      ),
    );
  }

  Widget _roundBody(AutoTuneSessionRoundRecord r, Map<int, String> labels) {
    final m = r.manifest;
    final snapshot = r.snapshot;
    final recs = snapshot?.llmRecommendations;
    final rejected = <Recommendation>{
      for (final d in snapshot?.userDecisions ?? const <RecommendationDecision>[])
        if (d.action.name == 'rejected') d.original,
    };
    final stops = m.stops ?? const <StopTiming>[];
    final pt = m.phaseTimings;
    final lines = <Widget>[];

    void addLine(String text, {Color color = AppTheme.textMuted}) {
      lines.add(Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, fontFamily: 'monospace', color: color)),
      ));
    }

    // What changed going in.
    if (r.round == 0) {
      addLine('Baseline synthesis — pre-seeded overlays only.');
    } else if (recs == null) {
      addLine('What changed: (snapshot pruned — see the round report file)');
    } else if (recs.isEmpty) {
      addLine('What changed: model returned no recommendations.');
    } else {
      addLine('What changed going in:', color: AppTheme.textPrimary);
      for (final rec in recs) {
        addLine('  ${_recLine(rec, labels)}'
            '${rejected.contains(rec) ? '  (rejected in review)' : ''}');
      }
    }
    for (final w in r.warnings) {
      addLine('⚠ $w', color: const Color(0xFFFFA726));
    }

    // Stop log + time split.
    if (stops.isNotEmpty) {
      addLine('Stop log:', color: AppTheme.textPrimary);
      for (final s in stops) {
        addLine('  ${_secs(s.elapsedSeconds)} → ${_stopKind(s.kind)}'
            '${s.symbol != null ? ' at ${s.symbol}' : ''}');
      }
    }
    if (pt != null) {
      addLine('Time split: selection ${_secs(pt.selectionSeconds)} · '
          'generation ${_secs(pt.generationSeconds + (pt.roundHookGenSeconds ?? 0))}'
          '${pt.advisorSeconds != null ? ' · advisor ${_secs(pt.advisorSeconds!)}' : ''}');
    }

    // Why it stopped.
    if (m.result.success) {
      addLine('Ran cleanly — no unhandled accesses left.');
    } else if (m.failedSymbol != null) {
      addLine('Halted at ${m.failedSymbol} — hook candidates exhausted.',
          color: const Color(0xFFE57373));
    } else if (m.lastPauseSymbol != null) {
      addLine('Last pause at ${m.lastPauseSymbol}.');
    }

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: lines);
  }

  // -- Small helpers -----------------------------------------------------------

  Widget _badge(String text, Color color) => Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w600, color: color)),
      );

  static String _outcome(SynthesisManifest m) {
    if (m.result.success) return 'success';
    if (m.failedSymbol != null) return 'failed @${m.failedSymbol}';
    if (m.lastPauseSymbol != null) return 'halted @${m.lastPauseSymbol}';
    return 'no-converge';
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

  /// Label-first recommendation line, matching the report writer's
  /// rendering (`set_forced_override sym ← "Return 1" (#2)`).
  static String _recLine(Recommendation r, Map<int, String> labels) {
    String label(int id) {
      final l = labels[id];
      return l == null ? '#$id' : '"$l" (#$id)';
    }

    switch (r) {
      case SetForcedOverride(:final symbol, :final artifactId, :final scope):
        final s = (scope == null || scope.isEmpty) ? '' : ' scope=$scope';
        return 'set_forced_override $symbol ← ${label(artifactId)}$s';
      case ClearForcedOverride(:final symbol):
        return 'clear_forced_override $symbol';
      case SetPreference(:final symbol, :final artifactId):
        return 'set_preference $symbol ← ${label(artifactId)}';
      case GenerateCustomHook(:final symbol):
        return 'generate_custom_hook $symbol';
      case AdjustIterationCap(:final newValue):
        return 'adjust_iteration_cap → $newValue';
      case SetGroupOverride(:final scope):
        return 'set_group_override $scope';
      case ClearGroupOverride(:final scope):
        return 'clear_group_override $scope';
    }
  }
}
