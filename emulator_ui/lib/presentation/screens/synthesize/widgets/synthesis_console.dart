import 'dart:async';

import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/auto_tune_session_provider.dart';
import '../../library/library_actions.dart';
import '../llm_synthesis_orchestrator.dart';
import '../synthesis_controller.dart';
import 'auto_tune_config_dialog.dart';
import 'auto_tune_panel.dart';
import 'auto_tune_session_view.dart';
import 'last_run_card.dart';
import 'pre_synthesis_report.dart';
import 'synthesis_report.dart';

/// Center pane of the Synthesize tab.
///
/// Three states keyed off [synthesisProgressProvider]:
///   - idle (null): config summary + Run Synthesis button
///   - running (!complete): live iteration/hook readout + countdown + Stop
///   - complete: success/failure banner + fidelity + Run Again
class SynthesisConsole extends ConsumerWidget {
  const SynthesisConsole({super.key});

  static const _countdownWindow = Duration(seconds: 30);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(synthesisProgressProvider);
    final emulator = ref.watch(currentEmulatorProvider);

    if (emulator == null) {
      return const _Centered(
        child: Text(
          'Open an emulator from the Library tab to run synthesis.',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      );
    }

    final base = progress == null
        ? _IdleView(emulator: emulator) as Widget
        : progress.complete
            ? _CompleteView(emulator: emulator)
            : const _RunningView(countdownWindow: _countdownWindow);

    // An active auto-tune session replaces the pane with ONE scrollable
    // column of same-chrome cards (no blocking overlay, no split pane):
    // control panel → trajectory/metrics/compact report → the round's
    // synthesis result in the familiar result styling.
    final orchestrator = ref.watch(autoTuneOrchestratorProvider);
    if (orchestrator == null) return base;
    return Container(
      color: AppTheme.bgCanvas,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AutoTunePanel(
              orchestrator: orchestrator,
              onDismiss: () {
                ref.read(autoTuneOrchestratorProvider.notifier).state = null;
                orchestrator.dispose();
              },
            ),
            const SizedBox(height: 12),
            const AutoTuneSessionView(),
            const SizedBox(height: 12),
            const AutoTuneResultCard(),
          ],
        ),
      ),
    );
  }
}

/// The current round's synthesis result during auto-tune — the same
/// content the standalone complete view shows (banner, big fidelity
/// block, substituted functions via [SynthesisReport]) wrapped in the
/// session's card chrome, titled by round instead of the misleading
/// "SYNTHESIS COMPLETE".
class AutoTuneResultCard extends ConsumerWidget {
  const AutoTuneResultCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(synthesisProgressProvider);
    final session = ref.watch(autoTuneSessionProvider);
    if (progress == null) return const SizedBox.shrink();

    final lastRound =
        (session?.rounds.isNotEmpty ?? false) ? session!.rounds.last.round : 0;
    final max = session?.maxRounds;
    final ofMax = max == null ? '' : ' OF $max';
    final running = !progress.complete;
    final round = running && (session?.rounds.isNotEmpty ?? false)
        ? lastRound + 1
        : lastRound;
    // Round 0 is the baseline, not an LLM round — "ROUND 0 OF 5" reads
    // as not-started, so name it. LLM rounds are genuinely 1..maxRounds.
    final label = round == 0 ? 'BASELINE' : 'ROUND $round$ofMax';
    final title = running
        ? '$label — SYNTHESIZING…'
        : '$label — ${progress.success ? 'COMPLETE' : 'FAILED'}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.5,
                color: AppTheme.textPrimary,
              ),
            ),
            const Spacer(),
            if (running)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                progress.success
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                size: 18,
                color: progress.success
                    ? const Color(0xFF81C784)
                    : const Color(0xFFE57373),
              ),
          ]),
          const SizedBox(height: 6),
          Text(
            // During the in-round LLM fallback the iteration readout is
            // frozen (emulation paused) — the status line is the only
            // truthful signal, so surface it.
            running && !progress.llmActive
                ? 'iteration ${progress.iteration} · '
                    '${progress.hooksApplied} hooks · '
                    '${progress.currentSymbol.isEmpty ? '—' : progress.currentSymbol}'
                : progress.status,
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 14),
          // The last completed round's full result (fidelity block,
          // decision provenance, substituted functions). Kept visible
          // while the next round synthesizes.
          const SynthesisReport(),
        ],
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  final Widget child;
  const _Centered({required this.child});

  @override
  Widget build(BuildContext context) => Container(
      color: AppTheme.bgCanvas,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: child,
      ),
    );
}

// ---------------------------------------------------------------------------
// Idle
// ---------------------------------------------------------------------------

class _IdleView extends ConsumerWidget {
  final Emulator emulator;
  const _IdleView({required this.emulator});

