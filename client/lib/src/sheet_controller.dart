import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

/// Состояние редактора листа: загрузка, автосохранение правок (FR-C11) и конфликты версий (FR-G5).
///
/// Правки уходят на сервер по одной в порядке ввода: каждая берёт row_version из последнего
/// ответа, поэтому быстрые правки одной строки не конфликтуют друг с другом. 409 означает, что
/// строку изменили извне (повторная обработка, другое окно): строка заменяется актуальной,
/// пользователь получает уведомление и может повторить правку.
class SheetController extends ChangeNotifier {
  SheetController(this.api, this.projectId, {this.onNotice, this.onConflict});

  final Api api;
  final String projectId;
  final void Function(String message)? onNotice;

  /// Конфликт правки ячеек (409): строка уже заменена актуальной, [changes] — несохранённая правка
  /// пользователя. Если не задан, пользователь получает уведомление через [onNotice].
  final void Function(Scene current, Map<String, Object?> changes)? onConflict;

  SceneSheet? sheet;
  String? error;
  int _pending = 0;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  bool get saving => _pending > 0;
  bool get readOnly => !(sheet?.reviewRequired ?? true);

  Scene? scene(String id) => sheet?.scenes.where((s) => s.id == id).firstOrNull;

  Future<void> load() async {
    try {
      sheet = await api.scenes(projectId);
      error = null;
    } on ApiException catch (e) {
      error = e.message;
    }
    _notify();
  }

  /// Правка ячеек строки; поля — как в PATCH (`description`, `shot_type`, `start_ms`, `end_ms`, `reset`).
  Future<bool> patch(String sceneId, Map<String, Object?> changes) =>
      _run(sceneId, (s) async => _merge(await api.patchScene(projectId, s, changes)), changes: changes);

  Future<bool> reset(String sceneId, String field) => patch(sceneId, {
        'reset': [field],
      });

  Future<bool> putReplicas(String sceneId, List<Map<String, Object?>> replicas) =>
      _run(sceneId, (s) async => _merge(await api.putReplicas(projectId, s, replicas)));

  /// Перенос реплики в соседнюю строку (FR-C5): в начало следующей или в конец предыдущей.
  Future<bool> moveReplica(String fromSceneId, String replicaId, int delta) => _run(fromSceneId, (from) async {
        final target = sheet!.scenes.where((s) => s.index == from.index + delta).firstOrNull;
        if (target == null) return;
        final moved = from.replicas.firstWhere((r) => r.id == replicaId);
        final items = target.replicas.map((r) => r.toJson()).toList();
        delta > 0 ? items.insert(0, moved.toJson()) : items.add(moved.toJson());
        _merge(await api.putReplicas(projectId, target, items));
      });

  Future<bool> split(String sceneId, int atMs) =>
      _run(sceneId, (s) async => sheet = await api.splitScene(projectId, s, atMs));

  Future<bool> mergeWithNext(String sceneId) => _run(sceneId, (s) async {
        final next = sheet!.scenes.where((x) => x.index == s.index + 1).firstOrNull;
        if (next != null) sheet = await api.mergeScene(projectId, s, next);
      });

  Future<bool> delete(String sceneId) => _run(sceneId, (s) async => sheet = await api.deleteScene(projectId, s));

  Future<bool> add(int startMs, int endMs) => _enqueue(() async => sheet = await api.addScene(projectId, startMs, endMs));

  Future<bool> setReviewRequired(bool value) => _enqueue(() async {
        await api.setReviewRequired(projectId, value);
        sheet = await api.scenes(projectId);
      });

  void _merge(List<Scene> changed) => sheet = sheet!.withScenes(changed);

  /// Операция над строкой: строка берётся из листа в момент выполнения (свежий row_version).
  Future<bool> _run(String sceneId, Future<void> Function(Scene s) op, {Map<String, Object?>? changes}) =>
      _enqueue(() async {
        final s = scene(sceneId);
        if (s == null) throw ApiException(404, 'Строка уже удалена');
        await op(s);
      }, changes: changes);

  Future<bool> _enqueue(Future<void> Function() op, {Map<String, Object?>? changes}) {
    _pending++;
    _notify();
    final done = _queue.then((_) async {
      try {
        await op();
        return true;
      } on ConflictException catch (e) {
        final current = e.current;
        if (current != null && sheet != null) {
          _merge([current]);
          if (onConflict != null && changes != null && !changes.containsKey('reset')) {
            onConflict!(current, changes);
            return false;
          }
          onNotice?.call('Строку ${current.index + 1} уже изменили: показаны актуальные данные, повторите правку');
        } else {
          await load();
          onNotice?.call(e.message);
        }
        return false;
      } on ApiException catch (e) {
        onNotice?.call(e.message);
        return false;
      } finally {
        _pending--;
        _notify();
      }
    });
    _queue = done.then((_) {});
    return done;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
