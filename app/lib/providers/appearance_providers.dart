// Day or night look. Auto (default): dark from 6 PM to 6 AM, Manila time, to match the night house.
// Settings can pin it to light or dark (saved on the device).
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
    return Appearance.values.firstWhere((a) => a.name == saved, orElse: () => Appearance.auto);
  }

  Future<void> set(Appearance a) async {
    await ref.read(sharedPreferencesProvider).setString(_key, a.name);
    state = a;
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(AppearanceNotifier.new);

/// True while the app should look like night. In auto it checks the clock every 30 s, so it turns
/// over within half a minute of 6 o'clock.
class NightNotifier extends Notifier<bool> {
  @override
  bool build() {
    final a = ref.watch(appearanceProvider);
    if (a != Appearance.auto) return a == Appearance.dark;
    final timer = Timer.periodic(const Duration(seconds: 30), (_) {
      final n = isNightAt(homeClock());
      if (n != state) state = n;
    });
    ref.onDispose(timer.cancel);
    return isNightAt(homeClock());
  }
}

final nightProvider = NotifierProvider<NightNotifier, bool>(NightNotifier.new);
