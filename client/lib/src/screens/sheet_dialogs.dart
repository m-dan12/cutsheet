import 'package:flutter/material.dart';

import '../models.dart';
import '../sheet_controller.dart';
import '../timecode.dart';
import '../ui/widgets.dart';

/// Действия со строкой: разделить, объединить со следующей, удалить. Общие для правого клика
/// по строке и кнопок над таблицей.
Future<void> splitScene(
  BuildContext context,
  SheetController controller,
  Scene s,
  SceneSheet sheet, {
  int? playerMs,
}) async {
  final at = await showDialog<int>(
    context: context,
    builder: (_) => SplitDialog(scene: s, sheet: sheet, initialMs: playerMs),
  );
  if (at != null) await controller.split(s.id, at);
}

Future<void> deleteScene(BuildContext context, SheetController controller, Scene s) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => CsDialog(
      title: 'Удалить сцену ${s.index + 1}?',
      icon: GIcons.trash,
      width: 440,
      body: const Text('Реплики сцены удалятся вместе с ней.', style: Cs.body),
      actions: [
        Btn('Отмена', kind: BtnKind.ghost, onPressed: () => Navigator.pop(c, false)),
        Btn('Удалить', kind: BtnKind.primary, onPressed: () => Navigator.pop(c, true)),
      ],
    ),
  );
  if (ok == true) await controller.delete(s.id);
}

Future<void> mergeScene(BuildContext context, SheetController controller, Scene s) async {
  if (await controller.mergeWithNext(s.id) && context.mounted) {
    showToast(context, 'Сцены ${s.index + 1} и ${s.index + 2} объединены');
  }
}

Future<void> showRowMenu(
  BuildContext context,
  Offset at, {
  required Scene scene,
  required SceneSheet sheet,
  required SheetController controller,
  int Function()? playerPositionMs,
}) async {
  final s = scene;
  final isLast = s.index == sheet.scenes.length - 1;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  PopupMenuItem<String> item(String value, String icon, String text, {bool enabled = true}) => PopupMenuItem(
    value: value,
    enabled: enabled,
    height: 36,
    child: Row(
      children: [
        GIcon(icon, color: enabled ? Cs.inkMuted : Cs.dashed),
        const SizedBox(width: 10),
        Text(text, style: Cs.body.copyWith(color: enabled ? Cs.ink : Cs.inkFaint)),
      ],
    ),
  );
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      item('split', GIcons.scissors, 'Разделить…'),
      item('merge', GIcons.merge, 'Объединить со следующей', enabled: !isLast),
      item('delete', GIcons.trash, 'Удалить'),
    ],
  );
  if (!context.mounted) return;
  switch (action) {
    case 'split':
      await splitScene(context, controller, s, sheet, playerMs: playerPositionMs?.call());
    case 'merge':
      await mergeScene(context, controller, s);
    case 'delete':
      await deleteScene(context, controller, s);
  }
}

/// Разделение сцены (FR-C6): точка по кадрам, шаг ±1 кадр, предпросмотр двух получившихся строк.
/// Начальная точка — позиция плеера, если она внутри сцены, иначе середина.
class SplitDialog extends StatefulWidget {
  const SplitDialog({super.key, required this.scene, required this.sheet, this.initialMs});
  final Scene scene;
  final SceneSheet sheet;
  final int? initialMs;

