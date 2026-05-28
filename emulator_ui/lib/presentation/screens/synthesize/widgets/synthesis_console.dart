import 'dart:async';

import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme.dart';
import '../../../../providers/app_providers.dart';
import '../../library/library_actions.dart';
import '../synthesis_controller.dart';
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

    if (progress == null) {
      return _IdleView(emulator: emulator);
    }
    if (progress.complete) {
      return _CompleteView(emulator: emulator);
    }
    return const _RunningView(countdownWindow: _countdownWindow);
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
  Widget build(BuildContext context, WidgetRef ref) => _Centered(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_fix_high, size: 40, color: AppTheme.textMuted),
          const SizedBox(height: 16),
          const Text(
            'SYNTHESIZE',
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
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _ready ? () => _launch(context, ref) : null,
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('Run Synthesis'),
            style: ElevatedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
        ],
      ),
    );

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

    try {
      if (mode == 'run') {
        await controller.runWithResolvedHooks(emulator);
      } else {
        // Clear stale resolved hooks so the run starts fresh.
        if (emulator.hooks.isNotEmpty) {
          ref.read(currentEmulatorProvider.notifier).state =
              emulator.copyWith(hooks: {}, modifiedAt: DateTime.now());
          ref.read(emulatorDirtyProvider.notifier).state = true;
        }
        await controller.startSynthesis(
          ref.read(currentEmulatorProvider)!,
        );
      }
    } catch (e) {
      if (ref.read(synthesisProgressProvider) == null) return; // user stopped
      ref.read(synthesisProgressProvider.notifier).state = null;
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

    return _Centered(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 96,
            height: 96,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 96,
                  height: 96,
                  child: CircularProgressIndicator(
                    value: fraction,
                    strokeWidth: 4,
                    backgroundColor: AppTheme.border,
                    valueColor:
                        const AlwaysStoppedAnimation(AppTheme.accent),
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
            ),
          ),
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
