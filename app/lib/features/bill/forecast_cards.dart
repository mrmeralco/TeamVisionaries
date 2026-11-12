// Bill & Savings: the evidence behind the forecast, from `forecast_detail` in GET /api/bill.
//   ForecastChartCard  the month day by day: metered so far (solid), the forecast (dashed) with its likely
//                      range opening up to month end, and Meralco's level boundaries as lines
//   ForecastHowCard    how the number is made: measured, learned, forecast, priced
//   ChargesCard        where the peso goes (energy, distribution, supply & metering, energy tax), each with
//                      its kWh × rate, and the distribution levels with the one this month lands in
// Every number comes from the server (server/app/energy.py forecast_detail, tariff.py); nothing is
// recomputed here except sums for display. Older servers send no detail: the Bill screen then skips these.
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../common/charts.dart' show niceCeil;
import '../common/ui.dart';
import '../meter/meter_cards.dart' show levelLabel;

String _php(Object? v) => formatPhp(numOr(v), whole: true);
String _rate(Object? v) => formatPhp(numOr(v)); // ₱1.45: per-kWh rates keep their centavos
/// A rate as Meralco's schedule prints it: ₱0.9803.
String _schedule(Object? v) => '₱${numOr(v).toStringAsFixed(4)}';
String _kwh(Object? v) => numOr(v).toDouble().toStringAsFixed(numOr(v) >= 100 ? 0 : 1);

/// "Nov 5" from the bill's "YYYY-MM" and a day of the month.
String _date(String month, int day) {
  final parts = month.split('-');
  final m = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1;
  const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${names[(m - 1).clamp(0, 11)]} $day';
}

// ------------------------------------------------------------------- chart --
class ForecastChartCard extends StatefulWidget {
  const ForecastChartCard(this.d, {super.key, required this.month, required this.daysInMonth});
  final Map<String, dynamic> d; // forecast_detail
  final String month; // YYYY-MM
  final int daysInMonth;

  @override
  State<ForecastChartCard> createState() => _ForecastChartCardState();
}

class _ForecastChartCardState extends State<ForecastChartCard> {
  int? _sel; // selected day (1..n)

  List<Map<String, dynamic>> get _days => listOfMaps(widget.d['days']);

  /// Level boundaries worth drawing: every one below the top of the axis.
  List<double> _bounds(double top) => [
        for (final r in listOfMaps(mapOf(widget.d['rates'])['distribution']))
          if (r['max_kwh'] is num && (r['max_kwh'] as num) < top) (r['max_kwh'] as num).toDouble(),
      ];

  double get _top {
    final d = widget.d;
    var top = numOr(d['high_kwh']).toDouble();
    // Show the next level up when the month is close to it, so "how close" is visible.
    final up = mapOf(mapOf(d['level'])['up']);
    if (up.isNotEmpty && numOr(up['kwh_away']) < 0.35 * numOr(d['kwh'], 1)) top = max(top, numOr(up['at_kwh']).toDouble());
    // A round top with a round middle (the gridlines' labels), no more than about one step of empty space.
    final step = niceCeil(top * 1.05 / 8) * 2;
    return max(step, (top * 1.05 / step).ceil() * step);
  }

  void _pick(double dx, double left, double width) {
    final n = widget.daysInMonth;
    final day = ((dx - left) / max(1, width) * n).round().clamp(1, n);
    if (day != _sel) setState(() => _sel = day);
  }

