import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../sheet_controller.dart';
import '../timecode.dart';

/// Таблица монтажного листа (FR-C4): №, начало, конец, план, описание, диалоги. Ячейки
/// редактируются на месте и сохраняются сами (FR-C5, FR-C11); правки человека помечены, к
/// авто-значению можно вернуться (FR-C9); сомнительные авто-результаты подсвечены (FR-C8).
class SheetTable extends StatelessWidget {
  const SheetTable({
    super.key,
    required this.controller,
    this.selectedId,
    this.onSelect,
    this.onPlay,
    this.playerPositionMs,
  });

  final SheetController controller;
  final String? selectedId;
  final void Function(Scene scene)? onSelect;
  final void Function(Scene scene)? onPlay;

  /// Позиция плеера для «Разрезать по позиции плеера»; null — плеера нет.
  final int Function()? playerPositionMs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sheet = controller.sheet;
        if (sheet == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                itemCount: sheet.scenes.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final s = sheet.scenes[i];
                  return SceneRowView(
                    key: ValueKey(s.id),
                    scene: s,
                    sheet: sheet,
                    controller: controller,
                    selected: s.id == selectedId,
                    onSelect: onSelect,
                    onPlay: onPlay,
                    playerPositionMs: playerPositionMs,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

const _wNumber = 56.0;
const _wTime = 120.0;
const _wShot = 150.0;
const _wActions = 88.0;

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    Widget cell(String text, [double? width]) => width == null
        ? Expanded(child: Text(text, style: style))
        : SizedBox(width: width, child: Text(text, style: style));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        cell('№', _wNumber),
        cell('Начало', _wTime),
        cell('Конец', _wTime),
        cell('План', _wShot),
        cell('Описание'),
        const SizedBox(width: 12),
        cell('Диалоги'),
        const SizedBox(width: _wActions),
      ]),
    );
  }
}

/// Одна строка листа.
class SceneRowView extends StatelessWidget {
  const SceneRowView({
    super.key,
    required this.scene,
    required this.sheet,
    required this.controller,
    this.selected = false,
    this.onSelect,
    this.onPlay,
    this.playerPositionMs,
  });

  final Scene scene;
  final SceneSheet sheet;
  final SheetController controller;
  final bool selected;
  final void Function(Scene scene)? onSelect;
  final void Function(Scene scene)? onPlay;
  final int Function()? playerPositionMs;

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final ro = controller.readOnly;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : Colors.transparent,
      child: InkWell(
        onTap: () => onSelect?.call(s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _wNumber,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(children: [
                    Text('${s.index + 1}', style: Theme.of(context).textTheme.titleMedium),
                    if (s.origin == 'user')
                      const Tooltip(message: 'Строка добавлена вручную', child: Icon(Icons.person, size: 14)),
                    if (s.needsEnrichment)
                      const Tooltip(
                        message: 'Границы изменены вручную: план и описание могут не соответствовать новым границам',
                        child: Icon(Icons.warning_amber, size: 14, color: Colors.orange),
                      ),
                  ]),
                ),
              ),
              SizedBox(
                width: _wTime,
                child: TimecodeField(
                  ms: s.startMs,
                  fps: sheet.fps,
                  edited: s.isEdited('start_ms'),
                  enabled: !ro,
                  onCommit: (ms) => controller.patch(s.id, {'start_ms': ms}),
                ),
              ),
              SizedBox(
                width: _wTime,
                child: TimecodeField(
                  ms: s.endMs,
                  fps: sheet.fps,
                  edited: s.isEdited('end_ms'),
                  enabled: !ro,
                  onCommit: (ms) => controller.patch(s.id, {'end_ms': ms}),
                ),
              ),
              SizedBox(width: _wShot, child: _ShotTypeCell(scene: s, sheet: sheet, controller: controller)),
              Expanded(child: _DescriptionCell(scene: s, controller: controller)),
              const SizedBox(width: 12),
              Expanded(child: _DialogueCell(scene: s, sheet: sheet, controller: controller)),
              SizedBox(
                width: _wActions,
                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (onPlay != null)
                    IconButton(
                      tooltip: 'Воспроизвести сцену',
                      icon: const Icon(Icons.play_circle_outline),
                      onPressed: () => onPlay!(s),
                    ),
                  if (!ro) _RowMenu(scene: s, sheet: sheet, controller: controller, playerPositionMs: playerPositionMs),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Отметка «изменено вручную» с подсказкой авто-значения и кнопкой сброса (FR-C9, ТЗ 6.2).
class EditedMark extends StatelessWidget {
  const EditedMark({super.key, required this.autoText, this.differs = false, this.onReset});

  /// Что предлагала автоматика; null — авто-значения нет.
  final String? autoText;
  final bool differs;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final color = differs ? Colors.orange : Theme.of(context).colorScheme.tertiary;
    final tip = StringBuffer(differs ? 'Изменено вручную, автоматика теперь предлагает другое' : 'Изменено вручную');
    if (autoText != null) tip.write('\nАвто: $autoText');
    if (onReset != null) tip.write('\nНажмите, чтобы вернуть авто-значение');
    return Tooltip(
      message: tip.toString(),
      child: InkWell(
        onTap: onReset,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(onReset == null ? Icons.edit : Icons.settings_backup_restore, size: 16, color: color),
        ),
      ),
    );
  }
}

