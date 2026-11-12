// Where the app finds the Sinag server, saved on the device.
//
// Defaults, in order:
//   1. --dart-define=SINAG_SERVER=http://192.168.43.100:8000
//   2. Web: the host that served the page, port 8000 (server laptop serves or runs `flutter run -d chrome`)
//   3. Android emulator: http://10.0.2.2:8000 (the dev machine). A real phone types the laptop IP in Settings.
// Mock mode (no server, answers from assets/mock/): --dart-define=SINAG_MOCK=true or the Settings toggle.
import 'package:flutter/foundation.dart';

class ServerConfig {
  const ServerConfig({required this.baseUrl, required this.useMock});

  final String baseUrl;
  final bool useMock;

  static const _defineUrl = String.fromEnvironment('SINAG_SERVER');
  static const _defineMock = bool.fromEnvironment('SINAG_MOCK');

  static ServerConfig get defaults => ServerConfig(baseUrl: defaultBaseUrl(), useMock: _defineMock);

  static String defaultBaseUrl() {
    if (_defineUrl.isNotEmpty) return normalizeUrl(_defineUrl)!;
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
