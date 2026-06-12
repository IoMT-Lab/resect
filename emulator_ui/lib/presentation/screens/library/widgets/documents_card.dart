import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../library_actions.dart';

/// Card that lists documents attached to the open project — datasheets,
/// source listings, reference guides, etc. Files live in
/// `~/.config/call_graph_viewer/projects/<id>/documents/` (see
/// [EmulatorRepository.addDocument]); the persisted `.emu` carries the
/// [DocumentEntry] list so reopening restores them.
class DocumentsCard extends ConsumerWidget {
  const DocumentsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emulator = ref.watch(currentEmulatorProvider);
    if (emulator == null) return const SizedBox.shrink();
    final documents = emulator.documents;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
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
                for (final doc in documents) _DocumentRow(doc: doc),
              ],
            ),
        ],
      ),
    );
  }
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
