// Small hand-drawn charts in the design's style: orange line with ring dots, light gridlines.
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Line chart (Energy "Solar Production"). Tap a point to see its value.
class LineChartView extends StatefulWidget {
  const LineChartView({super.key, required this.values, required this.labels, this.unit = 'kWh', this.height = 150});
  final List<double> values;
  final List<String> labels;
  final String unit;
  final double height;

  @override
  State<LineChartView> createState() => _LineChartViewState();
}

class _LineChartViewState extends State<LineChartView> {
  int? _sel;

  @override
  void didUpdateWidget(covariant LineChartView old) {
    super.didUpdateWidget(old);
    if (old.values.length != widget.values.length) _sel = null;
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.values;
    final sel = _sel ?? (v.isEmpty ? null : v.indexOf(v.reduce(max)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 16,
          child: sel == null
              ? null
              : Text('${widget.labels[sel]} · ${v[sel].toStringAsFixed(2)} ${widget.unit}',
                  style: ts(10, w: FontWeight.w600, color: C.orangeDeep)),
        ),
        LayoutBuilder(builder: (context, box) {
          return GestureDetector(
            onTapDown: (d) {
              if (v.isEmpty) return;
              final i = ((d.localPosition.dx - 8) / max(1, box.maxWidth - 16) * (v.length - 1)).round();
              setState(() => _sel = i.clamp(0, v.length - 1));
            },
            child: CustomPaint(
              size: Size(box.maxWidth, widget.height),
              painter: _LinePainter(v, sel),
            ),
          );
        }),
        const SizedBox(height: 6),
        _XLabels(widget.labels),
      ],
    );
  }
}

/// Shows at most ~8 evenly spaced labels so day (24) / month (30) don't overlap.
class _XLabels extends StatelessWidget {
  const _XLabels(this.labels);
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final n = labels.length;
    final step = max(1, (n / 7).ceil());
    const slot = 40.0; // each label is centred under its point in a fixed-width slot
    return LayoutBuilder(builder: (context, box) {
      double x(int i) => 8 + (box.maxWidth - 16) * (n == 1 ? 0.5 : i / (n - 1)); // same x as _LinePainter
      return SizedBox(
        height: 12,
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < n; i += step)
            Positioned(
              left: (x(i) - slot / 2).clamp(0, max(0, box.maxWidth - slot)),
              width: slot,
              child: Text(labels[i], textAlign: TextAlign.center, maxLines: 1, style: ts(8, w: FontWeight.w500, color: C.muted)),
            ),
        ]),
      );
    });
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.v, this.sel);
  final List<double> v;
  final int? sel;

  @override
  void paint(Canvas c, Size s) {
    final grid = Paint()
      ..color = const Color(0x1F292929)
      ..strokeWidth = 0.6;
    for (var i = 0; i < 4; i++) {
      final y = s.height * (i + 1) / 5;
      c.drawLine(Offset(0, y), Offset(s.width, y), grid);
    }
    if (v.isEmpty) return;
    final top = max(0.001, v.reduce(max));
    Offset at(int i) => Offset(
          8 + (s.width - 16) * (v.length == 1 ? 0.5 : i / (v.length - 1)),
          s.height - 6 - (s.height - 16) * (v[i] / top),
        );

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < v.length; i++) {
      final a = at(i - 1), b = at(i);
      final mx = (a.dx + b.dx) / 2;
      path.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
    }
    final fill = Path.from(path)
      ..lineTo(at(v.length - 1).dx, s.height)
      ..lineTo(at(0).dx, s.height)
      ..close();
    c.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                  colors: [C.orange.withValues(alpha: 0.22), C.orange.withValues(alpha: 0)])
              .createShader(Offset.zero & s));
    c.drawPath(
        path,
        Paint()
          ..color = C.orange
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round);

    final dotEvery = v.length > 12 ? (v.length / 8).ceil() : 1;
    for (var i = 0; i < v.length; i++) {
      if (i % dotEvery != 0 && i != sel) continue;
      final p = at(i);
      c.drawCircle(p, 3.5, Paint()..color = i == sel ? C.orange : Colors.white);
      c.drawCircle(
          p,
          3.5,
          Paint()
            ..color = C.orange
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_LinePainter o) => o.v != v || o.sel != sel;
}

/// Bar chart (Bill "Weekly Energy Cost"); the last bar is the current week.
class BarChartView extends StatelessWidget {
  const BarChartView({super.key, required this.values, required this.labels, required this.format, this.height = 96});
  final List<double> values;
  final List<String> labels;
  final String Function(double) format;
  final double height;

  @override
  Widget build(BuildContext context) {
    final top = values.isEmpty ? 1.0 : max(0.001, values.reduce(max));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(format(values[i]), style: ts(8, w: FontWeight.w700, color: C.ink)),
                  const SizedBox(height: 4),
                  Container(
                    height: max(4, height * values[i] / top),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: i == values.length - 1
                          ? const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                              colors: [C.orange, C.yellow])
                          : null,
                      color: i == values.length - 1 ? null : C.navOff.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(labels[i], style: ts(8, w: FontWeight.w500, color: C.muted)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
