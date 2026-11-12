// MockApiService: same methods as ApiService, answers from assets/mock/*.json
// (copies of docs/contracts/examples). Turn it on in Settings or with --dart-define=SOLARIS_MOCK=true.
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
  MockApiService({AssetLoader? loader}) : _load = loader ?? ((name) => rootBundle.loadString('assets/mock/$name.json'));

  final AssetLoader _load;
  final _settingsOverrides = <String, dynamic>{};

  Future<Map<String, dynamic>> _json(String name) async => jsonDecode(await _load(name)) as Map<String, dynamic>;

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
  Future<Map<String, dynamic>> getSettings() async => {...await _json('settings'), ..._settingsOverrides};
  @override
  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> changes) async {
    _settingsOverrides.addAll(changes);
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
      final t = live['telemetry'];
      if (t is Map<String, dynamic>) t['ts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return live;
    }

    yield {'type': 'telemetry', 'data': fresh(jsonDecode(jsonEncode(base)) as Map<String, dynamic>)};
    await for (final _ in Stream.periodic(every)) {
      final live = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
      final t = live['telemetry'] as Map<String, dynamic>;
      t['pv_w'] = (t['pv_w'] as int) + ((i++ % 5) - 2) * 100;
      t['batt_w'] = (t['load_w'] as int) - (t['pv_w'] as int);
      yield {'type': 'telemetry', 'data': fresh(live)};
    }
  }
}

typedef AssetLoader = Future<String> Function(String name);
