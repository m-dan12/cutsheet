import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../ui/widgets.dart';
import '../uploader.dart';

const videoExtensions = ['mp4', 'mov', 'mxf', 'mkv', 'avi', 'm4v', 'webm'];
const scriptExtensions = ['docx'];

/// Размер файла по-русски: «84 КБ», «3,8 ГБ».
String fileSize(int bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  final text = u == 0 || v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1).replaceAll('.', ',');
  return '$text ${units[u]}';
}

/// Новый проект (FR-C1, FR-C2): название, видео и сценарий .docx. Файлы уходят прямо в хранилище
/// частями; сценарий грузится первым (он маленький), обработка начинается, когда загрузится видео.
/// Возвращает созданный проект (в том числе если загрузку прервали: её можно продолжить в проекте).
class NewProjectDialog extends StatefulWidget {
  const NewProjectDialog({super.key, required this.api});
  final Api api;

  @override
  State<NewProjectDialog> createState() => _NewProjectDialogState();
}

class _Pick {
  _Pick(this.file, this.kind) : size = file.lengthSync();
  final File file;
  final String kind;
  final int size;
  Uploader? uploader;
  double? progress;
  bool done = false;
  String? error;

  String get name => file.uri.pathSegments.last;
}

class _NewProjectDialogState extends State<NewProjectDialog> {
  final _name = TextEditingController();
  _Pick? _video;
  _Pick? _script;
  Project? _project;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _video?.uploader?.dispose();
    _script?.uploader?.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Видео и сценарий',
      type: FileType.custom,
      allowedExtensions: [...videoExtensions, ...scriptExtensions],
    );
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      final ext = path.split('.').last.toLowerCase();
      if (videoExtensions.contains(ext)) _video = _Pick(File(path), 'video');
      if (scriptExtensions.contains(ext)) _script = _Pick(File(path), 'script');
    }
    if (_name.text.trim().isEmpty && _video != null) {
      final base = _video!.name;
      _name.text = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
    }
    setState(() {});
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _project ??= await widget.api.createProject(_name.text.trim());
      for (final pick in [_script, _video].nonNulls.where((p) => !p.done)) {
        await _upload(pick);
      }
      if (mounted) Navigator.pop(context, _project);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Загрузка прервалась: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload(_Pick pick) async {
    final resume = pick.uploader != null;
    final uploader = pick.uploader ??= Uploader(widget.api, _project!.id, pick.file, kind: pick.kind);
    if (!resume) {
      uploader.progress.listen((p) {
        if (mounted) setState(() => pick.progress = p);
      });
    }
    setState(() {
      pick.error = null;
      pick.progress ??= 0;
    });
    try {
      await (resume ? uploader.resume() : uploader.start());
      setState(() => pick.done = true);
    } catch (e) {
      if (mounted) setState(() => pick.error = '$e');
      rethrow;
    }
  }

  void _cancel() => Navigator.pop(context, _project);

  @override
  Widget build(BuildContext context) {
    final canCreate = !_busy && _name.text.trim().isNotEmpty;
    final retry = _error != null && _project != null;
    return CsDialog(
      title: 'Новый проект',
      subtitle: 'Видео и сценарий загружаются прямо в хранилище',
      icon: GIcons.cloudUp,
      onClose: _cancel,
      footerNote: 'Обработка начнётся сама, как только видео загрузится.',
      actions: [
        Btn('Отмена', kind: BtnKind.ghost, onPressed: _cancel),
        Btn(
          retry ? 'Продолжить загрузку' : 'Создать проект',
          kind: BtnKind.primary,
          onPressed: canCreate ? _create : null,
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FieldLabel('Название'),
          TextField(
            controller: _name,
            autofocus: true,
            enabled: _project == null,
            style: Cs.body,
            decoration: const InputDecoration(hintText: 'Название фильма'),
          ),
          const SizedBox(height: 18),
          if (!_busy && _project == null) _dropZone(),
          if (_video != null) ...[const SizedBox(height: 12), _fileCard(_video!)],
          if (_script != null) ...[const SizedBox(height: 12), _fileCard(_script!)],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: Cs.small.copyWith(color: Cs.danger)),
          ],
        ],
      ),
    );
  }

  Widget _dropZone() {
    return CustomPaint(
      painter: _DashedBorder(),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: Cs.surfaceSoft, borderRadius: BorderRadius.circular(16)),
        child: Column(
          children: [
            const GIcon(GIcons.cloudUp, size: 22, color: Cs.inkMuted),
            const SizedBox(height: 6),
            Text('Выберите видео и сценарий', style: Cs.strong.copyWith(fontSize: 15)),
            Text('Видео: MP4, MOV, MXF · Сценарий: .docx', style: Cs.small.copyWith(color: Cs.inkFaint)),
            const SizedBox(height: 14),
            Btn('Выбрать файлы', small: true, onPressed: _pickFiles),
          ],
        ),
      ),
    );
  }

  Widget _fileCard(_Pick p) {
    final isVideo = p.kind == 'video';
    final uploading = p.progress != null && !p.done && p.error == null;
    final status = p.error != null
        ? 'Загрузка прервалась'
        : p.done
        ? 'Загружен'
        : uploading
        ? 'Загрузка ${((p.progress ?? 0) * 100).toStringAsFixed(0)}%'
        : (isVideo ? 'Видео' : 'Сценарий');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Cs.border),
        borderRadius: BorderRadius.circular(Cs.rMedium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isVideo ? Cs.accentSoft : Cs.track,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: GIcon(
                  isVideo ? GIcons.video : GIcons.fileText,
                  size: 18,
                  color: isVideo ? Cs.accentInk : Cs.inkSoft,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, style: Cs.strong, overflow: TextOverflow.ellipsis),
                    Row(
                      children: [
                        Text(
                          uploading
                              ? '${fileSize(((p.progress ?? 0) * p.size).round())} из ${fileSize(p.size)}'
                              : fileSize(p.size),
                          style: Cs.monoText.copyWith(fontSize: 12, color: Cs.inkMuted),
                        ),
                        const Text(' · ', style: Cs.small),
                        if (p.done) ...[
                          const GIcon(GIcons.circleCheck, size: 14, color: Cs.successDot),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            status,
                            style: Cs.small.copyWith(color: p.error != null ? Cs.danger : Cs.inkMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_project == null && !_busy)
                IconBtn(
                  GIcons.trash,
                  tooltip: 'Убрать файл',
                  onPressed: () => setState(() => isVideo ? _video = null : _script = null),
                ),
            ],
          ),
          if (uploading) ...[
            const SizedBox(height: 12),
            Bar(value: p.progress),
            const SizedBox(height: 8),
            const Text('Если связь прервётся, загрузка продолжится с того же места.', style: Cs.caption),
          ],
        ],
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Cs.dashed
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
