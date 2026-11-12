// Where the app finds the Solaris server, saved on the device.
//
// Defaults, in order:
//   1. --dart-define=SOLARIS_SERVER=http://192.168.43.100:8000
//   2. Web built with --dart-define=SOLARIS_SAME_ORIGIN=true (the copy the server hosts at /app/): the page's own origin
//   3. Web: the host that served the page, port 8000 (`flutter run -d chrome` on the dev machine)
//   4. Android emulator: http://10.0.2.2:8000 (the dev machine). A real phone types the laptop IP in Settings.
// Mock data is the default; AI chat still connects to the laptop server.
import 'package:flutter/foundation.dart';

class ServerConfig {
  const ServerConfig({required this.baseUrl, required this.useMock});

  final String baseUrl;
  final bool useMock;

  static const _defineUrl = String.fromEnvironment('SOLARIS_SERVER');
  static const _defineMock = bool.fromEnvironment('SOLARIS_MOCK', defaultValue: true);
  static const _sameOrigin = bool.fromEnvironment('SOLARIS_SAME_ORIGIN');

  static ServerConfig get defaults => ServerConfig(baseUrl: defaultBaseUrl(), useMock: _defineMock);

  static String defaultBaseUrl() {
    if (_defineUrl.isNotEmpty) return normalizeUrl(_defineUrl)!;
    if (kIsWeb && _sameOrigin && Uri.base.hasAuthority) return Uri.base.origin;
    if (kIsWeb) {
      final host = Uri.base.host.isEmpty ? 'localhost' : Uri.base.host;
      return 'http://$host:8000';
    }
    return 'http://10.0.2.2:8000';
  }

  /// Accepts what people actually type: "192.168.43.100", "192.168.43.100:8000",
  /// "http://192.168.43.100:8000/". Returns null when it can't be a server URL.
  static String? normalizeUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty || !(u.scheme == 'http' || u.scheme == 'https')) return null;
    final port = u.hasPort ? u.port : 8000;
    return Uri(scheme: u.scheme, host: u.host, port: port).toString();
  }

  ServerConfig copyWith({String? baseUrl, bool? useMock}) =>
      ServerConfig(baseUrl: baseUrl ?? this.baseUrl, useMock: useMock ?? this.useMock);

  @override
  bool operator ==(Object other) =>
      other is ServerConfig && other.baseUrl == baseUrl && other.useMock == useMock;

  @override
  int get hashCode => Object.hash(baseUrl, useMock);
}
