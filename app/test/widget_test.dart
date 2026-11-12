// Smoke test: the app boots in mock mode, connects the live stream, and every tab renders.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sinag/main.dart';
import 'package:sinag/providers/server_providers.dart';

void main() {
  setUp(() {
    // rootBundle in tests: serve assets/mock/*.json from disk.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (msg) async {
      final key = utf8.decode(msg!.buffer.asUint8List());
      final file = File(Uri.decodeFull(key));
      if (!file.existsSync()) return null;
      return ByteData.sublistView(file.readAsBytesSync());
    });
  });

  testWidgets('boots in mock mode and shows every tab', (tester) async {
    SharedPreferences.setMockInitialValues({'use_mock': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const SinagApp(),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.text('Mock'), findsOneWidget); // live link connected via MockApiService
    expect(find.textContaining('State: '), findsOneWidget);

    for (final tab in ['Energy', 'Bill', 'Ask', 'Alerts', 'Home']) {
      await tester.tap(find.text(tab).last);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);

    // Stop the periodic mock stream so the test ends cleanly.
    await tester.pumpWidget(const SizedBox());
  });
}
