import 'package:emulator_orchestrator/data/services/hook_test_harness.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Modal result panel shown after the Hook DB dialog runs a hook
/// through the test harness. Displays the 10 captured `main()` return
/// values and any error message the harness produced.
class HookTestResultDialog extends StatelessWidget {
  final String hookLabel;
  final HookTestResult result;
  final VoidCallback? onRerun;

  const HookTestResultDialog({
    required this.hookLabel, required this.result, super.key,
    this.onRerun,
  });

  static Future<void> show(
    BuildContext context, {
    required String hookLabel,
    required HookTestResult result,
    VoidCallback? onRerun,
  }) =>
      showDialog<void>(
        context: context,
        builder: (_) => HookTestResultDialog(
          hookLabel: hookLabel,
          result: result,
          onRerun: onRerun,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final passed = result.ranToCompletion && result.errorMessage == null;
    final partialPass =
        result.ranToCompletion && result.errorMessage != null;
    return Dialog(
      backgroundColor: AppTheme.bgPanel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(hookLabel: hookLabel),
            const Divider(height: 1, color: AppTheme.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusRow(
                      passed: passed,
                      partialPass: partialPass,
                      runtime: result.runtime,
                    ),
                    if (result.errorMessage != null) ...[
                      const SizedBox(height: 12),
                      _ErrorBox(message: result.errorMessage!),
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      'main() return values (10 calls)',
                      style: TextStyle(
                          color: AppTheme.textMuted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    _ReturnValuesGrid(values: result.returnValues),
                    if (result.renodeLogTail.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _RenodeLogExpander(tail: result.renodeLogTail),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: AppTheme.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Row(
                children: [
                  if (onRerun != null)
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        onRerun!();
                      },
                      icon: const Icon(Icons.refresh, size: 14),
                      label: const Text('Re-run',
                          style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textPrimary,
                        side: const BorderSide(color: AppTheme.border),
                      ),
                    ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String hookLabel;
  const _Header({required this.hookLabel});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
        child: Row(
          children: [
            const Icon(Icons.science_outlined,
                size: 18, color: AppTheme.textPrimary),
            const SizedBox(width: 10),
            const Text(
              'HOOK TEST RESULT',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(width: 16),
            Flexible(
              child: Text(
                hookLabel,
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              color: AppTheme.textMuted,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
}

class _StatusRow extends StatelessWidget {
  final bool passed;
  final bool partialPass;
  final Duration runtime;

  const _StatusRow({
    required this.passed,
    required this.partialPass,
    required this.runtime,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = passed
        ? (Icons.check_circle, const Color(0xFF81C784), 'Ran without error')
        : partialPass
            ? (Icons.info_outline, const Color(0xFFFFB74D),
                'Ran with warnings')
            : (Icons.error_outline, const Color(0xFFE57373),
                'Did not complete');
    final runtimeStr =
        '${(runtime.inMilliseconds / 1000).toStringAsFixed(2)}s';
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(color: color, fontSize: 13),
        ),
        const SizedBox(width: 16),
        Text(
          '· $runtimeStr',
          style:
              const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFE57373).withValues(alpha: 0.08),
          border: Border.all(
              color: const Color(0xFFE57373).withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: SelectableText(
          message,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 11,
            fontFamily: 'monospace',
            height: 1.4,
          ),
        ),
      );
}

class _ReturnValuesGrid extends StatelessWidget {
  final List<int> values;
  const _ReturnValuesGrid({required this.values});

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'No results captured.',
          style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              fontStyle: FontStyle.italic),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bgCanvas,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < values.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      '[$i]',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  Text(
                    _fmtValue(values[i]),
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Show the value in decimal + hex side by side. Sign-aware decimal
  /// (interpret as int32) so a hook that returns -1 reads `-1` not
  /// `4294967295`.
  static String _fmtValue(int v) {
    final signed = (v & 0x80000000) != 0 ? v - 0x100000000 : v;
    final hex = v.toRadixString(16).padLeft(8, '0').toUpperCase();
    return '$signed  (0x$hex)';
  }
}

/// Collapsible "Renode log" expander shown below the return-values
/// grid. Hook bodies that `print(...)` or `sys.stderr.write(...)`
/// land in the tail; surfaces them in the dialog so users don't have
/// to `cat /tmp/resect_hook_test_harness/renode.log`.
class _RenodeLogExpander extends StatefulWidget {
  final String tail;
  const _RenodeLogExpander({required this.tail});

  @override
  State<_RenodeLogExpander> createState() => _RenodeLogExpanderState();
}

class _RenodeLogExpanderState extends State<_RenodeLogExpander> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                    color: AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'Renode log (tail)',
                    style: TextStyle(
                        color: AppTheme.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.bgCanvas,
                border: Border.all(color: AppTheme.border),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.tail,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    height: 1.3,
                  ),
                ),
              ),
            ),
        ],
      );
}
