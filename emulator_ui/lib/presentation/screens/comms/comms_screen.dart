import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';

/// COMMS tab — placeholder for the upcoming communications-abstraction
/// surface (mapping detected I2C / SPI / UART functions to Python
/// implementations).
///
/// Stays a placeholder for the foreseeable future: the feature depends on
/// the forthcoming Ghidra/Dart engine's classification pass.
class CommsScreen extends ConsumerWidget {
  const CommsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: AppTheme.bgCanvas,
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          color: AppTheme.bgPanel,
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'COMMS',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 3,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Map detected comms functions — I2C, SPI, UART — to Python implementations.',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 14, height: 1.5),
                ),
                SizedBox(height: 16),
                Text(
                  'Requires the new analysis engine with classification support. Not available yet.',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
                SizedBox(height: 20),
                ElevatedButton(
                  onPressed: null,
                  child: Text('Run classification'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
