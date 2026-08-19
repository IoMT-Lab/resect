import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// One round's plotted values, all on the shared 0–1 axis. Null series
/// values (e.g. coverage fidelity on a round with no traversal data)
/// leave a gap in that series.
class TrajectoryRound {
  const TrajectoryRound({
    required this.round,
    required this.fidelity,
    this.coverageFidelity,
    this.coverage,
    this.reverted = false,
    this.best = false,
  });

  final int round;
  final double fidelity;
  final double? coverageFidelity;
  final double? coverage;

  /// Reverted rounds draw hollow markers — their changes are not in
  /// effect.
  final bool reverted;

  /// The round whose overlays the session finished holding.
  final bool best;
}

/// Series colors, shared with the legend and the hover readout.
abstract class TrajectoryColors {
  static const fidelity = AppTheme.accent; // blue
  static const coverageFidelity = Color(0xFFFFA726); // amber
  static const coverage = Color(0xFF66BB6A); // green
}

/// Map a series of 0–1 values onto pixel offsets inside [size], with
/// round [minRound]..[maxRound] spread across the width. Null values
/// produce null offsets (series gap). Pure — unit-testable without a
/// canvas.
List<Offset?> trajectoryOffsets({
  required List<TrajectoryRound> rounds,
  required double? Function(TrajectoryRound) value,
  required Size size,
}) {
  if (rounds.isEmpty) return const [];
  final minRound = rounds.first.round;
  final maxRound = rounds.last.round;
  final span = (maxRound - minRound).clamp(1, 1 << 30);
  return [
    for (final r in rounds)
      switch (value(r)) {
        null => null,
        final v => Offset(
            (r.round - minRound) / span * size.width,
            (1 - v.clamp(0.0, 1.0)) * size.height,
          ),
      },
  ];
}

/// Line chart of the three session metrics — Fidelity, Coverage
/// Fidelity, Coverage — over auto-tune rounds. Hand-rolled painter (no
/// chart dependency); hover shows a per-round readout of all three.
class MetricTrajectoryChart extends StatefulWidget {
  const MetricTrajectoryChart({
    required this.rounds,
    this.height = 180,
    super.key,
  });

  final List<TrajectoryRound> rounds;
  final double height;

  @override
  State<MetricTrajectoryChart> createState() => _MetricTrajectoryChartState();
}

class _MetricTrajectoryChartState extends State<MetricTrajectoryChart> {
  /// Index into [widget.rounds] the pointer is nearest to, or null.
  int? _hovered;

  @override
  Widget build(BuildContext context) {
    final rounds = widget.rounds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(children: [
          _LegendEntry(color: TrajectoryColors.fidelity, label: 'Fidelity'),
          SizedBox(width: 16),
          _LegendEntry(
              color: TrajectoryColors.coverageFidelity,
              label: 'Coverage fidelity'),
          SizedBox(width: 16),
          _LegendEntry(color: TrajectoryColors.coverage, label: 'Coverage'),
        ]),
        const SizedBox(height: 8),
        SizedBox(
          height: widget.height,
          child: LayoutBuilder(builder: (context, constraints) {
            final size = Size(constraints.maxWidth, widget.height);
            return MouseRegion(
              onHover: (e) => setState(
                  () => _hovered = _nearestRound(e.localPosition, size)),
              onExit: (_) => setState(() => _hovered = null),
              child: Stack(children: [
                CustomPaint(
                  size: size,
                  painter: _TrajectoryPainter(
                    rounds: rounds,
                    hovered: _hovered,
                  ),
                ),
                if (_hovered != null) _readout(rounds[_hovered!], size),
              ]),
            );
          }),
        ),
      ],
    );
  }

  int? _nearestRound(Offset pos, Size size) {
    final rounds = widget.rounds;
    if (rounds.isEmpty) return null;
    final plot = _TrajectoryPainter.plotArea(size);
    final offsets = trajectoryOffsets(
      rounds: rounds,
      value: (r) => r.fidelity,
      size: plot.size,
    );
    int? best;
    var bestDx = double.infinity;
    for (var i = 0; i < offsets.length; i++) {
      final o = offsets[i];
      if (o == null) continue;
      final dx = ((o.dx + plot.left) - pos.dx).abs();
      if (dx < bestDx) {
        bestDx = dx;
        best = i;
      }
    }
    return best;
  }

  Widget _readout(TrajectoryRound r, Size size) {
    String pct(double? v) =>
        v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';
    return Positioned(
      top: 4,
      right: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.bgChrome.withValues(alpha: 0.92),
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'R${r.round}${r.reverted ? '  REVERTED' : ''}'
          '${r.best ? '  BEST' : ''}\n'
          'fidelity ${pct(r.fidelity)}\n'
          'cov fidelity ${pct(r.coverageFidelity)}\n'
          'coverage ${pct(r.coverage)}',
          style: const TextStyle(
            fontSize: 11,
            height: 1.4,
            fontFamily: 'monospace',
            color: AppTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 10, height: 3, color: color),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
      ]);
}