  String _readout(int day) {
    final p = _days.where((x) => x['day'] == day).firstOrNull;
    if (p == null) return '';
    final when = _date(widget.month, day);
    return switch (str(p['kind'])) {
      'actual' => '$when · ${_kwh(p['cum_kwh'])} kWh so far (metered)',
      _ => '$when · forecast ${_kwh(p['cum_kwh'])} kWh (likely ${_kwh(p['cum_low_kwh'])}–${_kwh(p['cum_high_kwh'])})',
    };
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final n = widget.daysInMonth;
    final top = _top;
    final level = mapOf(d['level']);
    final levelName = levelLabel(numOr(level['min_kwh']), level['max_kwh'] as num?);
    final sel = _sel ?? n;
    final scaler = MediaQuery.textScalerOf(context);
    final axis = ts(10, w: FontWeight.w500, color: C.muted);
    final gutter = (TextPainter(text: TextSpan(text: top.toStringAsFixed(0), style: axis), textDirection: TextDirection.ltr, textScaler: scaler)
              ..layout())
            .width +
        8;

    return SCard(
      key: const Key('bill-forecast-chart'),
      padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const CardTitle('This month, day by day'),
        const SizedBox(height: 2),
        Text('Grid kWh added up through the month: measured until yesterday, then the forecast.',
            style: ts(11, height: 1.4, color: C.muted)),
        const SizedBox(height: S.x3),
        Wrap(spacing: 14, runSpacing: 6, children: [
          _Key(line: C.orangeDeep, label: 'Measured'),
          _Key(line: C.orangeDeep, dashed: true, label: 'Forecast'),
          _Key(fill: C.orange.withValues(alpha: 0.18), label: 'Likely range'),
          _Key(line: C.muted, dashed: true, label: 'Meralco level'),
        ]),
        const SizedBox(height: S.x2),
        Semantics(
          liveRegion: true,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(color: C.pill, borderRadius: BorderRadius.circular(99)),
            child: Text(_readout(sel), style: ts(11, w: FontWeight.w700, color: C.orangeText)),
          ),
        ),
        const SizedBox(height: S.x3),
        Semantics(
          label: 'This month: ${_kwh(d['done_kwh'])} kWh measured in ${str(d['done_days'])} days. Forecast '
              '${_kwh(d['kwh'])} kWh by ${_date(widget.month, n)}, likely ${_kwh(d['low_kwh'])} to ${_kwh(d['high_kwh'])}, '
              'in the $levelName level.',
          excludeSemantics: true,
          child: LayoutBuilder(builder: (context, box) {
            final left = gutter + 8, width = box.maxWidth - gutter - 16 - 30;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (e) => _pick(e.localPosition.dx, left, width),
              onHorizontalDragStart: (e) => _pick(e.localPosition.dx, left, width),
              onHorizontalDragUpdate: (e) => _pick(e.localPosition.dx, left, width),
              child: CustomPaint(
                size: Size(box.maxWidth, 170),
                painter: _ForecastPainter(
                  days: _days,
                  n: n,
                  doneDays: numOr(d['done_days']).toInt(),
                  top: top,
                  bounds: _bounds(top),
                  sel: sel,
                  gutter: gutter,
                  axis: axis,
                  scaler: scaler,
                  today: 'Today',
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: Padding(
            padding: EdgeInsets.only(left: gutter + 8, right: 38),
            child: Row(children: [
              for (final (i, day) in [1, (n / 2).round(), n].indexed) ...[
                Expanded(
                  child: Text(_date(widget.month, day),
                      style: axis, maxLines: 1, softWrap: false, overflow: TextOverflow.clip,
                      textAlign: i == 0 ? TextAlign.left : (i == 1 ? TextAlign.center : TextAlign.right)),
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: S.x3),
        Text.rich(
          TextSpan(style: ts(12, height: 1.45, color: C.label), children: [
            const TextSpan(text: 'Heading for '),
            TextSpan(text: '${_kwh(d['kwh'])} kWh', style: ts(12, w: FontWeight.w800, color: C.ink)),
            TextSpan(text: ' (likely ${_kwh(d['low_kwh'])}–${_kwh(d['high_kwh'])}), in the '),
            TextSpan(text: levelName, style: ts(12, w: FontWeight.w800, color: C.ink)),
            const TextSpan(text: ' level. Tap or drag along the chart to read a day.'),
          ]),
        ),
      ]),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({this.line, this.fill, this.dashed = false, required this.label});
  final Color? line, fill;
  final bool dashed;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 16,
          height: 10,
          child: fill != null
              ? DecoratedBox(decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(2)))
              : CustomPaint(painter: _KeyLine(line!, dashed)),
        ),
        const SizedBox(width: 5),
        Flexible(child: Text(label, style: ts(11, w: FontWeight.w600, color: C.label))),
      ]);
}

class _KeyLine extends CustomPainter {
  _KeyLine(this.color, this.dashed);
  final Color color;
  final bool dashed;
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    if (!dashed) {
      c.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), p);
    } else {
      for (var x = 0.0; x < s.width; x += 6) {
        c.drawLine(Offset(x, s.height / 2), Offset(min(x + 3, s.width), s.height / 2), p);
      }
    }
  }

  @override
  bool shouldRepaint(_KeyLine o) => o.color != color || o.dashed != dashed;
}

class _ForecastPainter extends CustomPainter {
  _ForecastPainter({
    required this.days,
    required this.n,
    required this.doneDays,
    required this.top,
    required this.bounds,
    required this.sel,
    required this.gutter,
    required this.axis,
    required this.scaler,
    required this.today,
  });
  final List<Map<String, dynamic>> days;
  final int n, doneDays, sel;
  final double top, gutter;
  final List<double> bounds;
  final TextStyle axis;
  final TextScaler scaler;
  final String today;