  @override
  State<SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<SplitDialog> {
  late int _at;
  late final _text = TextEditingController();
  String? _error;

  Scene get s => widget.scene;
  double get _frameMs => 1000 / ((widget.sheet.fps ?? 0) > 0 ? widget.sheet.fps! : 25);

  @override
  void initState() {
    super.initState();
    final p = widget.initialMs;
    _set(p != null && p > s.startMs && p < s.endMs ? p : (s.startMs + s.endMs) ~/ 2);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool _valid(int ms) => ms > s.startMs && ms < s.endMs;

  void _set(int ms) {
    _at = ms.clamp(s.startMs + 1, s.endMs - 1);
    _text.text = timecode(_at, widget.sheet.fps);
    _error = null;
  }

  void _step(int frames) => setState(() => _set(_at + (frames * _frameMs).round()));

  void _typed(String v) {
    final ms = parseTimecode(v, widget.sheet.fps);
    setState(() {
      if (ms == null) {
        _error = 'ЧЧ:ММ:СС:КК';
      } else if (!_valid(ms)) {
        _error = 'Точка должна быть внутри сцены';
      } else {
        _at = ms;
        _error = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final fps = widget.sheet.fps;
    final frac = (_at - s.startMs) / (s.endMs - s.startMs);
    final first = s.replicas.where((r) => (r.startMs ?? 0) < _at).map((r) => r.line).join(' ');
    final second = s.replicas.where((r) => (r.startMs ?? 0) >= _at).map((r) => r.line).join(' ');
    final keyframe = s.keyframeUrls.firstOrNull;
    return CsDialog(
      title: 'Разделить сцену ${s.index + 1}',
      icon: GIcons.scissors,
      width: 520,
      actions: [
        Btn('Отмена', kind: BtnKind.ghost, onPressed: () => Navigator.pop(context)),
        Btn('Разделить', kind: BtnKind.primary, onPressed: _error == null ? () => Navigator.pop(context, _at) : null),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (keyframe != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  keyframe,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const ColoredBox(color: Cs.stageInner),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          LayoutBuilder(
            builder: (context, c) {
              void pick(double dx) =>
                  setState(() => _set(s.startMs + ((dx / c.maxWidth).clamp(0, 1) * (s.endMs - s.startMs)).round()));
              return GestureDetector(
                onTapDown: (d) => pick(d.localPosition.dx),
                onHorizontalDragUpdate: (d) => pick(d.localPosition.dx),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: SizedBox(
                    height: 36,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  flex: (frac * 1000).round().clamp(1, 999),
                                  child: const ColoredBox(color: Cs.accentSoft),
                                ),
                                Expanded(
                                  flex: 1000 - (frac * 1000).round().clamp(1, 999),
                                  child: const ColoredBox(color: Color(0xFFF5F0E4)),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: c.maxWidth * frac - 1,
                          top: -2,
                          bottom: -2,
                          child: Container(width: 2, color: Cs.accent),
                        ),
                        Positioned(
                          left: c.maxWidth * frac - 7,
                          top: -1,
                          child: Container(
                            width: 14,
                            height: 10,
                            decoration: BoxDecoration(color: Cs.accent, borderRadius: BorderRadius.circular(3)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const CapsLabel('Точка разделения'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _text,
                      style: Cs.monoText,
                      onChanged: _typed,
                      decoration: InputDecoration(errorText: _error),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const CapsLabel('Шаг'),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Btn('−1 кадр', small: true, onPressed: () => _step(-1)),
                      const SizedBox(width: 6),
                      Btn('+1 кадр', small: true, onPressed: () => _step(1)),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Cs.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _part(s.index + 1, s.startMs, _at, first, fps),
                const Divider(height: 1),
                _part(s.index + 2, _at, s.endMs, second, fps),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Реплики распределятся по времени. План и описание новой сцены пересчитаются автоматически.',
            style: Cs.caption,
          ),
        ],
      ),
    );
  }

  Widget _part(int n, int from, int to, String lines, double? fps) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Text('$n', style: Cs.monoText.copyWith(color: Cs.accentInk)),
        ),
        SizedBox(
          width: 200,
          child: Text('${timecode(from, fps)} → ${timecode(to, fps).substring(6)}', style: Cs.monoText),
        ),
        Expanded(
          child: Text(lines.isEmpty ? '—' : lines, style: Cs.small, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
}

/// Конфликт версий (FR-G5): строку изменили в другом окне или повторной обработкой, правка не
/// сохранена. Пользователь выбирает, какую версию оставить; true — сохранить свою.
class ConflictDialog extends StatefulWidget {
  const ConflictDialog({super.key, required this.current, required this.changes, required this.fps});
  final Scene current;
  final Map<String, Object?> changes;
  final double? fps;

  @override
  State<ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictDialog> {
  bool _mine = true;

  String _show(String field, Object? v) => switch (field) {
    'shot_type' => v == null ? '—' : shotTypeLabels[v] ?? '$v',
    'start_ms' || 'end_ms' => v is int ? timecode(v, widget.fps) : '—',
    _ => v == null || '$v'.isEmpty ? '—' : '$v',
  };

  Object? _saved(String field) => switch (field) {
    'shot_type' => widget.current.shotType,
    'description' => widget.current.description,
    'start_ms' => widget.current.startMs,
    'end_ms' => widget.current.endMs,
    _ => null,
  };

  String _describe(bool mine) =>
      widget.changes.entries.map((e) => _show(e.key, mine ? e.value : _saved(e.key))).join(' · ');

  @override
  Widget build(BuildContext context) {
    Widget option(bool mine, String label) {
      final on = _mine == mine;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _mine = mine),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFF6F8FE) : null,
            border: Border.all(color: on ? Cs.accent : Cs.border, width: on ? 1.5 : 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 18,
                  color: on ? Cs.accent : Cs.dashed,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CapsLabel(label, color: mine ? Cs.accentInk : null),
                    const SizedBox(height: 2),
                    Text(_describe(mine), style: Cs.body),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return CsDialog(
      title: 'Сцену ${widget.current.index + 1} изменили в другом окне',
      subtitle: 'Ваша правка не сохранена. Выберите, какую версию оставить.',
      icon: GIcons.warn,
      iconTone: PillKind.warn,
      width: 480,
      actions: [
        Btn('Отмена', kind: BtnKind.ghost, onPressed: () => Navigator.pop(context, false)),
        Btn('Сохранить выбор', kind: BtnKind.primary, onPressed: () => Navigator.pop(context, _mine)),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [option(true, 'Ваша версия'), const SizedBox(height: 10), option(false, 'Сохранённая')],
      ),
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
    return CsDialog(
      title: 'Диалоги · сцена ${s.index + 1}',
      subtitle: '${timecode(s.startMs, widget.sheet.fps)} → ${timecode(s.endMs, widget.sheet.fps)}',
      icon: GIcons.pencil,
      width: 760,
      footerNote: 'Enter в поле текста — новая строка; роли подсказываются из сценария.',
      actions: [
        Btn('Отмена', kind: BtnKind.ghost, onPressed: _saving ? null : () => Navigator.pop(context)),
        Btn('Сохранить', kind: BtnKind.primary, onPressed: _saving ? null : _save),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_drafts.isEmpty) Text('Реплик пока нет.', style: Cs.body.copyWith(color: Cs.inkMuted)),
          for (final (i, d) in _drafts.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 150, child: _roleField(d)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: d.text,
                      enabled: !d.reset.contains('text'),
                      minLines: 1,
                      maxLines: 4,
                      style: Cs.body,
                      decoration: InputDecoration(
                        hintText: 'Текст реплики',
                        helperText: d.reset.contains('text')
                            ? 'Будет возвращён текст из автоматики'
                            : d.source?.spokenText != null && d.source!.spokenText != d.source!.text
                            ? 'Сказано: ${d.source!.spokenText}'
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (d.source?.edited.contains('text') ?? false)
                    IconBtn(
                      GIcons.reset,
                      tooltip: 'Вернуть текст из автоматики',
                      color: d.reset.contains('text') ? Cs.accent : null,
                      onPressed: () =>
                          setState(() => d.reset.contains('text') ? d.reset.remove('text') : d.reset.add('text')),
                    ),
                  IconBtn(
                    GIcons.arrowUp,
                    tooltip: 'Выше',
                    onPressed: i == 0 ? null : () => setState(() => _drafts.insert(i - 1, _drafts.removeAt(i))),
                  ),
                  PopupMenuButton<int>(
                    tooltip: 'Перенести в другую сцену',
                    enabled: d.source?.id != null && !_saving,
                    icon: GIcon(GIcons.move, color: d.source?.id != null ? Cs.inkMuted : Cs.dashed),
                    onSelected: (delta) => _move(d, delta),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: -1, enabled: s.index > 0, child: const Text('В предыдущую сцену')),
                      PopupMenuItem(value: 1, enabled: s.index < last, child: const Text('В следующую сцену')),
                    ],
                  ),
                  IconBtn(
                    GIcons.trash,
                    tooltip: 'Удалить реплику',
                    onPressed: () => setState(() => _drafts.removeAt(i)),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Btn(
              'Реплика',
              icon: GIcons.plus,
              kind: BtnKind.ghost,
              small: true,
              onPressed: () => setState(() => _drafts.add(_Draft(null, null, ''))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roleField(_Draft d) => RawAutocomplete<String>(
    textEditingController: d.role,
    focusNode: d.roleFocus,
    optionsBuilder: (v) => widget.sheet.roles.where((r) => r.toLowerCase().startsWith(v.text.toLowerCase())),
    fieldViewBuilder: (context, controller, focus, _) => TextField(
      controller: controller,
      focusNode: focus,
      style: Cs.strong.copyWith(fontSize: 12, letterSpacing: 0.5),
      textCapitalization: TextCapitalization.characters,
      decoration: const InputDecoration(hintText: 'РОЛЬ'),
    ),
    optionsViewBuilder: (context, onSelected, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 6,
        color: Cs.surface,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220, maxWidth: 220),
          child: ListView(
            padding: const EdgeInsets.all(4),
            shrinkWrap: true,
            children: [
              for (final o in options)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onSelected(o),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Text(o, style: Cs.body),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
