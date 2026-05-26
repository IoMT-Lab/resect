import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:emulator_orchestrator/core/constants.dart';

import '../../core/theme.dart';
import '../../providers/app_providers.dart';
import '../widgets/connection_status_indicator.dart';

/// Bottom status bar — connection state, current emulator name + dirty flag,
/// app version. Pulled out of HomeScreen so every tab gets it for free.
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentEmulator = ref.watch(currentEmulatorProvider);
    final isDirty = ref.watch(emulatorDirtyProvider);

    return Container(
      height: AppConstants.statusBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: AppTheme.bgChrome,
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        children: [
          const ConnectionStatusIndicator(),
          if (currentEmulator != null) ...[
            const SizedBox(width: 8),
            Container(width: 1, height: 12, color: AppTheme.border),
            const SizedBox(width: 8),
            const Icon(Icons.folder_open, size: 12, color: AppTheme.textMuted),
            const SizedBox(width: 4),
            Text(
              currentEmulator.name,
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
            if (isDirty)
              const Text(
                ' *',
                style: TextStyle(fontSize: 11, color: Colors.orange),
              ),
          ],
          const Spacer(),
          const Text(
            AppConstants.appVersion,
            style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
