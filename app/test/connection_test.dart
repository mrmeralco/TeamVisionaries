import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinag/core/config/server_config.dart';
import 'package:sinag/services/api_service.dart';
import 'package:sinag/services/live_connection.dart';

/// liveMessages() fails on the first attempt, then delivers one message and drops.
class FlakyApi extends ApiService {
  FlakyApi() : super(baseUrl: 'http://x:8000');
  int attempts = 0;

  @override
  Stream<Map<String, dynamic>> liveMessages() {
    attempts++;
    if (attempts == 1) return Stream.error(Exception('refused'));
    return Stream.value({'type': 'telemetry', 'data': <String, dynamic>{}});
  }
}

void main() {
  group('ServerConfig.normalizeUrl', () {
    test('accepts a bare IP and adds http + port 8000', () {
      expect(ServerConfig.normalizeUrl('192.168.43.100'), 'http://192.168.43.100:8000');
    });
    test('keeps an explicit port and drops a trailing slash', () {
      expect(ServerConfig.normalizeUrl(' http://192.168.1.5:9000/ '), 'http://192.168.1.5:9000');
    });
    test('rejects junk', () {
      expect(ServerConfig.normalizeUrl(''), isNull);
      expect(ServerConfig.normalizeUrl('ftp://x'), isNull);
    });
  });

  test('backoff grows and caps', () {
    expect(backoffFor(0), const Duration(seconds: 1));
    expect(backoffFor(3), const Duration(seconds: 8));
    expect(backoffFor(9), const Duration(seconds: 15));
  });

  test('reconnectingLive retries after an error and reports status', () async {
    final api = FlakyApi();
    final events = await reconnectingLive(api, backoff: (_) => Duration.zero).take(6).toList();
    expect(events.map((e) => e.status ?? e.message!['type']).toList(), [
      LinkStatus.connecting,
      LinkStatus.waiting, // first attempt refused
      LinkStatus.connecting,
      LinkStatus.connected,
      'telemetry',
      LinkStatus.waiting, // socket closed → will reconnect
    ]);
    expect(events[1].error, isNotNull);
    expect(api.attempts, 2);
  });

  test('ApiService builds ws:// and wss:// URIs', () {
    expect(ApiService(baseUrl: 'http://10.0.2.2:8000').liveSocketUri().toString(), 'ws://10.0.2.2:8000/ws/live');
    expect(ApiService(baseUrl: 'https://sinag.test').liveSocketUri().toString(), 'wss://sinag.test/ws/live');
  });
}
