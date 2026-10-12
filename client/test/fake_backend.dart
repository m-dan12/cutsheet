import 'dart:convert';
import 'dart:io';

import 'package:cutsheet_client/src/api.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'api_test.dart' show MemoryTokens, tokens;

/// Бэкенд в памяти для виджет-тестов экранов: проекты, лист с правками и сомнениями, экспорты.
class FakeBackend {
  FakeBackend({this.stage = 'review', this.status = 'ready_for_review'});

  String stage;
  String status;
  final List<String> seen = [];

  Map<String, Object?> project(String id, String name, String stage, String status, {String? error}) => {
    'id': id,
    'name': name,
    'stage': stage,
    'status': status,
    'error': error,
    'video_uri': 's3://cutsheet/projects/$id/video/v.mp4',
    'fps': 25.0,
    'duration_ms': 768000,
    'created_at': DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String(),
    'review_required': true,
  };

  List<Map<String, Object?>> get projects => [
    project('p1', 'Перрон, черновой монтаж', stage, status),
    project('p2', 'Сосед', 'dialogue', 'running'),
    project('p3', 'Тестовый ролик', 'dialogue', 'failed', error: 'Сценарий не прочитан'),
  ];

  static Map<String, Object?> replica(
    String id,
    String? role,
    String text, {
    bool matched = true,
    List<String> edited = const [],
  }) => {
    'id': id,
    'index': 0,
    'start_ms': 0,
    'end_ms': 1000,
    'role': role,
    'text': text,
    'spoken_text': text,
    'confidence': matched ? 0.92 : 0.4,
    'matched': matched,
    'origin': 'auto',
    'edited': edited,
  };

  static Map<String, Object?> scene(
    int i,
    int start,
    int end,
    String shot,
    String desc, {
    double shotConf = 0.95,
    double descConf = 0.9,
    List<String> edited = const [],
    List<Map<String, Object?>> replicas = const [],
  }) => {
    'id': 's$i',
    'index': i,
    'start_ms': start,
    'end_ms': end,
    'shot_type': shot,
    'description': desc,
    'status': 'enriched',
    'row_version': 1,
    'keyframe_urls': <String>[],
    'origin': 'auto',
    'needs_enrichment': false,
    'edited': edited,
    'auto': {
      'shot_type': {
        'value': edited.contains('shot_type') ? 'close' : shot,
        'confidence': shotConf,
        'source': 'shot_type',
      },
      'description': {
        'value': edited.contains('description') ? 'Мирон выходит из тумана.' : desc,
        'confidence': descConf,
        'source': 'description',
      },
    },
    'replicas': replicas,
  };

  Map<String, Object?> get sheet => {
    'project_id': 'p1',
    'fps': 25.0,
    'duration_ms': 49080,
    'video_url': null,
    'review_required': true,
    'structure_edited': false,
    'shot_types': ['wide', 'medium', 'close', 'detail', 'unknown'],
    'roles': ['АННА', 'МИРОН'],
    'scenes': [
      scene(0, 0, 4480, 'wide', 'Пустой перрон пригородной станции на рассвете. Туман.'),
      scene(1, 4480, 9120, 'medium', 'Анна идёт вдоль края платформы с чемоданом.'),
      scene(
        2,
        9120,
        12800,
        'close',
        'Лицо Анны. Она смотрит на часы.',
        replicas: [replica('r1', 'АННА', 'Опять опаздывает.')],
      ),
      scene(3, 12800, 15320, 'detail', 'Стрелки вокзальных часов, без восемнадцати семь.', shotConf: 0.42),
      scene(
        4,
        15320,
        21640,
        'medium',
        'Из тумана появляется Мирон, машет Анне рукой.',
        edited: ['description'],
        replicas: [replica('r2', 'МИРОН', 'Аня! Подожди!'), replica('r3', 'АННА', 'Я думала, ты не придёшь.')],
      ),
      scene(
        5,
        21640,
        27000,
        'wide',
        'Двое на перроне, вдали огни поезда.',
        shotConf: 0.45,
        descConf: 0.41,
        replicas: [replica('r4', null, '…билеты у тебя?', matched: false), replica('r5', 'АННА', 'В кармане.')],
      ),
      scene(
        6,
        27000,
        31440,
        'close',
        'Мирон протягивает конверт.',
        replicas: [replica('r6', 'МИРОН', 'Здесь всё, что ты просила.')],
      ),
      scene(7, 31440, 36160, 'detail', 'Конверт в руках Анны, на нём надпись «Не открывать».', edited: ['shot_type']),
    ],
  };

  List<Map<String, Object?>> get exports => [
    {
      'id': 'e1',
      'format': 'xlsx',
      'status': 'completed',
      'error': null,
      'download_url': 'http://minio/x',
      'filename': 'Перрон - монтажный лист.xlsx',
      'created_at': '2026-10-12T15:57:00Z',
    },
    {
      'id': 'e2',
      'format': 'pdf',
      'status': 'requested',
      'error': null,
      'download_url': null,
      'filename': 'Перрон - монтажный лист.pdf',
      'created_at': '2026-10-12T15:58:00Z',
    },
  ];

  http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<Api> api() async {
    final client = MockClient((req) async {
      final path = req.url.path.replaceFirst('/api/v1', '');
      seen.add('${req.method} $path');
      if (path == '/auth/login') return http.Response(jsonEncode(tokens('a', 'r')), 200);
      if (path == '/projects') return _json(projects);
      if (path == '/projects/p1') return _json(projects.first);
      if (path == '/projects/p1/scenes') return _json(sheet);
      if (path == '/projects/p1/exports') return _json(exports);
      return http.Response('', 404);
    });
    final api = Api(client: client, tokens: MemoryTokens(), base: 'http://kong');
    await api.login('anna.sokolova@studio.ru', 'password1');
    return api;
  }
}

/// Шрифты дизайна из fonts/: в тестах текст меряется как в приложении, а не тестовым шрифтом.
Future<void> loadDesignFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.view(File('fonts/$f').readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await family('Lora', ['Lora-SemiBold.ttf']);
  await family('Carlito', ['Carlito-Regular.ttf', 'Carlito-Bold.ttf']);
  await family('IBM Plex Mono', ['IBMPlexMono-Regular.ttf', 'IBMPlexMono-Medium.ttf']);
}
