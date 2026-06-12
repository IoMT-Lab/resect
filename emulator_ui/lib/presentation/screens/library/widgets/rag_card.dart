import 'package:emulator_orchestrator/data/models/rag_index_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/config_providers.dart';
import '../library_actions.dart';

/// Card that surfaces the per-project RAG index state — last-built
/// timestamp, chunk-count breakdown, staleness banner, and rebuild
/// controls. Backs onto [ragIndexStatusProvider] (StateProvider that
/// the index service writes to as it (re)builds).
///
/// Collapses to a one-line "install LLM module" pointer when
/// `MODULE_LLM_HOOKGEN=0` so the slot isn't empty for users who
/// haven't opted into the LLM stack.
class RagCard extends ConsumerWidget {
  const RagCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final llmEnabled = ref.watch(moduleEnabledProvider('MODULE_LLM_HOOKGEN'));
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
      ),
      child: llmEnabled
          ? const _RagCardEnabled()
          : const _RagCardDisabled(),
    );
  }
}

class _RagCardDisabled extends StatelessWidget {
  const _RagCardDisabled();

  @override
  Widget build(BuildContext context) => const Row(
        children: [
          Icon(Icons.auto_awesome, size: 14, color: AppTheme.textMuted),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'RAG INDEX  ·  install the LLM module in System '
              'Configuration to enable hook-generation context.',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      );
}

class _RagCardEnabled extends ConsumerWidget {
  const _RagCardEnabled();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(ragIndexStatusProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              'RAG INDEX',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 3,
              ),
            ),
            const Spacer(),
            if (status.isInProgress)
              OutlinedButton.icon(
                onPressed: () => cancelRagIndex(context, ref),
                icon: const Icon(Icons.stop, size: 14),
                label: const Text('Cancel'),
                style: _buttonStyle,
              )
            else
              OutlinedButton.icon(
                onPressed: () => rebuildRagIndex(context, ref),
                icon: const Icon(Icons.refresh, size: 14),
                label: Text(status.neverBuilt ? 'Build' : 'Rebuild'),
                style: _buttonStyle,
              ),
          ],
        ),
        const SizedBox(height: 14),
        _StatusLine(status: status),
        const SizedBox(height: 8),
        _CountsLine(status: status),
        if (status.isStale && !status.isInProgress) ...[
          const SizedBox(height: 12),
          _StaleBanner(count: status.staleSourceCount),
        ],
      ],
    );
  }

  static final ButtonStyle _buttonStyle = OutlinedButton.styleFrom(
    foregroundColor: AppTheme.textPrimary,
    side: const BorderSide(color: AppTheme.border),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    minimumSize: const Size(0, 32),
    textStyle: const TextStyle(fontSize: 12),
  );
}

class _StatusLine extends StatelessWidget {
  final RagIndexStatus status;
  const _StatusLine({required this.status});

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = _resolve();
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  (IconData, Color, String) _resolve() {
    if (status.isInProgress) {
      return (
        Icons.sync,
        AppTheme.textPrimary,
        status.inProgressPhase ?? 'Building…',
      );
    }
    if (status.neverBuilt) {
      return (
        Icons.help_outline,
        AppTheme.textMuted,
        'Never built',
      );
    }
    if (status.isStale) {
      return (
        Icons.warning_amber_outlined,
        const Color(0xFFFFB74D),
        'Out of date',
      );
    }
    return (
      Icons.check_circle_outline,
      const Color(0xFF81C784),
      'Up to date · last built ${_relativeTime(status.lastBuiltAt!)}',
    );
  }
}

class _CountsLine extends StatelessWidget {
  final RagIndexStatus status;
  const _CountsLine({required this.status});

  @override
  Widget build(BuildContext context) {
    final parts = <String>['${status.chunkCount} chunks'];
    if (status.chunkCountsByKind.isNotEmpty) {
      final breakdown = status.chunkCountsByKind.entries
          .map((e) => '${e.value} ${e.key}')
          .join(' · ');
      parts.add(breakdown);
    }
    return Text(
      parts.join('  ·  '),
      style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  final int count;
  const _StaleBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    const warn = Color(0xFFFFB74D);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.08),
        border: Border.all(color: warn.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 14, color: warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Index out of date — $count source${count == 1 ? '' : 's'} '
              'changed since last build.',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _relativeTime(DateTime ts) {
  final delta = DateTime.now().difference(ts);
  if (delta.inDays >= 1) return '${delta.inDays}d ago';
  if (delta.inHours >= 1) return '${delta.inHours}h ago';
  if (delta.inMinutes >= 1) return '${delta.inMinutes}m ago';
  return 'just now';
}
