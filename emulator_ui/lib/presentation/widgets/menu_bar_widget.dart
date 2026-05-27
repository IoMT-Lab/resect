import 'package:emulator_orchestrator/core/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme.dart';
import '../../providers/app_providers.dart';
import '../dialogs/system_config_dialog.dart';
import '../dialogs/unsaved_changes_dialog.dart';
import '../screens/library/library_actions.dart';

/// Slim menu bar — File and Help only.
///
/// Tab-specific actions (Open ELF, Close, Exports, Vagrant Test, sidebar
/// toggles, Hook DB) live inside their respective tabs now. The File menu
/// keeps only the cross-tab essentials: New, Open, Save, Save As, Exit.
class MenuBarWidget extends ConsumerWidget {
  const MenuBarWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentEmulator = ref.watch(currentEmulatorProvider);
    final hasEmulator = currentEmulator != null;

    return Container(
      height: AppConstants.menuBarHeight,
      decoration: const BoxDecoration(
        color: AppTheme.bgChrome,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          _MenuBarItem(
            title: 'File',
            items: [
              _MenuItem(
                title: 'New Emulator...',
                shortcut: 'Ctrl+Shift+N',
                onTap: () {
                  ref.read(activeTabProvider.notifier).state = ResectTab.library;
                  createNewEmulator(context, ref);
                },
              ),
              _MenuItem(
                title: 'Open Emulator...',
                shortcut: 'Ctrl+Shift+O',
                onTap: () {
                  ref.read(activeTabProvider.notifier).state = ResectTab.library;
                  openEmulator(context, ref);
                },
              ),
              const _MenuDivider(),
              _MenuItem(
                title: 'Save Emulator',
                shortcut: 'Ctrl+S',
                enabled: hasEmulator,
                onTap: hasEmulator ? () => saveEmulator(context, ref) : () {},
              ),
              _MenuItem(
                title: 'Save Emulator As...',
                shortcut: 'Ctrl+Shift+S',
                enabled: hasEmulator,
                onTap: hasEmulator ? () => saveEmulatorAs(context, ref) : () {},
              ),
              const _MenuDivider(),
              _MenuItem(
                title: 'Exit',
                shortcut: 'Ctrl+Q',
                onTap: () => _exit(context, ref),
              ),
            ],
          ),
          _MenuBarItem(
            title: 'Tools',
            items: [
              _MenuItem(
                title: 'System Configuration...',
                onTap: () => SystemConfigDialog.show(context),
              ),
            ],
          ),
          _MenuBarItem(
            title: 'Help',
            items: [
              _MenuItem(
                title: 'About',
                onTap: () => _showAbout(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Exit, prompting about unsaved changes first.
  Future<void> _exit(BuildContext context, WidgetRef ref) async {
    final emulator = ref.read(currentEmulatorProvider);
    final isDirty = ref.read(emulatorDirtyProvider);
    if (emulator != null && isDirty) {
      final action = await UnsavedChangesDialog.show(
        context,
        emulatorName: emulator.name,
      );
      if (action == null || action == UnsavedChangesAction.cancel) return;
      if (action == UnsavedChangesAction.save) {
        if (!context.mounted) return;
        final ok = await saveEmulator(context, ref);
        if (!ok) return;
      }
    }
    await windowManager.destroy();
  }

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.bgPanel,
        title: const Text(AppConstants.appName),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version: ${AppConstants.appVersion}'),
            SizedBox(height: 8),
            Text(AppConstants.appDescription),
            SizedBox(height: 16),
            Text(
              'A tool for building high-fidelity emulators from firmware ELF '
              'binaries by iteratively discovering and substituting '
              'hardware-dependent functions with software hooks.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Menu primitives (private)
// ---------------------------------------------------------------------------

class _MenuBarItem extends StatelessWidget {
  final String title;
  final List<Widget> items;

  const _MenuBarItem({required this.title, required this.items});

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
      tooltip: title,
      offset: const Offset(0, 32),
      color: AppTheme.bgPanel,
      itemBuilder: (context) => [
          for (int i = 0; i < items.length; i++)
            PopupMenuItem<int>(
              value: i,
              padding: EdgeInsets.zero,
              enabled: items[i] is _MenuItem && (items[i] as _MenuItem).enabled,
              child: items[i],
            ),
        ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          title,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        ),
      ),
    );
}

class _MenuItem extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  final String? shortcut;
  final bool enabled;

  const _MenuItem({
    required this.title,
    required this.onTap,
    this.shortcut,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppTheme.textPrimary : AppTheme.textDisabled;
    return InkWell(
      onTap: enabled
          ? () {
              Navigator.pop(context);
              onTap();
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: TextStyle(color: color, fontSize: 13)),
            const SizedBox(width: 32),
            if (shortcut != null)
              Text(
                shortcut!,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) => const Divider(height: 1, color: AppTheme.border);
}
