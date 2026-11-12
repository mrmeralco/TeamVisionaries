// Screen tests: the whole app (router, providers, designed screens) driven by docs/contracts/examples.
// Covers what TESTING.md's "by eye" list lets a test see: data on every tab, brownout, fault, offline,
// empty (telemetry: null), live link, alerts read flow, chat, settings, and small screens.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solaris/core/utils/format.dart';
import 'package:solaris/features/ask/answer_sources.dart';
import 'package:solaris/features/common/charts.dart';
import 'package:solaris/features/ask/ask_screen.dart' show isBadNews;
import 'package:solaris/features/common/ui.dart';
import 'package:solaris/features/home/house_scene.dart';
import 'package:solaris/features/home/home_screen.dart' show homeClock;
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

/// Chat whose first answer is bad news (a brownout), then normal answers.
class BadNewsChat extends StateMock {
  bool first = true;
  @override
  Future<Map<String, dynamic>> chat(String message) async {
    if (!first) return super.chat(message);
    first = false;
    chats++;
    return {
      'reply': 'May brownout ngayon. Sa gamit mo, aabot pa ng mga 3 oras ang battery mo.',
      'chips': const [],
      'source': 'llm',
    };
  }
}

/// GET /api/bill/projection returns [result].
class ProjectionMock extends StateMock {
  ProjectionMock(this.result);
  final Map<String, dynamic> result;
  @override
  Future<Map<String, dynamic>> getBillProjection() async => result;
}

/// GET /api/upgrade returns [result], or fails when it's null.
class UpgradeMock extends StateMock {
  UpgradeMock(this.result);
  final Map<String, dynamic>? result;
  @override
  Future<Map<String, dynamic>> getUpgrade() async =>
      result ?? (throw TimeoutException('no system check'));
}

/// GET /api/tips returns [result] (the example when not given), or fails when [fail]; counts the calls.
class TipsMock extends StateMock {
  TipsMock({this.result, this.fail = false, super.live});
  final Map<String, dynamic>? result;
  final bool fail;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> getTips() async {
    calls++;
    if (fail) throw TimeoutException('no tips');
    return result ?? example('tips');
  }
}

/// GET /api/household returns [result] (the example when not given), or fails when [fail].
class HouseholdMock extends StateMock {
  HouseholdMock({this.result, this.fail = false});
  final Map<String, dynamic>? result;
  final bool fail;
  @override
  Future<Map<String, dynamic>> getHousehold() async {
    if (fail) throw TimeoutException('no household');
    return result ?? example('household');
  }
}

/// An out-of-scope refusal: no facts, so no sources (and an older server that never sends them).
class NoSourcesChat extends StateMock {
  @override
  Future<Map<String, dynamic>> chat(String message) async {
    chats++;
    return {'reply': 'Pasensya na, hindi ko pa alam iyan.', 'chips': <Object>[], 'source': 'llm'};
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

class RateMock extends StateMock {
  bool refreshed = false;
  @override
  Future<Map<String, dynamic>> getSettings() async => {
    ...await super.getSettings(),
    'rate_php_per_kwh': 15.0615,
    'meralco_rate': {
      'status': refreshed ? 'cached' : 'published', 'billing_month': '2026-10',
      'source_url': 'https://www.meralco.com.ph/', 'reference_kwh': 200,
      'fetched_at': 1791835200, 'checked_at': 1791835200,
    },
  };
  @override
  Future<Map<String, dynamic>> refreshMeralcoRate() async {
    refreshed = true;
    return getSettings();
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
    {StateMock? api,
    Size size = const Size(393, 852),
    FakeNotifier? notifier,
    bool onboarded = true,
    Map<String, Object>? prefs}) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  // Reduced motion: Mira's idle loop never settles, and pumpAndSettle waits for stillness. The loop
  // has its own test ('Mira idles…').
  t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
  // Daytime unless the test set the clock: the app goes dark at night, so tests mustn't follow the real clock.
  if (identical(homeClock, manilaNow)) {
    homeClock = () => DateTime(2026, 11, 12, 10);
    addTearDown(() => homeClock = manilaNow);
  }
  await t.pumpWidget(const SizedBox.shrink()); // a fresh app each time, not the previous one updated
  SharedPreferences.setMockInitialValues({'use_mock': true, if (onboarded) 'onboarded': true, ...?prefs});
  final saved = await SharedPreferences.getInstance();
  await t.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(saved),
      apiServiceProvider.overrideWithValue(api ?? StateMock()),
      systemNotifierProvider.overrideWithValue(notifier ?? FakeNotifier(supported: false)),
    ],
    child: const SolarisApp(),
  ));
  await t.pumpAndSettle();
  return ProviderScope.containerOf(t.element(find.byType(SolarisApp)));
}

/// [f] inside the "Coming months" card.
Finder _inComingMonths(Finder f) =>
    find.descendant(of: find.ancestor(of: find.text('Coming months'), matching: find.byType(Column)).first, matching: f);

/// A tall phone, so a whole Ask Mira conversation (answer + its sources) fits without scrolling.
const tallPhone = Size(393, 1600);

