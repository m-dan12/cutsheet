import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../export_controller.dart';
import '../hub.dart';
import '../models.dart';
import '../scene_player.dart';
import '../sheet_controller.dart';
import '../timecode.dart';
import '../ui/widgets.dart';
import '../uploader.dart';
import 'export_dialog.dart';
import 'new_project_dialog.dart' show scriptExtensions;
import 'player_panel.dart';
import 'projects_screen.dart' show Avatar;
import 'sheet_dialogs.dart';
import 'sheet_view.dart';
import 'status_chip.dart';

/// Проект: пока лист собирается — ход обработки по этапам (FR-C3) с найденными сценами; когда
/// готов — редактор монтажного листа со встроенным плеером (этап 4) и экспорт (этап 5).
class ProjectScreen extends StatefulWidget {
  const ProjectScreen({super.key, required this.api, required this.project});
  final Api api;
  final Project project;

  @override
  State<ProjectScreen> createState() => _ProjectScreenState();
}

class _ProjectScreenState extends State<ProjectScreen> {
  late Project _project = widget.project;
  late final ProjectHub _hub = ProjectHub(widget.api, _project.id, _onStatus, onExport: _onExport);
  late final SheetController _sheet = SheetController(
    widget.api,
    _project.id,
    onNotice: _notice,
    onConflict: _onConflict,
  );
  late final ExportController _exports = ExportController(widget.api, _project.id, onNotice: _notice);
  ScenePlayer? _player;
  String? _selectedId;
  final Map<String, double?> _stageProgress = {};
  final Map<String, DateTime> _stageTime = {};
  Uploader? _uploader;
  String? _uploadKind;
  double? _progress;
  String? _uploadError;
  String? _hubError;

  /// null — вид выбирается сам: лист, когда он готов, иначе ход обработки.
  bool? _showSheet;
  SheetFilter _filter = SheetFilter.all;
  String _query = '';
  bool _onlyScene = true;

  @override
  void initState() {
    super.initState();
    _hub.connect().catchError((Object e) {
      if (mounted) setState(() => _hubError = 'Нет связи со статусами в реальном времени. Нажмите «Обновить».');
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
    if (mounted) showToast(context, message);
  }

  /// Результаты этапов приходят из Aggregator: лист перечитывается, правки на сервере не теряются.
  void _onStatus(StatusUpdate s) {
    if (!mounted) return;
    setState(() {
      _project = _project.withStatus(s);
      _stageProgress[s.stage] = s.progress;
      _stageTime[s.stage] = DateTime.now();
    });
    if (s.status == 'done' || s.status == 'ready_for_review' || (s.stage == 'enrichment' && s.status == 'running')) {
      _refresh();
    }
  }

  void _onExport(ExportUpdate u) {
    _exports.onUpdate(u).then((_) {
      if (!mounted || u.status != 'completed') return;
      final job = _exports.jobs.where((j) => j.id == u.exportId).firstOrNull;
      if (job != null) {
        showToast(context, 'Файл готов: ${job.filename}', action: 'Сохранить', onAction: () => _saveExport(job));
      }
    });
  }

  /// Конфликт версий: показываем обе версии, выбранную «свою» отправляем ещё раз поверх свежей строки.
  Future<void> _onConflict(Scene current, Map<String, Object?> changes) async {
    if (!mounted) return;
    final mine = await showDialog<bool>(
      context: context,
      builder: (_) => ConflictDialog(current: current, changes: changes, fps: _sheet.sheet?.fps),
    );
    if (mine == true) await _sheet.patch(current.id, changes);
  }

  /// Выбранная строка; по умолчанию — первая.
  Scene? get _selected => (_selectedId == null ? null : _sheet.scene(_selectedId!)) ?? _sheet.sheet?.scenes.firstOrNull;

  void _select(Scene s, {bool play = false}) {
    setState(() => _selectedId = s.id);
    if (play || (_player?.player.state.playing ?? false)) {
      _onlyScene
          ? _player?.playRange(s.startMs, s.endMs)
          : _player?.seek(s.startMs).then((_) => _player?.player.play());
    } else {
      _player?.seek(s.startMs);
    }
  }

  Future<void> _setReviewRequired(bool value) async {
    if (await _sheet.setReviewRequired(value)) await _refresh();
  }

  Future<void> _reprocess(String from) async {
    try {
      final project = await widget.api.reprocess(_project.id, from);
      if (mounted) {
        setState(() {
          _project = project;
          _showSheet = null;
        });
      }
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
      final saved = await FilePicker.saveFile(
        dialogTitle: 'Сохранить монтажный лист',
        fileName: job.filename,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: [job.format],
      );
      if (saved != null) _notice('Сохранено: ${saved.toFilePath()}');
    } catch (e) {
      _notice('Не удалось сохранить файл: $e');
    }
  }

  void _openExport() {
    final sheet = _sheet.sheet;
    final n = sheet?.scenes.length ?? 0;
    final edited = sheet?.scenes.where(editedByUser).length ?? 0;
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x521C1B19),
      builder: (_) => ExportDialog(
        controller: _exports,
        subtitle: '$n ${_scenesWord(n)}${edited > 0 ? ' · с вашими правками' : ''}',
        onSave: _saveExport,
      ),
    );
  }

