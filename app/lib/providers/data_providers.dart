// REST data for each tab (Contract C). Each provider watches [apiServiceProvider], so changing the
// server in Settings refetches everything. Pull-to-refresh: `ref.invalidate(billProvider)` etc.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/live_connection.dart';
import 'live_providers.dart';
import 'server_providers.dart';

typedef Json = Map<String, dynamic>;

/// GET /api/energy?period=day|week|month&back=N: N periods before the current one (0 = today / this week /
/// this month, 1 = yesterday / last week / last month).
final energyProvider = FutureProvider.family<Json, (String, int)>(
  (ref, q) => ref.watch(apiServiceProvider).getEnergy(q.$1, back: q.$2),
);

/// GET /api/bill
final billProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getBill());

/// GET /api/bill/projection (this month + up to 3 estimated months)
final billProjectionProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getBillProjection());

/// GET /api/brownout
final brownoutProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getBrownout());

/// GET /api/outlook (next 48 h: weather solar forecast, battery projection, brownout runtime with sun)
final outlookProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getOutlook());

/// GET /api/upgrade (system check: recommendations from the household's last 30 days)
final upgradeProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getUpgrade());

/// GET /api/tips (solar tips: right now, today, habits; this month's CO₂ avoided)
final tipsProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getTips());

/// GET /api/household (routine + is anyone home now, from home use; new appliance-sized loads)
final householdProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getHousehold());

/// GET /api/solar-plan (no solar yet: suggested size, savings, payback; sponsored slots)
final solarPlanProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getSolarPlan());

/// GET /api/meter (smart meter mode: reading, voltage, usage pattern, Meralco level, insights)
final meterProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getMeter());

/// The household's setup: solar | meter_only | solar_and_meter. Settings decide; the live object (which
/// carries it too) fills in while settings load; an older server without the field is a solar home.
final setupProvider = Provider<String>((ref) {
  final s = ref.watch(serverSettingsProvider).value?['setup'] ?? ref.watch(liveProvider.select((l) => l.live?['setup']));
  return s is String && const {'solar', 'meter_only', 'solar_and_meter'}.contains(s) ? s : 'solar';
});

/// False for a home with only a meter: no solar, battery, brownout runtime, solar tips or system check.
final hasSolarProvider = Provider<bool>((ref) => ref.watch(setupProvider) != 'meter_only');

/// True when the home has a smart/utility meter (meter_only or solar_and_meter).
final hasMeterProvider = Provider<bool>((ref) => ref.watch(setupProvider) != 'solar');

/// GET /api/summary/daily
final dailySummaryProvider =
    FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getDailySummary());

/// GET /api/alerts, kept current by `alert` messages on /ws/live and refetched after a reconnect.
class AlertsNotifier extends AsyncNotifier<Json> {
  @override
  Future<Json> build() async {
    final api = ref.watch(apiServiceProvider);

    ref.listen(liveProvider.select((s) => s.lastAlert), (_, alert) {
      if (alert != null) _prepend(alert);
    });
    ref.listen(liveProvider.select((s) => s.link), (prev, next) {
      // Alerts may have fired while the socket was down.
      if (prev != null && prev != LinkStatus.connected && next == LinkStatus.connected) {
        ref.invalidateSelf();
      }
    });

    return api.getAlerts();
  }

  List<Json> get _alerts => ((state.value?['alerts'] as List?) ?? const []).cast<Json>();

  void _prepend(Json alert) {
    final current = state.value;
    if (current == null) return;
    if (_alerts.any((a) => a['id'] == alert['id'])) return;
    final unread = (current['unread'] as int? ?? 0) + (alert['read'] == true ? 0 : 1);
    state = AsyncData({...current, 'unread': unread, 'alerts': [alert, ..._alerts]});
  }

  Future<void> markRead(int id) async {
    final updated = await ref.read(apiServiceProvider).markAlertRead(id);
    final current = state.value;
    if (current == null) return;
    final wasUnread = _alerts.any((a) => a['id'] == id && a['read'] != true);
    state = AsyncData({
      ...current,
      'unread': wasUnread ? ((current['unread'] as int? ?? 1) - 1).clamp(0, 1 << 30) : current['unread'],
      'alerts': [for (final a in _alerts) a['id'] == id ? updated : a],
    });
  }

  Future<void> markAllRead() async {
    await ref.read(apiServiceProvider).markAllAlertsRead();
    final current = state.value;
    if (current == null) return;
    state = AsyncData({
      ...current,
      'unread': 0,
      'alerts': [for (final a in _alerts) {...a, 'read': true}],
    });
  }
}

final alertsProvider = AsyncNotifierProvider<AlertsNotifier, Json>(AlertsNotifier.new);

/// Unread count for the nav badge (0 while loading or offline).
final unreadAlertsProvider = Provider<int>(
  (ref) => ref.watch(alertsProvider).value?['unread'] as int? ?? 0,
);

/// The server answered PUT /api/settings but didn't keep [fields] (e.g. a server from before smart meter
/// mode drops `setup`). The app then shows what the server has, and says so instead of looking saved.
class SettingsNotKept implements Exception {
  const SettingsNotKept(this.fields);
  final List<String> fields;
  @override
  String toString() => 'SettingsNotKept($fields)';
}

/// GET / PUT /api/settings (rate ₱/kWh, battery kWh, user name, device id).
class SettingsNotifier extends AsyncNotifier<Json> {
  @override
  Future<Json> build() => ref.watch(apiServiceProvider).getSettings();

  /// PUT takes any subset of fields and returns the full object.
  Future<void> save(Json changes) async {
    final saved = await ref.read(apiServiceProvider).updateSettings(changes);
    state = AsyncData(saved);
    // Rate / battery size feed the bill, brownout runtime and live savings.
    ref.invalidate(billProvider);
    ref.invalidate(brownoutProvider);
    ref.invalidate(meterProvider);
    ref.invalidate(solarPlanProvider); // the rate prices the savings; the setup decides if there is a plan
    if (changes.containsKey('setup')) {
      // A different household: every number comes from somewhere else now (meter vs inverter).
      for (final p in [billProjectionProvider, outlookProvider, upgradeProvider, tipsProvider, householdProvider,
          dailySummaryProvider]) {
        ref.invalidate(p);
      }
      ref.invalidate(energyProvider);
      ref.invalidate(liveProvider); // reconnect: the first message carries the new setup
    }
    final dropped = [for (final e in changes.entries) if (saved[e.key] != e.value) e.key];
    if (dropped.isNotEmpty) throw SettingsNotKept(dropped);
  }
}

final serverSettingsProvider = AsyncNotifierProvider<SettingsNotifier, Json>(SettingsNotifier.new);
