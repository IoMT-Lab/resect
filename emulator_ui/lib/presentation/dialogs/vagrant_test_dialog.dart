import 'dart:async';

import 'package:emulator_orchestrator/core/app_paths.dart';
import 'package:emulator_orchestrator/data/models/emulator.dart';
import 'package:emulator_orchestrator/orchestrator/vagrant_test_runner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/file_selection.dart';
import '../../providers/app_providers.dart';

/// Dialog for running the Vagrant CI/CD test suite against the resect project.
///
/// Tests four things in order:
///   1. Provision VM (vagrant up completes without error)
///   2. Project files present in VM
///   3. Resect tool starts (CLI --help exits 0)
///   4. Synthesis runs (synthesizer runs without crashing)
class VagrantTestDialog extends ConsumerStatefulWidget {
  const VagrantTestDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const VagrantTestDialog(),
    );

  @override
  ConsumerState<VagrantTestDialog> createState() => _VagrantTestDialogState();
}

class _VagrantTestDialogState extends ConsumerState<VagrantTestDialog> {
  VagrantTestRunner? _runner;
  StreamSubscription<VagrantTestEvent>? _subscription;

  // Which step rows are expanded to show logs
  final Set<VagrantTestStepId> _expanded = {};

  // Whether to use the current emulator or a picked .emu file
  Emulator? _pickedEmulator;

  // Per-step scroll controllers and auto-scroll tracking
  final Map<VagrantTestStepId, ScrollController> _scrollControllers = {};
  final Set<VagrantTestStepId> _userScrolledUp = {};

  @override
  void initState() {
    super.initState();
    // Reset any leftover state from a previous run when the dialog opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(vagrantTestStateProvider.notifier).state = VagrantTestState();
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    // Fire-and-forget cancel — we can't await in dispose(), but the runner
    // will still kill the process and destroy the VM asynchronously.
    _runner?.cancel();
    for (final c in _scrollControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  ScrollController _controllerFor(VagrantTestStepId id) => _scrollControllers.putIfAbsent(id, () {
      final c = ScrollController();
      c.addListener(() {
        if (!c.hasClients) return;
        final atBottom = c.offset >= c.position.maxScrollExtent - 20;
        if (atBottom) {
          _userScrolledUp.remove(id);
        } else {
          _userScrolledUp.add(id);
        }
      });
      return c;
    });

  void _scrollToBottom(VagrantTestStepId id) {
    if (_userScrolledUp.contains(id)) return;
    final c = _scrollControllers[id];
    if (c == null || !c.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.hasClients) {
        c.jumpTo(c.position.maxScrollExtent);
      }
    });
  }

  Emulator? get _activeEmulator =>
      _pickedEmulator ?? ref.read(currentEmulatorProvider);

  bool get _canRun {
    final e = _activeEmulator;
    return e != null &&
        e.elfFilePath != null &&
        e.baseImagePath != null &&
        !ref.read(vagrantTestStateProvider).isRunning;
  }

  // -------------------------------------------------------------------------
  // Test execution

  Future<void> _runTest() async {
    final emulator = _activeEmulator;
    if (emulator == null) return;

    // Reset state
    ref.read(vagrantTestStateProvider.notifier).state = VagrantTestState(
      isRunning: true,
    );
    setState(_expanded.clear);

    final repoRoot = p.dirname(AppPaths.findEngineDir());
    _runner = VagrantTestRunner();

    _subscription = _runner!.events.listen(
      _handleEvent,
      onDone: () {
        if (mounted) {
          ref.read(vagrantTestStateProvider.notifier).update(
                (s) => s.copyWith(isRunning: false),
              );
        }
      },
    );

    await _runner!.start(emulator: emulator, repoRoot: repoRoot);
  }

  void _handleEvent(VagrantTestEvent event) {
    if (!mounted) return;

    // Expand the step row when it starts — done outside the Riverpod update
    // callback to avoid calling setState() inside a state-notifier update.
    if (event case VagrantTestStepStarted(:final step)) {
      setState(() => _expanded.add(step));
    }

    ref.read(vagrantTestStateProvider.notifier).update((state) {
      switch (event) {
        case VagrantTestStepStarted(:final step):
          return state.withStepUpdate(
            step,
            (s) => s.copyWith(status: VagrantStepStatus.running),
          );
        case VagrantTestLogLine(:final step, :final line):
          return state.withStepUpdate(
            step,
            (s) => s.copyWith(logs: [...s.logs, line]),
          );
        case VagrantTestStepPassed(:final step):
          return state.withStepUpdate(
            step,
            (s) => s.copyWith(status: VagrantStepStatus.passed),
          );
        case VagrantTestStepFailed(:final step, :final reason):
          return state
              .withStepUpdate(
                step,
                (s) => s.copyWith(
                  status: VagrantStepStatus.failed,
                  logs: [...s.logs, 'FAILED: $reason'],
                ),
              )
              .copyWith(complete: true, passed: false);
        case VagrantTestComplete(:final passed):
          return state.copyWith(complete: true, passed: passed);
        case VagrantTestCancelled():
          return state.copyWith(complete: true, passed: false);
      }
    });
  }

