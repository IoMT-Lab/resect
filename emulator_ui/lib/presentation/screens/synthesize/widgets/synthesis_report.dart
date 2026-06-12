import 'package:emulator_orchestrator/data/models/fidelity_result.dart';
import 'package:emulator_orchestrator/data/models/synthesis_manifest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';

/// Post-synthesis metrics report for the Synthesize tab.
///
/// Surfaces the full fidelity breakdown (overall, coverage, coverage fidelity,
/// subgraph, and the intact/degraded/hooked counts) plus a run summary and the
/// list of substituted functions. Exporting lives in the Publish tab — this
/// report is metrics-only.
class SynthesisReport extends ConsumerWidget {
  const SynthesisReport({super.key});

  static Color _fidelityColor(double pct) {
    if (pct >= 0.8) return const Color(0xFF66BB6A);
    if (pct >= 0.5) return const Color(0xFFFFA726);
    return const Color(0xFFE57373);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(synthesisResultProvider);
    final fidelity = ref.watch(fidelityResultProvider);
    if (result == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Run summary
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _SummaryStat(label: 'Iterations', value: '${result.totalIterations}'),
            const SizedBox(width: 28),
            _SummaryStat(
                label: 'Hooks Applied',
                value: '${result.resolvedHooks.length}'),
            const SizedBox(width: 28),
            _SummaryStat(
                label: 'Duration', value: '${result.totalDuration.inSeconds}s'),
          ],
        ),

        if (fidelity != null) ...[
          const SizedBox(height: 16),
          _buildFidelityDisplay(fidelity),
        ],

        if (!result.success && result.failedSymbol != null) ...[
          const SizedBox(height: 10),
          Text(
            'Failed at: ${result.failedSymbol}',
            style: TextStyle(fontSize: 12, color: Colors.red.shade300),
          ),
        ],

        if (result.manifest != null && result.manifest!.decisions.isNotEmpty) ...[
          const SizedBox(height: 16),
          _ManifestSection(manifest: result.manifest!),
        ],

        if (result.resolvedHooks.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'SUBSTITUTED FUNCTIONS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppTheme.textMuted,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppTheme.bgCanvas,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: AppTheme.border),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in result.resolvedHooks.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(Icons.functions,
                            size: 12, color: Colors.red.shade400),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            entry.key,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: AppTheme.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _HookSourceTag.fromHookName(entry.value),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward,
                            size: 10, color: AppTheme.textDisabled),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            entry.value,
                            style: TextStyle(
                                fontSize: 11, color: Colors.green.shade400),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFidelityDisplay(FidelityResult fidelity) {
    final pct = fidelity.overallFidelity;
    final color = _fidelityColor(pct);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.bgCanvas,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${(pct * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: color,
                  height: 1,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'FIDELITY',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textMuted,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: pct,
                backgroundColor: AppTheme.border,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          if (fidelity.coverage != null ||
              fidelity.coverageFidelity != null ||
              fidelity.subgraphFidelity != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                if (fidelity.coverage != null)
                  _SecondaryMetric(
                    value: fidelity.coverage!,
                    label: 'COVERAGE',
                    detail:
                        '${fidelity.traversedFunctions}/${fidelity.totalFunctions}',
                  ),
                if (fidelity.coverageFidelity != null)
                  _SecondaryMetric(
                    value: fidelity.coverageFidelity!,
                    label: 'COVERAGE FIDELITY',
                  ),
                if (fidelity.subgraphFidelity != null)
                  _SecondaryMetric(
                    value: fidelity.subgraphFidelity!,
                    label: 'SUBGRAPH FIDELITY',
                    detail: '${fidelity.subgraphFunctions}',
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '${fidelity.intactFunctions} intact · '
            '${fidelity.degradedFunctions} degraded · '
            '${fidelity.hookedFunctions} hooked',
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  const _SummaryStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
          Text(label,
              style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
        ],
      );
}

/// Small colored pill that labels where a resolved hook came from.
///
/// The synthesizer pre-seeds hooks with stable suffixed aliases (see
/// [SynthesizerWorkflow]) — this widget keys off those suffixes:
/// - `_override`  → forced override (user set via metadata sidebar)
/// - `_comms`     → comms-bus virtualization (bus hook or return0 fill-in)
/// - `_resolved`  → warm-start cache (a previous successful synthesis run)
/// - `_hook_<n>`  → discovered by the synthesizer this run
///
/// Showing the source per row is the easiest way to see, at a glance,
/// whether Virtualize-i2c (or any other gate) actually changed the
/// hook set on a given run.
class _HookSourceTag extends StatelessWidget {
  final String label;
  final Color color;
  const _HookSourceTag({required this.label, required this.color});

  factory _HookSourceTag.fromHookName(String hookName) {
    if (hookName.endsWith('_override')) {
      return const _HookSourceTag(
        label: 'OVERRIDE',
        color: Color(0xFFFFB74D),
      );
    }
    if (hookName.endsWith('_comms')) {
      return const _HookSourceTag(
        label: 'COMMS',
        color: Color(0xFF4FC3F7),
      );
    }
    if (hookName.endsWith('_resolved')) {
      return const _HookSourceTag(
        label: 'CACHED',
        color: Color(0xFFA5D6A7),
      );
    }
    return const _HookSourceTag(
      label: 'SYNTH',
      color: Color(0xFF81C784),
    );
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 1,
          ),
        ),
      );
}

/// "Decision provenance" panel — renders the per-symbol decisions
/// from the synthesis manifest with kind + source + fidelity +
/// prior-attempts count + LLM telemetry. Distinct from the
/// SUBSTITUTED FUNCTIONS list above: that one names the *hook*; this
/// one explains *why* the synthesizer picked it.
class _ManifestSection extends StatelessWidget {
  const _ManifestSection({required this.manifest});
  final SynthesisManifest manifest;

  @override
  Widget build(BuildContext context) {
    final kindCounts = <ManifestDecisionKind, int>{};
    for (final d in manifest.decisions) {
      kindCounts.update(d.decisionKind, (v) => v + 1, ifAbsent: () => 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'DECISION PROVENANCE',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppTheme.textMuted,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _kindSummary(kindCounts),
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppTheme.bgCanvas,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppTheme.border),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in manifest.decisions)
                _ManifestDecisionRow(decision: d),
            ],
          ),
        ),
      ],
    );
  }

  static String _kindSummary(Map<ManifestDecisionKind, int> counts) {
    if (counts.isEmpty) return '';
    final parts = <String>[];
    for (final kind in ManifestDecisionKind.values) {
      final n = counts[kind];
      if (n != null && n > 0) parts.add('$n ${kind.jsonName}');
    }
    return parts.join(' · ');
  }
}