  @override
  void paint(Canvas c, Size s) {
    final left = gutter + 8, right = s.width - 38, plotTop = 8.0, plotBottom = s.height - 4;
    double x(num day) => left + (right - left) * (day / max(1, n));
    double y(num v) => plotBottom - (plotBottom - plotTop) * (v / top);
    TextPainter label(String t, TextStyle st) =>
        TextPainter(text: TextSpan(text: t, style: st), textDirection: TextDirection.ltr, textScaler: scaler)..layout();

    // Grid: 0, ½ and the top, labelled.
    final grid = Paint()
      ..color = C.chartGrid
      ..strokeWidth = 0.6;
    for (final v in [0.0, top / 2, top]) {
      c.drawLine(Offset(left - 4, y(v)), Offset(right, y(v)), grid);
      final tp = label(v.toStringAsFixed(0), axis);
      tp.paint(c, Offset(gutter - tp.width, y(v) - tp.height / 2));
    }

    // Meralco level boundaries: crossing one moves the whole month to the next distribution rate.
    final dash = Paint()
      ..color = C.muted.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    for (final b in bounds) {
      for (var px = left; px < right; px += 7) {
        c.drawLine(Offset(px, y(b)), Offset(min(px + 3.5, right), y(b)), dash);
      }
      final tp = label('${b.round()}', axis.copyWith(fontWeight: FontWeight.w700, color: C.label));
      tp.paint(c, Offset(right + 4, y(b) - tp.height / 2));
    }

    final pts = [for (final d in days) (day: numOr(d['day']).toInt(), mid: numOr(d['cum_kwh']).toDouble(),
        lo: numOr(d['cum_low_kwh']).toDouble(), hi: numOr(d['cum_high_kwh']).toDouble(), kind: str(d['kind']))];
    if (pts.isEmpty) return;
    final doneKwh = doneDays == 0 ? 0.0 : pts.firstWhere((p) => p.day == doneDays, orElse: () => pts.first).mid;
    final ahead = pts.where((p) => p.kind != 'actual').toList();

    // Likely range: a band from today's start to the month's low-high.
    if (ahead.isNotEmpty) {
      final band = Path()..moveTo(x(doneDays), y(doneKwh));
      for (final p in ahead) {
        band.lineTo(x(p.day), y(p.hi));
      }
      for (final p in ahead.reversed) {
        band.lineTo(x(p.day), y(p.lo));
      }
      band.close();
      c.drawPath(band, Paint()..color = C.orange.withValues(alpha: 0.18));
    }

    // "Today" guide.
    final guide = Paint()
      ..color = C.orangeText.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var py = plotTop; py < plotBottom; py += 5) {
      c.drawLine(Offset(x(doneDays), py), Offset(x(doneDays), min(py + 2.5, plotBottom)), guide);
    }
    final tt = label(today, axis.copyWith(color: C.orangeText, fontWeight: FontWeight.w700));
    tt.paint(c, Offset((x(doneDays) + 3).clamp(left, right - tt.width), plotTop - 2));

