import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../export_controller.dart';
import '../hub.dart';
import '../models.dart';
import '../scene_player.dart';
import '../sheet_controller.dart';
import '../timecode.dart';
import '../uploader.dart';
import 'sheet_view.dart';
import 'status_chip.dart';

/// Карточка проекта: загрузка видео, статус пайплайна в реальном времени, редактор монтажного
/// листа со встроенным плеером (этап 4) и экспорт в xlsx / docx / pdf (этап 5).
class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.api, required this.project});
  final Api api;
  final Project project;

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  late Project _project = widget.project;
  late final ProjectHub _hub = ProjectHub(widget.api, _project.id, _onStatus, onExport: (u) => _exports.onUpdate(u));
  late final SheetController _sheet = SheetController(widget.api, _project.id, onNotice: _notice);
  late final ExportController _exports = ExportController(widget.api, _project.id, onNotice: _notice);
  ScenePlayer? _player;
  String? _selectedId;
  Uploader? _uploader;
  double? _progress;
  String? _uploadError;
  String? _hubError;

  @override
  void initState() {
    super.initState();
    _hub.connect().catchError((Object e) {
      if (mounted) setState(() => _hubError = 'Статусы в реальном времени недоступны: $e');
    });
    _refresh();
    _exports.load();
  }

  @override
  void dispose() {
    _hub.close();
    _exports.dispose();
    _uploader?.dispose();
    _sheet.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final project = await widget.api.project(_project.id);
      if (mounted) setState(() => _project = project);
    } on ApiException catch (e) {
      _notice(e.message);
    }
    await _sheet.load();
    final url = _sheet.sheet?.videoUrl;
    if (url != null && mounted) {
      setState(() => _player ??= ScenePlayer());
      await _player!.open(url);
    }
  }

  void _notice(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Результаты этапов приходят из Aggregator: лист перечитывается, правки на сервере не теряются.
  void _onStatus(StatusUpdate s) {
    if (!mounted) return;
    setState(() => _project = _project.withStatus(s));
    if (s.status == 'done' || s.status == 'ready_for_review') _refresh();
  }

  void _select(Scene s) {
    setState(() => _selectedId = s.id);
    _player?.seek(s.startMs);
  }

  void _play(Scene s) {
    setState(() => _selectedId = s.id);
    _player?.playRange(s.startMs, s.endMs);
  }

  Future<void> _setReviewRequired(bool value) async {
    if (await _sheet.setReviewRequired(value)) await _refresh();
  }

  Future<void> _reprocess(String from) async {
    try {
      final project = await widget.api.reprocess(_project.id, from);
      if (mounted) setState(() => _project = project);
      _notice('Обработка перезапущена, ваши правки сохранятся');
    } on ApiException catch (e) {
      _notice(e.message);
    }
  }

  /// Скачивание готового экспорта: пользователь выбирает, куда сохранить файл.
  Future<void> _saveExport(ExportJob job) async {
    final bytes = await _exports.fetch(job);
    if (bytes == null) return;
    try {
      final saved = await FilePicker.saveFile(dialogTitle: 'Сохранить монтажный лист', fileName: job.filename,
          bytes: bytes, type: FileType.custom, allowedExtensions: [job.format]);
      if (saved != null) _notice('Сохранено: ${saved.toFilePath()}');
    } catch (e) {
      _notice('Не удалось сохранить файл: $e');
    }
  }

  Future<void> _pickVideo() async {
    final files = await FilePicker.pickFiles(dialogTitle: 'Видео фильма', type: FileType.video);
    final path = files.firstOrNull?.path;
    if (path == null) return;
    _uploader?.dispose();
    final uploader = Uploader(widget.api, _project.id, File(path));
    uploader.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    setState(() => _uploader = uploader);
    await _run(uploader.start);
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() {
      _uploadError = null;
      _progress = _progress ?? 0;
    });
    try {
      await op();
      setState(() => _progress = null);
    } catch (e) {
      if (mounted) setState(() => _uploadError = 'Загрузка прервалась: $e');
    }
  }

  bool get _uploading => _progress != null && _uploadError == null;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_project.name),
        actions: [
          ListenableBuilder(
            listenable: _sheet,
            builder: (_, _) => Row(children: [
              if (_sheet.saving)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Сохранение…'),
                ),
              if (_sheet.sheet != null)
                Tooltip(
                  message: 'Режим «без правок»: лист берётся как есть, ревью необязательно (FR-C12)',
                  child: Row(children: [
                    const Text('Без правок'),
                    Switch(value: _sheet.readOnly, onChanged: (v) => _setReviewRequired(!v)),
                  ]),
                ),
            ]),
          ),
          ListenableBuilder(
            listenable: _sheet,
            // FR-C12: экспорт доступен, как только в листе есть строки; ревью необязательно.
            builder: (_, _) => PopupMenuButton<String>(
              tooltip: 'Экспорт монтажного листа',
              icon: const Icon(Icons.file_download_outlined),
              enabled: _sheet.sheet?.scenes.isNotEmpty ?? false,
              onSelected: _exports.request,
              itemBuilder: (_) => [
                for (final f in ExportController.formats.entries) PopupMenuItem(value: f.key, child: Text(f.value)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: StatusChip(stage: _project.stage, status: _project.status),
          ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
          PopupMenuButton<String>(
            tooltip: 'Перезапустить обработку',
            icon: const Icon(Icons.replay),
            onSelected: _reprocess,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'scenes', child: Text('Перезапустить с поиска склеек')),
              PopupMenuItem(value: 'dialogue', child: Text('Перезапустить с разбора сценария')),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_hubError != null) _Banner(text: _hubError!, color: Theme.of(context).colorScheme.errorContainer),
          if (_project.status == 'failed' && _project.error != null)
            _Banner(text: _project.error!, color: Theme.of(context).colorScheme.errorContainer),
          ListenableBuilder(
            listenable: _sheet,
            builder: (context, _) => _sheet.readOnly
                ? _Banner(
                    text: 'Режим «без правок»: лист используется как есть, экспорт доступен сразу после обработки. '
                        'Чтобы править, выключите переключатель.',
                    color: Theme.of(context).colorScheme.secondaryContainer)
                : const SizedBox.shrink(),
          ),
          ListenableBuilder(
            listenable: _exports,
            builder: (_, _) => _exports.jobs.isEmpty
                ? const SizedBox.shrink()
                : ExportBar(controller: _exports, onSave: _saveExport),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_player != null) _PlayerPanel(player: _player!, fps: _sheet.sheet?.fps),
              Expanded(child: _uploadPanel(context)),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: _sheet,
              builder: (context, _) => (_sheet.sheet?.scenes.isEmpty ?? true)
                  ? Center(child: Text(_sheet.error ?? _emptyText()))
                  : SheetTable(
                      controller: _sheet,
                      selectedId: _selectedId,
                      onSelect: _select,
                      onPlay: _player == null ? null : _play,
                      playerPositionMs: _player == null ? null : () => _player!.positionMs,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  String _emptyText() => switch ((_project.stage, _project.status)) {
        ('scenes', 'running') => 'Ищем склейки…',
        ('upload', _) || (_, 'created') => 'Загрузите видео, чтобы найти планы',
        _ => 'Планов нет',
      };

  Widget _uploadPanel(BuildContext context) {
    final hasVideo = _project.videoUri != null || _project.stage != 'upload';
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          if (_uploading) ...[
            Expanded(child: LinearProgressIndicator(value: _progress)),
            const SizedBox(width: 12),
            Text('${((_progress ?? 0) * 100).toStringAsFixed(0)} %'),
          ] else ...[
            FilledButton.icon(
              onPressed: _pickVideo,
              icon: const Icon(Icons.upload_file),
              label: Text(hasVideo ? 'Загрузить другое видео' : 'Выбрать видео'),
            ),
            if (_uploadError != null && _uploader != null) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () => _run(_uploader!.resume),
                icon: const Icon(Icons.replay),
                label: const Text('Продолжить загрузку'),
              ),
            ],
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _uploadError ?? _summary(),
                style: _uploadError != null ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _summary() {
    final sheet = _sheet.sheet;
    if (sheet == null || sheet.scenes.isEmpty) return '';
    final duration = sheet.durationMs == null ? '' : ', длительность ${timecode(sheet.durationMs!, sheet.fps)}';
    return 'Планов: ${sheet.scenes.length}$duration, ${sheet.fps?.toStringAsFixed(2) ?? '?'} кадр/с';
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(color: color, padding: const EdgeInsets.all(12), child: Text(text));
}

/// Встроенный плеер (FR-C7): клик по строке перематывает на начало сцены, ▶ в строке играет сцену.
class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({required this.player, required this.fps});
  final ScenePlayer player;
  final double? fps;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 480,
      child: Column(
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: Video(controller: player.video, controls: NoVideoControls)),
          Row(children: [
            IconButton(onPressed: player.toggle, icon: const Icon(Icons.play_arrow), tooltip: 'Играть / пауза'),
            StreamBuilder<Duration>(
              stream: player.position,
              builder: (_, snap) => Text(
                timecode(snap.data?.inMilliseconds ?? 0, fps),
                style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Последние экспорты: формат, статус и кнопка «Сохранить» у готовых.
class ExportBar extends StatelessWidget {
  const ExportBar({super.key, required this.controller, required this.onSave, this.limit = 3});
  final ExportController controller;
  final void Function(ExportJob job) onSave;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Экспорт:'),
          for (final job in controller.jobs.take(limit))
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text('${job.format.toUpperCase()} ${_time(job.createdAt)}'),
              const SizedBox(width: 8),
              if (job.pending || controller.isSaving(job))
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else if (job.status == 'completed')
                TextButton.icon(
                  onPressed: () => onSave(job),
                  icon: const Icon(Icons.save_alt, size: 18),
                  label: const Text('Сохранить'),
                )
              else
                Tooltip(
                  message: job.error ?? '',
                  child: Text('ошибка', style: TextStyle(color: scheme.error)),
                ),
            ]),
        ],
      ),
    );
  }

  static String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