Future<void> tab(WidgetTester t, String label) async {
  await t.tap(find.text(label).last);
  await t.pumpAndSettle();
}

/// Ask Mira is the floating button on every tab, not a tab.
Future<void> openMira(WidgetTester t) async {
  await t.tap(find.byTooltip('Ask Mira'));
  await t.pumpAndSettle();
}

void main() {
  group('Home', () {
    testWidgets('live readings, money and yesterday’s summary from the contract', (t) async {
      await pumpApp(t);
      final live = example('live');
      expect(find.text('Mock'), findsNothing); // demo data shows no connection chip
      expect(find.text(live['status_line'] as String), findsOneWidget);
      expect(find.textContaining('Juan'), findsOneWidget); // settings.user_name
      expect(find.text('3.2 kW'), findsOneWidget); // pv_w 3200, on the house's SOLAR label
      expect(find.text('1.8 kW'), findsOneWidget); // load_w, HOME
      expect(find.text('78%'), findsOneWidget); // batt_soc, BATTERY
      // The labelled house makes the hero taller: the money cards are just below the fold.
      await t.scrollUntilVisible(find.text('₱27.60'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('₱27.60'), findsOneWidget); // saved_today_php
      expect(find.text('₱2,310'), findsOneWidget); // bill.forecast_php
      // The recap is below the fold now that text is larger: scroll to it.
      await t.scrollUntilVisible(find.text(example('summary_daily')['summary'] as String), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(example('summary_daily')['summary'] as String), findsOneWidget);
    });

    test('house: each part of the drawing is a tap target; open ground is not', () {
      for (final s in Spot.values) {
        expect(spotAt(spotAnchor(s)), s, reason: s.name);
      }
      expect(spotAt(const Offset(283.5, 126)), Spot.solar); // a panel near the ridge
      expect(spotAt(const Offset(211.5, 265.5)), Spot.battery); // its base, in front of the wall
      expect(spotAt(const Offset(40, 240)), isNull); // the trees
      expect(spotAt(const Offset(100, 30)), isNull); // the sky above the roof
    });

    testWidgets('house: every part is labelled with its live number; tapping one zooms in on it', (t) async {
      await pumpApp(t);
      final scene = t.getRect(find.byType(HouseScene));
      final u = scene.width / kSceneW;
      Offset at(Spot s) => Offset(scene.left, scene.bottom - kSceneH * u) + spotAnchor(s) * u;
      // At rest: a label on each part, like the Tesla app.
      for (final title in ['SOLAR', 'HOME', 'BATTERY', 'GRID']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('3.2 kW'), findsOneWidget); // pv_w 3200
      expect(find.text('Producing'), findsNothing); // the explanation waits for a tap

      await t.tapAt(at(Spot.solar)); // the roof itself
      await t.pumpAndSettle();
      expect(find.text('Producing'), findsOneWidget);
      expect(find.text('Kuryenteng gawa ng solar panels mo ngayon. Libre ito.'), findsOneWidget);
      expect(find.text('SOLAR'), findsNWidgets(2), reason: 'the zoomed label, and the resting one faded out');

      await t.tap(find.byTooltip('Zoom out'));
      await t.pumpAndSettle();
      expect(find.text('Producing'), findsNothing);
      expect(find.byTooltip('Zoom out'), findsNothing);

      await t.tap(find.text('GRID')); // its label works too
      await t.pumpAndSettle();
      expect(find.text('Not in use'), findsOneWidget); // grid_w 0

      // Tapping open sky while zoomed takes the house back to the whole view.
      await t.tapAt(scene.topLeft + const Offset(80, 8));
      await t.pumpAndSettle();
      expect(find.text('Not in use'), findsNothing);
    });

    testWidgets('house: the night house from 6 PM to 6 AM, with light text on the navy sky', (t) async {
      addTearDown(() => homeClock = manilaNow);
      String houseAsset() => t
          .widgetList<SvgPicture>(find.descendant(of: find.byType(HouseScene), matching: find.byType(SvgPicture)))
          .map((w) => (w.bytesLoader as SvgAssetLoader).assetName)
          .single;
      Color valueColor() => t.widget<Text>(find.text('1.8 kW')).style!.color!;

      homeClock = () => DateTime(2026, 11, 12, 20, 30); // 8:30 PM
      await pumpApp(t);
      expect(houseAsset(), 'assets/images/house-hero-night.svg');
      expect(find.textContaining('Magandang gabi'), findsOneWidget);
      expect(valueColor(), Colors.white);
      expect(isNightAt(DateTime(2026, 1, 1, 5, 59)), isTrue);
      expect(isNightAt(DateTime(2026, 1, 1, 6)), isFalse);
      expect(isNightAt(DateTime(2026, 1, 1, 18)), isTrue);

      homeClock = () => DateTime(2026, 11, 12, 10); // 10 AM
      await pumpApp(t);
      expect(houseAsset(), 'assets/images/house-hero.svg');
      expect(find.textContaining('Magandang umaga'), findsOneWidget);
      expect(valueColor(), isNot(Colors.white));
    });

    testWidgets('brownout: the advisor card leads Home and opens the Brownout Advisor', (t) async {
      await pumpApp(t, api: StateMock(live: wsTelemetry()));
      expect(find.text('May brownout ngayon'), findsOneWidget); // the card, in the banner's place
      expect(find.text('Brownout advisor'), findsOneWidget);
      expect(find.text('~7.1'), findsOneWidget); // brownout.runtime_h on the card
      // The card pushes the tiles down: the grid tile is below it.
      await t.scrollUntilVisible(find.text('Off'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Off'), findsOneWidget); // grid tile
      await t.ensureVisible(find.text('May brownout ngayon'));
      await t.pumpAndSettle();
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

    testWidgets('grid on: the advisor card says how long the battery would last, and opens the advisor',
        (t) async {
      await pumpApp(t);
      await t.scrollUntilVisible(find.text('May kuryente mula sa grid'), 200, scrollable: find.byType(Scrollable).first);
      await t.drag(find.byType(Scrollable).first, const Offset(0, -150)); // clear of the nav bar and Mira button
      await t.pumpAndSettle();
      expect(find.text('May brownout ngayon'), findsNothing); // mock /api/brownout says active; live says grid on
      final hours = ((example('outlook')['brownout'] as Map)['hours'] as num).toStringAsFixed(1);
      expect(find.text('~$hours'), findsOneWidget); // outlook.brownout.hours
      await t.tap(find.text('Open Brownout Advisor'));
      await t.pumpAndSettle();
      expect(find.text('Brownout Advisor'), findsOneWidget);
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

  group('Your household on Home', () {
    const tall = Size(393, 3600);

    testWidgets('who is home now, a possible new appliance, and the usual weekday', (t) async {
      await pumpApp(t, api: HouseholdMock(), size: tall);
      final ex = example('household');
      expect(find.text('Your household'), findsOneWidget);
      expect(find.text('AT HOME NOW'), findsOneWidget);
      expect(find.text('Probably no one home'), findsOneWidget);
      expect(find.text(ex['now']['text'] as String), findsOneWidget);
      expect(find.text('Unusual for this hour'), findsNothing);
      // New appliance: +1.1 kW 9PM–2AM since Nov 7, with the backend's sentence and the bill impact.
      expect(find.text('NEW APPLIANCE?'), findsOneWidget);
      expect(find.text('+1.1 kW, 9PM–2AM since Nov 7'), findsOneWidget);
      expect(find.text((ex['new_loads'] as List).first['text'] as String), findsOneWidget);
      expect(find.text('Adds up to ₱2,485 a month'), findsOneWidget);
      // Routine.
      expect(find.text('Wala sa bahay tuwing weekday'), findsOneWidget);
      expect(find.text('A usual weekday'), findsOneWidget);
      for (final chip in ['Up  7AM', 'Out  9AM–6PM', 'Lights out  11PM', 'Busiest  9PM', 'Always on  280 W']) {
        expect(find.textContaining(chip, findRichText: true), findsOneWidget, reason: chip);
      }
      expect(find.text('Always-on use is 37.8% of your home’s use: up to ₱3,029 a month.'), findsOneWidget);
    });

    testWidgets('someone up at an unusual hour is flagged; nothing new, no routine yet', (t) async {
      await pumpApp(t, size: tall, api: HouseholdMock(result: {
        ...example('household'),
        'now': {'state': 'active', 'likely_home': true, 'load_w': 1200, 'usual_home_pct': 0, 'unusual': true,
                'next_active_ts': null, 'text': 'May gumagamit ng kuryente ngayon (1.2 kW): may tao sa bahay.'},
        'confidence': 'none', 'baseload': null, 'routine': {'weekday': null, 'weekend': null},
        'archetype': {'id': 'unknown', 'label': 'Inaaral pa ang routine ninyo', 'description': 'Kailangan pa ng ilang araw.'},
        'traits': <Object>[], 'new_loads': <Object>[],
      }));
      expect(find.text('Someone is home'), findsOneWidget);
      expect(find.text('Unusual for this hour'), findsOneWidget);
      expect(find.text('NEW APPLIANCE?'), findsNothing);
      expect(find.text('Inaaral pa ang routine ninyo'), findsOneWidget);
      expect(find.text('A usual weekday'), findsNothing);
    });

    testWidgets('a failed household request just hides the section', (t) async {
      await pumpApp(t, api: HouseholdMock(fail: true), size: tall);
      expect(find.text('Your household'), findsNothing);
      expect(find.text('Yesterday’s summary'), findsOneWidget);
    });
  });

  group('Solar tips on Home', () {
    const tall = Size(393, 3000);

    testWidgets('CO₂ avoided this month, then the first tips with their numbers; show more / fewer', (t) async {
      await pumpApp(t, api: TipsMock(), size: tall);
      final ex = example('tips');
      final tips = (ex['tips'] as List).cast<Map<String, dynamic>>();
      expect(find.text('Solar tips'), findsOneWidget);
      expect(find.text('Avoided this month'), findsOneWidget);
      expect(find.text('151'), findsOneWidget);                                  // impact.co2_avoided_kg
      expect(find.text('213 kWh of clean solar · 76.5% of your home ran on the sun'), findsOneWidget);
      expect(find.text('Like 7 trees growing for a year'), findsOneWidget);
      for (final tip in tips.take(3)) {
        expect(find.text(tip['title'] as String), findsOneWidget);
        expect(find.text(tip['body'] as String), findsOneWidget);
      }
      expect(find.text('TODAY'), findsOneWidget);
      expect(find.text('HABIT'), findsNWidgets(2));
      expect(find.textContaining('Solar sent to grid  4.4 kWh/day', findRichText: true), findsOneWidget);
      expect(find.text('Saves up to ₱1,672 a month'), findsOneWidget);
      // The 4th (tip of the day) waits behind "Show 1 more tip".
      expect(find.text(tips[3]['title'] as String), findsNothing);
      await t.ensureVisible(find.text('Show 1 more tip'));
      await t.tap(find.text('Show 1 more tip'));
      await t.pumpAndSettle();
      expect(find.text(tips[3]['title'] as String), findsOneWidget);
      expect(find.text('TIP OF THE DAY'), findsOneWidget);
      await t.tap(find.text('Show fewer tips'));
      await t.pumpAndSettle();
      expect(find.text(tips[3]['title'] as String), findsNothing);
    });

    testWidgets('a "right now" tip and no impact yet (no solar this month)', (t) async {
      await pumpApp(t, size: tall, api: TipsMock(result: {
        ...example('tips'),
        'impact': null,
        'tips': [
          {'id': 'surplus_now', 'kind': 'now', 'priority': 1, 'title': 'Sobra ang araw ngayon: gamitin na',
           'body': 'Gumagawa ang panels mo ng 3.2 kW pero 900 W lang ang gamit ng bahay.',
           'evidence': [{'label': 'Solar now', 'value': '3.2 kW'}], 'savings_php_month': null},
        ],
      }));
      expect(find.text('RIGHT NOW'), findsOneWidget);
      expect(find.text('Sobra ang araw ngayon: gamitin na'), findsOneWidget);
      expect(find.text('Avoided this month'), findsNothing);
      expect(find.textContaining('more tip'), findsNothing);
    });

    testWidgets('a failed tips request just hides the section', (t) async {
      await pumpApp(t, api: TipsMock(fail: true), size: tall);
      expect(find.text('Solar tips'), findsNothing);
      expect(find.text('Yesterday’s summary'), findsOneWidget); // the rest of Home still shows
    });

    testWidgets('tips follow the house: refetched when the live state changes', (t) async {
      final api = TipsMock();
      await pumpApp(t, api: api, size: tall);
      final before = api.calls;
      api.push({'type': 'telemetry', 'data': example('live')}); // same state: no refetch
      await t.pumpAndSettle();
      expect(api.calls, before);
      api.push({'type': 'telemetry', 'data': {...example('live'), 'state': 'grid'}});
      await t.pumpAndSettle();
      expect(api.calls, before + 1);
    });
  });

  testWidgets('Home (Figma rev 2): rate caption, bill card opens Bill, recap opens Ask with a question', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api);
    await t.scrollUntilVisible(find.text('At ₱15.06/kWh'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('At ₱15.06/kWh'), findsOneWidget); // live.rate_php_per_kwh
    await t.drag(find.byType(Scrollable).first, const Offset(0, -150)); // bring the money cards above the nav bar
    await t.pumpAndSettle();
    await t.tap(find.text('See bill details'));
    await t.pumpAndSettle();
    expect(find.text('Predicted bill for November'), findsOneWidget);

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
    testWidgets('device disconnect updates Home and signal while the server stays connected', (t) async {
      final api = StateMock();
      final container = await pumpApp(t, api: api);
      await container.read(serverConfigProvider.notifier).setUseMock(false);
      await t.pumpAndSettle();
      expect(find.text('Strong'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);

      // Older servers can send just a Device status message; RSSI can still be cached.
      api.push({'type': 'status', 'data': {...example('live')['device'] as Map<String, dynamic>, 'online': false}});
      await t.pumpAndSettle();
      expect(find.text('Strong'), findsNothing);
      expect(find.text('Device offline'), findsOneWidget);
      expect(find.text('Offline ang Solaris device'), findsOneWidget);
      expect(find.textContaining('Device offline · last received'), findsOneWidget);
      expect(find.text('Outdated'), findsNWidgets(4));
      await t.scrollUntilVisible(find.text('Unavailable'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('No issues'), findsNothing);
      expect(find.text('Unavailable'), findsOneWidget);
      expect(find.text('42°C'), findsOneWidget);
      expect(find.text('Last reading'), findsOneWidget);
      expect(find.text('Live'), findsNothing);

      api.push({'type': 'telemetry', 'data': example('live')});
      await t.pumpAndSettle();
      await t.drag(find.byType(Scrollable).first, const Offset(0, 1000));
      await t.pumpAndSettle();
      expect(find.text('Strong'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Offline ang Solaris device'), findsNothing);
      expect(find.text('No issues'), findsOneWidget);
      expect(find.text('Outdated'), findsNothing);
    });

    for (final fault in [0, 21]) {
      testWidgets('offline history stays clear on a small phone with large text, fault $fault', (t) async {
        t.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        final live = example('live')
          ..['state'] = 'offline'
          ..['device'] = {...example('live')['device'] as Map<String, dynamic>, 'online': false};
        (live['telemetry'] as Map)['fault_code'] = fault;
        (live['telemetry'] as Map)['grid_on'] = false;
        (live['telemetry'] as Map)['ts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
        await pumpApp(t, api: StateMock(live: live), size: const Size(320, 640));
        await t.scrollUntilVisible(find.text('Device offline · last received 2 min ago'), 150,
            scrollable: find.byType(Scrollable).first);
        expect(find.text('Device offline · last received 2 min ago'), findsOneWidget);
        await t.scrollUntilVisible(find.text('SOLAR'), 150, // the house's labels hold the readings
            scrollable: find.byType(Scrollable).first);
        expect(find.text('Outdated'), findsNWidgets(4));
        await t.scrollUntilVisible(find.text('Unavailable'), 200,
            scrollable: find.byType(Scrollable).first);
        expect(find.text('No issues'), findsNothing);
        expect(find.text('42°C'), findsOneWidget);
        expect(find.text('Last reading'), findsOneWidget);
        final inverter = t.getTopLeft(find.text('Inverter'));
        final status = t.getTopLeft(find.text('Inverter status'));
        final signal = t.getTopLeft(find.text('Solaris device'));
        expect(inverter.dx, lessThan(status.dx));
        expect(status.dx, lessThan(signal.dx));
        expect(find.text('Strong'), findsNothing);
        expect(find.text('May brownout ngayon'), findsNothing);
        expect(find.text('May kuryente mula sa grid'), findsNothing);
        if (fault != 0) {
          await t.scrollUntilVisible(find.text('Last reported fault: $fault'), 150,
              scrollable: find.byType(Scrollable).first);
          expect(find.text('Last reported fault: $fault'), findsOneWidget);
          await t.ensureVisible(find.text('Last reported fault: $fault'));
          await t.pumpAndSettle();
          await t.tap(find.text('Last reported fault: $fault'));
          await t.pumpAndSettle();
          expect(find.text('Mark all read'), findsOneWidget);
        }
        expect(t.takeException(), isNull);
      });
    }

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
    expect(find.text('2.9 kW'), findsOneWidget); // the GRID label on the house
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

    testWidgets('device connection toast dismisses automatically and can be closed', (t) async {
      final api = StateMock();
      await pumpApp(t, api: api);
      Map<String, dynamic> connected(int id) => {
        ...newAlert(id), 'type': 'device_online', 'severity': 'info',
        'title': 'Konektado na ang Solaris device', 'message': 'Tumatanggap na ulit ng data.',
      };
      api.push({'type': 'alert', 'data': connected(102)});
      await t.pumpAndSettle();
      expect(find.text('View alerts'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      await t.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);

      api.push({'type': 'alert', 'data': connected(103)});
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Close'));
      await t.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
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
      expect(find.text('Grid used'), findsOneWidget);
      expect(find.text(kwhNum((e['totals'] as Map)['grid_import_kwh'])), findsWidgets, reason: label);
      expect(find.text('Solar vs. Home vs. Grid (kWh)'), findsOneWidget);
    }
  });

  testWidgets('Energy: step back to yesterday and forward again; data stays on screen while loading', (t) async {
    await pumpApp(t);
    await tab(t, 'Energy');
    await t.tap(find.byTooltip('Earlier'));
    await t.pump(); // loading: the previous day's cards are still there, dimmed
    expect(find.text('Solar produced'), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.text('Yesterday'), findsOneWidget);
    await t.tap(find.byTooltip('Later'));
    await t.pumpAndSettle();
    expect(find.text('Yesterday'), findsNothing);
  });

  testWidgets('Bill: coming months show this month as the forecast and later months as widening estimates', (t) async {
    await pumpApp(t, size: const Size(393, 3200));
    await tab(t, 'Bill');
    final p = example('bill_projection');
    final months = (p['months'] as List).cast<Map<String, dynamic>>();
    expect(find.text('Coming months'), findsOneWidget);
    expect(find.textContaining('Only this month is a forecast'), findsOneWidget);
    for (final m in months) {
      expect(find.text(m['label'] as String), findsOneWidget);
      expect(find.text(formatPhp(m['bill_php'] as num, whole: true)), findsWidgets);
      expect(find.text('Likely ${formatPhp(m['low_php'] as num, whole: true)} – ${formatPhp(m['high_php'] as num, whole: true)}'),
          findsOneWidget);
    }
    expect(_inComingMonths(find.text('Forecast')), findsOneWidget); // the chart's legend has one too
    for (final m in months.skip(1)) {
      expect(find.text('Estimate ±${m['range_pct']}%'), findsOneWidget);
    }
    expect(find.textContaining('Further ahead is too uncertain to show'), findsOneWidget);
  });

  testWidgets('Bill: coming months without enough history show only this month', (t) async {
    final p = example('bill_projection');
    await pumpApp(t,
        api: ProjectionMock({...p, 'enough_data': false, 'months': [(p['months'] as List).first]}),
        size: const Size(393, 3200));
    await tab(t, 'Bill');
    expect(_inComingMonths(find.text('Forecast')), findsOneWidget); // the chart's legend has one too
    expect(find.textContaining('Estimate ±'), findsNothing);
    expect(find.textContaining('Needs about 2 weeks of readings'), findsOneWidget);
  });

  testWidgets('Bill: system check shows each recommendation with the household numbers behind it', (t) async {
    await pumpApp(t, size: const Size(393, 2600));
    await tab(t, 'Bill');
    final u = example('upgrade');
    final rec = (u['recommendations'] as List).first as Map<String, dynamic>;
    expect(find.text('System check'), findsOneWidget);
    expect(find.text('Upgrade worth considering'), findsOneWidget);
    expect(find.text(u['headline'] as String), findsOneWidget);
    expect(find.text('Your system: 5 kWp solar · 10 kWh battery · 5 kW inverter'), findsOneWidget);
    expect(find.text(rec['title'] as String), findsOneWidget);
    expect(find.text(rec['add'] as String), findsOneWidget);
    expect(find.text(rec['reason'] as String), findsOneWidget);
    for (final e in (rec['evidence'] as List).cast<Map<String, dynamic>>()) {
      expect(find.textContaining('${e['label']}  ${e['value']}', findRichText: true), findsOneWidget);
    }
    expect(find.text('~₱1,581/month saved  ·  ~₱100,000 installed  ·  pays back in ~5.3 yrs'), findsOneWidget);
    expect(find.textContaining('rough estimates'), findsOneWidget);
  });

  testWidgets('Bill: a system that fits says so', (t) async {
    await pumpApp(t, api: UpgradeMock({...example('upgrade'), 'verdict': 'ok', 'recommendations': <Object>[],
        'headline': 'Sakto ang system mo para sa gamit mo.'}), size: const Size(393, 2600));
    await tab(t, 'Bill');
    expect(find.text('Fits your use'), findsOneWidget);
    expect(find.text('Sakto ang system mo para sa gamit mo.'), findsOneWidget);
    expect(find.textContaining('rough estimates'), findsNothing); // no prices without a recommendation
  });

  testWidgets('Bill: a failed system check just hides the card', (t) async {
    await pumpApp(t, api: UpgradeMock(null), size: const Size(393, 2600));
    await tab(t, 'Bill');
    expect(find.text('Predicted bill for November'), findsOneWidget); // the bill still shows
    expect(find.text('System check'), findsNothing);
  });

  testWidgets('Bill: forecast, range, trend, savings, weekly costs', (t) async {
    await pumpApp(t);
    await tab(t, 'Bill');
    expect(find.text('Predicted bill for November'), findsOneWidget);
    expect(find.text('₱2,123 – ₱2,497'), findsOneWidget);
    expect(find.text('₱215 less than last month (−8.5%)'), findsOneWidget); // pesos first, plain words
    expect(find.text('₱1,963'), findsOneWidget); // savings_month_php
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

  testWidgets('Ask Mira: a floating button on every tab, not a tab; back returns to the tab', (t) async {
    await pumpApp(t);
    expect(find.text('Ask Mira'), findsNothing); // gone from the nav bar
    for (final l in ['Home', 'Energy', 'Bill', 'Alerts']) {
      await tab(t, l);
      expect(find.byTooltip('Ask Mira'), findsOneWidget, reason: l);
    }
    await openMira(t);
    expect(find.text('Get answers about your solar energy.'), findsOneWidget);
    await t.tap(find.byTooltip('Back'));
    await t.pumpAndSettle();
    expect(find.text('Mark all read'), findsOneWidget); // back on Alerts
  });

  testWidgets('Mira idles: rays sway, she floats, she blinks; still under reduced motion', (t) async {
    await t.pumpWidget(const MaterialApp(home: Center(child: MiraAvatar(size: 58))));
    // Let the sprite's layers load from the asset bundle.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await t.pump();
    final rays = find.descendant(of: find.byType(MiraAvatar), matching: find.byType(Transform)).first;
    Matrix4 at() => t.widget<Transform>(rays).transform.clone();
    final a = at();
    await t.pump(const Duration(milliseconds: 900)); // a quarter of the loop
    expect(at(), isNot(equals(a)), reason: 'the rays should have moved');
    expect(find.byType(SvgPicture), findsNWidgets(4)); // rays, face, eyes, mouth

    t.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await t.pumpWidget(const MaterialApp(home: Center(child: MiraAvatar(size: 58))));
    await t.pumpAndSettle(); // settles: nothing loops
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  group('Mira moods', () {
    test('every sprite cuts into its moving parts', () {
      String sprite(String mood) => File('assets/images/mira-$mood.svg').readAsStringSync();
      // rays + the mood's own pieces (eyes, mouth, waves, drop, each dot, each sparkle)
      expect(MiraRig.cut(sprite('idle'))!.movingParts, 3); // rays, eyes, mouth
      expect(MiraRig.cut(sprite('thinking'))!.movingParts, 6); // + 3 dots
      expect(MiraRig.cut(sprite('talking'))!.movingParts, 4); // + waves
      expect(MiraRig.cut(sprite('happy'))!.movingParts, 5); // mouth + 3 sparkles
      expect(MiraRig.cut(sprite('error'))!.movingParts, 4); // + sweat drop
      expect(MiraRig.cut('<svg viewBox="0 0 256 256"></svg>'), isNull); // no rays: she stays still
    });

    test('bad news is told with the sad face; reassurance is not bad news', () {
      expect(isBadNews('May brownout ngayon. Aabot pa ng 7 oras ang battery mo.'), isTrue);
      expect(isBadNews('Mas mataas ang bill mo ngayong buwan kaysa noong nakaraan.'), isTrue);
      expect(isBadNews('Maulap bukas, kaya kaunti lang ang solar.'), isTrue);
      expect(isBadNews('Offline ang Solaris device mo mula 8 PM.'), isTrue);
      expect(isBadNews('Walang problema ang inverter mo. Maayos ang lahat!'), isFalse);
      expect(isBadNews(example('chat')['reply'] as String), isFalse);
    });

    testWidgets('thinking: the dots pop up one by one, for as long as she works', (t) async {
      await t.pumpWidget(const MaterialApp(home: Center(child: MiraAvatar(mood: MiraMood.thinking, size: 58))));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
      expect(find.byType(SvgPicture), findsNWidgets(7)); // rays, face, eyes, mouth, 3 dots
      Matrix4 lastDot() =>
          t.widget<Transform>(find.descendant(of: find.byType(MiraAvatar), matching: find.byType(Transform)).last)
              .transform
              .clone();
      final early = lastDot();
      await t.pump(const Duration(milliseconds: 900)); // half a beat: the third dot is up
      expect(lastDot(), isNot(equals(early)));
      await t.pump(const Duration(seconds: 10));
      expect(find.byType(SvgPicture), findsNWidgets(7), reason: 'still thinking: it loops');
    });

    testWidgets('talking: a few beats, then she rests idle', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Center(child: MiraAvatar(mood: MiraMood.talking, size: 58, cycles: 3, settleTo: MiraMood.idle)),
      ));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
      expect(find.byType(SvgPicture), findsNWidgets(5)); // rays, face, eyes, mouth, waves
      await t.pump(const Duration(milliseconds: 1900)); // 3 beats of 600 ms
      await t.pumpAndSettle();
      expect(find.byType(SvgPicture), findsOneWidget); // the still idle sprite
    });
  });

  testWidgets('Ask Mira: bad news gets the sad face; a normal answer does not', (t) async {
    await pumpApp(t, api: BadNewsChat());
    await openMira(t);
    await t.enterText(find.byType(TextField), 'Kakayanin ba ng battery mamaya?');
    await t.tap(find.text('Send'));
    await t.pumpAndSettle();
    bool sad(Widget w) => w is MiraAvatar && w.mood == MiraMood.error;
    expect(find.byWidgetPredicate(sad), findsOneWidget);

    await t.tap(find.byTooltip('New conversation'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'Magkano ang natipid ko?');
    await t.tap(find.text('Send'));
    await t.pumpAndSettle();
    expect(find.byWidgetPredicate(sad), findsNothing);
  });

  testWidgets('Ask Mira: sends the question, shows reply + chips', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api, size: tallPhone);
    await openMira(t);
    await t.enterText(find.byType(TextField), 'Bakit mataas ang bill ko?');
    await t.tap(find.text('Send'));
    await t.pumpAndSettle();
    expect(api.chats, 1);
    expect(find.text('Bakit mataas ang bill ko?'), findsOneWidget);
    expect(find.text(example('chat')['reply'] as String), findsOneWidget);
    expect(find.textContaining('Bill this month  ₱857', findRichText: true), findsOneWidget); // chip: UTF-8 ₱ intact
    // Follow-up suggestions after the answer, without the question already asked.
    expect(find.text('Kakayanin ba ng battery mamaya?'), findsOneWidget);
    await t.tap(find.byTooltip('New conversation'));
    await t.pumpAndSettle();
    expect(find.text(example('chat')['reply'] as String), findsNothing);
  });

  testWidgets('Ask Mira: shows the data behind the answer, and each source opens its screen', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api, size: tallPhone);
    await openMira(t);
    await t.enterText(find.byType(TextField), 'Bakit mataas ang bill ko?');
    await t.tap(find.text('Send'));
    await t.pumpAndSettle();

    final sources = (example('chat')['sources'] as List).cast<Map<String, dynamic>>();
    expect(find.text('Where this answer comes from · ${sources.length}'), findsOneWidget);
    for (final s in sources) {
      expect(find.text(s['label'] as String), findsOneWidget);
      expect(find.text(s['detail'] as String), findsOneWidget); // the exact data sentence, ₱ intact
    }
    expect(find.text('Bill forecast'), findsOneWidget);
    expect(find.textContaining('Forecast  ·  End of this month'), findsOneWidget); // where it comes from + period
    expect(find.textContaining('Your history  ·  Last 7 days'), findsOneWidget);

    // Collapse and expand.
    final header = find.text('Where this answer comes from · ${sources.length}');
    await t.tap(header);
    await t.pumpAndSettle();
    expect(find.text('Bill forecast'), findsNothing);
    await t.tap(header);
    await t.pumpAndSettle();

    // A source opens the screen with that data.
    await t.tap(find.text('Bill forecast'));
    await t.pumpAndSettle();
    expect(find.text('Bill & Savings'), findsOneWidget);
  });

  testWidgets('Ask Mira sources: a live reading says when; an old one says how old', (t) async {
    final now = DateTime.utc(2026, 11, 12, 8); // 4:00 PM in Manila
    final at = now.millisecondsSinceEpoch ~/ 1000;
    Map<String, dynamic> live(int ts) => {'id': 'now.solar_w', 'label': 'Solar now', 'value': '676 W',
        'detail': '676 W ang kuha ng solar panels mo ngayon.', 'kind': 'live', 'period': 'Right now',
        'screen': 'home', 'as_of_ts': ts};
    await t.pumpWidget(MaterialApp(home: Scaffold(body: AnswerSources([live(at - 30)], now: now))));
    expect(find.text('Live reading  ·  Right now  ·  ${formatClock(at - 30)}'), findsOneWidget);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: AnswerSources([live(at - 7200)], now: now))));
    expect(find.text('Live reading  ·  Last reading 2 hr ago'), findsOneWidget);
    expect(find.textContaining('Right now'), findsNothing);
  });

  testWidgets('Ask Mira: an answer without sources shows no source list', (t) async {
    final api = NoSourcesChat();
    await pumpApp(t, api: api);
    await openMira(t);
    await t.enterText(find.byType(TextField), 'Sino ang presidente?');
    await t.tap(find.text('Send'));
    await t.pumpAndSettle();
    expect(find.textContaining('Where this answer comes from'), findsNothing);
  });

  testWidgets('Ask Mira: a failed answer offers Try again, which asks the same question', (t) async {
    final api = FailingChat();
    await pumpApp(t, api: api);
    await openMira(t);
    await t.enterText(find.byType(TextField), 'Magkano ang bill ko?');
    await t.tap(find.text('Send'));
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
    expect(find.text('₱15.0615 / kWh'), findsOneWidget);
    expect(find.widgetWithText(TextField, '15.0615'), findsNothing);
    await t.enterText(find.widgetWithText(TextField, '10.0'), '12.5');
    await t.ensureVisible(find.text('Save household'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(c.read(serverSettingsProvider).value!['battery_kwh'], 12.5);
    expect(c.read(serverSettingsProvider).value!['rate_php_per_kwh'], 15.0615);
  });

  testWidgets('Settings: invalid household values say why instead of doing nothing', (t) async {
    final c = await pumpApp(t);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '10.0'), 'abc');
    await t.ensureVisible(find.text('Save household'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(find.textContaining('Numero mula 1 hanggang 200'), findsOneWidget);
    expect(c.read(serverSettingsProvider).value!['rate_php_per_kwh'], 15.0615);
    await t.enterText(find.widgetWithText(TextField, 'abc'), '10.0');
    await t.ensureVisible(find.text('Save household'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save household'));
    await t.pumpAndSettle();
    expect(find.textContaining('Walang binago'), findsOneWidget);
  });

  testWidgets('Settings: published Meralco rate is read-only and refresh retains cached data', (t) async {
    final api = RateMock();
    await pumpApp(t, api: api);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, 'Juan'), 'Maria');
    await t.scrollUntilVisible(find.text('Refresh rate'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('₱15.0615 / kWh'), findsOneWidget);
    expect(find.text('October 2026 billing'), findsOneWidget);
    expect(find.text('Source: Meralco'), findsOneWidget);
    expect(find.widgetWithText(TextField, '15.0615'), findsNothing);
    await t.ensureVisible(find.text('Refresh rate'));
    await t.pumpAndSettle();
    await t.tap(find.text('Refresh rate'));
    await t.pumpAndSettle();
    expect(api.refreshed, isTrue);
    expect(find.text('₱15.0615 / kWh'), findsOneWidget);
    expect(find.textContaining('huling verified na rate'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Name'), -150, scrollable: find.byType(Scrollable).first);
    expect(find.widgetWithText(TextField, 'Maria'), findsOneWidget);
    expect(t.takeException(), isNull);
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
    for (final l in ['Energy', 'Bill', 'Alerts', 'Home']) {
      await tab(t, l);
      expect(t.takeException(), isNull, reason: l);
    }
    await openMira(t);
    expect(t.takeException(), isNull, reason: 'Ask Mira');
  });

  testWidgets('wide screens: the app is centred at its max width', (t) async {
    await pumpApp(t, size: const Size(1280, 800));
    expect(t.getSize(find.byType(Scaffold).first).width, 480);
  });

  testWidgets('every tab fits a small phone (320 × 640) without overflow', (t) async {
    await pumpApp(t, size: const Size(320, 640));
    for (final l in ['Energy', 'Bill', 'Alerts', 'Home']) {
      await tab(t, l);
      expect(t.takeException(), isNull, reason: l);
    }
    await openMira(t);
    expect(t.takeException(), isNull, reason: 'Ask Mira');
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
