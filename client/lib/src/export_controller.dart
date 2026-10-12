import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'models.dart';

/// Экспорт листа в xlsx / docx / pdf (этап 5, FR-C12).
///
/// Запрос уходит в Project API; готовность приходит сообщением хаба "export". Если хаб недоступен
/// (или сообщение потерялось), незавершённые экспорты опрашиваются раз в [pollEvery].
class ExportController extends ChangeNotifier {
  ExportController(this.api, this.projectId, {this.onNotice, this.pollEvery = const Duration(seconds: 5)});

  static const formats = {'xlsx': 'Excel (.xlsx)', 'docx': 'Word (.docx)', 'pdf': 'PDF'};

  final Api api;
  final String projectId;
  final void Function(String message)? onNotice;
  final Duration pollEvery;

  /// Последние экспорты, новые сверху.
  List<ExportJob> jobs = [];
  final Set<String> _saving = {};
  Timer? _poll;
  bool _disposed = false;

  bool get busy => jobs.any((j) => j.pending);
  bool isSaving(ExportJob job) => _saving.contains(job.id);

  Future<void> load() async {
    try {
      jobs = await api.exports(projectId);
      _schedule();
      _notify();
    } on ApiException catch (e) {
      onNotice?.call(e.message);
    }
  }

  Future<void> request(String format, {Map<String, Object?>? options}) async {
    try {
      _put(await api.requestExport(projectId, format, options: options));
    } on ApiException catch (e) {
      onNotice?.call(e.message);
    }
  }

  /// Сообщение хаба: перечитываем экспорт, чтобы получить свежую ссылку на файл.
  Future<void> onUpdate(ExportUpdate u) async {
    if (u.status == 'requested' && jobs.any((j) => j.id == u.exportId)) return;
    await _refresh(u.exportId);
    if (u.status == 'failed') onNotice?.call('Экспорт ${u.format} не удался: ${u.error ?? 'ошибка'}');
  }

  /// Содержимое готового файла для сохранения. Ссылка живёт час, поэтому перед скачиванием
  /// экспорт перечитывается и берётся свежая.
  Future<Uint8List?> fetch(ExportJob job) async {
    _saving.add(job.id);
    _notify();
    try {
      final fresh = await api.exportJob(projectId, job.id);
      _put(fresh);
      final url = fresh.downloadUrl ?? job.downloadUrl;
      if (url == null) throw ApiException(409, 'Файл ещё не готов');
      return await api.download(url);
    } on ApiException catch (e) {
      onNotice?.call(e.message);
      return null;
    } finally {
      _saving.remove(job.id);
      _notify();
    }
  }

  Future<void> _refresh(String exportId) async {
    try {
      _put(await api.exportJob(projectId, exportId));
    } on ApiException catch (e) {
      onNotice?.call(e.message);
    }
  }

  void _put(ExportJob job) {
    final i = jobs.indexWhere((j) => j.id == job.id);
    jobs = [...jobs];
    if (i >= 0) {
      jobs[i] = job;
    } else {
      jobs.insert(0, job);
    }
    _schedule();
    _notify();
  }

  void _schedule() {
    if (!busy) {
      _poll?.cancel();
      _poll = null;
    } else {
      _poll ??= Timer.periodic(pollEvery, (_) {
        for (final j in jobs.where((j) => j.pending).toList()) {
          _refresh(j.id);
        }
      });
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }
}
