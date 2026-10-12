import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../hub.dart';
import '../models.dart';
import '../timecode.dart';
import '../uploader.dart';
import 'status_chip.dart';

/// Карточка проекта: загрузка видео, статус пайплайна в реальном времени, найденные планы.
class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.api, required this.project});
  final Api api;
  final Project project;

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  late Project _project = widget.project;
  late final ProjectHub _hub = ProjectHub(widget.api, _project.id, _onStatus);
  SceneSheet? _sheet;
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
  }

  @override
  void dispose() {
    _hub.close();
    _uploader?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final project = await widget.api.project(_project.id);
      final sheet = await widget.api.scenes(_project.id);
      if (mounted) {
        setState(() {
          _project = project;
          _sheet = sheet;
        });
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _onStatus(StatusUpdate s) {
    if (!mounted) return;
    setState(() => _project = _project.withStatus(s));
    if (s.stage == 'scenes' && s.status == 'done') _refresh();
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
    final scenes = _sheet?.scenes ?? const <Scene>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(_project.name),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: StatusChip(stage: _project.stage, status: _project.status),
          ),
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_hubError != null) _Banner(text: _hubError!, color: Theme.of(context).colorScheme.errorContainer),
          if (_project.status == 'failed' && _project.error != null)
            _Banner(text: _project.error!, color: Theme.of(context).colorScheme.errorContainer),
          _uploadPanel(context),
          const Divider(height: 1),
          Expanded(
            child: scenes.isEmpty
                ? Center(child: Text(_emptyText()))
                : _SceneList(scenes: scenes, fps: _sheet?.fps),
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
    final sheet = _sheet;
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

/// Найденные планы: №, начало, конец, длительность, ключевые кадры (FR-C4, без редактирования).
class _SceneList extends StatelessWidget {
  const _SceneList({required this.scenes, required this.fps});
  final List<Scene> scenes;
  final double? fps;

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context).textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    return ListView.separated(
      itemCount: scenes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final s = scenes[i];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SizedBox(width: 40, child: Text('${s.index + 1}', style: Theme.of(context).textTheme.titleMedium)),
              SizedBox(
                width: 240,
                child: Text('${timecode(s.startMs, fps)} – ${timecode(s.endMs, fps)}\n${seconds(s.endMs - s.startMs)}',
                    style: mono),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final url in s.keyframeUrls)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.network(url, height: 72, fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(
                                    width: 128, height: 72, child: Icon(Icons.broken_image_outlined))),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
