import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Centered placeholder used by tab screens that haven't been built out yet.
class PlaceholderScreen extends StatelessWidget {
  final String title;
  final String subtitle;

  const PlaceholderScreen({
    required this.title, required this.subtitle, super.key,
  });

  @override
  Widget build(BuildContext context) => Container(
      color: AppTheme.bgCanvas,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
}
