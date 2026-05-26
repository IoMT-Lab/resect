import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';

/// Thin header bar above the Call Graph canvas.
///
/// Shows the currently inspected ELF path and exposes an "Open ELF for
/// inspection" button — the no-emulator-required entry point into call
/// graph viewing. With an emulator loaded, the ELF path is normally
/// synced from the emulator; this button lets you swap it out without
/// modifying the project.
class CallGraphToolbar extends ConsumerWidget {
  const CallGraphToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final elfPath = ref.watch(selectedElfPathProvider);

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppTheme.bgChrome,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined,
              size: 16, color: AppTheme.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              elfPath ?? 'No ELF selected',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: elfPath == null
                    ? AppTheme.textMuted
                    : AppTheme.textPrimary,
                fontSize: 12,
                fontStyle:
                    elfPath == null ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            onPressed: () => _openElfFile(ref),
            icon: const Icon(Icons.file_open_outlined, size: 14),
            label: const Text('Open ELF...'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.textPrimary,
              side: const BorderSide(color: AppTheme.border),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 32),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
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
