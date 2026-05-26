import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../library_actions.dart';
import 'recent_list.dart';

/// Shown in the Library tab when no emulator is loaded.
///
/// Two equal CTA cards (Create / Open) above a Recent list (if any).
class LibraryEmptyState extends ConsumerWidget {
  const LibraryEmptyState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: AppTheme.bgCanvas,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'LIBRARY',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Get started by creating a new emulator project or opening an '
              'existing one. A project bundles your firmware ELF, platform '
              'description, and resolved hooks.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: _CtaCard(
                    title: 'Create New Emulator',
                    description:
                        'Start a new project from a firmware ELF and a '
                        'Renode platform description.',
                    actionLabel: 'New',
                    primary: true,
                    onPressed: () => createNewEmulator(context, ref),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _CtaCard(
                    title: 'Open Existing',
                    description:
                        'Resume a saved .emu project file from disk.',
                    actionLabel: 'Open',
                    primary: false,
                    onPressed: () => openEmulator(context, ref),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const RecentList(showHeader: true),
          ],
        ),
      ),
    );
  }
}

class _CtaCard extends StatelessWidget {
  final String title;
  final String description;
  final String actionLabel;
  final bool primary;
  final VoidCallback onPressed;

  const _CtaCard({
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.primary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 2.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: primary
                ? ElevatedButton(
                    onPressed: onPressed,
                    child: Text(actionLabel),
                  )
                : OutlinedButton(
                    onPressed: onPressed,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textPrimary,
                      side: const BorderSide(color: AppTheme.border),
                    ),
                    child: Text(actionLabel),
                  ),
          ),
        ],
      ),
    );
  }
}