class _TrajectoryPainter extends CustomPainter {
  _TrajectoryPainter({required this.rounds, this.hovered});

  final List<TrajectoryRound> rounds;
  final int? hovered;

  /// Inset for axis labels: y labels on the left, round labels below.
  static Rect plotArea(Size size) =>
      Rect.fromLTRB(34, 4, size.width - 8, size.height - 18);

  @override
  void paint(Canvas canvas, Size size) {
    final plot = plotArea(size);
    final grid = Paint()
      ..color = AppTheme.border
      ..strokeWidth = 1;
    const labelStyle = TextStyle(fontSize: 9, color: AppTheme.textMuted);

    // Horizontal gridlines + y labels at 0/25/50/75/100%.
    for (var i = 0; i <= 4; i++) {
      final frac = i / 4;
      final y = plot.bottom - frac * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, '${(frac * 100).round()}%', labelStyle,
          Offset(0, y - 6), maxWidth: plot.left - 4);
    }

    if (rounds.isEmpty) return;

    // Round ticks — thin out labels when crowded.
    final every = (rounds.length / 12).ceil().clamp(1, 1 << 30);
    for (var i = 0; i < rounds.length; i++) {
      if (i % every != 0 && i != rounds.length - 1) continue;
      final x = _x(i, plot);
      _text(canvas, 'R${rounds[i].round}', labelStyle,
          Offset(x - 8, plot.bottom + 4), maxWidth: 30);
    }

    // Hover crosshair behind the series.
    if (hovered != null) {
      final x = _x(hovered!, plot);
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = AppTheme.textDisabled
          ..strokeWidth = 1,
      );
    }

    _series(canvas, plot, TrajectoryColors.coverage, (r) => r.coverage);
    _series(canvas, plot, TrajectoryColors.coverageFidelity,
        (r) => r.coverageFidelity);
    _series(canvas, plot, TrajectoryColors.fidelity, (r) => r.fidelity);
  }

  double _x(int index, Rect plot) {
    final span =
        (rounds.last.round - rounds.first.round).clamp(1, 1 << 30);
    return plot.left +
        (rounds[index].round - rounds.first.round) / span * plot.width;
  }

  void _series(Canvas canvas, Rect plot, Color color,
      double? Function(TrajectoryRound) value) {
    final offsets = trajectoryOffsets(
      rounds: rounds,
      value: value,
      size: plot.size,
    );
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path();
    var penDown = false;
    for (final o in offsets) {
      if (o == null) {
        penDown = false;
        continue;
      }
      final p = o.translate(plot.left, plot.top);
      penDown ? path.lineTo(p.dx, p.dy) : path.moveTo(p.dx, p.dy);
      penDown = true;
    }
    canvas.drawPath(path, line);

    // Markers: filled dots; hollow for reverted rounds.
    for (var i = 0; i < offsets.length; i++) {
      final o = offsets[i];
      if (o == null) continue;
      final p = o.translate(plot.left, plot.top);
      if (rounds[i].reverted) {
        canvas
          ..drawCircle(
              p,
              3,
              Paint()
                ..color = AppTheme.bgPanel
                ..style = PaintingStyle.fill)
          ..drawCircle(
              p,
              3,
              Paint()
                ..color = color
                ..strokeWidth = 1.5
                ..style = PaintingStyle.stroke);
      } else {
        canvas.drawCircle(p, 2.5, Paint()..color = color);
      }
    }
  }

  void _text(Canvas canvas, String s, TextStyle style, Offset at,
      {required double maxWidth}) {
    TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )
      ..layout(maxWidth: maxWidth)
      ..paint(canvas, at);
  }

  @override
  bool shouldRepaint(_TrajectoryPainter old) =>
      old.rounds != rounds || old.hovered != hovered;
}
