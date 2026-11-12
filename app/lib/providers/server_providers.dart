// Server connection state: saved config → one ApiService (real or mock) for the whole app.
// Changing the URL or the mock toggle rebuilds the ApiService, and everything that watches it
// (live socket, alerts, bill, ...) reconnects / refetches on its own.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/server_config.dart';
import '../services/api_service.dart';
import '../services/mock_api_service.dart';

/// Overridden in main() with the instance loaded before runApp.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('override sharedPreferencesProvider in main()'),
);

class ServerConfigNotifier extends Notifier<ServerConfig> {
  static const _kUrl = 'server_url';
  static const _kMock = 'use_mock';

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  ServerConfig build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final d = ServerConfig.defaults;
    return ServerConfig(
      baseUrl: prefs.getString(_kUrl) ?? d.baseUrl,
      useMock: prefs.getBool(_kMock) ?? d.useMock,
    );
  }

  /// Returns false (and changes nothing) if [input] isn't a usable server address.
  Future<bool> setBaseUrl(String input) async {
    final url = ServerConfig.normalizeUrl(input);
    if (url == null) return false;
    await _prefs.setString(_kUrl, url);
    state = state.copyWith(baseUrl: url);
    return true;
  }

  Future<void> setUseMock(bool value) async {
    await _prefs.setBool(_kMock, value);
    state = state.copyWith(useMock: value);
  }

  Future<void> reset() async {
    await _prefs.remove(_kUrl);
    await _prefs.remove(_kMock);
    state = ServerConfig.defaults;
  }
}

final serverConfigProvider =
    NotifierProvider<ServerConfigNotifier, ServerConfig>(ServerConfigNotifier.new);

final apiServiceProvider = Provider<ApiService>((ref) {
  final cfg = ref.watch(serverConfigProvider);
  final api = cfg.useMock ? MockApiService() : ApiService(baseUrl: cfg.baseUrl);
  ref.onDispose(api.close);
  return api;
});