    final stroke = Paint()
      ..color = C.orangeDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // Measured: solid, from the 1st.
    final measured = Path()..moveTo(x(0), y(0));
    for (final p in pts.where((p) => p.kind == 'actual')) {
      measured.lineTo(x(p.day), y(p.mid));
    }
    c.drawPath(measured, stroke);

    // Forecast: dashed, from where the measured line ends.
    var from = Offset(x(doneDays), y(doneKwh));
    for (final p in ahead) {
      final to = Offset(x(p.day), y(p.mid));
      final len = (to - from).distance;
      for (var t = 0.0; t < len; t += 7) {
        c.drawLine(Offset.lerp(from, to, t / len)!, Offset.lerp(from, to, min(t + 4, len) / len)!, stroke);
      }
      from = to;
    }

    // Month end: the forecast, ringed.
    final end = pts.last;
    c.drawCircle(Offset(x(end.day), y(end.mid)), 4.5, Paint()..color = C.card);
    c.drawCircle(Offset(x(end.day), y(end.mid)), 4.5, Paint()
      ..color = C.orangeDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2);

    // Selected day.
    final s0 = pts.where((p) => p.day == sel).firstOrNull;
    if (s0 != null) {
      c.drawLine(Offset(x(s0.day), plotTop), Offset(x(s0.day), plotBottom), Paint()
        ..color = C.orange.withValues(alpha: 0.35)
        ..strokeWidth = 1);
      c.drawCircle(Offset(x(s0.day), y(s0.mid)), 5, Paint()..color = C.orangeDeep);
      c.drawCircle(Offset(x(s0.day), y(s0.mid)), 2, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_ForecastPainter o) =>
      o.days != days || o.sel != sel || o.top != top || o.gutter != gutter || o.n != n;
}

// --------------------------------------------------------- how it is made --
class ForecastHowCard extends StatelessWidget {
  const ForecastHowCard(this.d, {super.key, required this.b, this.solar = true});
  final Map<String, dynamic> d; // forecast_detail
  final Map<String, dynamic> b; // the whole /api/bill
  final bool solar;

  @override
  Widget build(BuildContext context) {
    final sarima = d['method'] == 'sarima';
    final left = numOr(d['days_left']).toInt();
    final perDay = left == 0 ? 0 : numOr(d['days_left_kwh']) / left;
    final recent = d['recent_kwh_per_day'] as num?;
    final level = mapOf(d['level']);
    final source = b['grid_source'] == 'meter' ? 'your meter' : 'your inverter';
    final steps = <(String, String)>[
      (
        'Measured so far',
        '${_kwh(d['done_kwh'])} kWh from the grid in ${str(d['done_days'])} finished '
            '${d['done_days'] == 1 ? 'day' : 'days'}, read by $source.',
      ),
      (
        'Learned your pattern',
        '${sarima ? 'A weekly SARIMA model trained on your last ${str(d['history_days'])} days, so weekdays and weekends follow your own habits.' : 'Your weekday and weekend averages over your last ${str(d['history_days'])} days.'}'
            '${recent == null ? '' : ' Lately you use about ${_kwh(recent)} kWh a day (last 14 days).'}',
      ),
      (
        'Forecast the rest',
        '$left ${left == 1 ? 'day' : 'days'} left, today included: about ${_kwh(d['days_left_kwh'])} kWh, '
            '${_kwh(perDay)} kWh a day, adjusted for the season${solar ? ' and what your solar covers' : ''}.',
      ),
      (
        'Priced at Meralco’s rates',
        '${_kwh(d['done_kwh'])} + ${_kwh(d['days_left_kwh'])} = ${_kwh(d['kwh'])} kWh (likely '
            '${_kwh(d['low_kwh'])}–${_kwh(d['high_kwh'])}) lands in the '
            '${levelLabel(numOr(level['min_kwh']), level['max_kwh'] as num?)} level: ${_php(b['forecast_php'])}, '
            'likely ${_php(b['forecast_low_php'])}–${_php(b['forecast_high_php'])}.',
      ),
    ];
    return SCard(
      key: const Key('bill-forecast-how'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const CardTitle('How this forecast is made'),
        const SizedBox(height: S.x3),
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) const SizedBox(height: S.x3),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: C.orange.withValues(alpha: 0.16), shape: BoxShape.circle),
              child: Text('${i + 1}', style: ts(11, w: FontWeight.w800, color: C.orangeText)),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(steps[i].$1, style: ts(12.5, w: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(steps[i].$2, style: ts(12, height: 1.45, color: C.label)),
              ]),
            ),
          ]),
        ],
        const SizedBox(height: S.x3),
        Text(
          'The range is about 2 in 3: most months land inside it. It narrows as the month goes on.',
          style: ts(10.5, height: 1.4, color: C.muted),
        ),
      ]),
    );
  }
}

