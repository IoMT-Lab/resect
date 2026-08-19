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
/// rounds 0..[maxRound] spread across the width ([maxRound] defaults to
/// the last data round — pass the session's configured round budget for
/// a fixed axis that doesn't rescale as rounds land). Null values
/// produce null offsets (series gap). Pure — unit-testable without a
/// canvas.
List<Offset?> trajectoryOffsets({
  required List<TrajectoryRound> rounds,
  required double? Function(TrajectoryRound) value,
  required Size size,
  int? maxRound,
}) {
  if (rounds.isEmpty) return const [];
  final minRound = rounds.first.round;
  final span =
      ((maxRound ?? rounds.last.round) - minRound).clamp(1, 1 << 30);
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
    this.height = 240,
    this.maxRound,
    super.key,
  });

  final List<TrajectoryRound> rounds;
  final double height;

  /// When set, the x-axis spans rounds 0..[maxRound] regardless of how
  /// many rounds have landed — a session with a known round budget gets
  /// a stable axis instead of rescaling on every round. Null falls back
  /// to fitting the data.
  final int? maxRound;

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
                    maxRound: widget.maxRound,
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
      maxRound: widget.maxRound,
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
            fontSize: 12,
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
        Container(width: 14, height: 4, color: color),
        const SizedBox(width: 6),
        Text(label,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      ]);
}

class _TrajectoryPainter extends CustomPainter {
  _TrajectoryPainter({required this.rounds, this.hovered, this.maxRound});

  final List<TrajectoryRound> rounds;
  final int? hovered;
  final int? maxRound;

  /// End of the x domain: the fixed round budget when set, else the
  /// last data round.
  int get _domainEnd =>
      maxRound ?? (rounds.isEmpty ? 0 : rounds.last.round);

  /// Inset for axis labels: y labels on the left, round labels below.
  static Rect plotArea(Size size) =>
      Rect.fromLTRB(44, 6, size.width - 10, size.height - 22);

  @override
  void paint(Canvas canvas, Size size) {
    final plot = plotArea(size);
    final grid = Paint()
      ..color = AppTheme.border
      ..strokeWidth = 1;
    const labelStyle = TextStyle(fontSize: 11, color: AppTheme.textMuted);

    // Horizontal gridlines + y labels at 0/25/50/75/100%.
    for (var i = 0; i <= 4; i++) {
      final frac = i / 4;
      final y = plot.bottom - frac * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, '${(frac * 100).round()}%', labelStyle,
          Offset(0, y - 7), maxWidth: plot.left - 6);
    }

    if (rounds.isEmpty) return;

    // Round ticks across the whole domain (data or fixed budget) —
    // thinned out when crowded.
    final start = rounds.first.round;
    final domainSpan = (_domainEnd - start).clamp(1, 1 << 30);
    final tickCount = _domainEnd - start + 1;
    final every = (tickCount / 12).ceil().clamp(1, 1 << 30);
    for (var r = start; r <= _domainEnd; r++) {
      if ((r - start) % every != 0 && r != _domainEnd) continue;
      final x = plot.left + (r - start) / domainSpan * plot.width;
      _text(canvas, 'R$r', labelStyle, Offset(x - 9, plot.bottom + 6),
          maxWidth: 36);
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
    final span = (_domainEnd - rounds.first.round).clamp(1, 1 << 30);
    return plot.left +
        (rounds[index].round - rounds.first.round) / span * plot.width;
  }

  void _series(Canvas canvas, Rect plot, Color color,
      double? Function(TrajectoryRound) value) {
    final offsets = trajectoryOffsets(
      rounds: rounds,
      value: value,
      size: plot.size,
      maxRound: maxRound,
    );
    final line = Paint()
      ..color = color
      ..strokeWidth = 2.2
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
              4.5,
              Paint()
                ..color = AppTheme.bgPanel
                ..style = PaintingStyle.fill)
          ..drawCircle(
              p,
              4.5,
              Paint()
                ..color = color
                ..strokeWidth = 2
                ..style = PaintingStyle.stroke);
      } else {
        canvas.drawCircle(p, 4, Paint()..color = color);
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
      old.rounds != rounds ||
      old.hovered != hovered ||
      old.maxRound != maxRound;
}
