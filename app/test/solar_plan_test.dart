// "Go solar" (GET /api/solar-plan): a suggested solar size for a home without solar, and the sponsored slots
// kept apart from it. Not on Home (a meter-only home sees no solar there), so the card is pumped on its own.
// Driven by docs/contracts/examples/solar_plan*.json.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solaris/core/theme/app_theme.dart';
import 'package:solaris/features/home/solar_plan_card.dart';
import 'package:solaris/providers/server_providers.dart';

import 'widget_test.dart' show StateMock, example, pumpApp;

const _tall = Size(393, 4200);

/// A meter-only home whose /api/solar-plan returns [plan] (the example when not given) or fails.
class _PlanHome extends StateMock {
  _PlanHome({this.plan, this.fail = false}) : super(live: example('live_meter_only'));
  final Map<String, dynamic>? plan;
  final bool fail;
  @override
  Future<Map<String, dynamic>> getSolarPlan() async {
    if (fail) throw TimeoutException('no plan');
    return plan ?? example('solar_plan_meter_only');
  }
}

Future<StateMock> _home({Map<String, dynamic>? plan, bool fail = false, String setup = 'meter_only'}) async {
  final api = setup == 'meter_only' ? _PlanHome(plan: plan, fail: fail) : StateMock();
  await api.updateSettings({'setup': setup});
  return api;
}

/// Just the card, in the app theme.
Future<void> _card(WidgetTester t, {Map<String, dynamic>? plan}) async {
  t.view.physicalSize = _tall * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  SharedPreferences.setMockInitialValues({'use_mock': true});
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      apiServiceProvider.overrideWithValue(await _home(plan: plan)),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: SingleChildScrollView(child: SolarPlanCard())),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('a meter-only home sees the recommended size first, with savings, cost and payback', (t) async {
    await _card(t);
    final ex = example('solar_plan_meter_only');
    final opts = (ex['options'] as List).cast<Map<String, dynamic>>();
    expect(find.text('Go solar'), findsOneWidget);
    expect(find.text(ex['headline'] as String), findsOneWidget);
    expect(find.text('Your home: 17.8 kWh a day · 65% at night · about ₱8,670 a month now'), findsOneWidget);
    expect(find.text('RECOMMENDED'), findsOneWidget);
    // Recommended hybrid above the grid-tie.
    final hybrid = t.getTopLeft(find.text(opts[0]['title'] as String)).dy;
    final gridTie = t.getTopLeft(find.text(opts[1]['title'] as String)).dy;
    expect(hybrid, lessThan(gridTie));
    expect(find.text('8 × 580 W panels · about 21 m² of roof'), findsOneWidget);
    for (final chip in ['Battery  15 kWh', 'Battery  None', 'Brownout backup  ~14 h', 'Covers  88% of use']) {
      expect(find.textContaining(chip, findRichText: true), findsOneWidget, reason: chip);
    }
    expect(find.text('₱7,693/mo'), findsOneWidget);
    expect(find.text('₱532,000'), findsOneWidget);
    expect(find.text('~5.8 yrs'), findsOneWidget);
    expect(find.text('Bill ₱8,670 → ₱977 a month'), findsOneWidget);
    expect(find.text(opts[0]['why'] as String), findsOneWidget);
    expect(find.text(ex['disclaimer'] as String), findsOneWidget);
  });

  testWidgets('sponsored slots sit below the plan, labelled, as placeholders until configured', (t) async {
    await _card(t);
    expect(find.text('SPONSORED'), findsOneWidget);
    expect(find.text('Ad space · Solar installer'), findsOneWidget);
    expect(find.text('Ad space · Solar financing'), findsOneWidget);
    expect(t.getTopLeft(find.text('SPONSORED')).dy, greaterThan(t.getTopLeft(find.text('RECOMMENDED')).dy));
  });

  testWidgets('a real sponsor shows its name and site, without the ad-space label', (t) async {
    await _card(t, plan: {
      ...example('solar_plan_meter_only'),
      'sponsors': [
        {'id': 'acme', 'kind': 'installer', 'name': 'Acme Solar', 'tagline': 'Libreng site visit',
         'url': 'https://www.example.com/solar', 'placeholder': false},
      ],
    });
    expect(find.text('Acme Solar'), findsOneWidget);
    expect(find.text('www.example.com'), findsOneWidget);
    expect(find.textContaining('Ad space'), findsNothing);
  });

  testWidgets('not enough days yet: just the headline, no options', (t) async {
    await _card(t, plan: {
      ...example('solar_plan_meter_only'),
      'days': 3, 'usage': null, 'options': <Object>[],
      'headline': 'Kailangan ng 7 araw ng readings para masukat ang tamang laki ng solar (mayroon pa lang 3).',
    });
    expect(find.textContaining('Kailangan ng 7 araw'), findsOneWidget);
    expect(find.text('RECOMMENDED'), findsNothing);
  });

  testWidgets('Home never shows it: not to a meter-only home, not to a solar home', (t) async {
    await pumpApp(t, api: await _home(), size: _tall);
    expect(find.text('Go solar'), findsNothing);
    expect(find.text('SPONSORED'), findsNothing);
    expect(find.text('HOME'), findsOneWidget); // the rest of Home still shows
    await pumpApp(t, api: await _home(setup: 'solar'), size: _tall);
    expect(find.text('Go solar'), findsNothing);
  });
}
