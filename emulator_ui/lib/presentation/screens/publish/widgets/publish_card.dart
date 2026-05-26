import 'package:flutter/material.dart';

import '../../../../core/theme.dart';

/// A single export / action card in the Publish tab grid.
///
/// Renders an all-caps title, a one-sentence description, and either an
/// enabled primary button (when [onPressed] is non-null) or a single-line
/// `textMuted` hint explaining why the action is unavailable.
class PublishCard extends StatelessWidget {
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback? onPressed;

  /// When [onPressed] is null, displayed below the description in place of
  /// the button to explain the disabled state (e.g. "Save the emulator
  /// first").
  final String? disabledHint;

  /// Optional leading icon for visual cues.
  final IconData? icon;

  const PublishCard({
    super.key,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onPressed,
    this.disabledHint,
    this.icon,
  });

  bool get _enabled => onPressed != null;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.bgPanel,
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 16,
                  color: _enabled ? AppTheme.textPrimary : AppTheme.textDisabled,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: _enabled ? AppTheme.textPrimary : AppTheme.textDisabled,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: TextStyle(
              color: _enabled ? AppTheme.textMuted : AppTheme.textDisabled,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const Spacer(),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: _enabled
                ? ElevatedButton(
                    onPressed: onPressed,
                    child: Text(actionLabel),
                  )
                : Text(
                    disabledHint ?? 'Unavailable',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
