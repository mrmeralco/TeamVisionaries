// The household setup picked in onboarding is the one Settings shows, and changing it in Settings changes
// Home: one value (server settings `setup`), wherever it is read or written.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solaris/features/home/house_scene.dart';
import 'package:solaris/providers/data_providers.dart';

import 'widget_test.dart' show StateMock, example, pumpApp;

const _tall = Size(393, 3600);

/// A demo server whose live reading follows the setup, like the real one (live_meter_only for a meter home).
class _Home extends StateMock {
  Map<String, dynamic> get _live => example(setup == 'solar' ? 'live' : 'live_$setup');
  @override
  Future<Map<String, dynamic>> getLive() async => _live;
  @override
  Stream<Map<String, dynamic>> liveMessages({Duration every = const Duration(seconds: 5)}) {
    final c = socket = StreamController<Map<String, dynamic>>();
    c.onListen = () => c.add({'type': 'telemetry', 'data': _live});
    return c.stream;
  }
}

String _house(WidgetTester t) => t
    .widgetList<SvgPicture>(find.descendant(of: find.byType(HouseScene), matching: find.byType(SvgPicture)))
    .map((w) => (w.bytesLoader as SvgAssetLoader).assetName)
    .single;

bool _chip(WidgetTester t, String setup) => t.widget<ChoiceChip>(find.byKey(Key('setup-$setup'))).selected;

Future<void> _tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

Future<void> _settings(WidgetTester t) => _tap(t, find.bySemanticsLabel('Settings').first);

Future<void> _home(WidgetTester t) async {
  await t.pageBack();
  await t.pumpAndSettle();
}

void main() {
  testWidgets('onboarding "Smart meter lang" → Settings shows it; Settings changes Home both ways', (t) async {
    final api = _Home();
    final c = await pumpApp(t, api: api, onboarded: false, size: _tall);
    for (var i = 0; i < 4; i++) {
      await _tap(t, find.byKey(const Key('onboard-next')));
    }
    await t.enterText(find.byKey(const Key('onboard-name')), 'Ana');
    await t.pumpAndSettle();
    await _tap(t, find.byKey(const Key('onboard-next')));
    await _tap(t, find.byKey(const Key('onboard-meter_only')));
    await _tap(t, find.byKey(const Key('onboard-continue')));
    expect(_house(t), 'assets/images/house-hero-meter.svg');

    // Settings: the same answers.
    await _settings(t);
    expect(_chip(t, 'meter_only'), isTrue);
    expect(_chip(t, 'solar'), isFalse);
    expect(find.widgetWithText(TextField, 'Ana'), findsOneWidget);

    // Back to solar from Settings: Home follows.
    await _tap(t, find.byKey(const Key('setup-solar')));
    await _tap(t, find.text('Save household'));
    expect(api.setup, 'solar');
    await _home(t);
    expect(c.read(setupProvider), 'solar');
    expect(_house(t), 'assets/images/house-hero.svg');
    expect(find.text('SOLAR'), findsOneWidget);

    // And to the meter again.
    await _settings(t);
    expect(_chip(t, 'solar'), isTrue);
    await _tap(t, find.byKey(const Key('setup-meter_only')));
    await _tap(t, find.text('Save household'));
    await _home(t);
    expect(c.read(setupProvider), 'meter_only');
    expect(_house(t), 'assets/images/house-hero-meter.svg');
    expect(find.text('SOLAR'), findsNothing);
    expect(find.text('BATTERY'), findsNothing);
  });

  testWidgets('a server that drops the setup (older than smart meter mode): said, not shown as saved', (t) async {
    final api = _OldServer();
    final c = await pumpApp(t, api: api, onboarded: false, size: _tall);
    await _tap(t, find.byKey(const Key('onboard-skip')));
    await t.enterText(find.byKey(const Key('onboard-name')), 'Ana');
    await t.pumpAndSettle();
    await _tap(t, find.byKey(const Key('onboard-next')));
    await _tap(t, find.byKey(const Key('onboard-meter_only')));
    await _tap(t, find.byKey(const Key('onboard-continue')));
    // Still on the question, saying why, instead of a solar Home that looks like it ignored the answer.
    expect(find.textContaining('Hindi naitago ng server ang setup'), findsOneWidget);
    expect(find.textContaining('git pull'), findsOneWidget);
    expect(find.byKey(const Key('onboard-continue')), findsOneWidget);
    expect(c.read(setupProvider), 'solar'); // what the server really has
  });
}

/// A server from before smart meter mode: PUT /api/settings ignores `setup`, and settings have none.
class _OldServer extends StateMock {
  @override
  Future<Map<String, dynamic>> getSettings() async => {...await super.getSettings()}..remove('setup');
  @override
  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> changes) =>
      super.updateSettings({...changes}..remove('setup')).then((s) => {...s}..remove('setup'));
}
