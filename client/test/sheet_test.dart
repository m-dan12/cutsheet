import 'dart:convert';

import 'package:cutsheet_client/src/api.dart';
import 'package:cutsheet_client/src/models.dart';
import 'package:cutsheet_client/src/screens/sheet_view.dart';
import 'package:cutsheet_client/src/sheet_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'api_test.dart' show MemoryTokens;

Map<String, Object?> sceneJson(String id, int index, int start, int end,
        {int version = 1, String? description, String? shot, List<String> edited = const [], Map<String, Object?> auto = const {}}) =>
    {
      'id': id,
      'index': index,
      'start_ms': start,
      'end_ms': end,
      'shot_type': shot,
      'description': description,
      'status': 'detected',
      'row_version': version,
      'keyframe_urls': <String>[],
      'origin': 'auto',
      'needs_enrichment': false,
      'edited': edited,
      'auto': auto,
      'replicas': [
        if (index == 0)
          {
            'id': 'r1', 'index': 0, 'start_ms': 100, 'end_ms': 900, 'role': 'ИВАН', 'text': 'Привет',
            'spoken_text': 'привет', 'confidence': 0.9, 'matched': true, 'origin': 'auto', 'edited': <String>[],
          },
      ],
    };

Map<String, Object?> sheetJson({bool review = true, List<Map<String, Object?>>? scenes}) => {
      'project_id': 'p',
      'fps': 25.0,
      'duration_ms': 5000,
      'video_url': null,
      'review_required': review,
      'structure_edited': false,
      'shot_types': ['wide', 'medium', 'close', 'detail', 'unknown'],
      'roles': ['ИВАН'],
      'scenes': scenes ?? [sceneJson('a', 0, 0, 2000), sceneJson('b', 1, 2000, 5000)],
    };

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Future<Api> signedIn(MockClient client) async {
  final api = Api(client: client, tokens: MemoryTokens(), base: 'http://kong');
  await api.login('a@b.c', 'password1');
  return api;
}

Future<http.Response?> login(http.Request req) async => req.url.path == '/api/v1/auth/login'
    ? json({'access_token': 't', 'refresh_token': 'r', 'user': {'email': 'a@b.c'}})
    : null;

void main() {
  test('правки одной строки уходят по очереди с актуальной row_version', () async {
    final versions = <int>[];
    var version = 1;
    final client = MockClient((req) async {
      final auth = await login(req);
      if (auth != null) return auth;
      if (req.method == 'GET') return json(sheetJson());
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      versions.add(body['row_version'] as int);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      version++;
      return json({
        'scenes': [sceneJson('a', 0, 0, 2000, version: version, description: body['description'] as String?)],
      });
    });
    final c = SheetController(await signedIn(client), 'p');
    await c.load();
    final first = c.patch('a', {'description': 'раз'});
    final second = c.patch('a', {'description': 'два'});
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(versions, [1, 2]);
    expect(c.scene('a')!.description, 'два');
    expect(c.saving, isFalse);
  });

  test('409 заменяет строку актуальной и сообщает пользователю', () async {
    final notices = <String>[];
    final client = MockClient((req) async {
      final auth = await login(req);
      if (auth != null) return auth;
      if (req.method == 'GET') return json(sheetJson());
      return json({
        'title': 'Строку уже изменили: версия устарела',
        'scene': sceneJson('b', 1, 2000, 5000, version: 7, description: 'с сервера'),
      }, 409);
    });
    final c = SheetController(await signedIn(client), 'p', onNotice: notices.add);
    await c.load();
    expect(await c.patch('b', {'description': 'моё'}), isFalse);
    expect(c.scene('b')!.rowVersion, 7);
    expect(c.scene('b')!.description, 'с сервера');
    expect(notices.single, contains('Строку 2 уже изменили'));
  });

  test('модель: отметки правок, расхождение с автоматикой, низкая уверенность', () {
    final s = Scene.fromJson(sceneJson('a', 0, 0, 2000, shot: 'close', description: 'моё', edited: ['description'], auto: {
      'description': {'value': 'авто', 'confidence': 0.9, 'source': 'description'},
      'shot_type': {'value': 'close', 'confidence': 0.3, 'source': 'shot_type'},
    }));
    expect(s.isEdited('description'), isTrue);
    expect(s.autoDiffers('description'), isTrue);
    expect(s.lowConfidence('shot_type'), isTrue);
    expect(s.lowConfidence('description'), isFalse);
    expect(s.replicas.single.line, 'ИВАН: Привет');
  });

  testWidgets('таблица показывает строки, реплики и метку правки; без правок — только чтение', (tester) async {
    var review = true;
    final client = MockClient((req) async {
      final auth = await login(req);
      if (auth != null) return auth;
      return json(sheetJson(review: review, scenes: [
        sceneJson('a', 0, 0, 2000, description: 'Улица', edited: ['description']),
        sceneJson('b', 1, 2000, 5000),
      ]));
    });
    final api = await tester.runAsync(() => signedIn(client));
    final c = SheetController(api!, 'p');
    await tester.runAsync(c.load);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SheetTable(controller: c))));

    expect(find.text('Улица'), findsOneWidget);
    expect(find.text('00:00:02:00'), findsNWidgets(2));
    expect(find.byType(EditedMark), findsOneWidget);
    expect(find.textContaining('Привет'), findsOneWidget);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Улица')).enabled, isTrue);

    review = false;
    await tester.runAsync(c.load);
    await tester.pump();
    expect(c.readOnly, isTrue);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Улица')).enabled, isFalse);
  });
}
