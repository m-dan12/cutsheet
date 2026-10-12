import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../sheet_controller.dart';
import '../timecode.dart';
import '../ui/widgets.dart';
import 'sheet_dialogs.dart';

/// Фильтр строк над таблицей: все, требующие проверки, изменённые человеком.
enum SheetFilter { all, review, edited }

/// Строку стоит проверить (FR-C8): автоматика не уверена, реплика не найдена в сценарии
/// или границы менял человек и план с описанием могли устареть.
bool needsReview(Scene s) =>
    s.lowConfidence('shot_type') ||
    s.lowConfidence('description') ||
    s.needsEnrichment ||
    s.replicas.any((r) => r.origin == 'auto' && !r.matched);

/// Строку правил человек (FR-C9).
bool editedByUser(Scene s) => s.edited.isNotEmpty || s.origin == 'user' || s.replicas.any((r) => r.edited.isNotEmpty);

bool matchesFilter(Scene s, SheetFilter f, String query) {
  final ok = switch (f) {
    SheetFilter.all => true,
    SheetFilter.review => needsReview(s),
    SheetFilter.edited => editedByUser(s),
  };
  if (!ok || query.isEmpty) return ok;
  final q = query.toLowerCase();
  return (s.description ?? '').toLowerCase().contains(q) ||
      s.replicas.any((r) => r.line.toLowerCase().contains(q)) ||
      '${s.index + 1}' == q;
}

/// Таблица монтажного листа (FR-C4): №, начало, конец, план, описание, диалоги. Ячейки
/// редактируются на месте и сохраняются сами (FR-C5, FR-C11); правки человека помечены синим,
/// к авто-значению можно вернуться (FR-C9); сомнительные авто-результаты подсвечены янтарным (FR-C8).
class SheetTable extends StatelessWidget {
  const SheetTable({
    super.key,
    required this.controller,
    this.selectedId,
    this.onSelect,
    this.onPlay,
    this.playerPositionMs,
    this.filter = SheetFilter.all,
    this.query = '',
  });

  final SheetController controller;
  final String? selectedId;
  final void Function(Scene scene)? onSelect;
  final void Function(Scene scene)? onPlay;

  /// Позиция плеера для «Разделить по позиции плеера»; null — плеера нет.
  final int Function()? playerPositionMs;
  final SheetFilter filter;
  final String query;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final sheet = controller.sheet;
        if (sheet == null) return const SizedBox.shrink();
        final rows = sheet.scenes.where((s) => matchesFilter(s, filter, query)).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Header(),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text('Нет строк под этот фильтр', style: Cs.body.copyWith(color: Cs.inkMuted)),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final s = rows[i];
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

const _wNumber = 52.0;
const _wTime = 124.0;
const _wShot = 136.0;
const _descFlex = 3;
const _dialogueFlex = 2;

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    Widget cell(String text) => Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: CapsLabel(text));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        color: Cs.surfaceMuted,
        border: Border(bottom: BorderSide(color: Cs.border)),
      ),
      child: Row(
        children: [
          SizedBox(width: _wNumber, child: cell('№')),
          SizedBox(width: _wTime, child: cell('Начало')),
          SizedBox(width: _wTime, child: cell('Конец')),
          SizedBox(width: _wShot, child: cell('План')),
          Expanded(flex: _descFlex, child: cell('Описание')),
          Expanded(flex: _dialogueFlex, child: cell('Диалоги')),
        ],
      ),
    );
  }
}

/// Синяя точка «изменено вами» в углу ячейки.
class EditDot extends StatelessWidget {
  const EditDot({super.key, this.tooltip = 'Изменено вами'});
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(message: tooltip, child: const Dot(Cs.accent, size: 7));
}

/// Ячейка таблицы: отступы и синяя точка при правке (янтарный фон рисует строка).
class _Cell extends StatelessWidget {
  const _Cell({required this.child, this.edited = false, this.editedTip, this.horizontal = 12});
  final Widget child;
  final bool edited;
  final String? editedTip;
  final double horizontal;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(horizontal, 8, horizontal, 8),
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (edited) Positioned(top: 0, right: -4, child: EditDot(tooltip: editedTip ?? 'Изменено вами')),
      ],
    ),
  );
}

