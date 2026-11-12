// SPEC (Aldrin): what ApiService and MockApiService must do. Run: flutter test test/spec
//
// Needs: lib/services/api_service.dart   -> class ApiService({required String baseUrl, http.Client? client})
//        lib/services/mock_api_service.dart -> class MockApiService implements ApiService
// Methods may return Map<String, dynamic> or your own model with toJson(); either way the result must
// match docs/contracts/schema.json. Starter code that passes: test_spec/reference/.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solaris/services/api_service.dart';
import 'package:solaris/services/mock_api_service.dart';

import 'contract_schema.dart';

/// Fake backend: answers like the real server (from the example files) and records every request.
class FakeServer {
  final requests = <http.Request>[];

  late final client = MockClient((req) async {
    requests.add(req);
    final p = req.url.path;
    Map<String, dynamic>? body;
    if (req.method == 'GET' && p == '/api/live') body = example('live');
    if (req.method == 'GET' && p == '/api/energy') body = example('energy_${req.url.queryParameters['period']}');
    if (req.method == 'GET' && p == '/api/bill') body = example('bill');
    if (req.method == 'GET' && p == '/api/brownout') body = example('brownout');
    if (req.method == 'GET' && p == '/api/alerts') body = example('alerts');
    if (req.method == 'POST' && p == '/api/alerts/read-all') body = {'unread': 0};
    if (req.method == 'POST' && RegExp(r'^/api/alerts/\d+/read$').hasMatch(p)) {
      body = {...(example('alerts')['alerts'] as List).first as Map<String, dynamic>, 'read': true};
    }
    if (req.method == 'POST' && p == '/api/chat') body = example('chat');
    if (req.method == 'GET' && p == '/api/summary/daily') body = example('summary_daily');
    if (req.method == 'GET' && p == '/api/settings') body = example('settings');
    if (req.method == 'PUT' && p == '/api/settings') body = {...example('settings'), ...jsonDecode(req.body) as Map};
    if (req.method == 'GET' && p == '/api/health') body = {'ok': true, 'mock': false, 'llm': 'qwen3.5:4b', 'llm_reachable': true};
    if (body == null) return http.Response('{"detail":"Not Found"}', 404);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});
  });

  http.Request get last => requests.last;
}

void expectContract(String name, Object? result) {
  final errs = contractErrors(name, asJson(result));
  expect(errs, isEmpty, reason: 'does not match contract "$name":\n${errs.take(10).join('\n')}');
}

