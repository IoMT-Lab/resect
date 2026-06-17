import 'package:emulator_orchestrator/data/models/recommendation.dart';
import 'package:emulator_orchestrator/data/models/round_snapshot.dart';
import 'package:flutter/material.dart';

/// One row of the auto-tune modal's review state.
///
/// Renders a single [Recommendation] with:
/// - A color-coded "kind" chip (set / clear / preference / generate
///   / adjust).
/// - The target symbol (or "iteration cap" for `AdjustIterationCap`)
///   and a compact summary of the proposed change.
/// - The LLM's rationale below.
/// - Three controls: Accept (default), Reject, Edit.
///
/// The row is stateless — it surfaces the [currentAction] passed in
/// and notifies the parent of any change via the callbacks. The
/// modal owns the per-recommendation decision state so the user's
/// choices persist when scrolling or re-opening the modal.
class RecommendationReviewRow extends StatelessWidget {
  const RecommendationReviewRow({
    required this.recommendation,
    required this.currentAction,
    required this.editedRecommendation,
    required this.onAccept,
    required this.onReject,
    required this.onEdit,
    super.key,
  });

  /// The recommendation the LLM emitted for this row.
  final Recommendation recommendation;

  /// User's current choice. The row paints itself with a tinted
  /// background reflecting the action.
  final UserAction currentAction;

  /// If the user has edited the recommendation, the modified
  /// version. Used to render the summary using the edited values
  /// when present.
  final Recommendation? editedRecommendation;

  /// Called when the user taps Accept.
  final VoidCallback onAccept;

  /// Called when the user taps Reject.
  final VoidCallback onReject;

  /// Called when the user submits an edit. The new recommendation
  /// replaces [editedRecommendation] and the row's action becomes
  /// [UserAction.edited].
  final ValueChanged<Recommendation> onEdit;