  Future<void> _cancel() async {
    await _runner?.cancel();
    ref.read(vagrantTestStateProvider.notifier).update(
          (s) => s.copyWith(isRunning: false, complete: true, passed: false),
        );
  }

  Future<void> _pickEmulator() async {
    final path = await ref.read(fileSelectorProvider).openFile(
          dialogTitle: 'Select Emulator Project',
          extensions: ['emu'],
        );
    if (path == null) return;

    final repository = ref.read(emulatorRepositoryProvider);
    try {
      final emulator = await repository.loadEmulator(path);
      setState(() => _pickedEmulator = emulator);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load emulator: $e')),
        );
      }
    }
  }

  // -------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vagrantTestStateProvider);
    final emulator = _activeEmulator;

    return AlertDialog(
      title: const Text('Vagrant CI/CD Test'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildProjectSelector(emulator),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            ...state.steps.map(_buildStepRow),
            if (state.complete) ...[
              const SizedBox(height: 12),
              _buildResultBanner(state.passed),
            ],
          ],
        ),
      ),
      actions: [
        if (state.isRunning)
          TextButton(
            onPressed: _cancel,
            child: const Text('Cancel'),
          )
        else ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: _canRun ? _runTest : null,
            child: const Text('Run Test'),
          ),
        ],
      ],
    );
  }

  Widget _buildProjectSelector(Emulator? emulator) {
    final label = emulator != null
        ? '${emulator.name}  (${p.basename(emulator.elfFilePath ?? 'no ELF')})'
        : 'No project selected';

    return Row(
      children: [
        const Text('Project: ', style: TextStyle(fontWeight: FontWeight.w500)),
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: emulator != null ? null : Colors.red.shade400,
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: ref.read(vagrantTestStateProvider).isRunning
              ? null
              : _pickEmulator,
          child: const Text('Browse...'),
        ),
      ],
    );
  }

  Widget _buildStepRow(VagrantTestStepState step) {
    final isExpanded = _expanded.contains(step.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: step.logs.isEmpty
              ? null
              : () => setState(() {
                    if (isExpanded) {
                      _expanded.remove(step.id);
                    } else {
                      _expanded.add(step.id);
                    }
                  }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                _buildStatusIcon(step.status),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    step.id.label,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (step.logs.isNotEmpty) ...[
                  IconButton(
                    icon: const Icon(Icons.copy, size: 16),
                    color: Colors.grey,
                    tooltip: 'Copy logs',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: step.logs.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Logs copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (isExpanded && step.logs.isNotEmpty)
          Builder(builder: (_) {
            _scrollToBottom(step.id);
            return Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 180),
              margin: const EdgeInsets.only(left: 28, bottom: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectionArea(
                child: Scrollbar(
                  controller: _controllerFor(step.id),
                  child: ListView.builder(
                    controller: _controllerFor(step.id),
                    padding: const EdgeInsets.all(8),
                    itemCount: step.logs.length,
                    itemBuilder: (_, i) => Text(
                      step.logs[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildStatusIcon(VagrantStepStatus status) {
    switch (status) {
      case VagrantStepStatus.pending:
        return const Icon(Icons.radio_button_unchecked, size: 18, color: Colors.grey);
      case VagrantStepStatus.running:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case VagrantStepStatus.passed:
        return const Icon(Icons.check_circle, size: 18, color: Colors.green);
      case VagrantStepStatus.failed:
        return const Icon(Icons.cancel, size: 18, color: Colors.red);
    }
  }

  Widget _buildResultBanner(bool? passed) {
    if (passed == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: passed ? Colors.green.shade800 : Colors.red.shade800,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        passed ? 'All tests passed' : 'Test failed — expand a step to see logs',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
      ),
    );
  }
}