class _ManifestDecisionRow extends StatelessWidget {
  const _ManifestDecisionRow({required this.decision});
  final ManifestDecision decision;

  @override
  Widget build(BuildContext context) {
    final priorCount = decision.previousAttempts?.length ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              decision.symbol,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AppTheme.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _DecisionKindTag(kind: decision.decisionKind),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Text(
              _detailLine(decision, priorCount),
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textMuted,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static String _detailLine(ManifestDecision d, int priorCount) {
    final parts = <String>[d.decisionSource];
    if (d.fidelityAtDecision != null) {
      parts.add('fid ${d.fidelityAtDecision!.toStringAsFixed(2)}');
    }
    if (d.iterationIndex != null) {
      parts.add('iter ${d.iterationIndex}');
    }
    if (priorCount > 0) {
      parts.add('after $priorCount failed ${priorCount == 1 ? 'try' : 'tries'}');
    }
    if (d.llmInvocation != null) {
      parts.add(d.llmInvocation!.model);
    }
    return parts.join(' · ');
  }
}

class _DecisionKindTag extends StatelessWidget {
  const _DecisionKindTag({required this.kind});
  final ManifestDecisionKind kind;

  static const _palette = <ManifestDecisionKind, Color>{
    ManifestDecisionKind.forcedOverride: Color(0xFFFFB74D),
    ManifestDecisionKind.comms: Color(0xFF4FC3F7),
    ManifestDecisionKind.warmStart: Color(0xFFA5D6A7),
    ManifestDecisionKind.binding: Color(0xFF81C784),
    ManifestDecisionKind.iterationFallback: Color(0xFF90A4AE),
    ManifestDecisionKind.llmOnDemand: Color(0xFFCE93D8),
  };

  static const _shortLabel = <ManifestDecisionKind, String>{
    ManifestDecisionKind.forcedOverride: 'OVERRIDE',
    ManifestDecisionKind.comms: 'COMMS',
    ManifestDecisionKind.warmStart: 'WARM',
    ManifestDecisionKind.binding: 'BINDING',
    ManifestDecisionKind.iterationFallback: 'FALLBACK',
    ManifestDecisionKind.llmOnDemand: 'LLM',
  };

  @override
  Widget build(BuildContext context) {
    final color = _palette[kind] ?? AppTheme.textMuted;
    final label = _shortLabel[kind] ?? kind.jsonName.toUpperCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _SecondaryMetric extends StatelessWidget {
  final double value;
  final String label;
  final String? detail;
  const _SecondaryMetric({required this.value, required this.label, this.detail});

  @override
  Widget build(BuildContext context) {
    final color = SynthesisReport._fidelityColor(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${(value * 100).toStringAsFixed(1)}%',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color),
            ),
            const SizedBox(width: 4),
            Text(
              detail != null ? '$label ($detail)' : label,
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: AppTheme.textMuted,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        SizedBox(
          width: 100,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 3,
              child: LinearProgressIndicator(
                value: value,
                backgroundColor: AppTheme.border,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
