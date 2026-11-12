// Small hand-drawn charts in the design's style: orange line with ring dots, light gridlines.
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// One line on a [LineChartView].
class ChartSeries {
  const ChartSeries(this.name, this.color, this.values, {this.primary = false});
  final String name;
  final Color color;
  final List<double> values;

  /// The series that gets the Figma ring dots (solar).
  final bool primary;
}

/// Rounds up to 1, 2, 2.5 or 5 × 10ⁿ so axis labels are readable numbers.
double niceCeil(double x) {
  if (x <= 0) return 1;
  final mag = pow(10, (log(x) / ln10).floor()).toDouble();
  for (final m in [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * mag >= x - 1e-9) return m * mag;
  }
  return 10 * mag;
}

String _axis(double v, double top) => top < 1 ? v.toStringAsFixed(2) : (top < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0));

/// Line chart (Energy). Several series share a y-axis with values; tap or drag along the chart to
/// read each point. Screen readers get a one-sentence summary instead of the drawing.
class LineChartView extends StatefulWidget {
  const LineChartView({
    super.key,
    required this.series,
    required this.labels,
    this.title,
    this.unit = 'kWh',
    this.height = 140,
  });
  final String? title;
  final List<ChartSeries> series;
  final List<String> labels;
  final String unit;
  final double height;

  @override
  State<LineChartView> createState() => _LineChartViewState();
}

class _LineChartViewState extends State<LineChartView> {
  int? _sel;

  int get _n => widget.labels.length;

  @override
  void didUpdateWidget(covariant LineChartView old) {
    super.didUpdateWidget(old);
    if (old.labels.length != widget.labels.length || old.labels.firstOrNull != widget.labels.firstOrNull) _sel = null;
  }

  ChartSeries? get _primary => widget.series.where((s) => s.primary).firstOrNull ?? widget.series.firstOrNull;

  String _summary() {
    final parts = <String>[];
    for (final s in widget.series) {
      if (s.values.isEmpty) continue;
      final total = s.values.fold<double>(0, (a, b) => a + b);
      final peak = s.values.reduce(max);
      final at = s.values.indexOf(peak);
      parts.add('${s.name}: total ${total.toStringAsFixed(1)} ${widget.unit}, highest ${peak.toStringAsFixed(1)} at ${widget.labels[at]}');
    }
    return '${widget.title ?? 'Chart'}. ${parts.join('. ')}.';
  }

  void _pick(double dx, double left, double width) {
    if (_n == 0) return;
    final i = ((dx - left) / max(1, width) * (_n - 1)).round();
    final next = i.clamp(0, _n - 1);
    if (next != _sel) setState(() => _sel = next);
  }

