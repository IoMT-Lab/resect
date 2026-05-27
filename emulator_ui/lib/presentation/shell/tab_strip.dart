import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/app_providers.dart';

/// Lightroom-inspired top tab strip.
///
/// Renders the five [ResectTab] entries as all-caps, letter-spaced labels.
/// The active tab gets a 2px accent underline; "not ready" tabs (those
/// whose prerequisites aren't met yet) are dimmed but still clickable.
class TabStrip extends ConsumerWidget {
  const TabStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
      height: 44,
      color: AppTheme.bgChrome,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Identity (left)
          const Text(
            'RESECT',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.0,
            ),
          ),
          const Spacer(),
          // Tab labels (right)
          for (final tab in ResectTab.values) ...[
            _TabLabel(tab: tab),
            if (tab != ResectTab.values.last)
              const SizedBox(width: AppTheme.tabGutter),
          ],
        ],
      ),
    );
}

class _TabLabel extends ConsumerWidget {
  final ResectTab tab;
  const _TabLabel({required this.tab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readiness = ref.watch(tabReadinessProvider(tab));
    final active = readiness == TabReadiness.active;
    final ready = readiness != TabReadiness.notReady;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => ref.read(activeTabProvider.notifier).state = tab,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? AppTheme.accent : Colors.transparent,
                width: AppTheme.tabUnderlineThickness,
              ),
            ),
          ),
          child: Text(
            tab.label.toUpperCase(),
            style: AppTheme.tabLabel(active: active, ready: ready),
          ),
        ),
      ),
    );
  }
}
