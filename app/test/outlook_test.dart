// GET /api/outlook (added to Contract C after the spec tests were written): same checks as test/spec.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:solaris/services/api_service.dart';
import 'package:solaris/services/mock_api_service.dart';

import 'spec/contract_schema.dart';

void main() {
  test('outlook.json example matches the contract', () {
    expect(contractErrors('outlook', example('outlook')), isEmpty);
  });

  test('ApiService.getOutlook -> GET /api/outlook, contract-shaped, UTF-8', () async {
    late http.Request seen;
    final api = ApiService(
      baseUrl: 'http://192.168.43.100:8000',
      client: MockClient((req) async {
        seen = req;
        return http.Response.bytes(utf8.encode(jsonEncode(example('outlook'))), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    final o = await api.getOutlook();
    expect(seen.method, 'GET');
    expect(seen.url.toString(), 'http://192.168.43.100:8000/api/outlook');
    expect(contractErrors('outlook', o), isEmpty);
    expect((o['hours'] as List).length, 48);
  });

  test('MockApiService.getOutlook serves the example', () async {
    final mock = MockApiService(loader: (name) async => jsonEncode(example(name)));
    expect(contractErrors('outlook', await mock.getOutlook()), isEmpty);
  });
}