/// Одна строка листа. Клик выделяет строку и перематывает плеер, правый клик — действия со строкой.
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
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (e.buttons == kPrimaryButton && !selected) onSelect?.call(s);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: onPlay == null ? null : () => onPlay!(s),
        onSecondaryTapDown: ro
            ? null
            : (d) {
                onSelect?.call(s);
                showRowMenu(
                  context,
                  d.globalPosition,
                  scene: s,
                  sheet: sheet,
                  controller: controller,
                  playerPositionMs: playerPositionMs,
                );
              },
        child: Container(
          decoration: BoxDecoration(
            color: selected ? Cs.accentSoft : null,
            border: const Border(bottom: BorderSide(color: Cs.divider)),
          ),
          child: Stack(
            children: [
              // Янтарный фон ячеек с низкой уверенностью на всю высоту строки.
              Positioned.fill(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(width: _wNumber + 2 * _wTime),
                    SizedBox(
                      width: _wShot,
                      child: ColoredBox(color: s.lowConfidence('shot_type') ? Cs.warnSoft : Colors.transparent),
                    ),
                    Expanded(
                      flex: _descFlex,
                      child: ColoredBox(color: s.lowConfidence('description') ? Cs.warnSoft : Colors.transparent),
                    ),
                    const Expanded(flex: _dialogueFlex, child: SizedBox.shrink()),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _wNumber,
                    child: _NumberCell(scene: s, selected: selected),
                  ),
                  SizedBox(
                    width: _wTime,
                    child: _Cell(
                      horizontal: 6,
                      edited: s.isEdited('start_ms'),
                      child: TimecodeField(
                        ms: s.startMs,
                        fps: sheet.fps,
                        enabled: !ro,
                        onCommit: (ms) => controller.patch(s.id, {'start_ms': ms}),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _wTime,
                    child: _Cell(
                      horizontal: 6,
                      edited: s.isEdited('end_ms'),
                      child: TimecodeField(
                        ms: s.endMs,
                        fps: sheet.fps,
                        enabled: !ro,
                        onCommit: (ms) => controller.patch(s.id, {'end_ms': ms}),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _wShot,
                    child: _ShotTypeCell(scene: s, sheet: sheet, controller: controller),
                  ),
                  Expanded(
                    flex: _descFlex,
                    child: _DescriptionCell(scene: s, controller: controller),
                  ),
                  Expanded(
                    flex: _dialogueFlex,
                    child: _DialogueCell(scene: s, sheet: sheet, controller: controller),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NumberCell extends StatelessWidget {
  const _NumberCell({required this.scene, required this.selected});
  final Scene scene;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final s = scene;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${s.index + 1}', style: Cs.monoText.copyWith(color: selected ? Cs.accentInk : Cs.inkFaint)),
          const SizedBox(height: 4),
          if (s.origin == 'user')
            const Tooltip(
              message: 'Строка добавлена вручную',
              child: GIcon(GIcons.pencil, size: 12, color: Cs.accent),
            ),
          if (s.needsEnrichment)
            const Tooltip(
              message: 'Границы изменены вручную: план и описание могут не соответствовать новым границам',
              child: GIcon(GIcons.warn, size: 12, color: Cs.warn),
            ),
        ],
      ),
    );
  }
}

/// Отметка «Изменено вами · Вернуть авто» под ячейкой (FR-C9, ТЗ 6.2).
class EditedMark extends StatelessWidget {
  const EditedMark({super.key, required this.autoText, this.differs = false, this.onReset});

  /// Что предлагала автоматика; null — авто-значения нет.
  final String? autoText;
  final bool differs;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final tip = StringBuffer(differs ? 'Автоматика теперь предлагает другое' : 'Значение изменено вручную');
    if (autoText != null) tip.write('\nАвто: $autoText');
    const style = TextStyle(fontFamily: Cs.sans, fontSize: 12, height: 16 / 12, color: Cs.accentInk);
    return Tooltip(
      message: tip.toString(),
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            const GIcon(GIcons.pencil, size: 12, color: Cs.accentInk),
            const SizedBox(width: 6),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: differs ? 'Изменено вами · авто предлагает другое' : 'Изменено вами'),
                    if (onReset != null) ...[
                      const TextSpan(text: ' · '),
                      TextSpan(
                        text: 'Вернуть авто',
                        style: const TextStyle(decoration: TextDecoration.underline, decorationColor: Cs.accentInk),
                        recognizer: TapGestureRecognizer()..onTap = onReset,
                        mouseCursor: SystemMouseCursors.click,
                      ),
                    ],
                  ],
                ),
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка-предупреждение под ячейкой: модель не уверена.
class LowConfidenceNote extends StatelessWidget {
  const LowConfidenceNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      children: [
        const GIcon(GIcons.warn, size: 12, color: Cs.warn),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontFamily: Cs.sans, fontSize: 12, height: 16 / 12, color: Cs.warn),
          ),
        ),
      ],
    ),
  );
}

/// Поле таймкода `ЧЧ:ММ:СС:КК`; сохраняется по Enter или потере фокуса.
class TimecodeField extends StatefulWidget {
  const TimecodeField({super.key, required this.ms, required this.fps, required this.onCommit, this.enabled = true});

  final int ms;
  final double? fps;
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
      if (mounted) setState(() {});
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
      style: Cs.monoText,
      decoration: _inlineDecoration(focused: _focus.hasFocus).copyWith(errorText: _error),
    );
  }
}