void main() {
  group('contract examples (sanity: the checker and the shared files agree)', () {
    for (final (file, schema) in [
      ('live', 'live'), ('energy_day', 'energy'), ('energy_week', 'energy'), ('energy_month', 'energy'),
      ('bill', 'bill'), ('brownout', 'brownout'), ('alerts', 'alerts'), ('chat', 'chat'),
      ('summary_daily', 'summary'), ('settings', 'settings'), ('outlook', 'outlook'), ('upgrade', 'upgrade'),
    ]) {
      test('$file.json is a valid $schema', () => expectContract(schema, example(file)));
    }
    test('the checker catches a broken payload', () {
      final live = example('live')..remove('status_line');
      (live['telemetry'] as Map)['pv_w'] = 'lots';
      expect(contractErrors('live', live), hasLength(2));
    });
  });

  group('ApiService talks to the real endpoints', () {
    late FakeServer server;
    late ApiService api;
    setUp(() {
      server = FakeServer();
      api = ApiService(baseUrl: 'http://192.168.43.100:8000/', client: server.client); // trailing slash on purpose
    });

    void expectRequest(String method, String pathAndQuery) {
      expect(server.last.method, method);
      expect(server.last.url.toString(), 'http://192.168.43.100:8000$pathAndQuery');
    }

    test('getLive -> GET /api/live', () async {
      expectContract('live', await api.getLive());
      expectRequest('GET', '/api/live');
    });

    for (final period in ['day', 'week', 'month']) {
      test('getEnergy($period) -> GET /api/energy?period=$period', () async {
        expectContract('energy', await api.getEnergy(period));
        expectRequest('GET', '/api/energy?period=$period');
      });
    }

    test('getBill -> GET /api/bill', () async {
      expectContract('bill', await api.getBill());
      expectRequest('GET', '/api/bill');
    });

    test('getBrownout -> GET /api/brownout', () async {
      expectContract('brownout', await api.getBrownout());
      expectRequest('GET', '/api/brownout');
    });

    test('getAlerts -> GET /api/alerts', () async {
      expectContract('alerts', await api.getAlerts());
      expectRequest('GET', '/api/alerts');
    });

    test('markAlertRead(id) -> POST /api/alerts/{id}/read', () async {
      expectContract('alert', await api.markAlertRead(14));
      expectRequest('POST', '/api/alerts/14/read');
    });

    test('markAllAlertsRead -> POST /api/alerts/read-all', () async {
      await api.markAllAlertsRead();
      expectRequest('POST', '/api/alerts/read-all');
    });

    test('chat(message) -> POST /api/chat with {"message": ...}', () async {
      expectContract('chat', await api.chat('Bakit mataas ang bill ko?'));
      expectRequest('POST', '/api/chat');
      expect(jsonDecode(server.last.body), {'message': 'Bakit mataas ang bill ko?'});
      expect(server.last.headers['content-type'], startsWith('application/json'));
    });

    test('chat keeps ₱ and Taglish intact (UTF-8)', () async {
      final r = asJson(await api.chat('hi')) as Map;
      expect(r['reply'], contains('₱'));
    });

    test('getDailySummary -> GET /api/summary/daily', () async {
      expectContract('summary', await api.getDailySummary());
      expectRequest('GET', '/api/summary/daily');
    });

    test('getSettings / updateSettings -> GET, PUT /api/settings (partial body)', () async {
      expectContract('settings', await api.getSettings());
      final r = asJson(await api.updateSettings({'rate_php_per_kwh': 12.5})) as Map;
      expectRequest('PUT', '/api/settings');
      expect(jsonDecode(server.last.body), {'rate_php_per_kwh': 12.5});
      expect(r['rate_php_per_kwh'], 12.5);
      expectContract('settings', r);
    });

    test('health -> GET /api/health (Settings "Test connection")', () async {
      expectContract('health', await api.health());
      expectRequest('GET', '/api/health');
    });

    test('server errors surface as exceptions, not as empty data', () async {
      final broken = ApiService(baseUrl: 'http://x:8000', client: MockClient((_) async => http.Response('boom', 500)));
      expect(broken.getLive(), throwsA(anything));
    });

    test('liveSocketUri is ws://<same host:port>/ws/live', () {
      expect(api.liveSocketUri().toString(), 'ws://192.168.43.100:8000/ws/live');
    });
  });

  group('MockApiService works with no server at all', () {
    late MockApiService mock;
    setUp(() => mock = MockApiService(loader: (name) async => jsonEncode(example(name))));

    test('every screen gets contract-shaped data', () async {
      expectContract('live', await mock.getLive());
      for (final p in ['day', 'week', 'month']) {
        expectContract('energy', await mock.getEnergy(p));
      }
      expectContract('bill', await mock.getBill());
      expectContract('brownout', await mock.getBrownout());
      expectContract('alerts', await mock.getAlerts());
      expectContract('chat', await mock.chat('hi'));
      expectContract('summary', await mock.getDailySummary());
      expectContract('settings', await mock.getSettings());
      expectContract('health', await mock.health());
    });

    test('is a drop-in replacement for ApiService (one flag flips them)', () {
      final ApiService api = mock; // compiles only if MockApiService implements ApiService
      expect(api, isNotNull);
    });

    test('live stream emits telemetry messages like /ws/live', () async {
      final msgs = await mock.liveMessages().take(1).toList();
      for (final m in msgs) {
        expectContract('ws_message', m);
      }
    });
  });
}
