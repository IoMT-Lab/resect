import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/data/services/recommendation_service.dart';
import 'package:flutter/material.dart';

/// Modal dialog the user fills in before starting an auto-tune
/// session. Returns the chosen [AutoTuneConfig] via `Navigator.pop`,
/// or `null` if the user cancels.
///
/// Defaults match [AutoTuneConfig]'s default constructor; the user
/// can tweak any field. Wall-clock is expressed in minutes for
/// readability; the dialog converts to [Duration] on submit.
class AutoTuneConfigDialog extends StatefulWidget {
  const AutoTuneConfigDialog({super.key, this.initial});

  /// Pre-fill the form with these values. Null = use library defaults.
  final AutoTuneConfig? initial;

  /// Open the dialog and return the user's chosen config (or null).
  static Future<AutoTuneConfig?> show(
    BuildContext context, {
    AutoTuneConfig? initial,
  }) =>
      showDialog<AutoTuneConfig>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AutoTuneConfigDialog(initial: initial),
      );

  @override
  State<AutoTuneConfigDialog> createState() => _AutoTuneConfigDialogState();
}

class _AutoTuneConfigDialogState extends State<AutoTuneConfigDialog> {
  late final TextEditingController _maxRoundsCtl;
  late final TextEditingController _snapshotCapCtl;
  late final TextEditingController _windowCtl;
  OptimizationTarget? _target;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final init = widget.initial ?? const AutoTuneConfig();
    _maxRoundsCtl = TextEditingController(text: '${init.maxRounds}');
    _snapshotCapCtl = TextEditingController(text: '${init.snapshotCap}');
    _windowCtl = TextEditingController(text: '${init.snapshotWindowSize}');
    _target = init.optimizationTarget;
  }

  @override
  void dispose() {
    _maxRoundsCtl.dispose();
    _snapshotCapCtl.dispose();
    _windowCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final maxRounds = int.tryParse(_maxRoundsCtl.text);
    final snapshotCap = int.tryParse(_snapshotCapCtl.text);
    final window = int.tryParse(_windowCtl.text);
    if (maxRounds == null || maxRounds < 1) {
      setState(() => _errorText = 'Max rounds must be a positive integer.');
      return;
    }
    if (snapshotCap == null || snapshotCap < 0) {
      setState(() =>
          _errorText = 'Snapshot cap must be 0 or greater (0 = drop all).');
      return;
    }
    if (window == null || window < 1) {
      setState(() => _errorText = 'Snapshot window must be at least 1.');
      return;
    }
    Navigator.of(context).pop(
      AutoTuneConfig(
        maxRounds: maxRounds,
        snapshotCap: snapshotCap,
        snapshotWindowSize: window,
        optimizationTarget: _target,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Auto-tune configuration'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The orchestrator runs synthesis, asks the LLM for changes, '
              'lets you review each one, and re-runs synthesis. Pick the '
              'budget and target before starting.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _maxRoundsCtl,
              decoration: const InputDecoration(
                labelText: 'Max LLM rounds',
                helperText:
                    'Hard cap on rounds (excluding the round-0 baseline).',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _snapshotCapCtl,
              decoration: const InputDecoration(
                labelText: 'Snapshot cap',
                helperText:
                    'Max round-snapshots kept on this .emu (FIFO pruned).',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _windowCtl,
              decoration: const InputDecoration(
                labelText: 'LLM context window (rounds)',
                helperText:
                    'How many recent rounds the LLM sees as input each round.',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<OptimizationTarget?>(
              initialValue: _target,
              decoration: const InputDecoration(
                labelText: 'Optimization target',
                helperText:
                    'Optional. Biases LLM recommendations toward one metric.',
              ),
              items: const [
                DropdownMenuItem(
                  value: null,
                  child: Text('No explicit target'),
                ),
                DropdownMenuItem(
                  value: OptimizationTarget.overallFidelity,
                  child: Text('Overall fidelity'),
                ),
                DropdownMenuItem(
                  value: OptimizationTarget.coverageFidelity,
                  child: Text('Coverage fidelity (reach more code)'),
                ),
                DropdownMenuItem(
                  value: OptimizationTarget.subgraphFidelity,
                  child: Text('Subgraph fidelity (tighten the start→end path)'),
                ),
              ],
              onChanged: (v) => setState(() => _target = v),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 16),
              Text(
                _errorText!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Start auto-tune'),
        ),
      ],
    );
  }
}
