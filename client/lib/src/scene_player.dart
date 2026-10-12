import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Встроенный плеер (FR-C7) на media_kit (libmpv): видео играет прямо по presigned URL из S3,
/// перемотка — HTTP range-запросами. Умеет проиграть одну сцену и остановиться на её конце.
class ScenePlayer {
  ScenePlayer() {
    _sub = player.stream.position.listen(_onPosition);
  }

  final Player player = Player();
  late final VideoController video = VideoController(player);
  late final StreamSubscription<Duration> _sub;
  String? _url;
  int? _stopAtMs;

  Stream<Duration> get position => player.stream.position;
  Stream<bool> get playing => player.stream.playing;
  int get positionMs => player.state.position.inMilliseconds;

  /// Открывает видео, если URL сменился (presigned URL живёт не дольше часа и обновляется с листом).
  Future<void> open(String url) async {
    if (url == _url) return;
    final at = player.state.position;
    _url = url;
    await player.open(Media(url), play: false);
    if (at > Duration.zero) await player.seek(at);
  }

  Future<void> seek(int ms) async {
    _stopAtMs = null;
    await player.seek(Duration(milliseconds: ms));
  }

  /// Воспроизведение выбранной сцены: с начала до конца строки.
  Future<void> playRange(int startMs, int endMs) async {
    await player.seek(Duration(milliseconds: startMs));
    _stopAtMs = endMs;
    await player.play();
  }

  Future<void> toggle() async {
    _stopAtMs = null;
    await player.playOrPause();
  }

  void _onPosition(Duration d) {
    final stop = _stopAtMs;
    if (stop != null && d.inMilliseconds >= stop) {
      _stopAtMs = null;
      player.pause();
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    await player.dispose();
  }
}