/// Поле таймкода `ЧЧ:ММ:СС:КК`; сохраняется по Enter или потере фокуса.
class TimecodeField extends StatefulWidget {
  const TimecodeField({
    super.key,
    required this.ms,
    required this.fps,
    required this.onCommit,
    this.edited = false,
    this.enabled = true,
  });

  final int ms;
  final double? fps;
  final bool edited;
  final bool enabled;
  final Future<bool> Function(int ms) onCommit;

  @override
  State<TimecodeField> createState() => _TimecodeFieldState();
}

class _TimecodeFieldState extends State<TimecodeField> {
  late final _text = TextEditingController(text: timecode(widget.ms, widget.fps));
  final _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(TimecodeField old) {
    super.didUpdateWidget(old);
    if (old.ms != widget.ms && !_focus.hasFocus) _text.text = timecode(widget.ms, widget.fps);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _commit() async {
    final ms = parseTimecode(_text.text, widget.fps);
    if (ms == null) {
      setState(() => _error = 'ЧЧ:ММ:СС:КК');
      return;
    }
    setState(() => _error = null);
    if (timecode(ms, widget.fps) == timecode(widget.ms, widget.fps)) return;
    if (!await widget.onCommit(ms) && mounted) _text.text = timecode(widget.ms, widget.fps);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      focusNode: _focus,
      enabled: widget.enabled,
      onSubmitted: (_) => _commit(),
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        errorText: _error,
        suffixIcon: widget.edited ? const EditedMark(autoText: null) : null,
        suffixIconConstraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      ),
    );
  }
}

class _ShotTypeCell extends StatelessWidget {
  const _ShotTypeCell({required this.scene, required this.sheet, required this.controller});
  final Scene scene;
  final SceneSheet sheet;
  final SheetController controller;

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final auto = s.auto['shot_type'];
    final autoText = auto?.value is String ? shotTypeLabels[auto!.value] ?? '${auto.value}' : null;
    final low = s.lowConfidence('shot_type');
    return Container(
      decoration: low ? _lowConfidence : null,
      child: Row(children: [
        Expanded(
          child: Tooltip(
            message: low ? 'Автоматика не уверена (${_percent(auto?.confidence)})' : '',
            child: DropdownButton<String?>(
              value: s.shotType,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              hint: const Text('—'),
              items: [
                for (final code in sheet.shotTypes)
                  DropdownMenuItem(value: code, child: Text(shotTypeLabels[code] ?? code)),
              ],
              onChanged: controller.readOnly ? null : (v) => controller.patch(s.id, {'shot_type': v}),
            ),
          ),
        ),
        if (s.isEdited('shot_type'))
          EditedMark(
            autoText: autoText,
            differs: s.autoDiffers('shot_type'),
            onReset: controller.readOnly ? null : () => controller.reset(s.id, 'shot_type'),
          ),
      ]),
    );
  }
}

/// Описание: многострочное поле; сохраняется при потере фокуса и через секунду после ввода.
class _DescriptionCell extends StatefulWidget {
  const _DescriptionCell({required this.scene, required this.controller});
  final Scene scene;
  final SheetController controller;

  @override
  State<_DescriptionCell> createState() => _DescriptionCellState();
}

class _DescriptionCellState extends State<_DescriptionCell> {
  late final _text = TextEditingController(text: widget.scene.description ?? '');
  final _focus = FocusNode();
  Timer? _debounce;
  String _saved = '';

  @override
  void initState() {
    super.initState();
    _saved = _text.text;
    _focus.addListener(() {
      if (!_focus.hasFocus) _save();
    });
  }