  Future<void> _pickUpload(String kind) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: kind == 'video' ? 'Видео фильма' : 'Сценарий (.docx)',
      type: kind == 'video' ? FileType.video : FileType.custom,
      allowedExtensions: kind == 'video' ? null : scriptExtensions,
    );
    final path = files.firstOrNull?.path;
    if (path == null) return;
    _uploader?.dispose();
    final uploader = Uploader(widget.api, _project.id, File(path), kind: kind);
    uploader.progress.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    setState(() {
      _uploader = uploader;
      _uploadKind = kind;
    });
    await _run(uploader.start);
    if (kind == 'script' && _uploadError == null) _notice('Сценарий загружен');
  }

  Future<void> _run(Future<void> Function() op) async {
    setState(() {
      _uploadError = null;
      _progress = _progress ?? 0;
    });
    try {
      await op();
      setState(() => _progress = null);
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _uploadError = 'Загрузка прервалась: $e');
    }
  }

  bool get _uploading => _progress != null && _uploadError == null;
  bool get _ready => isReady(_project.stage, _project.status);
  bool get _hasScenes => _sheet.sheet?.scenes.isNotEmpty ?? false;
  bool get _sheetView => _showSheet ?? (_hasScenes && (_ready || _project.status == 'failed'));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 16),
        child: ListenableBuilder(
          listenable: _sheet,
          builder: (context, _) => Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _rail(),
              const SizedBox(width: 12),
              Expanded(child: _sheetView ? _editor() : _processing()),
              if (_sheetView && _sheet.sheet != null && MediaQuery.sizeOf(context).width >= 1180) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: MediaQuery.sizeOf(context).width >= 1400 ? 400 : 340,
                  child: PlayerPanel(
                    player: _player,
                    sheet: _sheet.sheet!,
                    scene: _selected,
                    onSelect: _select,
                    onlyScene: _onlyScene,
                    onOnlySceneChanged: (v) => setState(() => _onlyScene = v),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------- навигация ----------

  Widget _rail() {
    Widget item(String icon, String tip, bool on, VoidCallback? onTap) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tooltip(
        message: tip,
        child: Material(
          color: on ? Cs.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: on
                  ? BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: Cs.shadowSoft, color: Cs.surface)
                  : null,
              child: GIcon(icon, color: on ? Cs.ink : Cs.inkMuted),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: [
          const Brand(compact: true),
          const SizedBox(height: 20),
          item(GIcons.folder, 'Проекты', false, () => Navigator.of(context).maybePop()),
          item(GIcons.table, 'Монтажный лист', _sheetView, _hasScenes ? () => setState(() => _showSheet = true) : null),
          item(GIcons.listUl, 'Ход обработки', !_sheetView, () => setState(() => _showSheet = false)),
          item(GIcons.download, 'Экспорт', false, _hasScenes ? _openExport : null),
          const Spacer(),
          Tooltip(
            message: widget.api.email ?? '',
            child: Avatar(email: widget.api.email ?? ''),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumb() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      InkWell(
        onTap: () => Navigator.of(context).maybePop(),
        child: Text('Проекты', style: Cs.small.copyWith(color: Cs.inkFaint)),
      ),
      Text('  /  ', style: Cs.small.copyWith(color: Cs.inkFaint)),
    ],
  );

  Widget _reprocessMenu() => PopupMenuButton<String>(
    tooltip: 'Перезапустить обработку',
    onSelected: _reprocess,
    icon: const GIcon(GIcons.reset, color: Cs.inkMuted),
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'scenes', child: Text('Перезапустить с поиска склеек')),
      PopupMenuItem(value: 'dialogue', child: Text('Перезапустить с разбора сценария')),
    ],
  );

  List<Widget> _banners() => [
    if (_hubError != null) _Banner(icon: GIcons.cloudSlash, text: _hubError!, kind: PillKind.err),
    if (_project.status == 'failed' && _project.error != null)
      _Banner(icon: GIcons.circleXmark, text: _project.error!, kind: PillKind.err),
  ];

  // ---------- ход обработки ----------

  Widget _processing() {
    final sheet = _sheet.sheet;
    final scenes = sheet?.scenes ?? const <Scene>[];
    return Panel(
      padding: const EdgeInsets.fromLTRB(36, 28, 36, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _breadcrumb(),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(_project.name, style: Cs.heading(28, height: 36), overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 14),
                    StatusChip(stage: _project.stage, status: _project.status),
                  ],
                ),
              ),
              IconBtn(GIcons.rotate, tooltip: 'Обновить', onPressed: _refresh),
              _reprocessMenu(),
              const SizedBox(width: 8),
              Btn(
                'Открыть лист',
                kind: BtnKind.primary,
                onPressed: _hasScenes ? () => setState(() => _showSheet = true) : null,
              ),
            ],
          ),
          const SizedBox(height: 16),
          ..._banners().map((b) => Padding(padding: const EdgeInsets.only(bottom: 12), child: b)),
          Expanded(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 380, maxWidth: 520),
                    child: _steps(scenes),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 380, maxWidth: 720),
                    child: _found(scenes),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _steps(List<Scene> scenes) {
    final cur = pipelineStages.indexOf(_project.stage);
    final created = _project.status == 'created';
    String time(String stage) {
      final t = _stageTime[stage];
      return t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    _StepState state(int i) {
      if (created) return i == 0 ? _StepState.active : _StepState.pending;
      if (_ready) return _StepState.done;
      if (cur < 0) return _StepState.pending;
      if (i < cur) return _StepState.done;
      if (i > cur) return _StepState.pending;
      return switch (_project.status) {
        'failed' => _StepState.failed,
        'done' => _StepState.done,
        _ => _StepState.running,
      };
    }

    final fps = _project.fps;
    final videoInfo = [
      if (_project.durationMs != null) timecode(_project.durationMs!, fps),
      if (fps != null) '${fps.toStringAsFixed(fps % 1 == 0 ? 0 : 2)} кадр/с',
    ].join(', ');
    final withLines = scenes.where((s) => s.replicas.isNotEmpty).length;
    final described = scenes.where((s) => (s.description ?? '').isNotEmpty).length;
    final steps = [
      (
        'upload',
        'Загрузка файлов',
        'Файлы загружены',
        videoInfo.isEmpty ? 'Видео и сценарий .docx' : 'Видео $videoInfo',
      ),
      (
        'scenes',
        'Поиск сцен',
        'Сцены найдены',
        scenes.isEmpty
            ? 'Склейки ищутся по изменению кадра'
            : '${scenes.length} ${_scenesWord(scenes.length)} по склейкам',
      ),
      (
        'dialogue',
        'Диалоги сопоставляются',
        'Диалоги сопоставлены',
        'Расшифровка речи и привязка реплик к сценарию${withLines > 0 ? ' · реплики в $withLines из ${scenes.length}' : ''}',
      ),
      (
        'enrichment',
        'Сцены обогащаются',
        'Сцены описаны',
        'Крупность плана и описание кадра${described > 0 ? ' · $described из ${scenes.length} сцен' : ''}',
      ),
      ('review', 'Готово к проверке', 'Готово к проверке', 'Экспорт станет доступен сразу, проверка необязательна'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Cs.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (final (i, (stage, title, doneTitle, detail)) in steps.indexed)
            _Step(
              state: state(i),
              title: state(i) == _StepState.done ? doneTitle : title,
              detail: state(i) == _StepState.failed ? (_project.error ?? 'Этап завершился ошибкой') : detail,
              time: time(stage),
              progress: _stageProgress[stage],
              last: i == steps.length - 1,
              extra: i == 0 && (created || _project.stage == 'upload' || _uploading || _uploadError != null)
                  ? _uploadBox()
                  : null,
            ),
        ],
      ),
    );
  }

  /// Загрузка видео и сценария в существующий проект (если не загрузили при создании или прервали).
  Widget _uploadBox() {
    if (_uploading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${_uploadKind == 'script' ? 'Сценарий' : 'Видео'}: ${((_progress ?? 0) * 100).toStringAsFixed(0)}%',
            style: Cs.small,
          ),
          const SizedBox(height: 8),
          Bar(value: _progress),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_uploadError != null) ...[
          Text(_uploadError!, style: Cs.small.copyWith(color: Cs.danger)),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_uploadError != null && _uploader != null)
              Btn(
                'Продолжить загрузку',
                icon: GIcons.reset,
                small: true,
                kind: BtnKind.primary,
                onPressed: () => _run(_uploader!.resume),
              ),
            Btn(
              _project.videoUri != null ? 'Другое видео' : 'Выбрать видео',
              icon: GIcons.video,
              small: true,
              onPressed: () => _pickUpload('video'),
            ),
            Btn('Сценарий .docx', icon: GIcons.fileText, small: true, onPressed: () => _pickUpload('script')),
          ],
        ),
      ],
    );
  }

  Widget _found(List<Scene> scenes) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Найденные сцены', style: Cs.strong.copyWith(fontSize: 16, height: 1.5))),
            if (_hubError == null) ...[
              const Dot(Cs.successDot),
              const SizedBox(width: 8),
              const Text('Обновляется в реальном времени', style: Cs.small),
            ],
          ],
        ),
        const SizedBox(height: 14),
        if (scenes.isEmpty)
          Container(
            height: 160,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Cs.surfaceMuted, borderRadius: BorderRadius.circular(Cs.rMedium)),
            child: Text(
              _project.status == 'created' ? 'Загрузите видео, чтобы найти сцены' : 'Сцены появятся здесь',
              style: Cs.body.copyWith(color: Cs.inkMuted),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, c) {
              final cols = (c.maxWidth / 160).floor().clamp(2, 6);
              final w = (c.maxWidth - 12 * (cols - 1)) / cols;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final s in scenes.take(48))
                    SizedBox(
                      width: w,
                      child: InkWell(
                        onTap: () => setState(() {
                          _selectedId = s.id;
                          _showSheet = true;
                        }),
                        child: _SceneThumb(scene: s, fps: _sheet.sheet?.fps),
                      ),
                    ),
                ],
              );
            },
          ),
        if (scenes.length > 48) ...[const SizedBox(height: 8), Text('и ещё ${scenes.length - 48}', style: Cs.small)],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(color: Cs.surfaceMuted, borderRadius: BorderRadius.circular(Cs.rMedium)),
          child: Row(
            children: [
              const GIcon(GIcons.bell, color: Cs.inkMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Окно можно закрыть. Когда лист будет готов, проект появится в списке со статусом «Готов к проверке».',
                  style: Cs.body.copyWith(color: Cs.inkMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------- редактор листа ----------

  Widget _editor() {
    final sheet = _sheet.sheet!;
    final scenes = sheet.scenes;
    final review = scenes.where(needsReview).length;
    final edited = scenes.where(editedByUser).length;
    final ro = _sheet.readOnly;
    final sel = _selected;
    final duration = sheet.durationMs ?? (scenes.isEmpty ? 0 : scenes.last.endMs);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Cs.divider)),
            ),
            child: Row(
              children: [
                _breadcrumb(),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(_project.name, style: Cs.heading(20, height: 28), overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 12),
                      StatusChip(stage: _project.stage, status: _project.status),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _saveState(),
                const SizedBox(width: 12),
                Tooltip(
                  message: 'Режим «без правок»: лист берётся как есть, проверка необязательна (FR-C12)',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Без правок', style: Cs.small.copyWith(color: Cs.inkMuted)),
                      Transform.scale(
                        scale: 0.8,
                        child: Switch(value: ro, onChanged: (v) => _setReviewRequired(!v)),
                      ),
                    ],
                  ),
                ),
                IconBtn(GIcons.rotate, tooltip: 'Обновить', onPressed: _refresh),
                _reprocessMenu(),
                const SizedBox(width: 4),
                Btn(
                  'Экспорт',
                  icon: GIcons.download,
                  kind: BtnKind.primary,
                  onPressed: scenes.isEmpty ? null : _openExport,
                ),
              ],
            ),
          ),
          ..._banners(),
          if (!_ready && _project.status != 'failed')
            _Strip(
              icon: GIcons.rotate,
              text:
                  'Обработка ещё идёт: ${statusLabel(_project.stage, _project.status).toLowerCase()}. Правки сохранятся.',
              action: 'Ход обработки',
              onAction: () => setState(() => _showSheet = false),
            )
          else if (ro)
            const _Strip(
              icon: GIcons.lock,
              text:
                  'Режим «без правок»: лист используется как есть, экспорт доступен сразу. Чтобы править, выключите переключатель.',
            )
          else
            _Strip(
              icon: GIcons.sparkles,
              text: 'Черновик собран автоматически. Проверка необязательна: лист можно экспортировать как есть.',
              action: review > 0 ? 'Показать $review ${_placesWord(review)} для проверки' : null,
              onAction: () => setState(() => _filter = SheetFilter.review),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Row(
              children: [
                Segmented<SheetFilter>(
                  value: _filter,
                  items: [
                    (SheetFilter.all, 'Все · ${scenes.length}'),
                    (SheetFilter.review, 'Проверить · $review'),
                    (SheetFilter.edited, 'Изменённые · $edited'),
                  ],
                  onChanged: (f) => setState(() => _filter = f),
                ),
                const SizedBox(width: 10),
                SearchField(hint: 'Поиск по листу', width: 240, onChanged: (v) => setState(() => _query = v.trim())),
                const Spacer(),
                if (!ro) ...[
                  Btn(
                    'Разделить',
                    icon: GIcons.scissors,
                    kind: BtnKind.ghost,
                    small: true,
                    onPressed: sel == null
                        ? null
                        : () => splitScene(context, _sheet, sel, sheet, playerMs: _player?.positionMs),
                  ),
                  Btn(
                    'Объединить',
                    icon: GIcons.merge,
                    kind: BtnKind.ghost,
                    small: true,
                    onPressed: sel == null || sel.index >= scenes.length - 1
                        ? null
                        : () => mergeScene(context, _sheet, sel),
                  ),
                  Btn(
                    'Удалить',
                    icon: GIcons.trash,
                    kind: BtnKind.ghost,
                    small: true,
                    onPressed: sel == null ? null : () => deleteScene(context, _sheet, sel),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Cs.divider)),
              ),
              child: SheetTable(
                controller: _sheet,
                selectedId: _selected?.id,
                onSelect: _select,
                onPlay: _player == null ? null : (s) => _select(s, play: true),
                playerPositionMs: _player == null ? null : () => _player!.positionMs,
                filter: _filter,
                query: _query,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Cs.divider)),
            ),
            child: DefaultTextStyle(
              style: Cs.caption,
              child: Wrap(
                spacing: 18,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    [
                      '${scenes.length} ${_scenesWord(scenes.length)}',
                      timecode(duration, sheet.fps),
                      if (sheet.fps != null) '${sheet.fps!.toStringAsFixed(sheet.fps! % 1 == 0 ? 0 : 2)} кадр/с',
                    ].join(' · '),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Dot(Color(0xFFF2C46B), square: true),
                      const SizedBox(width: 6),
                      Text('$review требуют проверки'),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [const Dot(Cs.accent, size: 7), const SizedBox(width: 6), Text('$edited изменено вами')],
                  ),
                  const Text(
                    'Клик по строке перематывает видео · двойной клик проигрывает сцену · правый клик — действия',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _saveState() {
    if (_sheet.saving) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
          SizedBox(width: 6),
          Text('Сохранение…', style: Cs.small),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const GIcon(GIcons.circleCheck, size: 14, color: Cs.successDot),
        const SizedBox(width: 6),
        Text('Сохранено', style: Cs.small.copyWith(color: Cs.inkFaint)),
      ],
    );
  }
}