// ----------------------------------------------------------------- charges --
class ChargesCard extends StatelessWidget {
  const ChargesCard(this.d, {super.key, required this.total});
  final Map<String, dynamic> d; // forecast_detail
  final num total; // forecast_php: the charges add up to it

  static Color _color(String id) => switch (id) {
        'energy' => C.orangeDeep,
        'distribution' => C.orange,
        'fixed' => C.amber,
        _ => C.red,
      };

  @override
  Widget build(BuildContext context) {
    final charges = listOfMaps(d['charges']);
    final rates = mapOf(d['rates']);
    final level = mapOf(d['level']);
    final vat = str(rates['vat_pct'], '12');
    final sum = charges.fold<double>(0, (a, c) => a + numOr(c['php']).toDouble());
    final levelName = levelLabel(numOr(level['min_kwh']), level['max_kwh'] as num?);

    String evidence(Map<String, dynamic> c) => switch (str(c['id'])) {
          'energy' => '${_kwh(c['kwh'])} kWh × ${_rate(c['php_per_kwh'])}. Generation, transmission, system loss, '
              'subsidies and taxes: Meralco’s overall rate (${_rate(rates['overall_php_per_kwh'])}/kWh) less the '
              'distribution and fixed charges below.',
          'distribution' => '${_kwh(c['kwh'])} kWh × ${_rate(c['php_per_kwh'])} (${_schedule(level['distribution_php_per_kwh'])} '
              'for $levelName + $vat% VAT). Charged on every kWh of the month, at the level the total lands in.',
          'fixed' => '${_rate(rates['supply_php'])} supply + ${_rate(rates['metering_php'])} metering + $vat% VAT, '
              'the same every month.',
          _ => 'On the ${_kwh(c['kwh'])} kWh above ${str(rates['energy_tax_from_kwh'], '650')} kWh (BP 36).',
        };

    return SCard(
      key: const Key('bill-charges'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CardTitle('What makes up ${_php(total)}'),
        const SizedBox(height: 2),
        Text('The forecast, priced with Meralco’s residential rates. Your actual bill may differ by a few pesos.',
            style: ts(10.5, height: 1.4, color: C.muted)),
        const SizedBox(height: S.x3),
        // One bar, split by charge.
        ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(R.pill),
            child: SizedBox(
              height: 10,
              child: Row(children: [
                for (final c in charges)
                  if (numOr(c['php']) > 0)
                    Expanded(
                      flex: max(1, (numOr(c['php']) / max(1, sum) * 1000).round()),
                      child: Container(color: _color(str(c['id']))),
                    ),
              ]),
            ),
          ),
        ),
        for (final c in charges) ...[
          const SizedBox(height: S.x3),
          MergeSemantics(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: _color(str(c['id'])), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              const SizedBox(width: S.x2),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    switch (str(c['id'])) {
                      'energy' => 'Generation, transmission & other charges',
                      'distribution' => 'Distribution charge',
                      'fixed' => 'Supply & metering',
                      _ => 'Energy tax',
                    },
                    style: ts(12.5, w: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(evidence(c), style: ts(11, height: 1.45, color: C.label)),
                ]),
              ),
              const SizedBox(width: S.x2),
              Text(_php(c['php']), style: ts(13, w: FontWeight.w800)),
            ]),
          ),
        ],
        const SizedBox(height: S.x3),
        Divider(height: 1, color: C.divider),
        const SizedBox(height: S.x2),
        Row(children: [
          Expanded(child: Text('Forecast bill', style: ts(12.5, w: FontWeight.w800))),
          Text(_php(total), style: ts(14, w: FontWeight.w900, color: C.orangeText)),
        ]),
        const SizedBox(height: S.x4),
        _Levels(rates: rates, level: level, kwh: numOr(d['kwh'])),
        const SizedBox(height: S.x3),
        Text(
          'Rates: ${str(rates['source'])}. Overall rate ${_rate(rates['overall_php_per_kwh'])}/kWh from Settings. '
          'Not included: lifeline and senior citizen discounts.',
          style: ts(10, height: 1.4, color: C.muted),
        ),
      ]),
    );
  }
}

