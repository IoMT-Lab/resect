import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';

/// Shown in the Call Graph tab when no ELF is loaded.
///
/// Offers two ways forward — open an emulator project from Library, or
/// just open an ELF for inspection without creating an emulator.
class CallGraphEmptyState extends ConsumerWidget {
  const CallGraphEmptyState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasEmulator = ref.watch(currentEmulatorProvider) != null;

    return Container(
      color: AppTheme.bgCanvas,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'CALL GRAPH',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: 4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              hasEmulator
                  ? 'This emulator project has no firmware ELF set. Open an '
                      'ELF for inspection or set one from the Library tab.'
                  : 'Open an emulator project from the Library tab, or '
                      'open an ELF directly here for inspection-only viewing.',
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 13,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!hasEmulator) ...[
                  OutlinedButton.icon(
                    onPressed: () => ref.read(activeTabProvider.notifier).state =
                        ResectTab.library,
                    icon: const Icon(Icons.folder_outlined, size: 14),
                    label: const Text('Go to Library'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textPrimary,
                      side: const BorderSide(color: AppTheme.border),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                ElevatedButton.icon(
                  onPressed: () => _openElfFile(ref),
                  icon: const Icon(Icons.file_open_outlined, size: 14),
                  label: const Text('Open ELF for inspection'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openElfFile(WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      dialogTitle: 'Open ELF for inspection',
    );
    if (result == null || result.files.single.path == null) return;
    ref.read(selectedElfPathProvider.notifier).state = result.files.single.path;
  }
}