  @override
  Widget build(BuildContext context) {
    final effective = editedRecommendation ?? recommendation;
    return Card(
      color: _backgroundForAction(context, currentAction),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _KindChip(recommendation: effective),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _summary(effective),
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                _RowControls(
                  currentAction: currentAction,
                  onAccept: onAccept,
                  onReject: onReject,
                  onEdit: () => _openEditor(context),
                ),
              ],
            ),
            if (effective.rationale.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                effective.rationale,
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (currentAction == UserAction.edited &&
                editedRecommendation != null) ...[
              const SizedBox(height: 4),
              Text(
                'Edited from: ${_summary(recommendation)}',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _backgroundForAction(BuildContext context, UserAction action) {
    final scheme = Theme.of(context).colorScheme;
    switch (action) {
      case UserAction.accepted:
        return scheme.primaryContainer.withValues(alpha: 0.25);
      case UserAction.rejected:
        return scheme.errorContainer.withValues(alpha: 0.2);
      case UserAction.edited:
        return scheme.tertiaryContainer.withValues(alpha: 0.3);
    }
  }

  String _summary(Recommendation r) {
    switch (r) {
      case SetForcedOverride(
            :final symbol,
            :final artifactId,
            :final scope
          ):
        final scopeStr = scope != null && scope.isNotEmpty
            ? ' (scope: $scope)'
            : '';
        return 'Pin `$symbol` → artifact #$artifactId$scopeStr';
      case ClearForcedOverride(:final symbol):
        return 'Unpin `$symbol`';
      case SetPreference(:final symbol, :final artifactId):
        return 'Prefer artifact #$artifactId for `$symbol`';
      case GenerateCustomHook(:final symbol, :final intent):
        final intentStr = intent != null && intent.isNotEmpty
            ? ' — $intent'
            : '';
        return 'Generate new hook for `$symbol`$intentStr';
      case AdjustIterationCap(:final newValue):
        return 'Set iteration cap → $newValue';
    }
  }

  Future<void> _openEditor(BuildContext context) async {
    final edited = await _RecommendationEditorDialog.show(
      context,
      original: editedRecommendation ?? recommendation,
    );
    if (edited != null) onEdit(edited);
  }
}

class _RowControls extends StatelessWidget {
  const _RowControls({
    required this.currentAction,
    required this.onAccept,
    required this.onReject,
    required this.onEdit,
  });

  final UserAction currentAction;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          label: 'Accept',
          icon: Icons.check,
          selected: currentAction == UserAction.accepted,
          onPressed: onAccept,
          selectedColor: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 4),
        _ActionButton(
          label: 'Reject',
          icon: Icons.close,
          selected: currentAction == UserAction.rejected,
          onPressed: onReject,
          selectedColor: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(width: 4),
        _ActionButton(
          label: 'Edit',
          icon: Icons.edit,
          selected: currentAction == UserAction.edited,
          onPressed: onEdit,
          selectedColor: Theme.of(context).colorScheme.tertiary,
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
    required this.selectedColor,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;
  final Color selectedColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: IconButton(
        icon: Icon(icon),
        color: selected ? selectedColor : Theme.of(context).colorScheme.outline,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor:
              selected ? selectedColor.withValues(alpha: 0.15) : null,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.recommendation});

  final Recommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (recommendation) {
      SetForcedOverride() => ('OVERRIDE', Colors.indigo),
      ClearForcedOverride() => ('CLEAR', Colors.blueGrey),
      SetPreference() => ('PREFER', Colors.teal),
      GenerateCustomHook() => ('GENERATE', Colors.deepPurple),
      AdjustIterationCap() => ('ITER CAP', Colors.amber),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Inline editor that lets the user adjust a [Recommendation]'s
/// fields. Returns the edited recommendation on submit (or null on
/// cancel). Each [Recommendation] subclass exposes a different
/// field set; the editor renders the appropriate inputs.
class _RecommendationEditorDialog extends StatefulWidget {
  const _RecommendationEditorDialog({required this.original});

  final Recommendation original;

  static Future<Recommendation?> show(
    BuildContext context, {
    required Recommendation original,
  }) =>
      showDialog<Recommendation>(
        context: context,
        builder: (_) => _RecommendationEditorDialog(original: original),
      );

  @override
  State<_RecommendationEditorDialog> createState() =>
      _RecommendationEditorDialogState();
}

class _RecommendationEditorDialogState
    extends State<_RecommendationEditorDialog> {
  late final TextEditingController _rationaleCtl;
  // Per-kind controllers — only the relevant ones get populated.
  TextEditingController? _symbolCtl;
  TextEditingController? _artifactIdCtl;
  TextEditingController? _scopeCtl;
  TextEditingController? _intentCtl;
  TextEditingController? _newValueCtl;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final r = widget.original;
    _rationaleCtl = TextEditingController(text: r.rationale);
    switch (r) {
      case SetForcedOverride(:final symbol, :final artifactId, :final scope):
        _symbolCtl = TextEditingController(text: symbol);
        _artifactIdCtl = TextEditingController(text: '$artifactId');
        _scopeCtl = TextEditingController(text: scope ?? '');
      case ClearForcedOverride(:final symbol):
        _symbolCtl = TextEditingController(text: symbol);
      case SetPreference(:final symbol, :final artifactId):
        _symbolCtl = TextEditingController(text: symbol);
        _artifactIdCtl = TextEditingController(text: '$artifactId');
      case GenerateCustomHook(:final symbol, :final intent):
        _symbolCtl = TextEditingController(text: symbol);
        _intentCtl = TextEditingController(text: intent ?? '');
      case AdjustIterationCap(:final newValue):
        _newValueCtl = TextEditingController(text: '$newValue');
    }
  }

  @override
  void dispose() {
    _rationaleCtl.dispose();
    _symbolCtl?.dispose();
    _artifactIdCtl?.dispose();
    _scopeCtl?.dispose();
    _intentCtl?.dispose();
    _newValueCtl?.dispose();
    super.dispose();
  }

  void _submit() {
    final rationale = _rationaleCtl.text;
    final Recommendation? next;
    switch (widget.original) {
      case SetForcedOverride():
        final symbol = _symbolCtl!.text.trim();
        final artifactId = int.tryParse(_artifactIdCtl!.text);
        if (symbol.isEmpty) {
          setState(() => _errorText = 'Symbol must not be empty.');
          return;
        }
        if (artifactId == null) {
          setState(() => _errorText = 'Artifact id must be an integer.');
          return;
        }
        final scope = _scopeCtl!.text.trim();
        next = SetForcedOverride(
          rationale: rationale,
          symbol: symbol,
          artifactId: artifactId,
          scope: scope.isEmpty ? null : scope,
        );
      case ClearForcedOverride():
        final symbol = _symbolCtl!.text.trim();
        if (symbol.isEmpty) {
          setState(() => _errorText = 'Symbol must not be empty.');
          return;
        }
        next = ClearForcedOverride(rationale: rationale, symbol: symbol);
      case SetPreference():
        final symbol = _symbolCtl!.text.trim();
        final artifactId = int.tryParse(_artifactIdCtl!.text);
        if (symbol.isEmpty) {
          setState(() => _errorText = 'Symbol must not be empty.');
          return;
        }
        if (artifactId == null) {
          setState(() => _errorText = 'Artifact id must be an integer.');
          return;
        }
        next = SetPreference(
          rationale: rationale,
          symbol: symbol,
          artifactId: artifactId,
        );
      case GenerateCustomHook():
        final symbol = _symbolCtl!.text.trim();
        if (symbol.isEmpty) {
          setState(() => _errorText = 'Symbol must not be empty.');
          return;
        }
        final intent = _intentCtl!.text.trim();
        next = GenerateCustomHook(
          rationale: rationale,
          symbol: symbol,
          intent: intent.isEmpty ? null : intent,
        );
      case AdjustIterationCap():
        final value = int.tryParse(_newValueCtl!.text);
        if (value == null || value < 1) {
          setState(() => _errorText = 'New value must be a positive integer.');
          return;
        }
        next = AdjustIterationCap(rationale: rationale, newValue: value);
    }
    Navigator.of(context).pop(next);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit recommendation'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _rationaleCtl,
              decoration: const InputDecoration(labelText: 'Rationale'),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            ..._kindSpecificFields(),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
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
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }

  List<Widget> _kindSpecificFields() {
    final r = widget.original;
    final fields = <Widget>[];
    if (_symbolCtl != null) {
      fields.add(TextField(
        controller: _symbolCtl,
        decoration: const InputDecoration(labelText: 'Symbol'),
      ));
      fields.add(const SizedBox(height: 8));
    }
    if (_artifactIdCtl != null) {
      fields.add(TextField(
        controller: _artifactIdCtl,
        decoration: const InputDecoration(labelText: 'Artifact id'),
        keyboardType: TextInputType.number,
      ));
      fields.add(const SizedBox(height: 8));
    }
    if (_scopeCtl != null && r is SetForcedOverride) {
      fields.add(TextField(
        controller: _scopeCtl,
        decoration: const InputDecoration(
          labelText: 'Renode scope (optional)',
        ),
      ));
      fields.add(const SizedBox(height: 8));
    }
    if (_intentCtl != null && r is GenerateCustomHook) {
      fields.add(TextField(
        controller: _intentCtl,
        decoration: const InputDecoration(
          labelText: 'Intent hint for the LLM (optional)',
        ),
      ));
      fields.add(const SizedBox(height: 8));
    }
    if (_newValueCtl != null && r is AdjustIterationCap) {
      fields.add(TextField(
        controller: _newValueCtl,
        decoration: const InputDecoration(labelText: 'New iteration cap'),
        keyboardType: TextInputType.number,
      ));
      fields.add(const SizedBox(height: 8));
    }
    return fields;
  }
}
