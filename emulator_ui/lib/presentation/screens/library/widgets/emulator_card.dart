import 'package:emulator_orchestrator/data/models/emulator.dart';
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
          const SizedBox(height: 24),
          const Divider(height: 1, color: AppTheme.border),
          const SizedBox(height: 16),
          _DocumentsSection(documents: emulator.documents),
        ],
      ),
    );
  }
}

/// Documents attached to the open project — datasheets, source listings,
/// reference guides, etc. Files live in
/// `~/.config/call_graph_viewer/projects/<id>/documents/` (see
/// [EmulatorRepository.addDocument]); the persisted `.emu` carries the
/// [DocumentEntry] list so reopening restores them.
class _DocumentsSection extends ConsumerWidget {
  final List<DocumentEntry> documents;
  const _DocumentsSection({required this.documents});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'DOCUMENTS  (${documents.length})',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 3,
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () => addDocumentToEmulator(context, ref),
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Add document...'),
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
          const SizedBox(height: 12),
          if (documents.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No documents associated. Use "Add document..." to attach '
                'reference files (PDFs, datasheets, source listings, etc.) — '
                'they are copied into the project and travel with it on save.',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                ),
              ),
            )
          else
            Column(
              children: [
                for (final doc in documents)
                  _DocumentRow(doc: doc),
              ],
            ),
        ],
      );
}

class _DocumentRow extends ConsumerWidget {
  final DocumentEntry doc;
  const _DocumentRow({required this.doc});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => openDocument(context, ref, doc),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.description_outlined,
                  size: 16,
                  color: AppTheme.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    doc.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Remove from project',
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    color: AppTheme.textMuted,
                    splashRadius: 16,
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        removeDocumentFromEmulator(context, ref, doc),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
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
  Widget build(BuildContext context) => Padding(
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
