import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';
import 'token_store.dart';

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => message;
}

/// Клиент Kong (`/api/v1`). Хранит сессию: access-токен в памяти, refresh — в [TokenStore];
/// при 401 один раз обновляет токен и повторяет запрос (FR-C13).
class Api extends ChangeNotifier {
  Api({http.Client? client, TokenStore? tokens, String? base})
      : _http = client ?? http.Client(),
        _tokens = tokens ?? TokenStore(),
        _base = base ?? apiBase;

  final http.Client _http;
  final TokenStore _tokens;
  final String _base;

  String? _accessToken;
  String? email;

  bool get signedIn => _accessToken != null;
  String get base => _base;

  /// Токен для SignalR; обновляется, если сессия ещё жива.
  Future<String> accessToken() async {
    if (_accessToken == null && !await _refresh()) throw ApiException(401, 'Сессия истекла, войдите снова');
    return _accessToken!;
  }

  /// Вход по сохранённому refresh-токену при старте приложения.
  Future<bool> restore() async {
    email = await _tokens.readEmail();
    final ok = await _refresh();
    notifyListeners();
    return ok;
  }

  Future<void> login(String email, String password) => _signIn('login', email, password);
  Future<void> register(String email, String password) => _signIn('register', email, password);

  Future<void> logout() async {
    _accessToken = null;
    await _tokens.clear();
    notifyListeners();
  }

  Future<List<Project>> projects() async {
    final list = await _json('GET', '/projects') as List;
    return list.map((p) => Project.fromJson(p as Map<String, dynamic>)).toList();
  }

  Future<Project> project(String id) async =>
      Project.fromJson(await _json('GET', '/projects/$id') as Map<String, dynamic>);

  Future<Project> createProject(String name) async =>
      Project.fromJson(await _json('POST', '/projects', {'name': name}) as Map<String, dynamic>);

  Future<SceneSheet> scenes(String projectId) async =>
      SceneSheet.fromJson(await _json('GET', '/projects/$projectId/scenes') as Map<String, dynamic>);

  Future<UploadState> startUpload(String projectId,
          {required String kind, required String filename, required int sizeBytes, String? contentType}) async =>
      UploadState.fromJson(await _json('POST', '/projects/$projectId/uploads', {
        'kind': kind,
        'filename': filename,
        'size_bytes': sizeBytes,
        'content_type': ?contentType,
      }) as Map<String, dynamic>);

  Future<UploadState> uploadState(String projectId, String uploadId) async =>
      UploadState.fromJson(await _json('GET', '/projects/$projectId/uploads/$uploadId') as Map<String, dynamic>);

  Future<Project> completeUpload(String projectId, String uploadId) async => Project.fromJson(
      await _json('POST', '/projects/$projectId/uploads/$uploadId/complete') as Map<String, dynamic>);

  Future<void> _signIn(String action, String email, String password) async {
    final resp = await _http.post(Uri.parse('$_base/api/v1/auth/$action'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': email, 'password': password}));
    _accept(_decode(resp) as Map<String, dynamic>);
    notifyListeners();
  }

  Future<bool> _refresh() async {
    final refresh = await _tokens.readRefreshToken();
    if (refresh == null) return false;
    try {
      final resp = await _http.post(Uri.parse('$_base/api/v1/auth/refresh'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'refresh_token': refresh}));
      _accept(_decode(resp) as Map<String, dynamic>);
      return true;
    } on ApiException {
      _accessToken = null;
      await _tokens.clear();
      return false;
    }
  }

  void _accept(Map<String, dynamic> tokens) {
    _accessToken = tokens['access_token'] as String;
    email = (tokens['user'] as Map<String, dynamic>)['email'] as String;
    _tokens.save(refreshToken: tokens['refresh_token'] as String, email: email!);
  }

  Future<Object?> _json(String method, String path, [Object? body]) async {
    var resp = await _send(method, path, body);
    if (resp.statusCode == 401 && await _refresh()) resp = await _send(method, path, body);
    if (resp.statusCode == 401) {
      _accessToken = null;
      notifyListeners();
    }
    return _decode(resp);
  }

  Future<http.Response> _send(String method, String path, Object? body) {
    final req = http.Request(method, Uri.parse('$_base/api/v1$path'));
    if (_accessToken != null) req.headers['Authorization'] = 'Bearer $_accessToken';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    return _http.send(req).then(http.Response.fromStream);
  }

  static Object? _decode(http.Response resp) {
    final text = utf8.decode(resp.bodyBytes);
    final data = text.isEmpty ? null : jsonDecode(text);
    if (resp.statusCode >= 200 && resp.statusCode < 300) return data;
    throw ApiException(resp.statusCode, _problem(resp.statusCode, data));
  }

  /// Текст ошибки из ProblemDetails ASP.NET Core или ответа Kong.
  static String _problem(int status, Object? data) {
    if (data is Map<String, dynamic>) {
      final errors = data['errors'];
      if (errors is Map && errors.isNotEmpty) {
        return errors.values.expand((v) => v is List ? v : [v]).join('; ');
      }
      final text = data['detail'] ?? data['title'] ?? data['message'];
      if (text != null) return '$text';
    }
    return 'Ошибка сервера: HTTP $status';
  }
}