  bool get _ready =>
      (emulator.elfFilePath ?? '').isNotEmpty &&
      (emulator.baseImagePath ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Container(
        color: AppTheme.bgCanvas,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.auto_fix_high,
                      size: 40, color: AppTheme.textMuted),
                  const SizedBox(height: 16),
                  const Text(
                    'SYNTHESIZE',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _ready
                        ? 'Iteratively discover and substitute hardware-dependent '
                            'functions with hooks until the firmware runs cleanly.'
                        : 'This emulator needs both a firmware ELF and a platform '
                            '(.repl) before synthesis can run. Set them in the Library tab.',
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 12, height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  if (_ready) const PreSynthesisReport(),
                  if (_ready) const SizedBox(height: 14),
                  if (_ready) const LastRunCard(),
                  // Session view embeds only when no live panel is
                  // showing it already in the region above.
                  if (_ready &&
                      ref.watch(autoTuneOrchestratorProvider) == null &&
                      (ref.watch(autoTuneSessionProvider)?.rounds.isNotEmpty ??
                          false)) ...const [
                    SizedBox(height: 14),
                    AutoTuneSessionView(),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed:
                            _ready ? () => _launch(context, ref) : null,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Run Synthesis'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 14),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Tooltip(
                        message: emulator.emulatorPath == null
                            ? 'Save the project first so snapshots can persist.'
                            : 'LLM-orchestrated synthesis loop with per-round user review.',
                        child: OutlinedButton.icon(
                          onPressed: (_ready && emulator.emulatorPath != null)
                              ? () => _launchAutoTune(context, ref)
                              : null,
                          icon: const Icon(Icons.auto_awesome, size: 18),
                          label: const Text('Auto-tune'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Future<void> _launchAutoTune(BuildContext context, WidgetRef ref) async {
    final choice = await AutoTuneConfigDialog.show(context);
    if (choice == null || !context.mounted) return;
    final container = ProviderScope.containerOf(context);
    final orchestrator = LlmSynthesisOrchestrator(container);
    // Surface the running session inline: the console renders an
    // AutoTunePanel above the normal synthesis view while this
    // provider holds an orchestrator. It stays set after the session
    // finishes (so the done state is readable) until the panel's
    // Close button clears it.
    ref.read(autoTuneOrchestratorProvider.notifier).state = orchestrator;
    final sessionFuture = orchestrator.runAutoTune(
      choice.config,
      interactiveReview: choice.interactiveReview,
    );
    // Surface any uncaught error from the session. The orchestrator is
    // NOT disposed here — the panel keeps rendering the done state; its
    // Close button clears the provider and disposes.
    try {
      await sessionFuture;
    } catch (e, st) {
      debugPrint('[AutoTune] session error: $e\n$st');
    }
  }

  Future<void> _launch(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(synthesisControllerProvider);
    final config = emulator.emulationConfig;

    // Memory-map warning when starting mid-firmware without initialized state.
    if ((config.startFrom ?? '').isNotEmpty &&
        (config.memoryMapPath ?? '').isEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bgPanel,
          title: const Text('No Memory Map'),
          content: Text(
            'Starting from "${config.startFrom}" without a memory map may '
            'cause undefined behavior — registers and memory will not be '
            'initialized. You can add a memory map in the Execution Range '
            'section.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Go Back'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue Anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    // If prior hooks exist, ask: re-synthesize or just run with them.
    var mode = 'synthesize';
    if (emulator.hooks.isNotEmpty) {
      if (!context.mounted) return;
      final chosen = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bgPanel,
          title: const Text('Emulation Mode'),
          content: Text(
            '${emulator.hooks.length} hooks were resolved previously. '
            'Re-run the synthesizer, or run with the existing hooks?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('synthesize'),
              child: const Text('Synthesize'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('run'),
              child: const Text('Run'),
            ),
          ],
        ),
      );
      if (chosen == null) return;
      mode = chosen;
    }

    // The view will swap from _IdleView to _RunningView as soon as the
    // controller mutates `synthesisProgressProvider` non-null. Once that
    // happens this widget is disposed and `ref` becomes unusable. Capture
    // the root ProviderContainer so the catch block can still touch
    // providers after the swap.
    final container = ProviderScope.containerOf(context, listen: false);

    try {
      if (mode == 'run') {
        await controller.runWithResolvedHooks(emulator);
      } else {
        // Clear stale resolved hooks so the run starts fresh.
        if (emulator.hooks.isNotEmpty) {
          container.read(currentEmulatorProvider.notifier).state =
              emulator.copyWith(hooks: {}, modifiedAt: DateTime.now());
          container.read(emulatorDirtyProvider.notifier).state = true;
        }
        await controller.startSynthesis(
          container.read(currentEmulatorProvider)!,
        );
      }
    } catch (e, st) {
      // Surface the real error to stdout so it's visible regardless of
      // whether the widget is still mounted by the time we land here.
      // ignore: avoid_print
      print('[Synthesis] launch failed: $e\n$st');
      if (container.read(synthesisProgressProvider) == null) return;
      container.read(synthesisProgressProvider.notifier).state = null;
      if (!context.mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bgPanel,
          title: const Text('Synthesis Error'),
          content: Text(e.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

class _RunningView extends ConsumerStatefulWidget {
  final Duration countdownWindow;
  const _RunningView({required this.countdownWindow});

  @override
  ConsumerState<_RunningView> createState() => _RunningViewState();
}

class _RunningViewState extends ConsumerState<_RunningView> {
  Timer? _ticker;

  /// `47s` under a minute, `2m 07s` from there on.
  static String _formatElapsed(Duration d) {
    final secs = d.inSeconds.clamp(0, 359999);
    if (secs < 60) return '${secs}s';
    return '${secs ~/ 60}m ${(secs % 60).toString().padLeft(2, '0')}s';
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(synthesisProgressProvider);
    if (progress == null) return const SizedBox.shrink();

    final elapsed = DateTime.now().difference(progress.countdownStart);
    final remaining = widget.countdownWindow - elapsed;
    final remainingSecs = remaining.inSeconds.clamp(0, widget.countdownWindow.inSeconds);
    final fraction =
        (remaining.inMilliseconds / widget.countdownWindow.inMilliseconds)
            .clamp(0.0, 1.0);

    // While the on-demand LLM authors a hook, emulation is paused and
    // the 30s observation window doesn't apply — show an indeterminate
    // spinner with elapsed time instead of a countdown running to zero.
    final ring = progress.llmActive
        ? Stack(
            alignment: Alignment.center,
            children: [
              const SizedBox(
                width: 96,
                height: 96,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  backgroundColor: AppTheme.border,
                  valueColor: AlwaysStoppedAnimation(AppTheme.accent),
                ),
              ),
              Text(
                _formatElapsed(elapsed),
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          )
        : Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 96,
                height: 96,
                child: CircularProgressIndicator(
                  value: fraction,
                  strokeWidth: 4,
                  backgroundColor: AppTheme.border,
                  valueColor: const AlwaysStoppedAnimation(AppTheme.accent),
                ),
              ),
              Text(
                '${remainingSecs}s',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          );

    return _Centered(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 96, height: 96, child: ring),
          if (progress.llmActive) ...[
            const SizedBox(height: 8),
            const Text(
              'LLM authoring hook — emulation paused',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 20),
          Text(
            progress.status,
            style:
                const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          _StatRow(label: 'Iteration', value: '${progress.iteration}'),
          _StatRow(label: 'Hooks applied', value: '${progress.hooksApplied}'),
          if (progress.currentSymbol.isNotEmpty)
            _StatRow(label: 'Current', value: progress.currentSymbol),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(synthesisControllerProvider).stopSynthesis(),
            icon: const Icon(Icons.stop, size: 16),
            label: const Text('Stop'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.textPrimary,
              side: const BorderSide(color: AppTheme.border),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Complete
// ---------------------------------------------------------------------------

class _CompleteView extends ConsumerWidget {
  final Emulator emulator;
  const _CompleteView({required this.emulator});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(synthesisProgressProvider)!;
    final success = progress.success;

    return Container(
      color: AppTheme.bgCanvas,
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                success ? Icons.check_circle_outline : Icons.error_outline,
                size: 40,
                color: success
                    ? const Color(0xFF81C784)
                    : const Color(0xFFE57373),
              ),
              const SizedBox(height: 16),
              Text(
                success ? 'SYNTHESIS COMPLETE' : 'SYNTHESIS FAILED',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                progress.status,
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              const SynthesisReport(),
              // Session trajectory + metrics + compact report, when the
              // last synthesis came from an auto-tune session (live this
              // app run, or rehydrated from autotune_reports/) — unless
              // the live panel region above is already showing it.
              if (ref.watch(autoTuneOrchestratorProvider) == null &&
                  (ref.watch(autoTuneSessionProvider)?.rounds.isNotEmpty ??
                      false)) ...const [
                SizedBox(height: 14),
                AutoTuneSessionView(),
              ],
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => ref
                        .read(synthesisProgressProvider.notifier)
                        .state = null,
                    icon: const Icon(Icons.replay, size: 16),
                    label: const Text('Run Again'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textPrimary,
                      side: const BorderSide(color: AppTheme.border),
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: () => saveEmulator(context, ref),
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
          const SizedBox(width: 24),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
}
