import 'dart:math' as math;

import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../../widgets/synthesis_visuals.dart';

/// Pre-flight summary above the Run Synthesis button.
///
/// v4 design notes:
///   - Plain-language vocabulary (Ready / Hook candidates / Needs
///     discovery) instead of synthesizer-internal terms.
///   - Three-stat headline (Ready / Hook candidates / Needs discovery);
///     the per-run summary lives in the separate LastRunCard.
///   - Taller coverage bar; two-tone amber + two-tone grey.
///   - No disclosure-card chrome — saved hooks land as an inline tag
///     grid and the hook-candidates pool collapses to a single
///     sentence with a "Show full list" affordance for power users.
class PreSynthesisReport extends ConsumerWidget {
  const PreSynthesisReport({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(hookDecisionStateProvider);
    if (state == null) return const SizedBox.shrink();

    final callgraphAsync = ref.watch(callgraphProvider);
    final totalSymbols = callgraphAsync.maybeWhen(
      data: (g) => g?.symbols.length ?? state.decisions.length,
      orElse: () => state.decisions.length,
    );

    final readyHooks = <HookDecision>[];
    final candidates = <HookDecision>[];
    final preferenceOnly = <HookDecision>[];
    var candidatesHighFidelity = 0;
    final familyCounts = <String, int>{};
    for (final d in state.decisions) {
      switch (d.kind) {
        case HookDecisionKind.override:
        case HookDecisionKind.comms:
        case HookDecisionKind.resolved:
          readyHooks.add(d);
        case HookDecisionKind.binding:
          candidates.add(d);
          if ((d.fidelity ?? 0.0) >= 0.5) candidatesHighFidelity++;
          final family = _family(d.provenance ?? '(unattributed)');
          familyCounts[family] = (familyCounts[family] ?? 0) + 1;
        case HookDecisionKind.none:
          preferenceOnly.add(d);
      }
    }
    final candidatesLowFidelity = candidates.length - candidatesHighFidelity;

    // Split the "uncovered" remainder into reachable-from-entry (these
    // can fault during execution) vs unused code (unreachable from
    // Reset_Handler / main — never runs, never affects synthesis).
    final reachable = ref.watch(reachableSymbolsProvider);
    final decisionSymbols = {for (final d in state.decisions) d.symbol};
    final unbound = math.max(0, totalSymbols - state.decisions.length);
    final int needsDiscovery;
    final int unusedCode;
    if (reachable.isEmpty) {
      needsDiscovery = unbound;
      unusedCode = 0;
    } else {
      var ur = 0;
      for (final s in reachable) {
        if (!decisionSymbols.contains(s)) ur++;
      }
      needsDiscovery = ur;
      unusedCode = math.max(0, unbound - needsDiscovery);
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(elfHash: state.elfHash, totalSymbols: totalSymbols),
          const SizedBox(height: 16),
          _StatRow(
            readyCount: readyHooks.length,
            candidatesCount: candidates.length,
            needsDiscoveryCount: needsDiscovery,
          ),
          const SizedBox(height: 18),
          _CoverageBar(
            ready: readyHooks.length,
            candidatesHigh: candidatesHighFidelity,
            candidatesLow: candidatesLowFidelity,
            needsDiscovery: needsDiscovery,
            unusedCode: unusedCode,
          ),
          const SizedBox(height: 20),
          _ReadyHooksSection(decisions: readyHooks),
          const SizedBox(height: 14),
          _CandidatesSummary(
            count: candidates.length,
            highFidelity: candidatesHighFidelity,
            lowFidelity: candidatesLowFidelity,
            familyCounts: familyCounts,
            decisions: candidates,
          ),
          if (preferenceOnly.isNotEmpty) ...[
            const SizedBox(height: 10),
            _PreferenceOnlyFooter(count: preferenceOnly.length),
          ],
        ],
      ),
    );
  }

  /// Top-level "who produced this hook" bucket. The leading
  /// colon-segment of the provenance string, or the whole string when
  /// there is no colon (`user`, `harness+judge`).
  static String _family(String p) {
    final firstColon = p.indexOf(':');
    return firstColon < 0 ? p : p.substring(0, firstColon);
  }
}

