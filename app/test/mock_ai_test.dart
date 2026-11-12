import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:solaris/core/config/server_config.dart';
import 'package:solaris/services/api_service.dart';
import 'package:solaris/services/mock_api_service.dart';

void main() {
  test('mock is the default', () {
    expect(ServerConfig.defaults.useMock, isTrue);
  });

  test('mock chat and summary use laptop API and saved household settings', () async {
    final paths = <String>[];
    final remote = ApiService(baseUrl: 'http://laptop:8000', client: MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/api/settings') {
        expect(jsonDecode(request.body), {'user_name': 'Ana', 'setup': 'meter_only'});
        return http.Response('{}', 200);
      }
      if (request.url.path == '/api/chat') {
        expect(jsonDecode(request.body), {'message': 'Bakit mataas ang bill ko?'});
        return http.Response('{"source":"llm","reply":"From the laptop"}', 200);
      }
      return http.Response('{"text":"Seeded recap"}', 200);
    }));
    final mock = MockApiService(ai: remote, saved: {'user_name': 'Ana', 'setup': 'meter_only'},
        loader: (_) async => throw StateError('AI must not read canned assets'));
    expect((await mock.chat('Bakit mataas ang bill ko?'))['source'], 'llm');
    expect((await mock.getDailySummary())['text'], 'Seeded recap');
    expect(paths, ['/api/settings', '/api/chat', '/api/settings', '/api/summary/daily']);
    mock.close();
  });
}
