/// Адрес Kong. Переопределяется при запуске:
/// `flutter run -d windows --dart-define=API_BASE=http://192.168.1.10:8000`
const apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://localhost:8000');
