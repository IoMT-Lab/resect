import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../providers/app_providers.dart';
import 'widgets/documents_card.dart';
import 'widgets/emulator_card.dart';
import 'widgets/library_empty_state.dart';
import 'widgets/rag_card.dart';
import 'widgets/recent_list.dart';

/// LIBRARY tab — project / emulator file management.
///
/// Two faces:
///   - empty state: centered two-card CTA (Create / Open) above a Recent
///     list, when no emulator is loaded.
///   - loaded: three-column layout.
///       Left   — project: LOADED EMULATOR on top, RECENT below it.
///       Middle — RAG INDEX status / rebuild.
///       Right  — DOCUMENTS attached to the project.
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

  static const double _cardGap = 16;
  static const double _columnGap = 20;

  @override
  Widget build(BuildContext context) => Container(
        color: AppTheme.bgCanvas,
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1500),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    EmulatorCard(),
                    SizedBox(height: _cardGap),
                    _RecentCard(),
                  ],
                ),
              ),
              SizedBox(width: _columnGap),
              Expanded(
                flex: 2,
                child: RagCard(),
              ),
              SizedBox(width: _columnGap),
              Expanded(
                flex: 3,
                child: DocumentsCard(),
              ),
            ],
          ),
        ),
      );
}

/// The RECENT projects card. Lifted out of [_LoadedLayout] so the left
/// column can stack it under [EmulatorCard] with consistent chrome.
class _RecentCard extends StatelessWidget {
  const _RecentCard();

  @override
  Widget build(BuildContext context) => Container(
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
      );
}