String _scenesWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'сцена';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'сцены';
  return 'сцен';
}

String _placesWord(int n) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return 'место';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'места';
  return 'мест';
}

enum _StepState { done, running, active, failed, pending }

class _Step extends StatelessWidget {
  const _Step({
    required this.state,
    required this.title,
    required this.detail,
    required this.time,
    required this.progress,
    required this.last,
    this.extra,
  });

  final _StepState state;
  final String title;
  final String detail;
  final String time;
  final double? progress;
  final bool last;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (state) {
      _StepState.done => (Cs.successSoft, Cs.success, GIcons.check),
      _StepState.running => (Cs.accentSoft, Cs.accentInk, GIcons.rotate),
      _StepState.active => (Cs.accentSoft, Cs.accentInk, GIcons.cloudUp),
      _StepState.failed => (Cs.dangerSoft, Cs.danger, GIcons.xmark),
      _StepState.pending => (Colors.transparent, Cs.inkFaint, null),
    };
    final pending = state == _StepState.pending;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        border: last ? null : const Border(bottom: BorderSide(color: Cs.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: pending ? Border.all(color: Cs.dashed, width: 1.5) : null,
            ),
            alignment: Alignment.center,
            child: icon == null ? null : GIcon(icon, color: fg),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(title, style: Cs.strong.copyWith(color: pending ? Cs.inkFaint : Cs.ink)),
                    ),
                    if (state == _StepState.running && progress != null && progress! > 0)
                      Text(
                        '${(progress! * 100).round()}%',
                        style: Cs.monoText.copyWith(fontSize: 12, color: Cs.accentInk),
                      )
                    else if (time.isNotEmpty)
                      Text(time, style: Cs.monoText.copyWith(fontSize: 12, color: Cs.inkFaint)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: Cs.small.copyWith(
                    color: state == _StepState.failed ? Cs.danger : (pending ? Cs.inkFaint : Cs.inkMuted),
                  ),
                ),
                if (state == _StepState.running) ...[
                  const SizedBox(height: 8),
                  Bar(value: progress != null && progress! > 0 ? progress : null),
                ],
                if (extra != null) ...[const SizedBox(height: 12), extra!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SceneThumb extends StatelessWidget {
  const _SceneThumb({required this.scene, required this.fps});
  final Scene scene;
  final double? fps;

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final url = s.keyframeUrls.firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (url != null)
                  Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFFBDB8B0)),
                  )
                else
                  const ColoredBox(color: Color(0xFFBDB8B0)),
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0xB81C1B19), borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      '${s.index + 1}',
                      style: Cs.monoText.copyWith(fontSize: 11, height: 14 / 11, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(timecode(s.startMs, fps), style: Cs.monoText.copyWith(fontSize: 12, color: Cs.inkFaint)),
            ),
            if (s.shotType != null)
              Text(shotTypeLabels[s.shotType] ?? s.shotType!, style: Cs.caption.copyWith(color: Cs.inkMuted)),
          ],
        ),
      ],
    );
  }
}

/// Полоса-подсказка под шапкой листа.
class _Strip extends StatelessWidget {
  const _Strip({required this.icon, required this.text, this.action, this.onAction});
  final String icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    decoration: const BoxDecoration(
      color: Cs.surfaceMuted,
      border: Border(bottom: BorderSide(color: Cs.divider)),
    ),
    child: Row(
      children: [
        GIcon(icon, color: Cs.inkMuted),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: Cs.small)),
        if (action != null) Btn(action!, kind: BtnKind.ghost, small: true, onPressed: onAction),
      ],
    ),
  );
}

/// Ошибка или предупреждение на всю ширину.
class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, required this.kind});
  final String icon;
  final String text;
  final PillKind kind;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = Pill.colors(kind);
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          GIcon(icon, color: fg),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: Cs.small.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }
}
