import 'package:emulator_orchestrator/data/models/auto_tune_config.dart';
import 'package:emulator_orchestrator/services/llm/recommendation_service.dart';
import 'package:flutter/material.dart';

/// What the user picked at session start: the shared engine config
/// plus the UI-only review-mode choice.
typedef AutoTuneSessionChoice = ({
  AutoTuneConfig config,
  bool interactiveReview,
});

/// Modal dialog the user fills in before starting an auto-tune
/// session. Returns the chosen [AutoTuneSessionChoice] via
/// `Navigator.pop`, or `null` if the user cancels.
///
/// Defaults match [AutoTuneConfig]'s default constructor; the user
/// can tweak any field.
class AutoTuneConfigDialog extends StatefulWidget {
  const AutoTuneConfigDialog({super.key, this.initial});

  /// Pre-fill the form with these values. Null = use library defaults.
  final AutoTuneConfig? initial;

  /// Open the dialog and return the user's chosen session settings
  /// (or null on cancel).
  static Future<AutoTuneSessionChoice?> show(
    BuildContext context, {
    AutoTuneConfig? initial,
  }) =>
      showDialog<AutoTuneSessionChoice>(
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
  late final TextEditingController _maxRecsCtl;
  late final TextEditingController _stagnantCtl;
  OptimizationTarget? _target;
  var _interactiveReview = true;
  var _warmStart = AutoTuneConfig.defaultWarmStart;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final init = widget.initial ?? const AutoTuneConfig();
    _maxRoundsCtl = TextEditingController(text: '${init.maxRounds}');
    _snapshotCapCtl = TextEditingController(text: '${init.snapshotCap}');
    _windowCtl = TextEditingController(text: '${init.snapshotWindowSize}');
    _maxRecsCtl =
        TextEditingController(text: '${init.maxRecommendationsPerRound}');
    _stagnantCtl = TextEditingController(text: '${init.stagnantRoundLimit}');
    _target = init.optimizationTarget;
    _warmStart = init.warmStart;
  }

  @override
  void dispose() {
    _maxRoundsCtl.dispose();
    _snapshotCapCtl.dispose();
    _windowCtl.dispose();
    _maxRecsCtl.dispose();
    _stagnantCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final maxRounds = int.tryParse(_maxRoundsCtl.text);
    final snapshotCap = int.tryParse(_snapshotCapCtl.text);
    final window = int.tryParse(_windowCtl.text);
    final maxRecs = int.tryParse(_maxRecsCtl.text);
    final stagnant = int.tryParse(_stagnantCtl.text);
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
    if (maxRecs == null || maxRecs < 1) {
      setState(() =>
          _errorText = 'Max recommendations per round must be at least 1.');
      return;
    }
    if (stagnant == null || stagnant < 1) {
      setState(() => _errorText = 'Stagnant-round limit must be at least 1.');
      return;
    }
    Navigator.of(context).pop((
      config: AutoTuneConfig(
        maxRounds: maxRounds,
        snapshotCap: snapshotCap,
        snapshotWindowSize: window,
        maxRecommendationsPerRound: maxRecs,
        stagnantRoundLimit: stagnant,
        warmStart: _warmStart,
        optimizationTarget: _target,
      ),
      interactiveReview: _interactiveReview,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
      title: const Text('Auto-tune configuration'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The engine runs synthesis, asks the LLM for changes, '
                'and re-runs synthesis. Pick the budget, target, and '
                'review mode before starting.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Review each round'),
                subtitle: const Text(
                    'Pause every round to accept/edit/reject the '
                    "LLM's recommendations. Off = accept everything "
                    'automatically (the CLI behavior).'),
                value: _interactiveReview,
                onChanged: (v) => setState(() => _interactiveReview = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Warm-start rounds'),
                subtitle: const Text(
                    "Seed each round with the previous round's resolved "
                    'hooks. Off = every round is an independent synthesis '
                    'from the overlay set (comparable rounds; the default).'),
                value: _warmStart,
                onChanged: (v) => setState(() => _warmStart = v),
              ),
              const SizedBox(height: 4),
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
                controller: _maxRecsCtl,
                decoration: const InputDecoration(
                  labelText: 'Max recommendations per round',
                  helperText:
                      "Cap on the LLM's proposed changes each round "
                      "(the schema's maxItems).",
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _stagnantCtl,
                decoration: const InputDecoration(
                  labelText: 'Stagnant-round limit',
                  helperText:
                      'Consecutive no-coverage-progress rounds before the '
                      'session stops early.',
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
                    child:
                        Text('Subgraph fidelity (tighten the start→end path)'),
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
