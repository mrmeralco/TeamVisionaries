// Day or night look. Light by default. Settings can switch to Auto (dark from 6 PM to 6 AM, Manila time,
// with the night house) or always dark (saved on the device).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/clock.dart';
import 'server_providers.dart';

enum Appearance { auto, light, dark }

class AppearanceNotifier extends Notifier<Appearance> {
  static const _key = 'appearance';

  @override
  Appearance build() {
    final saved = ref.watch(sharedPreferencesProvider).getString(_key);
    return Appearance.values.firstWhere((a) => a.name == saved, orElse: () => Appearance.light);
  }

  Future<void> set(Appearance a) async {
    await ref.read(sharedPreferencesProvider).setString(_key, a.name);
    state = a;
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(AppearanceNotifier.new);

/// Night by the clock: 6 PM to 6 AM, Manila time, checked every 30 s so it turns over within half a
/// minute of 6 o'clock. Home's house and sky follow it whatever the app's appearance.
class ClockNightNotifier extends Notifier<bool> {
  @override
  bool build() {
    final timer = Timer.periodic(const Duration(seconds: 30), (_) {
      final n = isNightAt(homeClock());
      if (n != state) state = n;
    });
    ref.onDispose(timer.cancel);
    return isNightAt(homeClock());
  }
}

final clockNightProvider = NotifierProvider<ClockNightNotifier, bool>(ClockNightNotifier.new);

/// True while the whole app should look dark: always for Dark, never for Light, by the clock for Auto.
final nightProvider = Provider<bool>((ref) => switch (ref.watch(appearanceProvider)) {
      Appearance.light => false,
      Appearance.dark => true,
      Appearance.auto => ref.watch(clockNightProvider),
    });
