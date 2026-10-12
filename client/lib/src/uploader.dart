import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'models.dart';

/// Загрузка файла напрямую в S3 по presigned URL частями (FR-C2). Каждая часть повторяется
/// при обрыве; [resume] спрашивает у Project API, каких частей не хватает, и догружает их.
class Uploader {
  Uploader(this.api, this.projectId, this.file, {this.kind = 'video', http.Client? client})
      : _http = client ?? http.Client();

  final Api api;
  final String projectId;
  final File file;
  final String kind;
  final http.Client _http;

  String? uploadId;
  final _progress = StreamController<double>.broadcast();

  /// Доля загруженного от 0 до 1.
  Stream<double> get progress => _progress.stream;

  Future<void> start() async {
    final size = await file.length();
    final state = await api.startUpload(projectId,
        kind: kind, filename: file.uri.pathSegments.last, sizeBytes: size, contentType: _contentType());
    uploadId = state.uploadId;
    await _upload(state);
  }

  Future<void> resume() async {
    if (uploadId == null) return start();
    await _upload(await api.uploadState(projectId, uploadId!));
  }

  Future<void> _upload(UploadState state) async {
    var done = state.uploadedParts.fold<int>(0, (sum, n) => sum + _partLength(state, n));
    _progress.add(done / state.sizeBytes);
    final raf = await file.open();
    try {
      for (final part in state.parts) {
        final length = _partLength(state, part.partNumber);
        await _withRetry(() => _putPart(raf, state, part, length, (sent) {
              _progress.add((done + sent) / state.sizeBytes);
            }));
        done += length;
      }
    } finally {
      await raf.close();
    }
    await api.completeUpload(projectId, state.uploadId);
    _progress.add(1);
  }

  Future<void> _putPart(RandomAccessFile raf, UploadState state, PartUrl part, int length,
      void Function(int sent) onSent) async {
    await raf.setPosition((part.partNumber - 1) * state.partSize);
    final bytes = await raf.read(length);
    final req = http.StreamedRequest('PUT', Uri.parse(part.url))..contentLength = bytes.length;
    final resp = _http.send(req);
    // Отдаём часть кусками по 256 КиБ, чтобы показывать прогресс внутри части.
    const chunk = 256 * 1024;
    for (var offset = 0; offset < bytes.length; offset += chunk) {
      req.sink.add(bytes.sublist(offset, min(offset + chunk, bytes.length)));
      onSent(min(offset + chunk, bytes.length));
      await Future<void>.delayed(Duration.zero);
    }
    await req.sink.close();
    final r = await resp;
    await r.stream.drain<void>();
    if (r.statusCode != 200) throw ApiException(r.statusCode, 'S3 отклонил часть ${part.partNumber}: HTTP ${r.statusCode}');
  }

  int _partLength(UploadState s, int partNumber) =>
      min(s.partSize, s.sizeBytes - (partNumber - 1) * s.partSize);

  static Future<void> _withRetry(Future<void> Function() op) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await op();
      } on Exception {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  String _contentType() {
    final ext = file.path.split('.').last.toLowerCase();
    return switch (ext) {
      'mov' => 'video/quicktime',
      'mkv' => 'video/x-matroska',
      'avi' => 'video/x-msvideo',
      'webm' => 'video/webm',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      _ => 'video/mp4',
    };
  }

  void dispose() => _progress.close();
}
