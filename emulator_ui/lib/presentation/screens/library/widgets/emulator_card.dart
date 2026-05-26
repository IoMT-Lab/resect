import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../library_actions.dart';

/// Detail card for the currently loaded emulator.
///
/// Shows name, dirty-state indicator, key file paths, hook count, and the
/// Save / Save As / Close actions.
class EmulatorCard extends ConsumerWidget {
  const EmulatorCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emulator = ref.watch(currentEmulatorProvider);
    final isDirty = ref.watch(emulatorDirtyProvider);
    if (emulator == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'LOADED EMULATOR',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 3,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  emulator.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isDirty)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text(
                    'UNSAVED',
                    style: TextStyle(
                      color: Colors.orange,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          _DetailRow(
            label: 'Project',
            value: emulator.emulatorPath ?? '(not saved yet)',
            mutedValue: emulator.emulatorPath == null,
          ),
          _DetailRow(
            label: 'Firmware (.elf)',
            value: emulator.elfFilePath ?? '(none)',
            mutedValue: emulator.elfFilePath == null,
          ),
          _DetailRow(
            label: 'Platform (.repl)',
            value: emulator.baseImagePath ?? '(none)',
            mutedValue: emulator.baseImagePath == null,
          ),
          _DetailRow(
            label: 'Resolved hooks',
            value: '${emulator.hooks.length}',
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              ElevatedButton(
                onPressed: () => saveEmulator(context, ref),
                child: const Text('Save'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => saveEmulatorAs(context, ref),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.border),
                ),
                child: const Text('Save As'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => closeEmulator(context, ref),
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.textMuted,
                ),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mutedValue;

  const _DetailRow({
    required this.label,
    required this.value,
    this.mutedValue = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: mutedValue ? AppTheme.textMuted : AppTheme.textPrimary,
                fontSize: 12,
                fontStyle: mutedValue ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
