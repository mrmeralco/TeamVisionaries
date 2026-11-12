// The app is light by default; Home's house and sky still follow the time (the night house from 6 PM).
// Settings > Appearance > Auto makes night (6 PM to 6 AM, Manila) a full dark
// mode, to match the night house: navy page, dark cards, light text, on every screen; Dark keeps it dark. And the house on Home
// matches the household: no panels or battery for a meter-only home, still labelled.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solaris/core/theme/app_theme.dart';
import 'package:solaris/core/utils/format.dart';
import 'package:solaris/features/home/home_screen.dart' show homeClock;
import 'package:solaris/features/home/house_scene.dart';
import 'package:solaris/providers/appearance_providers.dart';

import 'widget_test.dart' show StateMock, example, pumpApp;

const _tall = Size(393, 3000);
const _navy = Color(0xFF0F1729);
const _cream = Color(0xFFFFF3E5);

String _houseAsset(WidgetTester t) => t
    .widgetList<SvgPicture>(find.descendant(of: find.byType(HouseScene), matching: find.byType(SvgPicture)))
    .map((w) => (w.bytesLoader as SvgAssetLoader).assetName)
    .single;

Color? _textColor(WidgetTester t, String text) => t.widget<Text>(find.text(text).first).style?.color;

Color? _pageColor(WidgetTester t) => t.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor;

void _at(int hour, [int minute = 0]) {
  homeClock = () => DateTime(2026, 11, 12, hour, minute);
  addTearDown(() => homeClock = manilaNow);
}

const _auto = {'appearance': 'auto'};

Future<StateMock> _meterHome() async {
  final api = StateMock(live: example('live_meter_only'));
  await api.updateSettings({'setup': 'meter_only'});
  return api;
}

void main() {
  testWidgets('light by default, even at night; the house on Home still follows the time', (t) async {
    _at(21);
    await pumpApp(t, size: _tall);
    expect(C.night, isFalse);
    expect(_pageColor(t), _cream);
    expect(_textColor(t, 'Solar tips'), isNot(_navy)); // dark text on the light dashboard
    expect(_houseAsset(t), 'assets/images/house-hero-night.svg');
    expect(find.textContaining('Magandang gabi'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    expect(t.widget<ChoiceChip>(find.byKey(const Key('appearance-light'))).selected, isTrue);
  });

  testWidgets('Auto, at night: every screen is dark: navy page, light text', (t) async {
    _at(20, 30);
    await pumpApp(t, size: _tall, prefs: _auto);
    expect(C.night, isTrue);
    expect(_pageColor(t), _navy);
    expect(_textColor(t, 'Solar tips'), C.ink);
    expect(C.ink.computeLuminance(), greaterThan(0.8)); // light text
    expect(Theme.of(t.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
    expect(_houseAsset(t), 'assets/images/house-hero-night.svg');

    // Other tabs too.
    await t.tap(find.text('Bill').last);
    await t.pumpAndSettle();
    expect(_pageColor(t), _navy);
  });

  testWidgets('Auto, by day: light', (t) async {
    _at(10);
    await pumpApp(t, size: _tall, prefs: _auto);
    expect(C.night, isFalse);
    expect(_pageColor(t), _cream);
    expect(_houseAsset(t), 'assets/images/house-hero.svg');
  });

  testWidgets('Auto turns dark by itself at 6 PM, without reopening the app', (t) async {
    _at(17, 59);
    await pumpApp(t, size: _tall, prefs: _auto);
    expect(C.night, isFalse);
    final dayInk = _textColor(t, 'Solar tips');

    homeClock = () => DateTime(2026, 11, 12, 18, 0, 5);
    await t.pump(const Duration(seconds: 31));
    await t.pumpAndSettle();
    expect(C.night, isTrue);
    expect(_pageColor(t), _navy);
    // Const widgets repaint too, not just the ones that rebuild on their own.
    expect(_textColor(t, 'Solar tips'), isNot(dayInk));
    expect(_houseAsset(t), 'assets/images/house-hero-night.svg');
  });

  testWidgets('Settings > Appearance: dark, back to light, then Auto at night', (t) async {
    _at(10);
    final c = await pumpApp(t, size: _tall);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('appearance-dark')));
    await t.pumpAndSettle();
    expect(C.night, isTrue);
    expect(_pageColor(t), _navy);
    expect(c.read(appearanceProvider), Appearance.dark);

    await t.tap(find.byKey(const Key('appearance-light')));
    await t.pumpAndSettle();
    expect(C.night, isFalse);
    expect(_pageColor(t), _cream);

    // Auto from Settings: dark at night.
    _at(21);
    final again = await pumpApp(t, size: _tall);
    await t.tap(find.bySemanticsLabel('Settings').first);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('appearance-auto')));
    await t.pumpAndSettle();
    expect(C.night, isTrue);
    expect(again.read(appearanceProvider), Appearance.auto);
  });

  testWidgets('a meter-only home: the house without solar, with HOME and GRID labels', (t) async {
    _at(10);
    await pumpApp(t, api: await _meterHome(), size: _tall);
    expect(_houseAsset(t), 'assets/images/house-hero-meter.svg');
    expect(find.text('HOME'), findsOneWidget);
    expect(find.text('GRID'), findsOneWidget);
    for (final gone in ['SOLAR', 'BATTERY', 'METER']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // A label zooms in and explains, like the solar house.
    await t.tap(find.text('GRID'));
    await t.pumpAndSettle();
    expect(find.textContaining('boltahe ng kuryente mula sa Meralco'), findsOneWidget);
    expect(find.text('Normal'), findsWidgets);
  });

  testWidgets('a meter-only home at night (Auto): the night house without solar', (t) async {
    _at(22);
    await pumpApp(t, api: await _meterHome(), size: _tall, prefs: _auto);
    expect(_houseAsset(t), 'assets/images/house-hero-night-meter.svg');
    expect(find.text('HOME'), findsOneWidget);
  });

  test('the meter-only house shows only the parts it has: tapping anywhere finds home or the meter', () {
    final found = <Spot?>{
      for (var x = 0.0; x <= kSceneW; x += 3)
        for (var y = 0.0; y <= kSceneH; y += 3) spotAt(Offset(x, y), spots: meterSpots),
    };
    expect(found, {null, Spot.home, Spot.grid});
  });
}
