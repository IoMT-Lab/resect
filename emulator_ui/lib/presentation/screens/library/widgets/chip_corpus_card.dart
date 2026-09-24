import 'package:emulator_orchestrator/data/models/chip_identity.dart';
import 'package:emulator_orchestrator/services/corpus/vendor_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/config_providers.dart';

/// Library-tab card: the detected MCU and its shared SDK/document
/// corpus. Fetch pulls the vendor SDK + register maps + datasheets for
/// the chip family and embeds them into the shared cache, where
/// synthesis and auto-tune retrieve them. Gated behind the LLM module
/// (embeddings need Ollama).
class ChipCorpusCard extends ConsumerWidget {
  const ChipCorpusCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final llmEnabled = ref.watch(moduleEnabledProvider('MODULE_LLM_HOOKGEN'));
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
      ),
      child: llmEnabled ? const _Enabled() : const _Disabled(),
    );
  }
}

class _Disabled extends StatelessWidget {
  const _Disabled();
  @override
  Widget build(BuildContext context) => const Row(children: [
        Icon(Icons.memory, size: 16, color: AppTheme.textMuted),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'CHIP CORPUS — enable the LLM module to fetch vendor SDKs and '
            'datasheets for the detected MCU.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
        ),
      ]);
}

class _Enabled extends ConsumerWidget {
  const _Enabled();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chip = ref.watch(chipIdentityProvider);
    final status = ref.watch(corpusStatusProvider);
    final progress = ref.watch(corpusFetchProgressProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('CHIP CORPUS',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                  color: AppTheme.textPrimary)),
          const Spacer(),
          if (chip?.corpusKey != null)
            TextButton.icon(
              onPressed: progress != null
                  ? null
                  : () => _startFetch(context, ref, chip!),
              icon: const Icon(Icons.download, size: 14),
              label: Text(status == null ? 'Fetch' : 'Update'),
            ),
        ]),
        const SizedBox(height: 8),
        if (chip == null)
          const Text('Open a project to detect its MCU.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12))
        else ...[
          Text('Detected: ${chip.label}'
              '${chip.corpusKey != null ? '  [${chip.corpusKey}]' : ''}',
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 13)),
          if (chip.evidence.isNotEmpty)
            Text(chip.evidence.first.detail,
                style:
                    const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          const SizedBox(height: 8),
          if (progress != null)
            Row(children: [
              const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(progress,
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 11),
                      overflow: TextOverflow.ellipsis)),
            ])
          else if (status == null)
            Text(
                chip.corpusKey == null
                    ? 'No curated vendor sources for this MCU yet.'
                    : 'No corpus fetched. Click Fetch to pull the SDK.',
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 12))
          else
            Text(
                '${status.chunkCount} chunks · '
                '${status.chunkCountsByKind.entries.map((e) => '${e.value} ${e.key}').join(' · ')}',
                style:
                    const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        ],
      ],
    );
  }

  Future<void> _startFetch(
      BuildContext context, WidgetRef ref, ChipIdentity chip) async {
    final service = ref.read(corpusServiceProvider);
    final plan = service.planFor(chip);
    if (plan == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No curated adapter for ${chip.corpusKey}.')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConsentDialog(plan: plan),
    );
    if (confirmed != true) return;

    final progressNotifier = ref.read(corpusFetchProgressProvider.notifier);
    progressNotifier.state = 'Starting…';
    try {
      await for (final e in service.fetchAndIngest(chip, plan)) {
        final pct = e.total > 0 ? ' (${e.done}/${e.total})' : '';
        progressNotifier.state = '${e.message}$pct';
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Corpus fetch failed: $e')));
      }
    } finally {
      progressNotifier.state = null;
      ref.read(corpusRefreshProvider.notifier).state++;
    }
  }
}

class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog({required this.plan});
  final FetchPlan plan;

  @override
  Widget build(BuildContext context) {
    final totalMb =
        (plan.approxTotalBytes / (1024 * 1024)).toStringAsFixed(0);
    return AlertDialog(
      title: Text('Fetch ${plan.corpusKey} corpus'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('~$totalMb MB total, cached locally (never redistributed):',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            ...plan.items.map((i) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${i.key}  [${i.kind.name}]'
                          '${i.approxBytes != null ? '  ~${(i.approxBytes! / (1024 * 1024)).toStringAsFixed(0)} MB' : ''}'
                          '${i.optional ? '  (optional)' : ''}',
                          style: const TextStyle(fontSize: 12)),
                      Text(i.licenseNote,
                          style: const TextStyle(
                              fontSize: 10, color: AppTheme.textMuted)),
                    ],
                  ),
                )),
            for (final n in plan.notes)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('note: $n',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Fetch')),
      ],
    );
  }
}