/// Поле внутри ячейки: без рамки, при фокусе — синяя рамка и мягкое свечение.
InputDecoration _inlineDecoration({bool focused = false, String? hint}) => InputDecoration(
  isDense: true,
  filled: focused,
  fillColor: Cs.surface,
  hintText: hint,
  contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(color: Cs.accent),
  ),
);

const _resetValue = '__auto__';

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
    final edited = s.isEdited('shot_type');
    final color = low ? Cs.warn : Cs.ink;
    return _Cell(
      edited: edited,
      editedTip: autoText == null ? null : 'Изменено вами · авто: $autoText',
      child: Tooltip(
        message: low ? 'Модель не уверена в плане (${percent(auto?.confidence)})' : '',
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: s.shotType,
            isExpanded: true,
            isDense: true,
            borderRadius: BorderRadius.circular(12),
            dropdownColor: Cs.surface,
            icon: const GIcon(GIcons.chevronDown, size: 14, color: Cs.inkFaint),
            style: Cs.body.copyWith(color: color),
            hint: Text('—', style: Cs.body.copyWith(color: Cs.inkFaint)),
            selectedItemBuilder: (_) => [
              for (final code in sheet.shotTypes)
                Row(
                  children: [
                    if (low) ...[
                      const GIcon(GIcons.warn, size: 14, color: Cs.warn, semanticLabel: 'Низкая уверенность'),
                      const SizedBox(width: 6),
                    ],
                    Flexible(child: Text(shotTypeLabels[code] ?? code, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              if (edited && autoText != null) const SizedBox.shrink(),
            ],
            items: [
              for (final code in sheet.shotTypes)
                DropdownMenuItem(
                  value: code,
                  child: Text(shotTypeLabels[code] ?? code, style: Cs.body),
                ),
              if (edited && autoText != null)
                DropdownMenuItem(
                  value: _resetValue,
                  child: Row(
                    children: [
                      const GIcon(GIcons.reset, color: Cs.inkMuted),
                      const SizedBox(width: 8),
                      Text('Вернуть авто: $autoText (${percent(auto?.confidence)})', style: Cs.small),
                    ],
                  ),
                ),
            ],
            onChanged: controller.readOnly
                ? null
                : (v) =>
                      v == _resetValue ? controller.reset(s.id, 'shot_type') : controller.patch(s.id, {'shot_type': v}),
          ),
        ),
      ),
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
      if (mounted) setState(() {});
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
    final ro = widget.controller.readOnly;
    return _Cell(
      edited: s.isEdited('description'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _text,
            focusNode: _focus,
            enabled: !ro,
            minLines: 1,
            maxLines: 4,
            onChanged: _onChanged,
            style: Cs.body,
            decoration: _inlineDecoration(
              focused: _focus.hasFocus,
              hint: s.status == 'detected' ? 'Описание появится после обогащения' : 'Описание',
            ),
          ),
          if (s.isEdited('description'))
            EditedMark(
              autoText: auto?.value as String?,
              differs: s.autoDiffers('description'),
              onReset: ro ? null : () => widget.controller.reset(s.id, 'description'),
            ),
          if (low) LowConfidenceNote('Модель не уверена в описании (${percent(auto?.confidence)})'),
        ],
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
    final ro = controller.readOnly;
    return InkWell(
      onTap: ro
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (_) => ReplicasDialog(scene: s, sheet: sheet, controller: controller),
            ),
      child: _Cell(
        edited: s.replicas.any((r) => r.edited.isNotEmpty || r.origin == 'user'),
        child: s.replicas.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                child: Text(ro ? '—' : 'Добавить реплику', style: Cs.body.copyWith(color: Cs.inkFaint)),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, r) in s.replicas.indexed) ...[
                      if (i > 0) const SizedBox(height: 6),
                      _ReplicaView(replica: r),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _ReplicaView extends StatelessWidget {
  const _ReplicaView({required this.replica});
  final Replica replica;

  @override
  Widget build(BuildContext context) {
    final r = replica;
    final unmatched = !r.matched && r.origin == 'auto';
    final roleStyle = TextStyle(
      fontFamily: Cs.sans,
      fontSize: 11,
      height: 16 / 11,
      letterSpacing: 0.55,
      fontWeight: FontWeight.w700,
      color: unmatched ? Cs.warn : Cs.inkSoft,
    );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(r.role == null ? '? НЕ РАСПОЗНАНО' : r.role!.toUpperCase(), style: roleStyle),
        Text(r.text, style: Cs.body.copyWith(color: unmatched ? Cs.warn : Cs.ink)),
      ],
    );
    return Tooltip(
      message: unmatched ? 'Реплика не найдена в сценарии${r.role == null ? ', говорящий не определён' : ''}' : '',
      child: unmatched
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Cs.warnSoft, borderRadius: BorderRadius.circular(6)),
              child: body,
            )
          : body,
    );
  }
}

String percent(double? c) => c == null ? '?' : '${(c * 100).round()}%';
