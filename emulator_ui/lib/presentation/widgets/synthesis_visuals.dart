import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Big-number-plus-label stat cell — the visual primitive both
/// pre-synthesis and post-synthesis reports use for their header
/// summary rows. Promoted here so both speak the same vocabulary.
class SummaryStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const SummaryStat({
    required this.label,
    required this.value,
    super.key,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: valueColor ?? AppTheme.textPrimary,
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
          ),
        ],
      );
}

/// Three-stop color ramp used by the post-synthesis report's fidelity
/// bar and reused by the pre-synthesis report's coverage bar so the
/// red/orange/green semantics match. [pct] is 0.0-1.0.
Color fidelityColor(double pct) {
  if (pct >= 0.8) return const Color(0xFF66BB6A);
  if (pct >= 0.5) return const Color(0xFFFFA726);
  return const Color(0xFFE57373);
}

/// Tone the pre-synthesis coverage bar uses for each bucket. Green
/// for the deterministic pre-applied segment, amber for the
/// reactive-bindings pool, neutral grey for the unbound remainder.
///
/// The amber pool further splits into two tones — saturated amber
/// for high-fidelity bindings (≥0.5; the synthesizer is more likely
/// to settle on these as the winning candidate) and muted amber for
/// low-fidelity bindings (<0.5; classifier-seeded floors that may
/// need iteration past). [binding] is kept as a single-tone fallback
/// for callers that don't want the split.
abstract class CoverageColors {
  static const preApplied = Color(0xFF66BB6A); // matches fidelity-high
  static const binding = Color(0xFFFFA726); // matches fidelity-mid
  static const bindingHigh = Color(0xFFFFA726); // saturated amber
  static const bindingLow = Color(0xFF8C6A2C); // muted amber
  static const unbound = Color(0xFF5A5A5A); // matches textDisabled tone
}
