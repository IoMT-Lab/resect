import 'dart:async';

import 'package:emulator_orchestrator/data/models/last_run_insight.dart';
import 'package:emulator_orchestrator/services/llm/llm_client.dart';
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
  StreamSubscription<LlmStreamEvent>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(synthesisResultProvider);
    final metrics = ref.watch(manifestMetricsProvider);
    final emulator = ref.watch(currentEmulatorProvider);
    if (result == null) return const SizedBox.shrink();

    final insight = ref.watch(lastRunInsightProvider);
    final generating = ref.watch(lastRunInsightGeneratingProvider);
    final buffer = ref.watch(lastRunInsightStreamBufferProvider);
    final thinkingBuffer = ref.watch(lastRunInsightThinkingBufferProvider);
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
            fidelityPct: metrics?.overallFidelity,
            failureText: 'Last attempt: '
                '${result.failureLabel.toLowerCase()}.',
          ),
          const SizedBox(height: 16),
          _RecommendationPanel(
            llmEnabled: llmEnabled,
            insight: insight,
            stale: stale,
            generating: generating,
            buffer: buffer,
            thinkingBuffer: thinkingBuffer,
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
    // reach /api/tags and the onModelSelected callback never fires.
    // Overwritten by whatever the service picks (smallest installed).
    var actualModelTag = ref.read(llmClientProvider).model;

    ref.read(lastRunInsightGeneratingProvider.notifier).state = true;
    ref.read(lastRunInsightStreamBufferProvider.notifier).state = '';
    ref.read(lastRunInsightThinkingBufferProvider.notifier).state = '';

    final stream = service.generateEvents(
      manifest: manifest,
      currentState: decisionState,
      callGraph: callGraph,
      onModelSelected: (tag) => actualModelTag = tag,
    );

    final respBuf = StringBuffer();
    final thinkBuf = StringBuffer();
    await _sub?.cancel();
    _sub = stream.listen(
      (event) {
        switch (event) {
          case LlmThinkingChunk(:final text):
            thinkBuf.write(text);
            ref.read(lastRunInsightThinkingBufferProvider.notifier).state =
                thinkBuf.toString();
          case LlmResponseChunk(:final text):
            respBuf.write(text);
            ref.read(lastRunInsightStreamBufferProvider.notifier).state =
                respBuf.toString();
          case LlmStreamDone():
            // Terminal stats event — `onDone` below already handles
            // closing out the advisor card, and the Last Run flow
            // doesn't surface budget diagnostics today (only the
            // auto-tune flow does, via RecommendationService).
            break;
        }
      },
      onDone: () {
        final text = respBuf.toString().trim();
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
        ref.read(lastRunInsightThinkingBufferProvider.notifier).state = '';
      },
      onError: (Object e) {
        ref.read(lastRunInsightGeneratingProvider.notifier).state = false;
        ref.read(lastRunInsightStreamBufferProvider.notifier).state = '';
        ref.read(lastRunInsightThinkingBufferProvider.notifier).state = '';
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
    required this.failureText,
  });
  final bool success;
  final double? fidelityPct;

  /// Failure sentence from [SynthesizerResult.failureLabel] — already
  /// reason-aware (cap/cancel endings carry no failed symbol).
  final String failureText;

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
            success
                ? (fidelityPct != null
                    ? 'Firmware ran clean within the observation window.'
                    : 'Last attempt completed.')
                : failureText,
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
    required this.thinkingBuffer,
    required this.onGenerate,
    required this.onCancel,
  });

  final bool llmEnabled;
  final LastRunInsight? insight;
  final bool stale;
  final bool generating;
  final String buffer;
  final String thinkingBuffer;
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

  Widget _disabledBody() => const Row(
        children: [
          Icon(
            Icons.power_off,
            size: 18,
            color: AppTheme.textDisabled,
          ),
          SizedBox(width: 8),
          Expanded(
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
                // Reasoning pane — surfaces the model's thinking trace
                // as it arrives so the user has live feedback during
                // the seconds-to-minutes the LLM spends reasoning.
                // Hidden until the first thinking chunk lands.
                if (thinkingBuffer.isNotEmpty) ...[
                  const Text(
                    'REASONING',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Text(
                        thinkingBuffer,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontFamily: 'monospace',
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'RESPONSE',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  buffer.isEmpty
                      ? (thinkingBuffer.isEmpty
                          ? 'Thinking…'
                          : '(model still reasoning — response will stream when it concludes)')
                      : buffer,
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
