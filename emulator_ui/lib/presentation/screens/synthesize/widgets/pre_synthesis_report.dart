import 'package:emulator_orchestrator/data/models/hook_decision_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';

/// Renders the live [HookDecisionState] for the current project,
/// grouped by overlay kind, as a pre-flight summary above the Run
/// Synthesis button.
///
/// Reactive: edits to `hookOverrides` / `hookOverrideScopes` /
/// `hookPreferences` / `hookBindings` / comms config etc. all
/// propagate through `hookDecisionStateProvider` and re-render the
/// card without an autosave round-trip.
class PreSynthesisReport extends ConsumerWidget {
  const PreSynthesisReport({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(hookDecisionStateProvider);
    if (state == null) return const SizedBox.shrink();
    if (state.decisions.isEmpty) {
      return _NoDecisionsCard(elfHash: state.elfHash);
    }

    final byKind = <HookDecisionKind, List<HookDecision>>{};
    for (final d in state.decisions) {
      byKind.putIfAbsent(d.kind, () => []).add(d);
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
          _Header(state: state, totalSymbols: state.decisions.length),
          const SizedBox(height: 12),
          // Sections in synthesizer dispatch priority order. Skipping
          // a kind means it has no decisions — common for new projects
          // (no overrides yet, no comms config, etc.).
          for (final kind in HookDecisionKind.values)
            if (byKind[kind] != null && byKind[kind]!.isNotEmpty) ...[
              _KindSection(kind: kind, decisions: byKind[kind]!),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state, required this.totalSymbols});
  final HookDecisionState state;
  final int totalSymbols;

  @override
  Widget build(BuildContext context) {
    final hash = state.elfHash.isEmpty
        ? '(firmware not yet processed)'
        : 'elfHash ${state.elfHash.substring(0, 8)}…';
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
          '$totalSymbols symbol${totalSymbols == 1 ? '' : 's'} · $hash',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _NoDecisionsCard extends StatelessWidget {
  const _NoDecisionsCard({required this.elfHash});
  final String elfHash;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppTheme.bgPanel,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.border),
        ),
        padding: const EdgeInsets.all(16),
        child: const Text(
          'No overrides, comms hooks, warm-start hooks, bindings, or '
          'preferences are set for this project. Synthesis will iterate '
          'the artifact-DB candidates for each unhooked symbol using '
          'their intrinsic-score floors.',
          style: TextStyle(
            color: AppTheme.textMuted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      );
}

class _KindSection extends StatelessWidget {
  const _KindSection({required this.kind, required this.decisions});
  final HookDecisionKind kind;
  final List<HookDecision> decisions;

  @override
  Widget build(BuildContext context) {
    final title = _kindTitle(kind, decisions.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _kindSubtitle(kind),
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
        ),
        const SizedBox(height: 6),
        for (final d in decisions) _DecisionRow(decision: d),
      ],
    );
  }

  static String _kindTitle(HookDecisionKind kind, int count) {
    final noun = switch (kind) {
      HookDecisionKind.override => 'Forced overrides',
      HookDecisionKind.comms => 'Comms hooks',
      HookDecisionKind.resolved => 'Warm-start hooks',
      HookDecisionKind.binding => 'Fidelity-scored bindings',
      HookDecisionKind.none => 'Preference-only',
    };
    return '$noun ($count)';
  }

  static String _kindSubtitle(HookDecisionKind kind) => switch (kind) {
        HookDecisionKind.override =>
          'Pre-seeded unconditionally; never iterated past. Fail-fatal.',
        HookDecisionKind.comms =>
          'Protocol-virtualized via the comms-bus server; pre-seeded with the protocol scope.',
        HookDecisionKind.resolved =>
          'Warm-start bodies preserved from a prior successful synthesis run.',
        HookDecisionKind.binding =>
          'Per-symbol compatibility records; drive the iteration-loop sort. Not fail-fatal.',
        HookDecisionKind.none =>
          'Symbols with a preference hint but no other overlay; the preference promotes one artifact to first-try.',
      };
}

class _DecisionRow extends StatelessWidget {
  const _DecisionRow({required this.decision});
  final HookDecision decision;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Text(
                decision.symbol,
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
                _detail(decision),
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      );

  static String _detail(HookDecision d) {
    final parts = <String>[];
    switch (d.kind) {
      case HookDecisionKind.override:
        parts.add('artifact #${d.artifactId}');
        if (d.scope != null) parts.add('scope: ${d.scope}');
      case HookDecisionKind.comms:
        final role = d.role ?? '(fill-zero)';
        parts.add('${d.protocol}/$role');
        if (d.port != null) parts.add('port ${d.port}');
      case HookDecisionKind.resolved:
        final firstLine = (d.body ?? '')
            .split('\n')
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
        parts.add(firstLine.length > 60
            ? '${firstLine.substring(0, 57)}…'
            : firstLine);
      case HookDecisionKind.binding:
        parts.add('artifact #${d.artifactId}');
        if (d.fidelity != null) {
          parts.add('fidelity ${d.fidelity!.toStringAsFixed(2)}');
        }
        if (d.provenance != null) parts.add(d.provenance!);
      case HookDecisionKind.none:
        // Nothing primary — preference is on the right side below.
        break;
    }
    if (d.preferredArtifactId != null) {
      parts.add('preferred: #${d.preferredArtifactId}');
    }
    return parts.join(' · ');
  }
}
