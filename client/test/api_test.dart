import 'dart:convert';

import 'package:cutsheet_client/src/api.dart';
import 'package:cutsheet_client/src/token_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MemoryTokens implements TokenStore {
  String? refresh;
  String? email;

  @override
  Future<String?> readRefreshToken() async => refresh;
  @override
  Future<String?> readEmail() async => email;
  @override
  Future<void> save({required String refreshToken, required String email}) async {
    refresh = refreshToken;
    this.email = email;
  }

  @override
  Future<void> clear() async => refresh = null;
}

Map<String, Object> tokens(String access, String refresh) => {
      'access_token': access,
      'refresh_token': refresh,
      'expires_in': 900,
      'token_type': 'Bearer',
      'user': {'id': '1', 'email': 'a@b.c', 'role': 'user'},
    };

void main() {
  test('при 401 обновляет токен и повторяет запрос', () async {
    final seen = <String>[];
    final client = MockClient((req) async {
      seen.add('${req.method} ${req.url.path} ${req.headers['Authorization'] ?? ''}'.trim());
      switch (req.url.path) {
        case '/api/v1/auth/login':
          return http.Response(jsonEncode(tokens('old', 'r1')), 200);
        case '/api/v1/auth/refresh':
          expect(jsonDecode(req.body)['refresh_token'], 'r1');
          return http.Response(jsonEncode(tokens('new', 'r2')), 200);
        case '/api/v1/projects':
          return req.headers['Authorization'] == 'Bearer new'
              ? http.Response('[]', 200)
              : http.Response('{"message":"token expired"}', 401);
      }
      return http.Response('', 404);
    });
    final store = MemoryTokens();
    final api = Api(client: client, tokens: store, base: 'http://kong');

    await api.login('a@b.c', 'password1');
    expect(await api.projects(), isEmpty);
    expect(store.refresh, 'r2');
    expect(seen, [
      'POST /api/v1/auth/login',
      'GET /api/v1/projects Bearer old',
      'POST /api/v1/auth/refresh',
      'GET /api/v1/projects Bearer new',
    ]);
  });

  test('текст ошибки берётся из ProblemDetails', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({'title': 'One or more validation errors occurred.', 'errors': {'password': ['пароль не короче 8 символов']}}),
        400,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    final api = Api(client: client, tokens: MemoryTokens(), base: 'http://kong');
    expect(() => api.register('a@b.c', '1'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'пароль не короче 8 символов')));
  });
}