  @override
  void didUpdateWidget(_DescriptionCell old) {
    super.didUpdateWidget(old);
    final fresh = widget.scene.description ?? '';
    if (fresh != _saved && !_focus.hasFocus) {
      _text.text = fresh;
      _saved = fresh;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_text.text != _saved) _save();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), _save);
  }

  void _save() {
    _debounce?.cancel();
    final text = _text.text.trim();
    if (text == _saved.trim()) return;
    _saved = _text.text;
    widget.controller.patch(widget.scene.id, {'description': text.isEmpty ? null : text});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scene;
    final auto = s.auto['description'];
    final low = s.lowConfidence('description');
    return Container(
      decoration: low ? _lowConfidence : null,
      child: TextField(
        controller: _text,
        focusNode: _focus,
        enabled: !widget.controller.readOnly,
        minLines: 1,
        maxLines: 4,
        onChanged: _onChanged,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: s.status == 'detected' ? 'Описание появится после обогащения' : 'Описание',
          helperText: low ? 'Автоматика не уверена (${_percent(auto?.confidence)})' : null,
          suffixIcon: s.isEdited('description')
              ? EditedMark(
                  autoText: auto?.value as String?,
                  differs: s.autoDiffers('description'),
                  onReset: widget.controller.readOnly ? null : () => widget.controller.reset(s.id, 'description'),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(minWidth: 20, minHeight: 20),
        ),
      ),
    );
  }
}

class _DialogueCell extends StatelessWidget {
  const _DialogueCell({required this.scene, required this.sheet, required this.controller});
  final Scene scene;
  final SceneSheet sheet;
  final SheetController controller;

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final theme = Theme.of(context);
    return InkWell(
      onTap: controller.readOnly
          ? null
          : () => showDialog<void>(
                context: context,
                builder: (_) => ReplicasDialog(scene: s, sheet: sheet, controller: controller),
              ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: s.replicas.isEmpty
            ? Text(controller.readOnly ? '' : 'Добавить реплику', style: TextStyle(color: theme.hintColor))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in s.replicas)
                    Tooltip(
                      message: !r.matched && r.origin == 'auto'
                          ? 'Реплика не найдена в сценарии${r.role == null ? ', говорящий не определён' : ''}'
                          : '',
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                            text: r.role == null ? '?: ' : '${r.role}: ',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: r.text),
                          if (r.edited.isNotEmpty) const TextSpan(text: ' ✎'),
                        ]),
                        style: !r.matched && r.origin == 'auto'
                            ? TextStyle(color: Colors.orange.shade800, fontStyle: FontStyle.italic)
                            : null,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.scene, required this.sheet, required this.controller, this.playerPositionMs});
  final Scene scene;
  final SceneSheet sheet;
  final SheetController controller;
  final int Function()? playerPositionMs;

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final at = playerPositionMs?.call();
    final atInside = at != null && at > s.startMs && at < s.endMs;
    final isLast = s.index == sheet.scenes.length - 1;
    return PopupMenuButton<String>(
      tooltip: 'Действия со строкой',
      onSelected: (action) async {
        switch (action) {
          case 'split-player':
            await controller.split(s.id, at!);
          case 'split-middle':
            await controller.split(s.id, (s.startMs + s.endMs) ~/ 2);
          case 'merge':
            await controller.mergeWithNext(s.id);
          case 'delete':
            if (!context.mounted) return;
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text('Удалить строку ${s.index + 1}?'),
                content: const Text('Реплики строки удалятся вместе с ней.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
                ],
              ),
            );
            if (ok == true) await controller.delete(s.id);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'split-player',
          enabled: atInside,
          child: Text(atInside ? 'Разрезать на ${timecode(at, sheet.fps)}' : 'Разрезать по позиции плеера'),
        ),
        const PopupMenuItem(value: 'split-middle', child: Text('Разрезать посередине')),
        PopupMenuItem(value: 'merge', enabled: !isLast, child: const Text('Объединить со следующей')),
        const PopupMenuItem(value: 'delete', child: Text('Удалить строку')),
      ],
    );
  }
}

/// Правка реплик строки (FR-C5): роль, текст, порядок, добавление, удаление, перенос в соседнюю строку.
class ReplicasDialog extends StatefulWidget {
  const ReplicasDialog({super.key, required this.scene, required this.sheet, required this.controller});
  final Scene scene;
  final SceneSheet sheet;
  final SheetController controller;

  @override
  State<ReplicasDialog> createState() => _ReplicasDialogState();
}

