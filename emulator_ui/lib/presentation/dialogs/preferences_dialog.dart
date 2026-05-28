import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../providers/config_providers.dart';

/// Application preferences (Tools ▸ Preferences). Distinct from System
/// Configuration (build/environment): these are user-facing app behaviors.
/// Backed by the same repo-local `resect.config` via [systemConfigProvider].
class PreferencesDialog extends ConsumerWidget {
  const PreferencesDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        builder: (_) => const PreferencesDialog(),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final autosave = ref.watch(autosaveEnabledProvider);
    return AlertDialog(
      backgroundColor: AppTheme.bgPanel,
      title: const Text('Preferences'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: autosave,
              onChanged: (v) async {
                await (ref.read(systemConfigProvider.notifier)
                      ..setBool('PREF_AUTOSAVE', v))
                    .save();
              },
              title: const Text(
                'Autosave',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              ),
              subtitle: const Text(
                'Automatically save the project after synthesis, call-graph '
                'regeneration, and hook changes. Only applies to projects that '
                'have already been saved.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
