// Reference ApiService (Contract C). Copy to lib/services/api_service.dart, or keep yours and make
// test/spec/api_service_spec_test.dart pass. Every method returns the decoded JSON; wrap it in your
// own models if you like (give them a toJson() that returns the same shape, and the spec still works).
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
  Future<Map<String, dynamic>> getEnergy(String period) => _get('/api/energy?period=$period'); // day|week|month
  Future<Map<String, dynamic>> getBill() => _get('/api/bill');
  Future<Map<String, dynamic>> getBrownout() => _get('/api/brownout');
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

  /// Every message: {"type": "telemetry"|"alert"|"status"|"meter", "data": {...}}.
  /// Reconnect with a delay when the stream closes (the server may restart during the demo).
  Stream<Map<String, dynamic>> liveMessages() {
    final channel = WebSocketChannel.connect(liveSocketUri());
    return channel.stream.map((raw) => jsonDecode(raw as String) as Map<String, dynamic>);
  }

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
