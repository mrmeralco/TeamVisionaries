// ApiService: one class for every Contract C call (docs/contracts/C-api.md).
// Starts from test_spec/reference/api_service.dart; `flutter test test/spec` must stay green.
// Every method returns the decoded JSON map; screens read fields by their contract names.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'ApiException($statusCode): $body';
}

class ApiService {
  /// [baseUrl] is what the user types in Settings, e.g. "http://192.168.43.100:8000".
  ApiService({required String baseUrl, http.Client? client})
      : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http = client ?? http.Client();

  final String baseUrl;
  final http.Client _http;
  static const _timeout = Duration(seconds: 15);
  static const _chatTimeout = Duration(seconds: 30); // the local LLM can take ~10 s

  Future<Map<String, dynamic>> getLive() => _get('/api/live');
  /// [period] day|week|month; [back] how many periods before the current one (0 = today / this week / month).
  Future<Map<String, dynamic>> getEnergy(String period, {int back = 0}) =>
      _get('/api/energy?period=$period${back > 0 ? '&back=$back' : ''}');
  Future<Map<String, dynamic>> getBill() => _get('/api/bill');
  Future<Map<String, dynamic>> getBrownout() => _get('/api/brownout');

  /// 48 h solar forecast, battery projection and brownout runtime with the sun counted.
  Future<Map<String, dynamic>> getOutlook() => _get('/api/outlook');
  Future<Map<String, dynamic>> getAlerts({bool unreadOnly = false}) =>
      _get(unreadOnly ? '/api/alerts?unread_only=true' : '/api/alerts');
  Future<Map<String, dynamic>> markAlertRead(int id) => _send('POST', '/api/alerts/$id/read');
  Future<Map<String, dynamic>> markAllAlertsRead() => _send('POST', '/api/alerts/read-all');
  Future<Map<String, dynamic>> chat(String message) =>
      _send('POST', '/api/chat', body: {'message': message}, timeout: _chatTimeout);
  Future<Map<String, dynamic>> getDailySummary() => _get('/api/summary/daily');
  Future<Map<String, dynamic>> getSettings() => _get('/api/settings');
  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> changes) =>
      _send('PUT', '/api/settings', body: changes);
  Future<Map<String, dynamic>> health() => _get('/api/health');

  /// `ws://<host>:<port>/ws/live`
  Uri liveSocketUri() {
    final u = Uri.parse(baseUrl);
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws', path: '/ws/live');
  }

  /// One WebSocket session. Every message: {"type": "telemetry"|"alert"|"status"|"meter", "data": {...}}.
  /// The stream ends (or errors) when the socket drops; [reconnectingLive] wraps this with backoff.
  /// Cancelling the subscription closes the socket.
  Stream<Map<String, dynamic>> liveMessages() {
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? sub;
    late final StreamController<Map<String, dynamic>> out;
    out = StreamController<Map<String, dynamic>>(
      onListen: () {
        final ch = WebSocketChannel.connect(liveSocketUri());
        channel = ch;
        ch.ready.ignore(); // connection errors also arrive on the stream; don't leak an unhandled error
        sub = ch.stream.listen(
          (raw) {
            try {
              out.add(jsonDecode(raw as String) as Map<String, dynamic>);
            } catch (_) {
              // ignore malformed frames instead of killing the session
            }
          },
          onError: out.addError,
          onDone: out.close,
          cancelOnError: true,
        );
      },
      onCancel: () async {
        await sub?.cancel();
        await channel?.sink.close();
      },
    );
    return out.stream;
  }

  void close() => _http.close();

  Future<Map<String, dynamic>> _get(String path) => _send('GET', path);

  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, dynamic>? body, Duration timeout = _timeout}) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _http.send(req).timeout(timeout));
    final text = utf8.decode(res.bodyBytes); // ₱ and Taglish text: always decode as UTF-8
    if (res.statusCode >= 400) throw ApiException(res.statusCode, text);
    return jsonDecode(text) as Map<String, dynamic>;
  }
}
