import 'package:emulator_orchestrator/data/models/recent_emulator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../library_actions.dart';

/// `[ RECENT ]` list of previously opened emulators.
///
/// Each row is clickable and reopens the emulator. The list watches
/// [recentEmulatorsProvider] and shows nothing when the list is empty.
class RecentList extends ConsumerWidget {
  /// When true, prepend a `[ RECENT ]` section header. Set false when the
  /// list is rendered inside a card that already provides a header.
  final bool showHeader;

  /// Maximum number of recent entries to display.
  final int max;

  const RecentList({
    super.key,
    this.showHeader = false,
    this.max = 10,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentsAsync = ref.watch(recentEmulatorsProvider);

    return recentsAsync.when(
      data: (recents) {
        if (recents.isEmpty) return const SizedBox.shrink();
        final shown = recents.take(max).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader) ...[
              const _SectionHeader('RECENT'),
              const SizedBox(height: 10),
            ],
            for (final entry in shown)
              _RecentRow(
                entry: entry,
                onTap: () => openEmulator(context, ref, path: entry.path),
              ),
          ],
        );
      },
      loading: () => const SizedBox(
        height: 40,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      ),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _RecentRow extends StatelessWidget {
  final RecentEmulator entry;
  final VoidCallback onTap;

  const _RecentRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppTheme.border)),
        ),
        child: Row(
          children: [
            const Icon(Icons.folder_open, size: 14, color: AppTheme.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _formatTimestamp(entry.lastOpened),
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );

  String _formatTimestamp(DateTime ts) {
    final delta = DateTime.now().difference(ts);
    if (delta.inDays >= 1) return '${delta.inDays}d ago';
    if (delta.inHours >= 1) return '${delta.inHours}h ago';
    if (delta.inMinutes >= 1) return '${delta.inMinutes}m ago';
    return 'just now';
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) => Text(
      label,
      style: const TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 3,
      ),
    );
}