/// Meralco's distribution levels, this month's highlighted, and how far the next one up or down is.
class _Levels extends StatelessWidget {
  const _Levels({required this.rates, required this.level, required this.kwh});
  final Map<String, dynamic> rates, level;
  final num kwh;

  @override
  Widget build(BuildContext context) {
    final rows = listOfMaps(rates['distribution']);
    final up = mapOf(level['up']), down = mapOf(level['down']);
    final current = level['max_kwh'];
    final vat = str(rates['vat_pct'], '12');
    // Each level runs from the one before's top.
    final levels = <(num, num?, Object?)>[];
    num lo = 0;
    for (final r in rows) {
      final hi = r['max_kwh'] as num?;
      levels.add((lo, hi, r['php_per_kwh']));
      lo = hi ?? lo;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Distribution charge by level', style: ts(12.5, w: FontWeight.w700)),
      const SizedBox(height: 2),
      Text('The month’s total kWh decides the level, and every kWh pays that level’s rate.',
          style: ts(11, height: 1.4, color: C.label)),
      const SizedBox(height: S.x2),
      Container(
        decoration: BoxDecoration(borderRadius: R.control, border: Border.all(color: C.divider)),
        child: Column(children: [
          for (final (lo, hi, rate) in levels)
            Container(
              key: hi == current ? const Key('bill-level-current') : null,
              padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 7),
              color: hi == current ? C.orange.withValues(alpha: 0.12) : null,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(levelLabel(lo, hi),
                        style: ts(12, w: hi == current ? FontWeight.w800 : FontWeight.w500, color: hi == current ? C.ink : C.label)),
                    if (hi == current) Text('This month', style: ts(10, w: FontWeight.w800, color: C.orangeText)),
                  ]),
                ),
                const SizedBox(width: S.x2),
                Flexible(
                  child: Text('${_schedule(rate)}/kWh',
                      textAlign: TextAlign.right,
                      style: ts(12, w: hi == current ? FontWeight.w800 : FontWeight.w500, color: hi == current ? C.ink : C.label)),
                ),
              ]),
            ),
        ]),
      ),
      const SizedBox(height: 4),
      Text('Before $vat% VAT.', style: ts(10, color: C.muted)),
      if (up.isNotEmpty) ...[
        const SizedBox(height: S.x2),
        _Step(
          icon: Icons.trending_up_rounded,
          color: C.red,
          text: '${_kwh(up['kwh_away'])} kWh more and the month passes ${_kwh(up['at_kwh'])} kWh: every kWh moves to '
              'the next level’s rate, about ${_php(up['jump_php'])} more on top of the extra kWh.',
        ),
      ],
      if (down.isNotEmpty) ...[
        const SizedBox(height: S.x2),
        _Step(
          icon: Icons.trending_down_rounded,
          color: C.green,
          text: 'Use ${_kwh(down['kwh_away'])} kWh less and the month drops to ${_kwh(down['at_kwh'])} kWh or under: '
              'every kWh goes back to the lower rate, about ${_php(down['jump_php'])} less on top of the kWh you save.',
        ),
      ],
    ]);
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: S.x2),
        Expanded(child: Text(text, style: ts(11.5, height: 1.45, color: C.label))),
      ]);
}
