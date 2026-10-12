// Проверка клиента против поднятого окружения (make up), как в make e2e, но кодом клиента:
//   flutter test test/live_backend_test.dart --dart-define=LIVE_VIDEO=../tools/sample.mp4
// Без LIVE_VIDEO тест пропускается.
import 'dart:async';
import 'dart:io';

import 'package:cutsheet_client/src/api.dart';
import 'package:cutsheet_client/src/hub.dart';
import 'package:cutsheet_client/src/models.dart';
import 'package:cutsheet_client/src/uploader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'api_test.dart' show MemoryTokens;

const video = String.fromEnvironment('LIVE_VIDEO');

void main() {
  test('вход → проект → загрузка → статус по SignalR → планы', () async {
    final api = Api(tokens: MemoryTokens());
    await api.register('client-${DateTime.now().microsecondsSinceEpoch}@example.com', 'client-password');
    final project = await api.createProject('client smoke');

    final done = Completer<void>();
    final statuses = <String>[];
    final hub = ProjectHub(api, project.id, (StatusUpdate s) {
      statuses.add('${s.stage}/${s.status}');
      if (s.stage == 'scenes' && s.status == 'done' && !done.isCompleted) done.complete();
      if (s.status == 'failed' && !done.isCompleted) done.completeError(s.error ?? 'failed');
    });
    await hub.connect();

    final uploader = Uploader(api, project.id, File(video));
    final progress = <double>[];
    uploader.progress.listen(progress.add);
    await uploader.start();
    expect(progress.last, 1);

    await done.future.timeout(const Duration(minutes: 3));
    await hub.close();
    expect(statuses, containsAllInOrder(['scenes/running', 'scenes/done']));

    final sheet = await api.scenes(project.id);
    expect(sheet.scenes, isNotEmpty);
    expect(sheet.scenes.first.keyframeUrls, isNotEmpty);
    expect((await api.project(project.id)).status, 'done');
  }, skip: video.isEmpty ? 'нужен --dart-define=LIVE_VIDEO=<путь к видео> и make up' : false);
}
