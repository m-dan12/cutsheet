/// Таймкод `ЧЧ:ММ:СС:КК` без drop-frame (ТЗ, FR-E3): кадры считаются по fps видео.
String timecode(int ms, double? fps) {
  final rate = (fps == null || fps <= 0) ? 25.0 : fps;
  final totalSeconds = ms ~/ 1000;
  final frames = ((ms % 1000) * rate / 1000).floor();
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(h)}:${two(m)}:${two(s)}:${two(frames)}';
}

/// Длительность в секундах с одной цифрой после запятой: «2,5 с».
String seconds(int ms) => '${(ms / 1000).toStringAsFixed(1).replaceAll('.', ',')} с';

/// Разбор `ЧЧ:ММ:СС:КК` (или `ММ:СС:КК`, `СС:КК`) обратно в миллисекунды; null — не таймкод.
/// Кадр переводится в мс с округлением вверх, чтобы [timecode] вернул тот же кадр.
int? parseTimecode(String text, double? fps) {
  final rate = (fps == null || fps <= 0) ? 25.0 : fps;
  final parts = text.trim().split(RegExp(r'[:;.]'));
  if (parts.isEmpty || parts.length > 4 || parts.any((p) => int.tryParse(p) == null)) return null;
  final n = [...List.filled(4 - parts.length, 0), ...parts.map(int.parse)];
  final (h, m, s, f) = (n[0], n[1], n[2], n[3]);
  if (n.any((v) => v < 0) || m > 59 || s > 59 || f >= rate.ceil()) return null;
  return ((h * 3600 + m * 60 + s) * 1000) + (f * 1000 / rate).ceil();
}
