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

/// GET /api/brownout
final brownoutProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getBrownout());

/// GET /api/outlook (next 48 h: weather solar forecast, battery projection, brownout runtime with sun)
final outlookProvider = FutureProvider<Json>((ref) => ref.watch(apiServiceProvider).getOutlook());

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
  }
}

final serverSettingsProvider = AsyncNotifierProvider<SettingsNotifier, Json>(SettingsNotifier.new);
