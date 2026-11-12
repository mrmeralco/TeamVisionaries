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
import 'package:solaris/core/utils/format.dart';
import 'package:solaris/features/common/charts.dart';
import 'package:solaris/features/common/ui.dart';
import 'package:solaris/main.dart';
import 'package:solaris/providers/data_providers.dart';
import 'package:solaris/providers/notification_providers.dart';
import 'package:solaris/providers/server_providers.dart';
import 'package:solaris/services/system_notifier.dart';
import 'package:solaris/services/mock_api_service.dart';

final contracts = Platform.environment['SOLARIS_CONTRACTS'] ?? '../docs/contracts';
Map<String, dynamic> example(String name) =>
    jsonDecode(File('$contracts/examples/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// MockApiService whose /ws/live sends one chosen `/api/live` object, to put Home in each state.
class StateMock extends MockApiService {
  StateMock({this.live}) : super(loader: (name) async => File('$contracts/examples/$name.json').readAsStringSync());
  final Map<String, dynamic>? live;
  int chats = 0;
  StreamController<Map<String, dynamic>>? socket; // the open /ws/live, to push messages from tests
  final extraAlerts = <Map<String, dynamic>>[]; // alerts the "server" has that the example file doesn't

  void push(Map<String, dynamic> msg) => socket!.add(msg);

  @override
  Future<Map<String, dynamic>> getAlerts({bool unreadOnly = false}) async {
    final a = await super.getAlerts(unreadOnly: unreadOnly);
    final list = [...extraAlerts, ...(a['alerts'] as List)];
    return {...a, 'alerts': list, 'unread': (a['unread'] as int) + extraAlerts.length};
  }

  @override
  Future<Map<String, dynamic>> getLive() async => live ?? example('live');

  @override
  Stream<Map<String, dynamic>> liveMessages({Duration every = const Duration(seconds: 5)}) {
    final c = socket = StreamController<Map<String, dynamic>>();
    c.onListen = () => c.add({'type': 'telemetry', 'data': live ?? example('live')});
    return c.stream; // stays open, like a quiet socket
  }

  @override
  Future<Map<String, dynamic>> chat(String message) {
    chats++;
    return super.chat(message);
  }
}

/// Chat that fails until [fail] is cleared (for "Try again").
class FailingChat extends StateMock {
  bool fail = true;
  @override
  Future<Map<String, dynamic>> chat(String message) async {
    if (fail) {
      chats++;
      throw TimeoutException('no answer');
    }
    return super.chat(message);
  }
}

/// Records notifications instead of calling the browser.
class FakeNotifier implements SystemNotifier {
  FakeNotifier({this.supported = true, this.grant = true});
  @override
  final bool supported;
  final bool grant;
  bool hidden = false;
  String _permission = 'default';
  final shown = <String>[];
  @override
  String get permission => supported ? _permission : 'unsupported';
  @override
  Future<bool> requestPermission() async {
    _permission = grant ? 'granted' : 'denied';
    return grant;
  }

  @override
  bool get appHidden => hidden;
  @override
  void show(String title, String body, {String? tag}) => shown.add(title);
}

Future<ProviderContainer> pumpApp(WidgetTester t,
    {StateMock? api, Size size = const Size(393, 852), FakeNotifier? notifier}) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  SharedPreferences.setMockInitialValues({'use_mock': true});
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      apiServiceProvider.overrideWithValue(api ?? StateMock()),
      systemNotifierProvider.overrideWithValue(notifier ?? FakeNotifier(supported: false)),
    ],
    child: const SolarisApp(),
  ));
  await t.pumpAndSettle();
  return ProviderScope.containerOf(t.element(find.byType(SolarisApp)));
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
      // The recap is below the fold now that text is larger: scroll to it.
      await t.scrollUntilVisible(find.text(example('summary_daily')['summary'] as String), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(example('summary_daily')['summary'] as String), findsOneWidget);
    });

    testWidgets('brownout: banner opens the Brownout Advisor with runtime + advice', (t) async {
      await pumpApp(t, api: StateMock(live: wsTelemetry()));
      expect(find.text('May brownout ngayon'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget); // grid tile
      await t.tap(find.text('May brownout ngayon'));
      await t.pumpAndSettle();
      expect(find.text('Brownout Advisor'), findsOneWidget);
      expect(find.text('~7.1 hrs'), findsOneWidget);
      expect(find.text(example('brownout')['advice'] as String), findsOneWidget);
      // /api/outlook section: tomorrow's forecast sun and the server's advice.
      await t.scrollUntilVisible(find.text(example('outlook')['advice'] as String), 300,
          scrollable: find.byType(Scrollable).last);
      expect(find.text('Next 48 hours'), findsOneWidget);
      expect(find.text(kwhNum(example('outlook')['solar_tomorrow_kwh'])), findsOneWidget);
    });

    testWidgets('fault: banner opens the inverter alert explained, over the Alerts tab', (t) async {
      final live = example('live')
        ..['state'] = 'fault'
        ..['status_line'] = 'May fault ang inverter.';
      await pumpApp(t, api: StateMock(live: live));
      await t.tap(find.text('May problema ang inverter'));
      await t.pumpAndSettle();
      expect(find.text('Ano ang ibig sabihin nito?'), findsOneWidget); // the explanation the banner promises
      expect(find.text('Ano ang gagawin?'), findsOneWidget);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
      expect(find.text('Mark all read'), findsOneWidget);
    });

    testWidgets('offline: says so, no crash', (t) async {
      final live = example('live')
        ..['state'] = 'offline'
        ..['device'] = {...example('live')['device'] as Map<String, dynamic>, 'online': false};
      await pumpApp(t, api: StateMock(live: live));
      expect(find.text('Offline ang Solaris device'), findsOneWidget);
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

  testWidgets('Home (Figma rev 2): rate caption, bill card opens Bill, recap opens Ask with a question', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api);
    expect(find.text('At ₱13.00/kWh'), findsOneWidget); // live.rate_php_per_kwh
    await t.drag(find.byType(Scrollable).first, const Offset(0, -200)); // bring the money cards above the nav bar
    await t.pumpAndSettle();
    await t.tap(find.text('Tap for Bill Details'));
    await t.pumpAndSettle();
    expect(find.text('PREDICTED BILL THIS MONTH · NOVEMBER'), findsOneWidget);

    await tab(t, 'Home');
    // Scroll the recap clear of the bottom nav bar, then tap the link.
    await t.scrollUntilVisible(find.text('Ask Mira about yesterday'), 200, scrollable: find.byType(Scrollable).first);
    await t.drag(find.byType(Scrollable).first, const Offset(0, -150));
    await t.pumpAndSettle();
    await t.tap(find.text('Ask Mira about yesterday'));
    await t.pumpAndSettle();
    expect(find.text('Get answers about your solar energy.'), findsOneWidget); // on Ask Mira now
    expect(api.chats, 1);
    expect(find.text(example('chat')['reply'] as String), findsOneWidget);
  });


  group('Inverter health on Home', () {
    testWidgets('normal: temperature, no fault, Wi-Fi signal', (t) async {
      await pumpApp(t);
      expect(find.text('42°C'), findsOneWidget); // live.telemetry.inv_temp_c
      expect(find.text('No issues'), findsOneWidget);
      expect(find.text('Strong'), findsOneWidget); // rssi -55
    });

    testWidgets('fault code shows and opens Alerts', (t) async {
      final live = example('live');
      (live['telemetry'] as Map)['fault_code'] = 21;
      (live['telemetry'] as Map)['inv_temp_c'] = 66;
      await pumpApp(t, api: StateMock(live: live));
      expect(find.text('66°C'), findsOneWidget);
      await t.tap(find.text('Fault 21'));
      await t.pumpAndSettle();
      expect(find.text('Mark all read'), findsOneWidget);
    });
  });

  testWidgets('Grid tile says which way power flows (grid_w: + import, − export)', (t) async {
    final live = example('live');
    (live['telemetry'] as Map)['grid_w'] = -2930;
    await pumpApp(t, api: StateMock(live: live));
    expect(find.text('2.9'), findsOneWidget);
    expect(find.text('Exporting'), findsOneWidget);
  });

  group('Alerts outside the app', () {
    Map<String, dynamic> newAlert(int id) => {
          'id': id, 'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000, 'type': 'brownout', 'severity': 'critical',
          'title': 'Brownout', 'message': 'Nawalan ng kuryente mula sa grid.', 'read': false,
        };

    testWidgets('pushed alert while hidden + enabled -> system notification, no snackbar', (t) async {
      final api = StateMock();
      final n = FakeNotifier();
      final c = await pumpApp(t, api: api, notifier: n);
      expect(await c.read(notifyAlertsProvider.notifier).setEnabled(true), isTrue);
      n.hidden = true;
      api.push({'type': 'alert', 'data': newAlert(99)});
      await t.pumpAndSettle();
      expect(n.shown, ['Solaris: Brownout']);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('pushed alert while visible -> snackbar, no system notification', (t) async {
      final api = StateMock();
      final n = FakeNotifier();
      final c = await pumpApp(t, api: api, notifier: n);
      await c.read(notifyAlertsProvider.notifier).setEnabled(true);
      api.push({'type': 'alert', 'data': newAlert(98)});
      await t.pump();
      expect(n.shown, isEmpty);
      expect(find.textContaining('Brownout: Nawalan'), findsOneWidget);
    });

    testWidgets('coming back to the app reports alerts missed while away', (t) async {
      final api = StateMock();
      await pumpApp(t, api: api);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      api.extraAlerts.addAll([newAlert(100), newAlert(101)]); // arrived while the socket was closed
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
      expect(find.text('2 bagong alert habang wala ka.'), findsOneWidget);
    });

    testWidgets('Settings switch asks permission; a refusal keeps it off', (t) async {
      final c = await pumpApp(t, notifier: FakeNotifier(grant: false));
      await t.tap(find.bySemanticsLabel('Settings').first);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('notify-switch')));
      await t.pumpAndSettle();
      expect(c.read(notifyAlertsProvider), isFalse);
      expect(find.textContaining('Hindi pinayagan'), findsOneWidget);
    });
  });

  testWidgets('Energy: totals and chart for day / week / month', (t) async {
    await pumpApp(t);
    await tab(t, 'Energy');
    for (final (label, file) in [('Today', 'energy_day'), ('Week', 'energy_week'), ('Month', 'energy_month')]) {
      await t.tap(find.text(label).first); // the period switch (the range label below may say "Today" too)
      await t.pumpAndSettle();
      final e = example(file);
      expect(find.text(kwhNum((e['totals'] as Map)['pv_kwh'])), findsOneWidget, reason: label);
      expect(find.text(pctNum(e['self_sufficiency_pct'])), findsOneWidget, reason: label);
      expect(find.text('Grid Used'), findsOneWidget);
      expect(find.text(kwhNum((e['totals'] as Map)['grid_import_kwh'])), findsWidgets, reason: label);
      expect(find.text('Solar vs. Home vs. Grid (kWh)'), findsOneWidget);
    }
  });

  testWidgets('Energy: step back to yesterday and forward again; data stays on screen while loading', (t) async {
    await pumpApp(t);
    await tab(t, 'Energy');
    await t.tap(find.byTooltip('Earlier'));
    await t.pump(); // loading: the previous day's cards are still there, dimmed
    expect(find.text('Solar Produced'), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.text('Yesterday'), findsOneWidget);
    await t.tap(find.byTooltip('Later'));
    await t.pumpAndSettle();
    expect(find.text('Yesterday'), findsNothing);
  });

  testWidgets('Bill: forecast, range, trend, savings, weekly costs', (t) async {
    await pumpApp(t);
    await tab(t, 'Bill');
    expect(find.text('PREDICTED BILL THIS MONTH · NOVEMBER'), findsOneWidget);
    expect(find.text('₱1,833 – ₱2,156'), findsOneWidget);
    expect(find.text('₱186 less than last month (−8.5%)'), findsOneWidget); // pesos first, plain words
    expect(find.text('₱1,694'), findsOneWidget); // savings_month_php
    final weeks = example('bill')['weekly_costs'] as List;
    for (final w in weeks) {
      expect(find.text(w['label'] as String), findsOneWidget);
    }
    // Tap a week's bar to see its cost.
    expect(find.textContaining('Week of ${weeks.last['label']}'), findsOneWidget);
    await t.ensureVisible(find.text(weeks.first['label'] as String));
    await t.pumpAndSettle();
    await t.tap(find.text(weeks.first['label'] as String));
    await t.pumpAndSettle();
    expect(find.text('Week of ${weeks.first['label']}: ${formatPhp(weeks.first['php'] as num, whole: true)}'), findsOneWidget);
  });

  testWidgets('Ask Mira: sends the question, shows reply + chips', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api);
    await tab(t, 'Ask Mira');
    await t.enterText(find.byType(TextField), 'Bakit mataas ang bill ko?');
    await t.tap(find.text('SEND'));
    await t.pumpAndSettle();
    expect(api.chats, 1);
    expect(find.text('Bakit mataas ang bill ko?'), findsOneWidget);
    expect(find.text(example('chat')['reply'] as String), findsOneWidget);
    expect(find.textContaining('Bill this month  ₱746', findRichText: true), findsOneWidget); // chip: UTF-8 ₱ intact
    // Follow-up suggestions after the answer, without the question already asked.
    expect(find.text('Kakayanin ba ng battery mamaya?'), findsOneWidget);
    await t.tap(find.byTooltip('New conversation'));
    await t.pumpAndSettle();
    expect(find.text(example('chat')['reply'] as String), findsNothing);
  });

  testWidgets('Ask Mira: a failed answer offers Try again, which asks the same question', (t) async {
    final api = FailingChat();
    await pumpApp(t, api: api);
    await tab(t, 'Ask Mira');
    await t.enterText(find.byType(TextField), 'Magkano ang bill ko?');
    await t.tap(find.text('SEND'));
    await t.pumpAndSettle();
    expect(find.textContaining('Hindi ma-reach'), findsOneWidget);
    api.fail = false;
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(api.chats, 2);
    expect(find.textContaining('Hindi ma-reach'), findsNothing);
    expect(find.text(example('chat')['reply'] as String), findsOneWidget);
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
    expect(find.text('Ano ang ibig sabihin nito?'), findsOneWidget); // detail sheet, not just "read"
    await t.tap(find.text('Close'));
    await t.pumpAndSettle();
    // Severity filter.
    await t.tap(find.text('Critical  3'));
    await t.pumpAndSettle();
    expect(find.text('Mainit ang inverter'), findsNothing);
    await t.tap(find.text('All  6'));
    await t.pumpAndSettle();
    expect(find.text('Mainit ang inverter'), findsOneWidget);
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
    await t.pumpAndSettle();
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(c.read(serverSettingsProvider).value!['rate_php_per_kwh'], 12.5);
  });

  testWidgets('Settings: invalid household values say why instead of doing nothing', (t) async {
    final c = await pumpApp(t);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '13.0'), 'abc');
    await t.ensureVisible(find.text('Save household'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(find.textContaining('Numero mula 1 hanggang 100'), findsOneWidget);
    expect(c.read(serverSettingsProvider).value!['rate_php_per_kwh'], 13.0);
    await t.enterText(find.widgetWithText(TextField, 'abc'), '13.0');
    await t.ensureVisible(find.text('Save household'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(find.textContaining('Walang binago'), findsOneWidget);
  });

  testWidgets('Home says how old the reading is', (t) async {
    final live = example('live');
    (live['telemetry'] as Map)['ts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600;
    await pumpApp(t, api: StateMock(live: live));
    expect(find.text('Last reading 10 min ago'), findsOneWidget);
  });

  testWidgets('large system text (2x) on a small phone: no overflow on any tab', (t) async {
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpApp(t, size: const Size(320, 640));
    expect(t.takeException(), isNull, reason: 'Home');
    for (final l in ['Energy', 'Bill', 'Ask Mira', 'Alerts', 'Home']) {
      await tab(t, l);
      expect(t.takeException(), isNull, reason: l);
    }
  });

  testWidgets('wide screens: the app is centred at its max width', (t) async {
    await pumpApp(t, size: const Size(1280, 800));
    expect(t.getSize(find.byType(Scaffold).first).width, 480);
  });

  testWidgets('every tab fits a small phone (320 × 640) without overflow', (t) async {
    await pumpApp(t, size: const Size(320, 640));
    for (final l in ['Energy', 'Bill', 'Ask Mira', 'Alerts', 'Home']) {
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
    test('alert times, durations, badge', () {
      final now = DateTime.utc(2026, 11, 12, 4); // 12:00 PM Manila
      expect(formatWhen(1794446366, now: now), startsWith('9:19 AM')); // same Manila day
      expect(formatWhen(1794446366 - 86400, now: now), 'Yesterday, 9:19 AM');
      expect(formatWhen(1794446366 - 5 * 86400, now: now), 'Nov 7, 9:19 AM');
      expect(formatDuration(45), '45 min');
      expect(formatDuration(85), '1 h 25 min');
      expect(formatDuration(120), '2 h');
      expect(badgeText(7), '7');
      expect(badgeText(120), '99+');
    });
    test('safe reads fall back instead of throwing', () {
      expect(str(null, '—'), '—');
      expect(numOr('x'), 0);
      expect(listOfMaps(null), isEmpty);
      expect(friendlyError(const FormatException('bad')).kind, ErrorKind.data);
      expect(friendlyError(TimeoutException('slow')).kind, ErrorKind.offline);
    });
    test('chart axis rounds up to readable numbers', () {
      expect(niceCeil(0.37), 0.5);
      expect(niceCeil(3.4), 5);
      expect(niceCeil(12), 20);
      expect(niceCeil(0), 1);
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
