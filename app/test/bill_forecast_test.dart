// Bill: the forecast shows its evidence (forecast_detail in GET /api/bill): the month day by day with the
// forecast and its range on the chart, how the number is made, and the charges it adds up from, with the
// distribution charge tied to the Meralco level the month lands in.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solaris/core/utils/format.dart';

import 'widget_test.dart' show StateMock, example, pumpApp, tab;

const _tall = Size(393, 4200);

String _php(num v) => formatPhp(v, whole: true);

/// A server from before forecast_detail.
class _OldServer extends StateMock {
  @override
  Future<Map<String, dynamic>> getBill() async => {...await super.getBill()}..remove('forecast_detail');
}

Future<StateMock> _meterHome() async {
  final api = StateMock(live: example('live_meter_only'));
  await api.updateSettings({'setup': 'meter_only'});
  return api;
}

void main() {
  testWidgets('the forecast on a chart: measured, then forecast with its range, and the level lines', (t) async {
    await pumpApp(t, size: _tall);
    await tab(t, 'Bill');
    final f = example('bill')['forecast_detail'] as Map<String, dynamic>;
    expect(find.byKey(const Key('bill-forecast-chart')), findsOneWidget);
    expect(find.text('This month, day by day'), findsOneWidget);
    final legend = find.byKey(const Key('bill-forecast-chart'));
    for (final key in ['Measured', 'Forecast', 'Likely range', 'Meralco level']) {
      expect(find.descendant(of: legend, matching: find.text(key)), findsOneWidget, reason: key);
    }
    // Month end is selected first: the forecast and its range.
    final end = (f['days'] as List).last as Map;
    expect(find.text('Nov 30 · forecast ${(end['cum_kwh'] as num).toStringAsFixed(0)} kWh '
        '(likely ${(end['cum_low_kwh'] as num).toStringAsFixed(0)}–${(end['cum_high_kwh'] as num).toStringAsFixed(0)})'),
        findsOneWidget);

    // Tapping early in the month reads a measured day.
    final chart = t.getRect(find.descendant(of: find.byKey(const Key('bill-forecast-chart')), matching: find.byType(CustomPaint)).last);
    await t.tapAt(Offset(chart.left + chart.width * 0.2, chart.center.dy));
    await t.pumpAndSettle();
    expect(find.textContaining('kWh so far (metered)'), findsOneWidget);
  });

  testWidgets('how the forecast is made: measured, learned, forecast, priced', (t) async {
    await pumpApp(t, size: _tall);
    await tab(t, 'Bill');
    final b = example('bill');
    final f = b['forecast_detail'] as Map<String, dynamic>;
    expect(find.text('How this forecast is made'), findsOneWidget);
    for (final step in ['Measured so far', 'Learned your pattern', 'Forecast the rest', 'Priced at Meralco’s rates']) {
      expect(find.text(step), findsOneWidget, reason: step);
    }
    expect(find.textContaining('${f['done_days']} finished days, read by your inverter'), findsOneWidget);
    expect(find.textContaining('SARIMA model trained on your last ${f['history_days']} days'), findsOneWidget);
    expect(find.textContaining('${f['days_left']} days left, today included'), findsOneWidget);
    expect(find.textContaining(': ${_php(b['forecast_php'] as num)}, likely'), findsOneWidget);
  });

  testWidgets('the charges add up to the forecast, each with its kWh and rate', (t) async {
    await pumpApp(t, size: _tall);
    await tab(t, 'Bill');
    final b = example('bill');
    final f = b['forecast_detail'] as Map<String, dynamic>;
    final total = b['forecast_php'] as num;
    expect(find.text('What makes up ${_php(total)}'), findsOneWidget);
    final charges = (f['charges'] as List).cast<Map<String, dynamic>>();
    expect(charges.fold<num>(0, (a, c) => a + (c['php'] as num)), closeTo(total, 0.02));
    for (final (id, label) in [
      ('energy', 'Generation, transmission & other charges'),
      ('distribution', 'Distribution charge'),
      ('fixed', 'Supply & metering'),
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
      final c = charges.firstWhere((c) => c['id'] == id);
      expect(find.text(_php(c['php'] as num)), findsWidgets, reason: id);
    }
    // The distribution charge's evidence: its rate, the level, VAT, all kWh.
    final dist = charges.firstWhere((c) => c['id'] == 'distribution');
    expect(find.textContaining('kWh × ${formatPhp(dist['php_per_kwh'] as num)} (₱0.9803 for Up to 200 kWh + 12% VAT)'),
        findsOneWidget);
    expect(find.textContaining('Charged on every kWh of the month'), findsOneWidget);
    expect(find.textContaining('₱16.38 supply + ₱5.00 metering + 12% VAT'), findsOneWidget);
    expect(find.textContaining('Meralco Summary Schedule of Rates'), findsOneWidget);
  });

  testWidgets('the distribution levels, this month highlighted, and how close the next one is', (t) async {
    await pumpApp(t, size: _tall);
    await tab(t, 'Bill');
    expect(find.text('Distribution charge by level'), findsOneWidget);
    for (final row in ['Up to 200 kWh', '201–300 kWh', '301–400 kWh', 'Over 400 kWh']) {
      expect(find.text(row), findsWidgets, reason: row);
    }
    expect(find.descendant(of: find.byKey(const Key('bill-level-current')), matching: find.text('Up to 200 kWh')),
        findsOneWidget);
    expect(find.text('₱1.2908/kWh'), findsOneWidget); // the schedule's own figures
    final up = ((example('bill')['forecast_detail'] as Map)['level'] as Map)['up'] as Map;
    expect(find.textContaining('${(up['kwh_away'] as num).toStringAsFixed(1)} kWh more and the month passes 200 kWh'),
        findsOneWidget);
    expect(find.textContaining('about ${_php(up['jump_php'] as num)} more'), findsOneWidget);
  });

  testWidgets('a smart meter home over 400 kWh: the step down, from the meter', (t) async {
    await pumpApp(t, api: await _meterHome(), size: _tall);
    await tab(t, 'Bill');
    expect(find.descendant(of: find.byKey(const Key('bill-level-current')), matching: find.text('Over 400 kWh')),
        findsOneWidget);
    expect(find.textContaining('read by your meter'), findsOneWidget);
    expect(find.textContaining('kWh less and the month drops to 400 kWh or under'), findsOneWidget);
    expect(find.textContaining('what your solar covers'), findsNothing);
  });

  testWidgets('an older server without the detail: the Bill screen as before', (t) async {
    await pumpApp(t, api: _OldServer(), size: _tall);
    await tab(t, 'Bill');
    expect(find.text('Predicted bill for November'), findsOneWidget);
    for (final key in ['bill-forecast-chart', 'bill-forecast-how', 'bill-charges']) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    expect(find.text('Weekly energy cost'), findsOneWidget);
  });
}