  @override
  Widget build(BuildContext context) {
    final p = _primary;
    final sel = _sel ?? (p == null || p.values.isEmpty ? null : p.values.indexOf(p.values.reduce(max)));
    final scaler = MediaQuery.textScalerOf(context);
    final allValues = [for (final s in widget.series) ...s.values];
    final top = niceCeil(allValues.isEmpty ? 0 : allValues.reduce(max));
    final axisStyle = ts(10, w: FontWeight.w500, color: C.muted);
    // Left gutter wide enough for the longest y label at the current text size.
    final gutter = [for (final v in [0.0, top / 2, top]) _axis(v, top)]
            .map((s) => (TextPainter(text: TextSpan(text: s, style: axisStyle), textDirection: TextDirection.ltr, textScaler: scaler)
                  ..layout())
                .width)
            .reduce(max) +
        8;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.title != null) Semantics(header: true, child: Text(widget.title!, style: ts(13, w: FontWeight.w700, spacing: 0.1))),
        const SizedBox(height: 6),
        // Legend.
        Wrap(spacing: 14, runSpacing: 4, children: [
          for (final s in widget.series)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 12, height: 4, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 5),
              Text(s.name, style: ts(11, w: FontWeight.w600, color: C.label)),
            ]),
        ]),
        const SizedBox(height: 8),
        // Selected point, as in Figma 41:485's peach pill.
        if (sel != null)
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(color: C.pill, borderRadius: BorderRadius.circular(99)),
              child: Text(
                '${widget.labels[sel]}:  ${[
                  for (final s in widget.series)
                    if (sel < s.values.length) '${s.name} ${s.values[sel].toStringAsFixed(1)}',
                ].join(' · ')} ${widget.unit}',
                style: ts(11, w: FontWeight.w700, color: C.orangeText),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Semantics(
          label: _summary(),
          excludeSemantics: true,
          child: LayoutBuilder(builder: (context, box) {
            final plotLeft = gutter + 8, plotWidth = box.maxWidth - gutter - 16;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _pick(d.localPosition.dx, plotLeft, plotWidth),
              onHorizontalDragStart: (d) => _pick(d.localPosition.dx, plotLeft, plotWidth),
              onHorizontalDragUpdate: (d) => _pick(d.localPosition.dx, plotLeft, plotWidth),
              child: CustomPaint(
                size: Size(box.maxWidth, widget.height),
                painter: _LinePainter(widget.series, sel, top, gutter, axisStyle, scaler),
              ),
            );
          }),
        ),
        const SizedBox(height: 6),
        ExcludeSemantics(child: _XLabels(widget.labels, left: gutter, selected: sel)),
        const SizedBox(height: 4),
        Text('Tap or drag along the chart to see each point.', style: ts(10, color: C.muted)),
      ],
    );
  }
}

/// Shows at most ~7 evenly spaced labels so day (24) / month (30) don't overlap.
class _XLabels extends StatelessWidget {
  const _XLabels(this.labels, {required this.left, this.selected});
  final List<String> labels;
  final double left;
  final int? selected;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final n = labels.length;
    final step = max(1, (n / 6).ceil());
    const slot = 44.0; // each label is centred under its point in a fixed-width slot
    final style = ts(10, w: FontWeight.w500, color: C.muted);
    final height = MediaQuery.textScalerOf(context).scale(10) * 1.4 + 2;
    return LayoutBuilder(builder: (context, box) {
      final x0 = left + 8, w = box.maxWidth - left - 16;
      double x(int i) => x0 + w * (n == 1 ? 0.5 : i / (n - 1)); // same x as _LinePainter
      return SizedBox(
        height: height,
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < n; i += step)
            Positioned(
              left: (x(i) - slot / 2).clamp(0, max(0, box.maxWidth - slot)),
              width: slot,
              child: Text(
                labels[i],
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: i == selected ? style.copyWith(color: C.orangeText, fontWeight: FontWeight.w700) : style,
              ),
            ),
        ]),
      );
    });
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.series, this.sel, this.top, this.gutter, this.axisStyle, this.scaler);
  final List<ChartSeries> series;
  final int? sel;
  final double top, gutter;
  final TextStyle axisStyle;
  final TextScaler scaler;

  @override
  void paint(Canvas c, Size s) {
    final left = gutter + 8, right = s.width - 8, plotTop = 6.0, plotBottom = s.height - 6;
    double y(double v) => plotBottom - (plotBottom - plotTop) * (v / top);

    // Grid lines at 0, ¼, ½, ¾, 1 of the axis; labels at 0, ½ and the top.
    final grid = Paint()
      ..color = C.chartGrid
      ..strokeWidth = 0.6;
    for (var i = 0; i <= 4; i++) {
      final v = top * i / 4;
      c.drawLine(Offset(left - 4, y(v)), Offset(right, y(v)), grid);
      if (i.isEven) {
        final tp = TextPainter(text: TextSpan(text: _axis(v, top), style: axisStyle), textDirection: TextDirection.ltr, textScaler: scaler)
          ..layout();
        tp.paint(c, Offset(gutter - tp.width, y(v) - tp.height / 2));
      }
    }

    final n = series.isEmpty ? 0 : series.map((e) => e.values.length).reduce(max);
    if (n == 0) return;
    Offset at(List<double> v, int i) => Offset(left + (right - left) * (n == 1 ? 0.5 : i / (n - 1)), y(v[i]));

    // Selected point: a vertical guide.
    if (sel != null) {
      final x = left + (right - left) * (n == 1 ? 0.5 : sel! / (n - 1));
      c.drawLine(Offset(x, plotTop), Offset(x, plotBottom), Paint()
        ..color = C.orange.withValues(alpha: 0.35)
        ..strokeWidth = 1);
    }

    // Draw secondary series first so solar sits on top.
    for (final ser in [...series.where((e) => !e.primary), ...series.where((e) => e.primary)]) {
      final v = ser.values;
      if (v.isEmpty) continue;
      final path = Path()..moveTo(at(v, 0).dx, at(v, 0).dy);
      for (var i = 1; i < v.length; i++) {
        path.lineTo(at(v, i).dx, at(v, i).dy);
      }
      c.drawPath(
          path,
          Paint()
            ..color = ser.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = ser.primary ? 2.2 : 1.6
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round);

      if (ser.primary) {
        // Figma ring dots (9 px), thinned out on long series.
        final dotEvery = v.length > 12 ? (v.length / 8).ceil() : 1;
        for (var i = 0; i < v.length; i += dotEvery) {
          if (i == sel) continue;
          final p = at(v, i);
          c.drawCircle(p, 3.5, Paint()..color = Colors.white);
          c.drawCircle(p, 3.5, Paint()
            ..color = ser.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
        }
      }
      if (sel != null && sel! < v.length) {
        final p = at(v, sel!);
        c.drawCircle(p, ser.primary ? 5.5 : 4, Paint()..color = ser.color);
        c.drawCircle(p, ser.primary ? 2 : 1.5, Paint()..color = Colors.white);
      }
    }
  }

  @override
  bool shouldRepaint(_LinePainter o) => o.series != series || o.sel != sel || o.top != top || o.gutter != gutter;
}

