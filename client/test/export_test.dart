import 'dart:convert';

import 'package:cutsheet_client/src/api.dart';
import 'package:cutsheet_client/src/export_controller.dart';
import 'package:cutsheet_client/src/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'api_test.dart' show MemoryTokens, tokens;

const pid = 'p1';

Map<String, Object?> job(String id, String status, {String format = 'pdf', String? url, String? error}) => {
      'id': id,
      'format': format,
      'status': status,
      'error': error,
      'download_url': url,
      'filename': 'Фильм - монтажный лист.$format',
      'created_at': '2026-10-12T10:00:00Z',
      'completed_at': null,
    };

/// Сервер экспорта в памяти: [states] — что вернёт GET по id.
http.Response json(Object? body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

Future<(Api, List<String>)> fakeApi(Map<String, Map<String, Object?>> states, {List<int>? file}) async {
  final seen = <String>[];
  final client = MockClient((req) async {
    seen.add('${req.method} ${req.url.path}');
    final path = req.url.path;
    if (path == '/api/v1/auth/login') return http.Response(jsonEncode(tokens('a', 'r')), 200);
    if (path == '/api/v1/projects/$pid/exports' && req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (body['format'] == 'odt') return json({'errors': {'format': ['xlsx, docx или pdf']}}, 400);
      states['e-new'] = job('e-new', 'requested', format: body['format'] as String);
      return json(states['e-new'], 202);
    }
    if (path == '/api/v1/projects/$pid/exports') {
      return json(states.values.toList(), 200);
    }
    if (path.startsWith('/api/v1/projects/$pid/exports/')) {
      final s = states[path.split('/').last];
      return s == null ? http.Response('', 404) : json(s, 200);
    }
    if (req.url.host == 'minio') return http.Response.bytes(file ?? [1, 2, 3], 200);
    return http.Response('', 404);
  });
  final api = Api(client: client, tokens: MemoryTokens(), base: 'http://kong');
  await api.login('a@b.c', 'pw');
  return (api, seen);
}

void main() {
  test('ExportJob и ExportUpdate из JSON', () {
    final j = ExportJob.fromJson(job('e1', 'completed', url: 'http://minio/x'));
    expect((j.format, j.pending, j.downloadUrl, j.filename), ('pdf', false, 'http://minio/x', 'Фильм - монтажный лист.pdf'));
    final u = ExportUpdate.fromJson({'project_id': pid, 'export_id': 'e1', 'format': 'pdf', 'status': 'failed', 'error': 'x'});
    expect((u.exportId, u.status, u.error), ('e1', 'failed', 'x'));
  });

  test('запрос экспорта, готовность из хаба и сохранение файла', () async {
    final states = <String, Map<String, Object?>>{};
    final (api, seen) = await fakeApi(states, file: utf8.encode('%PDF-1.4'));
    final notices = <String>[];
    final c = ExportController(api, pid, onNotice: notices.add, pollEvery: const Duration(hours: 1));

    await c.request('pdf');
    expect(c.jobs.single.pending, isTrue);
    expect(c.busy, isTrue);

    states['e-new'] = job('e-new', 'completed', url: 'http://minio/sheet.pdf');
    await c.onUpdate(ExportUpdate(exportId: 'e-new', format: 'pdf', status: 'completed'));
    expect(c.jobs.single.status, 'completed');
    expect(c.busy, isFalse);

    expect(utf8.decode((await c.fetch(c.jobs.single))!), '%PDF-1.4');
    expect(seen, containsAllInOrder(['GET /api/v1/projects/$pid/exports/e-new', 'GET /sheet.pdf']));
    expect(notices, isEmpty);
    c.dispose();
  });

  test('ошибка экспорта и неверный формат попадают в уведомления', () async {
    final states = {'e1': job('e1', 'failed', error: 'template not found: nope')};
    final (api, _) = await fakeApi(states);
    final notices = <String>[];
    final c = ExportController(api, pid, onNotice: notices.add);
    await c.load();
    expect(c.jobs.single.error, 'template not found: nope');

    await c.onUpdate(ExportUpdate(exportId: 'e1', format: 'pdf', status: 'failed', error: 'template not found: nope'));
    await c.request('odt');
    expect(notices, ['Экспорт pdf не удался: template not found: nope', 'xlsx, docx или pdf']);
    c.dispose();
  });

  test('без хаба незавершённый экспорт опрашивается', () async {
    final states = <String, Map<String, Object?>>{};
    final (api, _) = await fakeApi(states);
    final c = ExportController(api, pid, pollEvery: const Duration(milliseconds: 20));
    await c.request('xlsx');
    states['e-new'] = job('e-new', 'completed', format: 'xlsx', url: 'http://minio/sheet.xlsx');
    for (var i = 0; i < 50 && c.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(c.jobs.single.status, 'completed');
    c.dispose();
  });
}
