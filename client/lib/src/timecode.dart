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
