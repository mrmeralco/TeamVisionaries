// Screen tests: the whole app (router, providers, designed screens) driven by docs/contracts/examples.
// Covers what TESTING.md's "by eye" list lets a test see: data on every tab, brownout, fault, offline,
// empty (telemetry: null), live link, alerts read flow, chat, settings, and small screens.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sinag/core/utils/format.dart';
import 'package:sinag/main.dart';
import 'package:sinag/providers/data_providers.dart';
import 'package:sinag/providers/server_providers.dart';
import 'package:sinag/services/mock_api_service.dart';

final contracts = Platform.environment['SINAG_CONTRACTS'] ?? '../docs/contracts';
Map<String, dynamic> example(String name) =>
    jsonDecode(File('$contracts/examples/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// MockApiService whose /ws/live sends one chosen `/api/live` object, to put Home in each state.
class StateMock extends MockApiService {
  StateMock({this.live}) : super(loader: (name) async => File('$contracts/examples/$name.json').readAsStringSync());
  final Map<String, dynamic>? live;
  int chats = 0;

  @override
  Future<Map<String, dynamic>> getLive() async => live ?? example('live');

  @override
  Stream<Map<String, dynamic>> liveMessages({Duration every = const Duration(seconds: 5)}) {
    final c = StreamController<Map<String, dynamic>>();
    c.onListen = () => c.add({'type': 'telemetry', 'data': live ?? example('live')});
    return c.stream; // stays open, like a quiet socket
  }

  @override
  Future<Map<String, dynamic>> chat(String message) {
    chats++;
    return super.chat(message);
  }
}

Future<ProviderContainer> pumpApp(WidgetTester t, {StateMock? api, Size size = const Size(393, 852)}) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  SharedPreferences.setMockInitialValues({'use_mock': true});
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      apiServiceProvider.overrideWithValue(api ?? StateMock()),
    ],
    child: const SinagApp(),
  ));
  await t.pumpAndSettle();
  return ProviderScope.containerOf(t.element(find.byType(SinagApp)));
}