// ---------------------------------------------------------------------------
// Header (title + elfHash)
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.elfHash, required this.totalSymbols});
  final String elfHash;
  final int totalSymbols;

  @override
  Widget build(BuildContext context) {
    final hash = elfHash.isEmpty
        ? '(firmware not yet processed)'
        : 'elfHash ${elfHash.substring(0, 8)}…';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        const Text(
          'PRE-SYNTHESIS REVIEW',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '$totalSymbols functions · $hash',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Three-stat headline
// ---------------------------------------------------------------------------

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.readyCount,
    required this.candidatesCount,
    required this.needsDiscoveryCount,
  });

  final int readyCount;
  final int candidatesCount;
  final int needsDiscoveryCount;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          SummaryStat(
            label: 'Ready',
            value: '$readyCount',
            valueColor: CoverageColors.preApplied,
          ),
          SummaryStat(
            label: 'Hook candidates',
            value: '$candidatesCount',
            valueColor: CoverageColors.binding,
          ),
          SummaryStat(
            label: 'Needs discovery',
            value: '$needsDiscoveryCount',
            valueColor: needsDiscoveryCount > 0
                ? CoverageColors.unbound
                : AppTheme.textPrimary,
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Coverage bar (tall, full-width, four/five-segment)
// ---------------------------------------------------------------------------

class _CoverageBar extends StatelessWidget {
  const _CoverageBar({
    required this.ready,
    required this.candidatesHigh,
    required this.candidatesLow,
    required this.needsDiscovery,
    required this.unusedCode,
  });
  final int ready;
  final int candidatesHigh;
  final int candidatesLow;
  final int needsDiscovery;
  final int unusedCode;

  @override
  Widget build(BuildContext context) {
    final candidates = candidatesHigh + candidatesLow;
    final total = ready + candidates + needsDiscovery + unusedCode;
    if (total == 0) return const SizedBox.shrink();
    final unusedColor = CoverageColors.unbound.withValues(alpha: 0.35);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 18,
            child: Row(
              children: [
                if (ready > 0)
                  Expanded(
                    flex: ready,
                    child: Container(color: CoverageColors.preApplied),
                  ),
                if (candidatesHigh > 0)
                  Expanded(
                    flex: candidatesHigh,
                    child: Container(color: CoverageColors.bindingHigh),
                  ),
                if (candidatesLow > 0)
                  Expanded(
                    flex: candidatesLow,
                    child: Container(color: CoverageColors.bindingLow),
                  ),
                if (needsDiscovery > 0)
                  Expanded(
                    flex: needsDiscovery,
                    child: Container(color: CoverageColors.unbound),
                  ),
                if (unusedCode > 0)
                  Expanded(
                    flex: unusedCode,
                    child: Container(color: unusedColor),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 18,
          runSpacing: 4,
          children: [
            _LegendChip(
              color: CoverageColors.preApplied,
              label: 'Ready · $ready (${_pct(ready, total)}%)',
            ),
            _LegendChip(
              color: CoverageColors.bindingHigh,
              label: 'Hook candidates · $candidates '
                  '(${_pct(candidates, total)}%) · '
                  '$candidatesHigh high / $candidatesLow low',
            ),
            _LegendChip(
              color: CoverageColors.unbound,
              label: 'Needs discovery · $needsDiscovery '
                  '(${_pct(needsDiscovery, total)}%)',
            ),
            if (unusedCode > 0)
              _LegendChip(
                color: unusedColor,
                label:
                    'Unused code · $unusedCode (${_pct(unusedCode, total)}%)',
              ),
          ],
        ),
      ],
    );
  }

  static String _pct(int n, int total) =>
      (100 * n / total).toStringAsFixed(n * 100 % total == 0 ? 0 : 1);
}

class _LegendChip extends StatelessWidget {
  const _LegendChip({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Ready hooks — inline tag grid, no card chrome
// ---------------------------------------------------------------------------

class _ReadyHooksSection extends StatelessWidget {
  const _ReadyHooksSection({required this.decisions});
  final List<HookDecision> decisions;

  @override
  Widget build(BuildContext context) {
    if (decisions.isEmpty) {
      return const Text(
        'Ready hooks: none — synthesis will iterate from scratch.',
        style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
      );
    }
    final overrides =
        decisions.where((d) => d.kind == HookDecisionKind.override).toList();
    final comms =
        decisions.where((d) => d.kind == HookDecisionKind.comms).toList();
    final resolved =
        decisions.where((d) => d.kind == HookDecisionKind.resolved).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label: 'Ready hooks', count: decisions.length),
        const SizedBox(height: 6),
        if (overrides.isNotEmpty) ...[
          _SubLabel(text: 'Locked overrides · ${overrides.length}'),
          _SymbolWrap(decisions: overrides),
          const SizedBox(height: 6),
        ],
        if (comms.isNotEmpty) ...[
          _SubLabel(text: 'Comms bus hooks · ${comms.length}'),
          _SymbolWrap(decisions: comms),
          const SizedBox(height: 6),
        ],
        if (resolved.isNotEmpty)
          _WarmStartGrouped(decisions: resolved),
      ],
    );
  }
}

/// Inline symbol tag grid for [decisions]. No body preview — the
/// symbol name carries the relevant signal.
class _SymbolWrap extends StatelessWidget {
  const _SymbolWrap({required this.decisions});
  final List<HookDecision> decisions;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final d in decisions)
            Text(
              d.symbol,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
        ],
      );
}

