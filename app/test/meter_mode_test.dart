// Smart meter mode: a home with only a meter, or with solar and a meter. Same app, driven by the
// *_meter_only / *_solar_and_meter examples in docs/contracts/examples (what mock mode demos).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solaris/core/utils/format.dart';
import 'package:solaris/features/meter/meter_cards.dart';
import 'package:solaris/providers/data_providers.dart';
import 'package:solaris/services/mock_api_service.dart';

import 'widget_test.dart' show StateMock, example, openMira, pumpApp, tab;

/// A tall phone, so a whole tab is built (ListView only builds what is on screen).
const _tall = Size(393, 3200);

final _solarWords = RegExp(r'\b(solar|battery|baterya|inverter)\b', caseSensitive: false);

Future<StateMock> _home(String setup) async {
  final api = StateMock(live: example(setup == 'solar' ? 'live' : 'live_$setup'));
  await api.updateSettings({'setup': setup});
  return api;
}

void main() {
  group('Meter only', () {
    testWidgets('Home: meter tiles and insights; no solar, battery, tips or brownout runtime', (t) async {
      await pumpApp(t, api: await _home('meter_only'), size: _tall);
      final m = example('live_meter_only')['meter'] as Map;
      // The house without panels or battery, labelled from the meter.
      expect(find.text('HOME'), findsOneWidget);
      expect(find.text('${((m['power_w'] as num) / 1000).toStringAsFixed(1)} kW'), findsOneWidget);
      expect(find.text('GRID'), findsOneWidget);
      expect(find.text('SOLAR'), findsNothing); // no panels on a meter-only house
      expect(find.text('${(m['voltage_v'] as num).round()} V'), findsOneWidget);
      // Under it, what the labels don't say.
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('Power factor'), findsOneWidget);
      for (final gone in ['SOLAR', 'BATTERY', 'Saved today', 'Brownout advisor', 'Solar tips']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      final day = example('energy_day_meter_only')['totals'] as Map;
      expect(find.text('Used today'), findsOneWidget);
      expect(find.text('${kwhNum(day['grid_import_kwh'])} kWh'), findsOneWidget);
      expect(find.text('Your electricity'), findsOneWidget);
      for (final i in listOfMaps(example('meter')['insights'])) {
        expect(find.text(str(i['title'])), findsOneWidget, reason: str(i['id']));
      }
      expect(find.text(example('live_meter_only')['status_line'] as String), findsOneWidget);
    });

    testWidgets('Home in a brownout: what to do, no battery hours', (t) async {
      final live = example('live_meter_only');
      live['state'] = 'brownout';
      (live['meter'] as Map)['grid_on'] = false;
      final api = StateMock(live: live);
      await api.updateSettings({'setup': 'meter_only'});
      await pumpApp(t, api: api, size: _tall);
      expect(find.text('May brownout ngayon'), findsOneWidget);
      expect(find.text(example('brownout_meter_only')['advice'] as String), findsOneWidget);
      expect(find.text('hrs'), findsNothing);
      expect(find.text('Off'), findsNWidgets(2)); // the HOME and GRID labels on the house
    });

    testWidgets('Energy: use, busiest time and the typical day; no solar or self-sufficiency', (t) async {
      await pumpApp(t, api: await _home('meter_only'), size: _tall);
      await tab(t, 'Energy');
      final e = example('energy_day_meter_only');
      expect(find.text('Electricity used'), findsOneWidget);
      expect(find.text(kwhNum((e['totals'] as Map)['grid_import_kwh'])), findsOneWidget);
      expect(find.text('Busiest hour'), findsOneWidget);
      expect(find.text('Home use from the grid (kWh)'), findsOneWidget);
      for (final gone in ['Solar produced', 'Battery used', 'Self-sufficiency', 'Where your power went']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      final u = example('meter')['usage'] as Map;
      expect(find.text('Your typical day'), findsOneWidget);
      expect(find.text(formatWatts(u['base_w'] as num)), findsOneWidget);
      expect(find.text('${u['night_share_pct']}%'), findsOneWidget);
      await t.tap(find.text('Week').first);
      await t.pumpAndSettle();
      expect(find.text('Busiest day'), findsOneWidget);
    });

    testWidgets('Bill: Meralco level from the meter; no solar savings or system check', (t) async {
      await pumpApp(t, api: await _home('meter_only'), size: _tall);
      await tab(t, 'Bill');
      final b = example('bill_meter_only');
      final tier = example('meter')['tier'] as Map;
      expect(find.text(formatPhp(b['forecast_php'] as num, whole: true)), findsWidgets); // hero + coming months
      expect(find.textContaining('measured by your meter'), findsOneWidget);
      expect(find.text('Meralco level this month'), findsOneWidget);
      expect(find.text(levelLabel(tier['level_min_kwh'] as num, tier['level_max_kwh'] as num?)), findsOneWidget);
      for (final gone in ['Your solar savings', 'System check', 'Saved this month']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      expect(find.textContaining('free daytime sunshine'), findsNothing);
    });

    testWidgets('Ask Mira: welcome and suggestions are about electricity, not solar', (t) async {
      await pumpApp(t, api: await _home('meter_only'), size: _tall);
      await openMira(t);
      expect(find.textContaining('gamit mo sa kuryente, bill o meter'), findsOneWidget);
      expect(find.text('Get answers about your electricity.'), findsOneWidget);
      final texts = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '').where((s) => s.endsWith('?'));
      expect(texts, isNotEmpty);
      expect(texts.where(_solarWords.hasMatch), isEmpty);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('every tab fits a small phone (320 × 640) at ${scale}x text without overflow', (t) async {
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpApp(t, api: await _home('meter_only'), size: const Size(320, 640));
        expect(t.takeException(), isNull, reason: 'Home');
        for (final l in ['Energy', 'Bill', 'Alerts', 'Home']) {
          await tab(t, l);
          expect(t.takeException(), isNull, reason: l);
        }
        await openMira(t);
        expect(t.takeException(), isNull, reason: 'Ask Mira');
      });
    }
  });

  group('Solar + meter', () {
    testWidgets('Home keeps the solar house labels and adds the utility meter', (t) async {
      await pumpApp(t, api: await _home('solar_and_meter'), size: _tall);
      for (final label in ['SOLAR', 'BATTERY', 'GRID']) {
        expect(find.text(label), findsOneWidget, reason: label);   // the house scene's live labels
      }
      expect(find.text('Saved today'), findsOneWidget);
      expect(find.text('Meralco meter'), findsOneWidget);
      expect(find.text('Utility side'), findsOneWidget);
      expect(find.text('Your electricity'), findsOneWidget);
      expect(find.text('Solar tips'), findsOneWidget);
    });

    testWidgets('Bill: solar savings and the Meralco level, priced from the meter', (t) async {
      await pumpApp(t, api: await _home('solar_and_meter'), size: _tall);
      await tab(t, 'Bill');
      expect(find.text('Your solar savings'), findsOneWidget);
      expect(find.text('Meralco level this month'), findsOneWidget);
      expect(find.textContaining('measured by your meter'), findsOneWidget);
    });

    testWidgets('Energy: the solar chart plus the grid-side typical day', (t) async {
      await pumpApp(t, api: await _home('solar_and_meter'), size: _tall);
      await tab(t, 'Energy');
      expect(find.text('Solar vs. Home vs. Grid (kWh)'), findsOneWidget);
      expect(find.text('Your typical day on the grid'), findsOneWidget);
    });
  });

  group('Solar only (unchanged)', () {
    testWidgets('no meter cards anywhere', (t) async {
      await pumpApp(t, size: _tall);
      expect(find.text('Your electricity'), findsNothing);
      expect(find.text('Utility side'), findsNothing);
      await tab(t, 'Bill');
      expect(find.text('Meralco level this month'), findsNothing);
      expect(find.text('Your solar savings'), findsOneWidget);
      await tab(t, 'Energy');
      expect(find.text('Your typical day'), findsNothing);
    });
  });

  testWidgets('Settings: choose "Smart meter only", the battery field goes and the setup is saved', (t) async {
    final c = await pumpApp(t, size: _tall);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    expect(find.text('Battery size'), findsOneWidget);
    await t.tap(find.byKey(const Key('setup-meter_only')));
    await t.pumpAndSettle();
    expect(find.text('Battery size'), findsNothing);
    await t.ensureVisible(find.text('Save household'));
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(c.read(serverSettingsProvider).value!['setup'], 'meter_only');
    expect(c.read(setupProvider), 'meter_only');
    expect(c.read(hasSolarProvider), isFalse);
  });

  group('Mock mode demos each setup', () {
    late MockApiService mock;
    setUp(() => mock = MockApiService(loader: (name) async => _encode(example(name))));

    test('meter only: live, energy, bill and meter come from the meter examples', () async {
      await mock.updateSettings({'setup': 'meter_only'});
      expect((await mock.getSettings())['setup'], 'meter_only');
      final live = await mock.getLive();
      expect(live['telemetry'], isNull);
      expect((live['meter'] as Map)['meter_type'], 'sdm120');
      expect(((await mock.getEnergy('week'))['totals'] as Map)['pv_kwh'], 0);
      expect((await mock.getBill())['grid_source'], 'meter');
      expect((await mock.getMeter())['tier'], isNotNull);
      final first = await mock.liveMessages(every: const Duration(milliseconds: 1)).take(2).toList();
      expect(first.every((m) => (m['data'] as Map)['meter'] != null), isTrue);
      expect((await mock.getAlerts())['alerts'], isNotEmpty); // no variant: falls back to the shared example
    });

    test('solar + meter and back to solar', () async {
      await mock.updateSettings({'setup': 'solar_and_meter'});
      final live = await mock.getLive();
      expect(live['telemetry'], isNotNull);
      expect(live['meter'], isNotNull);
      await mock.updateSettings({'setup': 'solar'});
      expect((await mock.getLive())['meter'], isNull);
      expect((await mock.getBill())['grid_source'], 'inverter');
    });
  });
}

String _encode(Map<String, dynamic> m) => const JsonEncoder().convert(m);
