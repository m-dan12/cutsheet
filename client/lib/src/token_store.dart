import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Токены в защищённом хранилище ОС (FR-C13): Windows Credential Manager, Keychain, libsecret.
class TokenStore {
  TokenStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _refreshKey = 'cutsheet.refresh_token';
  static const _emailKey = 'cutsheet.email';

  Future<String?> readRefreshToken() => _safe(() => _storage.read(key: _refreshKey));
  Future<String?> readEmail() => _safe(() => _storage.read(key: _emailKey));

  Future<void> save({required String refreshToken, required String email}) async {
    await _safe(() => _storage.write(key: _refreshKey, value: refreshToken));
    await _safe(() => _storage.write(key: _emailKey, value: email));
  }

  Future<void> clear() => _safe(() => _storage.delete(key: _refreshKey));

  // Без хранилища (например, нет libsecret на Linux) клиент работает, но вход не запоминается.
  static Future<T?> _safe<T>(Future<T?> Function() op) async {
    try {
      return await op();
    } catch (_) {
      return null;
    }
  }
}