/// Warm-start (carryover) hooks grouped by body shape so projects
/// where every saved hook returns 0 don't render eight identical
/// preview rows. Each group renders as `N hooks → <last-line>` + the
/// symbol tag grid.
class _WarmStartGrouped extends StatelessWidget {
  const _WarmStartGrouped({required this.decisions});
  final List<HookDecision> decisions;

  @override
  Widget build(BuildContext context) {
    final byShape = <String, List<HookDecision>>{};
    for (final d in decisions) {
      final shape = _shape(d.body ?? '');
      byShape.putIfAbsent(shape, () => []).add(d);
    }
    final shapes = byShape.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SubLabel(text: 'From last run · ${decisions.length}'),
        for (final entry in shapes) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              '${entry.value.length} hook${entry.value.length == 1 ? '' : 's'}'
              '  →  ${entry.key}',
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ),
          _SymbolWrap(decisions: entry.value),
        ],
      ],
    );
  }

  static String _shape(String body) {
    final lines =
        body.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return '(empty)';
    final last = lines.last.trim();
    if (last.length > 80) return '${last.substring(0, 77)}…';
    return last;
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: CoverageColors.preApplied,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '· $count',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ],
      );
}

class _SubLabel extends StatelessWidget {
  const _SubLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
        child: Text(
          text,
          style: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Hook candidates — one-line summary + "Show full list"
// ---------------------------------------------------------------------------

class _CandidatesSummary extends StatelessWidget {
  const _CandidatesSummary({
    required this.count,
    required this.highFidelity,
    required this.lowFidelity,
    required this.familyCounts,
    required this.decisions,
  });

  final int count;
  final int highFidelity;
  final int lowFidelity;
  final Map<String, int> familyCounts;
  final List<HookDecision> decisions;

  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return const Text(
        'Hook candidates: none — synthesis will use built-in templates only.',
        style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: CoverageColors.binding,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Hook candidates',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '· $count',
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  _summary(),
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => _showFullList(context),
                icon: const Icon(Icons.list_alt, size: 14),
                label: const Text(
                  'Show full list',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _summary() {
    // Build a plain-language sentence: "All N classifier-generated"
    // when the pool is single-family; otherwise list contributors.
    final entries = familyCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final source = entries.length == 1
        ? '${_familyLabel(entries.single.key)}-generated'
        : entries
            .take(3)
            .map((e) => '${e.value} ${_familyLabel(e.key)}')
            .join(', ');
    final fidelityHalf = '$highFidelity high-confidence, '
        '$lowFidelity low-confidence';
    return 'All $count $source — $fidelityHalf. '
        'Synthesis tries these in order when execution faults.';
  }

  static String _familyLabel(String family) {
    switch (family) {
      case 'classifier':
        return 'classifier';
      case 'llm':
        return 'LLM';
      case 'user':
        return 'user-authored';
      case 'harness':
      case 'harness+judge':
        return 'harness-verified';
      default:
        return family;
    }
  }

  void _showFullList(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bgPanel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      'Hook candidates ($count)',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      color: AppTheme.textMuted,
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.builder(
                    itemCount: decisions.length,
                    itemBuilder: (_, i) {
                      final d = decisions[i];
                      final parts = <String>['artifact #${d.artifactId}'];
                      if (d.fidelity != null) {
                        parts.add(
                            'fidelity ${d.fidelity!.toStringAsFixed(2)}');
                      }
                      if (d.provenance != null) parts.add(d.provenance!);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                d.symbol,
                                style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: Text(
                                parts.join(' · '),
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preference-only footer
// ---------------------------------------------------------------------------

class _PreferenceOnlyFooter extends StatelessWidget {
  const _PreferenceOnlyFooter({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, left: 16),
        child: Text(
          '+ $count function${count == 1 ? '' : 's'} have a preference hint '
          '(no other overlay — synthesis tries the preferred candidate first).',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
        ),
      );
}
