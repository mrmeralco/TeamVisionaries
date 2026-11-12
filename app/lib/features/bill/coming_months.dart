// Bill & Savings: "Coming months" from GET /api/bill/projection. This month is the forecast; up to 3 months
// after it are estimates whose range widens each month (drawn to scale, so the uncertainty is visible).
// Nothing beyond 3 months: the server doesn't project it, and the note says why.
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../common/ui.dart';

String _php(Object? v) => formatPhp(numOr(v), whole: true);

class ComingMonthsCard extends StatelessWidget {
  const ComingMonthsCard(this.p, {super.key});
  final Map<String, dynamic> p;

  @override
  Widget build(BuildContext context) {
    final months = listOfMaps(p['months']);
    final enough = p['enough_data'] == true;
    final top = months.fold<double>(1, (a, m) => numOr(m['high_php']).toDouble() > a ? numOr(m['high_php']).toDouble() : a);

    return SCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const CardTitle('Coming months'),
        const SizedBox(height: 2),
        Text('Only this month is a forecast. Later months are estimates that get less certain each month.',
            style: ts(10.5, height: 1.4, color: C.muted)),
        for (final m in months) ...[const SizedBox(height: S.x3), _MonthRow(m, top: top)],
        const SizedBox(height: S.x3),
        Text(
          enough
              ? 'Up to ${str(p['max_months'], '3')} months ahead. Estimates assume your recent use and today’s '
                  'rate (${formatPhp(numOr(p['rate_php_per_kwh']))}/kWh); weather, new appliances and Meralco’s '
                  'monthly rate can change them. Further ahead is too uncertain to show.'
              : 'Needs about 2 weeks of readings before the coming months can be estimated.',
          style: ts(10, height: 1.4, color: C.muted),
        ),
      ]),
    );
  }
}

class _MonthRow extends StatelessWidget {
  const _MonthRow(this.m, {required this.top});
  final Map<String, dynamic> m;
  final double top; // highest high_php across months: one scale for every bar

  @override
  Widget build(BuildContext context) {
    final forecast = m['kind'] == 'forecast';
    final lo = numOr(m['low_php']).toDouble(), hi = numOr(m['high_php']).toDouble(), v = numOr(m['bill_php']).toDouble();
    final range = '${_php(lo)} – ${_php(hi)}';
    final tag = forecast ? 'Forecast' : 'Estimate ±${str(m['range_pct'])}%';
    final color = forecast ? C.orangeDeep : C.orangeText;

    return MergeSemantics(
      child: Semantics(
        label: '${str(m['label'])}: ${forecast ? 'forecast' : 'estimate'} ${_php(v)}, likely $range',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(str(m['label']), style: ts(12.5, w: FontWeight.w700))),
            const SizedBox(width: S.x2),
            Text(_php(v), style: ts(14, w: FontWeight.w800, color: color)),
          ]),
          const SizedBox(height: S.x1),
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            double x(double php) => (php / top).clamp(0, 1) * w;
            return SizedBox(
              height: 10,
              child: Stack(children: [
                Positioned(left: 0, right: 0, top: 4, child: Container(height: 2, color: C.divider)),
                Positioned(
                  left: x(lo),
                  width: (x(hi) - x(lo)).clamp(2, w),
                  top: 2,
                  child: Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: forecast ? 0.45 : 0.25),
                      borderRadius: BorderRadius.circular(R.pill),
                    ),
                  ),
                ),
                Positioned(
                  left: (x(v) - 4).clamp(0, w - 8),
                  top: 1,
                  child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                ),
              ]),
            );
          }),
          const SizedBox(height: S.x1),
          // Wraps under large system text instead of overflowing.
          Wrap(spacing: S.x2, runSpacing: S.x1, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: 2),
              decoration: BoxDecoration(
                color: (forecast ? C.green : C.muted).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(R.pill),
              ),
              child: Text(tag, style: ts(10, w: FontWeight.w700, color: forecast ? C.green : C.label)),
            ),
            Text('Likely $range', style: ts(10, color: C.muted)),
          ]),
        ]),
      ),
    );
  }
}
