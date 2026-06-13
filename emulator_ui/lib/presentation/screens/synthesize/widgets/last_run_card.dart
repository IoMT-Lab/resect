import 'dart:async';

import 'package:emulator_orchestrator/data/models/last_run_insight.dart';
import 'package:emulator_orchestrator/data/services/last_run_insight_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/config_providers.dart';
import '../../../widgets/synthesis_visuals.dart';

/// Visually-distinct card surfaced below the pre-synthesis review.
/// Shows the last synthesis run's headline metrics (fidelity, iters,
/// duration) and an LLM-generated recommendation for the next run.
///
/// Recommendation is user-triggered (Generate button), streams tokens
/// live, persists cached against the manifest's `synthesizerRunId`,
/// and goes stale when the next synthesis run produces a new id.
class LastRunCard extends ConsumerStatefulWidget {
  const LastRunCard({super.key});

  @override
  ConsumerState<LastRunCard> createState() => _LastRunCardState();
}

class _LastRunCardState extends ConsumerState<LastRunCard> {
  StreamSubscription<String>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(synthesisResultProvider);
    final fidelity = ref.watch(fidelityResultProvider);
    final emulator = ref.watch(currentEmulatorProvider);
    if (result == null) return const SizedBox.shrink();

    final insight = ref.watch(lastRunInsightProvider);
    final generating = ref.watch(lastRunInsightGeneratingProvider);
    final buffer = ref.watch(lastRunInsightStreamBufferProvider);
    // Gate the LLM-dependent recommendation panel on the same module
    // flag the other LLM-driven UI (rag_card, hook_database_dialog,
    // llm_hook_gen_dialog) uses. The card's headline metrics
    // (fidelity, iters, duration) are derived from local data and
    // stay visible regardless — only the Generate button and the
    // active recommendation render under the flag.
    final llmEnabled = ref.watch(moduleEnabledProvider('MODULE_LLM_HOOKGEN'));
    // Insight is stale when its `runIdAtGeneration` doesn't match the
    // current run's `synthesizerRunId`. We compare against the live
    // manifest because that's what next-run regeneration would target.
    final currentRunId = result.manifest?.synthesizerRunId;
    final cachedRunId = insight?.runIdAtGeneration;
    final stale = insight != null &&
        currentRunId != null &&
        cachedRunId != null &&
        cachedRunId != currentRunId;

    return Container(
      decoration: BoxDecoration(
        // Slightly warmer background than the pre-synthesis card to
        // visually separate the two without introducing a new accent.
        color: const Color(0xFF332D26),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            runId: currentRunId,
            iters: result.totalIterations,
            durationSeconds: result.totalDuration.inSeconds,
          ),
          const SizedBox(height: 14),
          _BigFidelity(
            success: result.success,
            fidelityPct: fidelity?.overallFidelity,
            failedSymbol: result.failedSymbol,
          ),
          const SizedBox(height: 16),
          _RecommendationPanel(
            llmEnabled: llmEnabled,
            insight: insight,
            stale: stale,
            generating: generating,
            buffer: buffer,
            onGenerate: !llmEnabled ||
                    emulator == null ||
                    result.manifest == null
                ? null
                : () => _generate(context),
            onCancel: _cancel,
          ),
        ],
      ),
    );
  }

  Future<void> _generate(BuildContext context) async {
    final result = ref.read(synthesisResultProvider);
    final manifest = result?.manifest;
    final callGraph = ref.read(callgraphProvider).valueOrNull;
    final decisionState = ref.read(hookDecisionStateProvider);
    if (manifest == null || callGraph == null || decisionState == null) {
      return;
    }
    final service = ref.read(lastRunInsightServiceProvider);
    // Fallback model tag for the rare case where the service can't
    // reach /api/tags and the first sentinel never fires. Overwritten
    // by whatever the service picks (smallest installed).
    var actualModelTag = ref.read(llmClientProvider).model;

    ref.read(lastRunInsightGeneratingProvider.notifier).state = true;
    ref.read(lastRunInsightStreamBufferProvider.notifier).state = '';

    final stream = service.generate(
      manifest: manifest,
      currentState: decisionState,
      callGraph: callGraph,
    );

    final buf = StringBuffer();
    await _sub?.cancel();
    _sub = stream.listen(
      (token) {
        // First token from the service is a model-tag sentinel
        // (`\x00!model:<name>`) so the panel records which model
        // actually wrote the cached insight. Strip it from the visible
        // stream buffer.
        if (token.startsWith(LastRunInsightService.modelSentinelPrefix)) {
          actualModelTag = token
              .substring(LastRunInsightService.modelSentinelPrefix.length);
          return;
        }
        buf.write(token);
        ref.read(lastRunInsightStreamBufferProvider.notifier).state =
            buf.toString();
      },
      onDone: () {
        final text = buf.toString().trim();
        if (text.isNotEmpty) {
          ref.read(lastRunInsightProvider.notifier).state = LastRunInsight(
            text: text,
            runIdAtGeneration: manifest.synthesizerRunId,
            generatedAt: DateTime.now(),
            modelTag: actualModelTag,
          );
          ref.read(emulatorDirtyProvider.notifier).state = true;
        }
        ref.read(lastRunInsightGeneratingProvider.notifier).state = false;
        ref.read(lastRunInsightStreamBufferProvider.notifier).state = '';
      },
      onError: (Object e) {
        ref.read(lastRunInsightGeneratingProvider.notifier).state = false;
        ref.read(lastRunInsightStreamBufferProvider.notifier).state = '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('LLM call failed: $e')),
        );
      },
      cancelOnError: true,
    );
  }

  void _cancel() {
    _sub?.cancel();
    _sub = null;
    ref.read(lastRunInsightGeneratingProvider.notifier).state = false;
    ref.read(lastRunInsightStreamBufferProvider.notifier).state = '';
  }
}

