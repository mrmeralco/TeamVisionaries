// MockApiService: same methods as ApiService, answers from assets/mock/*.json
// (copies of docs/contracts/examples). Turn it on in Settings or with --dart-define=SOLARIS_MOCK=true.
// Household setup: saving {"setup": "meter_only"} (or solar_and_meter) in Settings switches the demo to
// `<name>_<setup>.json` wherever that file exists, like the backend's mock mode.
//
// pubspec.yaml:
//   flutter:
//     assets:
//       - assets/mock/
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'api_service.dart';

class MockApiService implements ApiService {
  /// [saved]: settings changed in an earlier session; [onSave] keeps them (e.g. on the device), so the
  /// demo household (setup, name) survives a reload.
  MockApiService({AssetLoader? loader, Map<String, dynamic>? saved, this.onSave})
      : _load = loader ?? ((name) => rootBundle.loadString('assets/mock/$name.json')) {
    if (saved != null) _settingsOverrides.addAll(saved);
  }

  final AssetLoader _load;
  final void Function(Map<String, dynamic> overrides)? onSave;
  final _settingsOverrides = <String, dynamic>{};

  /// solar | meter_only | solar_and_meter: the demo household (saved through [updateSettings]).
  String get setup => '${_settingsOverrides['setup'] ?? 'solar'}';

  /// The example for the current [setup] when there is one (e.g. live_meter_only), else the plain example.
  Future<Map<String, dynamic>> _json(String name) async {
    if (setup != 'solar') {
      try {
        return jsonDecode(await _load('${name}_$setup')) as Map<String, dynamic>;
      } catch (_) {
        // no variant for this setup: same data as a solar home (alerts, chat, ...)
      }
    }
    return jsonDecode(await _load(name)) as Map<String, dynamic>;
  }

  @override
  String get baseUrl => 'mock://';

  @override
  Future<Map<String, dynamic>> getLive() => _json('live');
  @override
  Future<Map<String, dynamic>> getEnergy(String period, {int back = 0}) async {
    final e = await _json('energy_$period');
    // Demo data has one example per period: earlier periods reuse it with the dates moved back.
    final shift = back * switch (period) { 'day' => 86400, 'week' => 7 * 86400, _ => 0 };
    if (shift == 0) return e;
    return {
      ...e,
      'start_ts': (e['start_ts'] as int) - shift,
      'end_ts': (e['end_ts'] as int) - shift,
      'points': [for (final p in e['points'] as List) {...(p as Map<String, dynamic>), 'ts': (p['ts'] as int) - shift}],
    };
  }
  @override
  Future<Map<String, dynamic>> getBill() => _json('bill');
  @override
  Future<Map<String, dynamic>> getBillProjection() => _json('bill_projection');
  @override
  Future<Map<String, dynamic>> getBrownout() => _json('brownout');
  @override
  Future<Map<String, dynamic>> getOutlook() => _json('outlook');
  @override
  Future<Map<String, dynamic>> getUpgrade() => _json('upgrade');
  @override
  Future<Map<String, dynamic>> getTips() => _json('tips');
  @override
  Future<Map<String, dynamic>> getHousehold() => _json('household');
  @override
  Future<Map<String, dynamic>> getSolarPlan() => _json('solar_plan');
  @override
  Future<Map<String, dynamic>> getMeter() => _json('meter');
  @override
  Future<Map<String, dynamic>> getAlerts({bool unreadOnly = false}) async {
    final a = await _json('alerts');
    if (unreadOnly) a['alerts'] = (a['alerts'] as List).where((x) => x['read'] == false).toList();
    return a;
  }

  @override
  Future<Map<String, dynamic>> markAlertRead(int id) async {
    final list = (await _json('alerts'))['alerts'] as List;
    final a = list.cast<Map<String, dynamic>>().firstWhere((x) => x['id'] == id, orElse: () => throw ApiException(404, 'alert not found'));
    return {...a, 'read': true};
  }

  @override
  Future<Map<String, dynamic>> markAllAlertsRead() async => {'unread': 0};
  @override
  Future<Map<String, dynamic>> chat(String message) => _json('chat');
  @override
  Future<Map<String, dynamic>> getDailySummary() => _json('summary_daily');
  @override
  Future<Map<String, dynamic>> getSettings() async => {...await _json('settings'), ..._settingsOverrides, 'setup': setup};
  @override
  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> changes) async {
    _settingsOverrides.addAll(changes);
    onSave?.call(Map.of(_settingsOverrides));
    return getSettings();
  }

  @override
  Future<Map<String, dynamic>> health() async => {'ok': true, 'mock': true, 'llm': null, 'llm_reachable': false};

  @override
  void close() {}

  @override
  Uri liveSocketUri() => Uri.parse('ws://mock/ws/live');

  /// Emits the example reading every 5 s with small changes, like the real /ws/live.
  @override
  Stream<Map<String, dynamic>> liveMessages({Duration every = const Duration(seconds: 5)}) async* {
    final base = await _json('live');
    var i = 0;
    // Stamp readings "now" so Home's "Updated …" line reads like a live demo, not a 6-hour-old file.
    Map<String, dynamic> fresh(Map<String, dynamic> live) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final r in [live['telemetry'], live['meter']]) {
        if (r is Map<String, dynamic>) r['ts'] = now;
      }
      return live;
    }

    yield {'type': 'telemetry', 'data': fresh(jsonDecode(jsonEncode(base)) as Map<String, dynamic>)};
    await for (final _ in Stream.periodic(every)) {
      final live = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
      final step = ((i++ % 5) - 2) * 100;
      final t = live['telemetry'];
      final m = live['meter'];
      if (t is Map<String, dynamic>) {
        t['pv_w'] = (t['pv_w'] as int) + step;
        t['batt_w'] = (t['load_w'] as int) - (t['pv_w'] as int);
      } else if (m is Map<String, dynamic>) {
        m['power_w'] = (m['power_w'] as num) + step; // meter only: the house's draw moves instead
      }
      yield {'type': 'telemetry', 'data': fresh(live)};
    }
  }
}

typedef AssetLoader = Future<String> Function(String name);
