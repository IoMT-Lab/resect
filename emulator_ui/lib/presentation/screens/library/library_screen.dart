import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../providers/app_providers.dart';
import 'widgets/emulator_card.dart';
import 'widgets/library_empty_state.dart';
import 'widgets/recent_list.dart';

/// LIBRARY tab — project / emulator file management.
///
/// Two faces:
///   - empty state: centered two-card CTA (Create / Open) above a Recent
///     list, when no emulator is loaded.
///   - loaded: two-column layout with the loaded emulator's detail card on
///     the left and the Recent list on the right.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emulator = ref.watch(currentEmulatorProvider);
    if (emulator == null) {
      return const LibraryEmptyState();
    }
    return const _LoadedLayout();
  }
}

class _LoadedLayout extends StatelessWidget {
  const _LoadedLayout();

  @override
  Widget build(BuildContext context) => Container(
      color: AppTheme.bgCanvas,
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(flex: 3, child: EmulatorCard()),
            const SizedBox(width: 24),
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppTheme.bgPanel,
                  border: Border.all(color: AppTheme.border),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'RECENT',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 3,
                      ),
                    ),
                    SizedBox(height: 12),
                    RecentList(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
}