class _Draft {
  _Draft(this.source, String? role, String text)
      : role = TextEditingController(text: role ?? ''),
        text = TextEditingController(text: text);
  final Replica? source;
  final TextEditingController role;
  final TextEditingController text;
  final FocusNode roleFocus = FocusNode();
  final Set<String> reset = {};
}

class _ReplicasDialogState extends State<ReplicasDialog> {
  late final List<_Draft> _drafts = [for (final r in widget.scene.replicas) _Draft(r, r.role, r.text)];
  bool _saving = false;

  @override
  void dispose() {
    for (final d in _drafts) {
      d.role.dispose();
      d.text.dispose();
      d.roleFocus.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final items = [
      for (final d in _drafts)
        if (d.text.text.trim().isNotEmpty)
          {
            if (d.source?.id != null) 'id': d.source!.id,
            'role': d.role.text.trim().isEmpty ? null : d.role.text.trim(),
            'text': d.text.text.trim(),
            if (d.reset.isNotEmpty) 'reset': d.reset.toList(),
          },
    ];
    final ok = await widget.controller.putReplicas(widget.scene.id, items);
    if (mounted) {
      setState(() => _saving = false);
      if (ok) Navigator.pop(context);
    }
  }

  Future<void> _move(_Draft d, int delta) async {
    setState(() => _saving = true);
    final ok = await widget.controller.moveReplica(widget.scene.id, d.source!.id!, delta);
    if (mounted) {
      setState(() => _saving = false);
      if (ok) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scene;
    final last = widget.sheet.scenes.length - 1;
    return AlertDialog(
      title: Text('Реплики строки ${s.index + 1}'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, d) in _drafts.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      width: 170,
                      child: RawAutocomplete<String>(
                        textEditingController: d.role,
                        focusNode: d.roleFocus,
                        optionsBuilder: (v) => widget.sheet.roles
                            .where((r) => r.toLowerCase().startsWith(v.text.toLowerCase())),
                        fieldViewBuilder: (context, controller, focus, _) => TextField(
                          controller: controller,
                          focusNode: focus,
                          decoration: const InputDecoration(labelText: 'Роль', isDense: true),
                        ),
                        optionsViewBuilder: (context, onSelected, options) => Align(
                          alignment: Alignment.topLeft,
                          child: Material(
                            elevation: 4,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 220),
                              child: ListView(
                                shrinkWrap: true,
                                children: [
                                  for (final o in options) ListTile(dense: true, title: Text(o), onTap: () => onSelected(o)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: d.text,
                        enabled: !d.reset.contains('text'),
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: 'Текст',
                          isDense: true,
                          helperText: d.reset.contains('text')
                              ? 'Будет возвращён текст из автоматики'
                              : d.source?.spokenText != null && d.source!.spokenText != d.source!.text
                                  ? 'Сказано: ${d.source!.spokenText}'
                                  : null,
                        ),
                      ),
                    ),
                    if (d.source?.edited.contains('text') ?? false)
                      IconButton(
                        tooltip: 'Вернуть текст из автоматики',
                        icon: const Icon(Icons.settings_backup_restore),
                        onPressed: () => setState(() => d.reset.contains('text') ? d.reset.remove('text') : d.reset.add('text')),
                      ),
                    IconButton(
                      tooltip: 'Выше',
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: i == 0 ? null : () => setState(() => _drafts.insert(i - 1, _drafts.removeAt(i))),
                    ),
                    PopupMenuButton<int>(
                      tooltip: 'Перенести',
                      enabled: d.source?.id != null && !_saving,
                      icon: const Icon(Icons.drive_file_move_outline),
                      onSelected: (delta) => _move(d, delta),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: -1, enabled: s.index > 0, child: const Text('В предыдущую строку')),
                        PopupMenuItem(value: 1, enabled: s.index < last, child: const Text('В следующую строку')),
                      ],
                    ),
                    IconButton(
                      tooltip: 'Удалить реплику',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => _drafts.removeAt(i)),
                    ),
                  ]),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _drafts.add(_Draft(null, null, ''))),
                  icon: const Icon(Icons.add),
                  label: const Text('Добавить реплику'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: _saving ? null : _save, child: const Text('Сохранить')),
      ],
    );
  }
}

const _lowConfidence = BoxDecoration(color: Color(0x33FFC107), borderRadius: BorderRadius.all(Radius.circular(4)));

String _percent(double? c) => c == null ? '?' : '${(c * 100).round()} %';
