// Alert notifications outside the app: the platform notifier and the user's on/off choice (saved).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/system_notifier.dart';
import 'server_providers.dart';

/// Overridden in tests with a fake.
final systemNotifierProvider = Provider<SystemNotifier>((ref) => createSystemNotifier());

class NotifyAlertsNotifier extends Notifier<bool> {
  static const _key = 'notify_alerts';

  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(_key) ?? false;

  /// Turning it on asks for permission first; stays off if the user (or the browser) says no.
  Future<bool> setEnabled(bool on) async {
    var ok = on;
    if (on) ok = await ref.read(systemNotifierProvider).requestPermission();
    await ref.read(sharedPreferencesProvider).setBool(_key, ok);
    state = ok;
    return ok;
  }
}

final notifyAlertsProvider = NotifierProvider<NotifyAlertsNotifier, bool>(NotifyAlertsNotifier.new);