/// Bar chart (Bill "Weekly Energy Cost"); the last bar is the current week. Tap a bar for its detail.
class BarChartView extends StatefulWidget {
  const BarChartView({
    super.key,
    required this.values,
    required this.labels,
    required this.format,
    this.detail,
    this.height = 96,
  });
  final List<double> values;
  final List<String> labels;
  final String Function(double) format;

  /// Text shown above the bars for the selected one (defaults to "label: value").
  final String Function(int i)? detail;
  final double height;

  @override
  State<BarChartView> createState() => _BarChartViewState();
}

class _BarChartViewState extends State<BarChartView> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final values = widget.values;
    if (values.isEmpty) return const SizedBox.shrink();
    final sel = (_sel ?? values.length - 1).clamp(0, values.length - 1);
    final top = max(0.001, values.reduce(max));
    String detail(int i) => widget.detail?.call(i) ?? '${widget.labels[i]}: ${widget.format(values[i])}';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: C.pill, borderRadius: BorderRadius.circular(99)),
          child: Text(detail(sel), style: ts(11, w: FontWeight.w700, color: C.orangeText)),
        ),
      ),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == sel,
                label: detail(i),
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _sel = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.format(values[i]),
                            style: ts(10, w: FontWeight.w700, color: i == sel ? C.orangeText : C.ink)),
                        const SizedBox(height: 4),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          height: max(4, widget.height * values[i] / top),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(6),
                            gradient: i == sel
                                ? const LinearGradient(
                                    begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [C.orange, C.yellow])
                                : null,
                            color: i == sel ? null : C.navOff.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(widget.labels[i], style: ts(10, w: FontWeight.w600, color: i == sel ? C.ink : C.muted)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ]);
  }
}