Future<void> tab(WidgetTester t, String label) async {
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

void main() {
  group('Home', () {
    testWidgets('live readings, money and yesterday’s summary from the contract', (t) async {
      await pumpApp(t);
      final live = example('live');
      expect(find.text('Mock'), findsWidgets); // /ws/live link up through MockApiService
      expect(find.text(live['status_line'] as String), findsOneWidget);
      expect(find.textContaining('Juan'), findsOneWidget); // settings.user_name
      expect(find.text('3.2'), findsOneWidget); // pv_w 3200 -> kW
      expect(find.text('1.8'), findsOneWidget); // load_w
      expect(find.text('78'), findsOneWidget); // batt_soc
      expect(find.text('₱23.82'), findsOneWidget); // saved_today_php
      expect(find.text('₱1,995'), findsOneWidget); // bill.forecast_php
      expect(find.text(example('summary_daily')['summary'] as String), findsOneWidget);
    });

    testWidgets('brownout: banner opens the Brownout Advisor with runtime + advice', (t) async {
      await pumpApp(t, api: StateMock(live: wsTelemetry()));
      expect(find.text('May brownout ngayon'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget); // grid tile
      await t.tap(find.text('May brownout ngayon'));
      await t.pumpAndSettle();
      expect(find.text('Brownout Advisor'), findsOneWidget);
      expect(find.text('~7.1 oras'), findsOneWidget);
      expect(find.text(example('brownout')['advice'] as String), findsOneWidget);
    });

    testWidgets('fault: banner goes to the Alerts tab', (t) async {
      final live = example('live')
        ..['state'] = 'fault'
        ..['status_line'] = 'May fault ang inverter.';
      await pumpApp(t, api: StateMock(live: live));
      await t.tap(find.text('May problema ang inverter'));
      await t.pumpAndSettle();
      expect(find.text('Mark all read'), findsOneWidget);
    });

    testWidgets('offline: says so, no crash', (t) async {
      final live = example('live')
        ..['state'] = 'offline'
        ..['device'] = {...example('live')['device'] as Map<String, dynamic>, 'online': false};
      await pumpApp(t, api: StateMock(live: live));
      expect(find.text('Offline ang Sinag device'), findsOneWidget);
    });

    testWidgets('empty: telemetry null shows a friendly empty state', (t) async {
      final live = example('live')
        ..['telemetry'] = null
        ..['state'] = 'offline';
      await pumpApp(t, api: StateMock(live: live));
      expect(find.text('Wala pang reading mula sa device.'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('Energy: totals and chart for day / week / month', (t) async {
    await pumpApp(t);
    await tab(t, 'Energy');
    for (final (label, file) in [('Today', 'energy_day'), ('Week', 'energy_week'), ('Month', 'energy_month')]) {
      await t.tap(find.text(label));
      await t.pumpAndSettle();
      final e = example(file);
      expect(find.text(kwhNum((e['totals'] as Map)['pv_kwh'])), findsOneWidget, reason: label);
      expect(find.text(pctNum(e['self_sufficiency_pct'])), findsOneWidget, reason: label);
      expect(find.text('Solar Production'), findsOneWidget);
    }
  });

  testWidgets('Bill: forecast, range, trend, savings, weekly costs', (t) async {
    await pumpApp(t);
    await tab(t, 'Bill');
    expect(find.text('PREDICTED BILL THIS MONTH · NOVEMBER'), findsOneWidget);
    expect(find.text('₱1,833 – ₱2,156'), findsOneWidget);
    expect(find.text('8.5% lower than last month'), findsOneWidget);
    expect(find.text('₱1,694'), findsOneWidget); // savings_month_php
    for (final w in (example('bill')['weekly_costs'] as List)) {
      expect(find.text(w['label'] as String), findsOneWidget);
    }
  });

  testWidgets('Ask Sinag: sends the question, shows reply + chips', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api);
    await tab(t, 'Ask Sinag');
    await t.enterText(find.byType(TextField), 'Bakit mataas ang bill ko?');
    await t.tap(find.text('SEND'));
    await t.pumpAndSettle();
    expect(api.chats, 1);
    expect(find.text('Bakit mataas ang bill ko?'), findsOneWidget);
    expect(find.text(example('chat')['reply'] as String), findsOneWidget);
    expect(find.textContaining('Bill this month  ₱746', findRichText: true), findsOneWidget); // chip: UTF-8 ₱ intact
  });

  testWidgets('Alerts: grouped list, badge, tap marks read, mark all read', (t) async {
    final c = await pumpApp(t);
    expect(c.read(unreadAlertsProvider), 4);
    expect(find.text('4'), findsOneWidget); // nav badge
    await tab(t, 'Alerts');
    expect(find.text('Mainit ang inverter'), findsOneWidget);
    await t.tap(find.text('Mainit ang inverter'));
    await t.pumpAndSettle();
    expect(c.read(unreadAlertsProvider), 3);
    await t.tap(find.text('Mark all read'));
    await t.pumpAndSettle();
    expect(c.read(unreadAlertsProvider), 0);
    expect(find.text('Mark all read'), findsNothing);
  });

  testWidgets('Settings: opens from the gear and saves a partial household update', (t) async {
    final c = await pumpApp(t);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    expect(find.text('Test connection'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextField, '13.0'), '12.5');
    await t.ensureVisible(find.text('Save household'));
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(c.read(serverSettingsProvider).value!['rate_php_per_kwh'], 12.5);
  });

  testWidgets('every tab fits a small phone (320 × 640) without overflow', (t) async {
    await pumpApp(t, size: const Size(320, 640));
    for (final l in ['Energy', 'Bill', 'Ask Sinag', 'Alerts', 'Home']) {
      await tab(t, l);
      expect(t.takeException(), isNull, reason: l);
    }
  });

  group('format', () {
    test('pesos', () {
      expect(formatPhp(2450, whole: true), '₱2,450');
      expect(formatPhp(85), '₱85.00');
    });
    test('times are Asia/Manila whatever the phone timezone', () {
      expect(formatClock(1794446366), '9:19 AM'); // 2026-11-12 01:19:26 UTC
      expect(formatShortDate(1792339200), 'Oct 19');
      expect(monthNameOf('2026-11'), 'November');
    });
    test('numbers for tiles', () {
      expect(kwNum(3200), '3.2');
      expect(kwhNum(18.44), '18.4');
      expect(kwhNum(5.674), '5.67');
      expect(pctNum(83.7), '83.7');
      expect(pctNum(64), '64');
    });
  });
}

/// The `telemetry` message in ws_messages.json: a brownout reading.
Map<String, dynamic> wsTelemetry() {
  final msgs = (jsonDecode(File('$contracts/examples/ws_messages.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
  return Map<String, dynamic>.from(msgs.firstWhere((m) => m['type'] == 'telemetry')['data'] as Map);
}
