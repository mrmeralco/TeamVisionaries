// First run with Mira: hello, how Solaris works, how to use it, your name, then "Ano ang meron sa bahay
// mo?" (solar or a smart meter only). Name and setup are saved together (PUT /api/settings); a meter-only
// home then sees no solar on Home, only its use and ways to save.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solaris/providers/data_providers.dart';
import 'package:solaris/providers/onboarding_providers.dart';

import 'widget_test.dart' show StateMock, example, pumpApp;

const _tall = Size(393, 3600);

/// A server that can't be reached when saving.
class _Offline extends StateMock {
  @override
  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> changes) async =>
      throw TimeoutException('no server');
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(Key(key)));
  await t.pumpAndSettle();
}

/// Through the introduction and the name, to the setup question.
Future<void> _toSetup(WidgetTester t, {String name = 'Ana'}) async {
  for (var i = 0; i < 3; i++) {
    await _tap(t, 'onboard-next');
  }
  await t.enterText(find.byKey(const Key('onboard-name')), name);
  await t.pumpAndSettle();
  await _tap(t, 'onboard-next');
}

FilledButton _button(WidgetTester t, String key) => t.widget<FilledButton>(find.byKey(Key(key)));

void main() {
  testWidgets('Mira introduces herself, explains Solaris and how to use it, before anything else', (t) async {
    await pumpApp(t, onboarded: false, size: _tall);
    expect(find.textContaining('Ako si Mira'), findsOneWidget);
    expect(find.text('Solar tips'), findsNothing); // not on Home yet

    await _tap(t, 'onboard-next');
    expect(find.text('Binabasa ng Solaris device ang bahay mo'), findsOneWidget);
    expect(find.text('Sinasabihan kita agad'), findsOneWidget);

    await _tap(t, 'onboard-next');
    for (final tab in ['Home', 'Energy', 'Bill', 'Alerts', 'Ako, si Mira']) {
      expect(find.text(tab), findsOneWidget, reason: tab);
    }

    // Back works.
    await _tap(t, 'onboard-back');
    expect(find.text('Binabasa ng Solaris device ang bahay mo'), findsOneWidget);
  });

  testWidgets('asks for a name; can\'t continue without one; Mira uses it', (t) async {
    await pumpApp(t, onboarded: false, size: _tall);
    await _tap(t, 'onboard-skip'); // straight to the name
    expect(find.textContaining('ano ang pangalan mo?'), findsOneWidget);
    expect(_button(t, 'onboard-next').onPressed, isNull);
    await t.enterText(find.byKey(const Key('onboard-name')), '  Ana ');
    await t.pumpAndSettle();
    await _tap(t, 'onboard-next');
    expect(find.text('Salamat, Ana! Huling tanong: ano ang meron sa bahay mo?'), findsOneWidget);
    // Nothing chosen yet: can't finish.
    expect(_button(t, 'onboard-continue').onPressed, isNull);
  });

  testWidgets('"Smart meter lang": saved with the name, Home shows ways to save and no solar', (t) async {
    final api = StateMock();
    final c = await pumpApp(t, api: api, onboarded: false, size: _tall);
    await _toSetup(t, name: 'Ana');
    await _tap(t, 'onboard-meter_only');
    expect(find.byKey(const Key('onboard-also-meter')), findsNothing); // only asked of solar homes
    await _tap(t, 'onboard-continue');

    expect(api.setup, 'meter_only');
    expect(c.read(setupProvider), 'meter_only');
    expect(c.read(serverSettingsProvider).value!['user_name'], 'Ana');
    expect(c.read(onboardedProvider), isTrue);
    expect(find.textContaining(', Ana!'), findsOneWidget); // the greeting

    // Home: the saving tips from the meter lead, under their own title.
    expect(find.text('Paano makatipid'), findsOneWidget);
    final insights = (example('meter')['insights'] as List).cast<Map<String, dynamic>>();
    for (final id in ['tier_drop', 'peak_hours', 'base_load']) {
      final title = insights.firstWhere((i) => i['id'] == id)['title'] as String;
      expect(find.text(title), findsOneWidget, reason: id);
    }
    expect(
      t.getTopLeft(find.text('Paano makatipid')).dy,
      lessThan(t.getTopLeft(find.text('Normal ang boltahe')).dy),
    );
    // Nothing about solar.
    for (final solar in ['Solar tips', 'Saved today', 'Go solar', 'SPONSORED', 'SOLAR', 'BATTERY']) {
      expect(find.text(solar), findsNothing, reason: solar);
    }
    expect(find.text('Used today'), findsOneWidget);
  });

  testWidgets('"May solar ako" + smart meter too: saved as solar_and_meter', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api, onboarded: false, size: _tall);
    await _toSetup(t);
    await _tap(t, 'onboard-solar');
    await _tap(t, 'onboard-also-meter');
    await _tap(t, 'onboard-continue');
    expect(api.setup, 'solar_and_meter');
    expect(find.text('Solar tips'), findsOneWidget);
    expect(find.text('Paano makatipid'), findsNothing);
  });

  testWidgets('"May solar ako" alone: saved as solar', (t) async {
    final api = StateMock();
    await pumpApp(t, api: api, onboarded: false, size: _tall);
    await _toSetup(t);
    await _tap(t, 'onboard-solar');
    await _tap(t, 'onboard-continue');
    expect(api.setup, 'solar');
    expect(find.text('Saved today'), findsOneWidget);
  });

  testWidgets('no server: stays on the question, says so, and links to the server settings', (t) async {
    final c = await pumpApp(t, api: _Offline(), onboarded: false, size: _tall);
    await _toSetup(t);
    await _tap(t, 'onboard-meter_only');
    await _tap(t, 'onboard-continue');
    expect(find.textContaining('Hindi na-save.'), findsOneWidget);
    expect(find.textContaining('hindi ko na-save'), findsOneWidget); // Mira says so too
    expect(c.read(onboardedProvider), isFalse);
    await t.tap(find.text('Server settings'));
    await t.pumpAndSettle();
    expect(find.text('Server address (laptop IP)'), findsOneWidget);
  });

  testWidgets('answered once: the next launch opens Home', (t) async {
    await pumpApp(t, size: _tall);
    expect(find.textContaining('Ako si Mira'), findsNothing);
    expect(find.text('Solar tips'), findsOneWidget);
  });
}
