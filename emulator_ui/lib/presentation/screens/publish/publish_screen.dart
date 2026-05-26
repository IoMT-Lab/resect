import 'package:emulator_orchestrator/data/models/emulator.dart';
import '../../../core/file_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../providers/app_providers.dart';
import '../../dialogs/vagrant_test_dialog.dart';
import 'widgets/publish_card.dart';

/// PUBLISH tab — produce the deliverable.
///
/// A 2x2 grid of action cards: Emulator Bundle (.zip), Renode Script
/// (.resc), Vagrant Bundle (.zip), and Run Vagrant CI Test. Cards become
/// active when their prerequisites are met (saved emulator, hooks present,
/// ELF + .repl set).
class PublishScreen extends ConsumerWidget {
  const PublishScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emulator = ref.watch(currentEmulatorProvider);
    final isDirty = ref.watch(emulatorDirtyProvider);

    return Container(
      color: AppTheme.bgCanvas,
      padding: const EdgeInsets.all(32),
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(),
            const SizedBox(height: 32),
            if (emulator == null)
              const _NoEmulatorNotice()
            else
              _CardGrid(emulator: emulator, isDirty: isDirty),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: const [
        Text(
          'PUBLISH',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: 4,
          ),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 12),
        Text(
          'Export the current emulator as a portable bundle, a standalone '
          'Renode script, or a Vagrant test environment.',
          style: TextStyle(
            color: AppTheme.textMuted,
            fontSize: 13,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _NoEmulatorNotice extends StatelessWidget {
  const _NoEmulatorNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
      ),
      child: const Text(
        'No emulator loaded. Open or create one from the Library tab '
        'before exporting.',
        style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _CardGrid extends ConsumerWidget {
  final Emulator emulator;
  final bool isDirty;

  const _CardGrid({required this.emulator, required this.isDirty});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasElf = (emulator.elfFilePath ?? '').isNotEmpty;
    final hasRepl = (emulator.baseImagePath ?? '').isNotEmpty;
    final hasHooks = emulator.hooks.isNotEmpty;
    final isSaved = (emulator.emulatorPath ?? '').isNotEmpty && !isDirty;

    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: PublishCard(
                  title: 'Emulator Bundle',
                  description:
                      'Zip the .emu file along with the firmware ELF, platform '
                      'description, and any attached documents.',
                  actionLabel: 'Export .zip',
                  icon: Icons.archive_outlined,
                  onPressed: isSaved
                      ? () => _exportEmulator(context, ref)
                      : null,
                  disabledHint:
                      isSaved ? null : 'Save the emulator first.',
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: PublishCard(
                  title: 'Renode Script',
                  description:
                      'Generate a standalone .resc script that re-creates this '
                      'emulator inside Renode with all resolved hooks applied.',
                  actionLabel: 'Export .resc',
                  icon: Icons.terminal,
                  onPressed: (hasElf && hasRepl && hasHooks)
                      ? () => _exportResc(context, ref)
                      : null,
                  disabledHint: !hasHooks
                      ? 'Run the synthesizer to resolve hooks first.'
                      : (!hasElf || !hasRepl)
                          ? 'Set the firmware (.elf) and platform (.repl) first.'
                          : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: PublishCard(
                  title: 'Vagrant Bundle',
                  description:
                      'Zip a Vagrantfile + provisioning script + .resc so the '
                      'emulator can be reproduced inside a VM.',
                  actionLabel: 'Export .zip',
                  icon: Icons.computer_outlined,
                  onPressed: (hasElf && hasRepl && hasHooks)
                      ? () => _exportVagrant(context, ref)
                      : null,
                  disabledHint: !hasHooks
                      ? 'Run the synthesizer to resolve hooks first.'
                      : (!hasElf || !hasRepl)
                          ? 'Set the firmware (.elf) and platform (.repl) first.'
                          : null,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: PublishCard(
                  title: 'Vagrant CI Test',
                  description:
                      'Spin up a fresh Ubuntu VM and run the CLI synthesizer '
                      'end-to-end as a CI/CD validation check.',
                  actionLabel: 'Run Test...',
                  icon: Icons.fact_check_outlined,
                  onPressed: (hasElf && hasRepl)
                      ? () => _runVagrantTest(context)
                      : null,
                  disabledHint: (hasElf && hasRepl)
                      ? null
                      : 'Set the firmware (.elf) and platform (.repl) first.',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportEmulator(BuildContext context, WidgetRef ref) async {
    final result = await ref.read(fileSelectorProvider).saveFile(
          dialogTitle: 'Export Emulator Bundle',
          suggestedName: '${emulator.name}.zip',
          extensions: ['zip'],
        );
    if (result == null) return;
    final zipPath = result.endsWith('.zip') ? result : '$result.zip';

    final repository = ref.read(emulatorRepositoryProvider);
    try {
      await repository.exportEmulator(emulator, zipPath);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported: $zipPath')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  Future<void> _exportResc(BuildContext context, WidgetRef ref) async {
    final result = await ref.read(fileSelectorProvider).saveFile(
          dialogTitle: 'Export Renode Script',
          suggestedName: '${emulator.name}.resc',
          extensions: ['resc'],
        );
    if (result == null) return;
    final outputPath = result.endsWith('.resc') ? result : '$result.resc';

    final repository = ref.read(emulatorRepositoryProvider);
    try {
      await repository.exportResc(emulator, outputPath);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported: $outputPath')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  Future<void> _exportVagrant(BuildContext context, WidgetRef ref) async {
    final result = await ref.read(fileSelectorProvider).saveFile(
          dialogTitle: 'Export Vagrant Bundle',
          suggestedName: '${emulator.name}_vagrant.zip',
          extensions: ['zip'],
        );
    if (result == null) return;
    final zipPath = result.endsWith('.zip') ? result : '$result.zip';

    final repository = ref.read(emulatorRepositoryProvider);
    try {
      await repository.exportVagrant(emulator, zipPath);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported: $zipPath')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  Future<void> _runVagrantTest(BuildContext context) async {
    await VagrantTestDialog.show(context);
  }
}
