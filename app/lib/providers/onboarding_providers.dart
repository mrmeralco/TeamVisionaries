// First run: has this device answered "what does your home have?" yet (saved on the device). The answer
// itself (solar | meter_only | solar_and_meter) is saved on the server as `setup` in /api/settings.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_providers.dart';

class OnboardedNotifier extends Notifier<bool> {
  static const key = 'onboarded';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(key) ?? false;

  Future<void> complete() async {
    await ref.read(sharedPreferencesProvider).setBool(key, true);
    state = true;
  }
}

final onboardedProvider = NotifierProvider<OnboardedNotifier, bool>(OnboardedNotifier.new);