// ---------------------------------------------------------------------------
// Card header
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({
    required this.runId,
    required this.iters,
    required this.durationSeconds,
  });
  final String? runId;
  final int iters;
  final int durationSeconds;

  @override
  Widget build(BuildContext context) {
    final timestamp = _prettyRunId(runId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        const Text(
          'LAST RUN',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          timestamp == null
              ? '$iters iter · ${durationSeconds}s'
              : '$timestamp · $iters iter · ${durationSeconds}s',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
        ),
      ],
    );
  }

  /// `2026-06-12T21:58:54.910` → `2026-06-12 21:58`.
  static String? _prettyRunId(String? runId) {
    if (runId == null) return null;
    try {
      final dt = DateTime.parse(runId);
      String two(int n) => n.toString().padLeft(2, '0');
      return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
          '${two(dt.hour)}:${two(dt.minute)}';
    } catch (_) {
      return runId;
    }
  }
}

// ---------------------------------------------------------------------------
// Big fidelity headline
// ---------------------------------------------------------------------------

class _BigFidelity extends StatelessWidget {
  const _BigFidelity({
    required this.success,
    required this.fidelityPct,
    required this.failedSymbol,
  });
  final bool success;
  final double? fidelityPct;
  final String? failedSymbol;

  @override
  Widget build(BuildContext context) {
    final color = fidelityPct != null
        ? fidelityColor(fidelityPct!)
        : (success ? CoverageColors.preApplied : const Color(0xFFE57373));
    final headline = fidelityPct != null
        ? '${(fidelityPct! * 100).toStringAsFixed(1)}%'
        : (success ? 'Success' : 'Failed');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          success ? Icons.check_circle : Icons.cancel,
          size: 28,
          color: color,
        ),
        const SizedBox(width: 10),
        Text(
          headline,
          style: TextStyle(
            color: color,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            fidelityPct != null
                ? (success
                    ? 'Firmware ran clean within the observation window.'
                    : 'Last attempt failed at '
                        '`${failedSymbol ?? '?'}`.')
                : (success
                    ? 'Last attempt completed.'
                    : 'Last attempt failed at '
                        '`${failedSymbol ?? '?'}`.'),
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Recommendation panel (empty / streaming / loaded / stale states)
// ---------------------------------------------------------------------------

class _RecommendationPanel extends StatelessWidget {
  const _RecommendationPanel({
    required this.llmEnabled,
    required this.insight,
    required this.stale,
    required this.generating,
    required this.buffer,
    required this.onGenerate,
    required this.onCancel,
  });

  final bool llmEnabled;
  final LastRunInsight? insight;
  final bool stale;
  final bool generating;
  final String buffer;
  final VoidCallback? onGenerate;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (!llmEnabled && insight == null) {
      // Module is off and there's no cached advisory to display —
      // hide the LLM-affordance entirely so the user isn't asked to
      // click a button that can't work. A cached advisory from a prior
      // session when the module was on still renders below.
      body = _disabledBody();
    } else if (generating) {
      body = _streamingBody();
    } else if (insight == null) {
      body = _emptyBody();
    } else {
      body = _loadedBody();
    }
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.border),
      ),
      padding: const EdgeInsets.all(12),
      child: body,
    );
  }

  Widget _disabledBody() => Row(
        children: [
          const Icon(
            Icons.power_off,
            size: 18,
            color: AppTheme.textDisabled,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'LLM module is off — enable MODULE_LLM_HOOKGEN in '
              'system settings to get recommendations from your runs.',
              style:
                  TextStyle(color: AppTheme.textDisabled, fontSize: 12),
            ),
          ),
        ],
      );

  Widget _emptyBody() => Row(
        children: [
          const Icon(
            Icons.lightbulb_outline,
            size: 18,
            color: AppTheme.textMuted,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Ask the LLM what to try next based on this run.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: onGenerate,
            icon: const Icon(Icons.auto_awesome, size: 14),
            label: const Text('Generate', style: TextStyle(fontSize: 11)),
          ),
        ],
      );

  Widget _streamingBody() => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(Color(0xFFFFA726)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  buffer.isEmpty ? 'Thinking…' : buffer,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    minimumSize: const Size(0, 24),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onCancel,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _loadedBody() {
    final i = insight!;
    final color = stale ? AppTheme.textMuted : AppTheme.textPrimary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.lightbulb,
              size: 18,
              color: stale ? AppTheme.textMuted : const Color(0xFFFFA726),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                i.text,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              stale
                  ? 'Generated for the previous run · ${i.modelTag}'
                  : '${i.modelTag} · ${_relativeTime(i.generatedAt)}',
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                minimumSize: const Size(0, 24),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onGenerate,
              icon: const Icon(Icons.refresh, size: 14),
              label: Text(
                stale ? 'Regenerate (last run is newer)' : 'Regenerate',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _relativeTime(DateTime then) {
    final delta = DateTime.now().difference(then);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 24) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }
}
