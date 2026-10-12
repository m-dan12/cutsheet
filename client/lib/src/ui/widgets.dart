import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'gravity_icons.dart';
import 'theme.dart';

export 'gravity_icons.dart';
export 'theme.dart';

/// Иконка Gravity UI (SVG 16×16, цвет — currentColor).
class GIcon extends StatelessWidget {
  const GIcon(this.svg, {super.key, this.size = 16, this.color, this.semanticLabel});
  final String svg;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? DefaultTextStyle.of(context).style.color ?? Cs.ink;
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
      semanticsLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
    );
  }
}

/// Логотип: чёрный квадрат с плёнкой и название.
class Brand extends StatelessWidget {
  const Brand({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: compact ? 36 : 32,
      height: compact ? 36 : 32,
      decoration: BoxDecoration(color: Cs.ink, borderRadius: BorderRadius.circular(compact ? 10 : 9)),
      alignment: Alignment.center,
      child: const GIcon(GIcons.filmstrip, color: Colors.white),
    );
    if (compact) return mark;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 10),
        Text('CutSheet', style: Cs.heading(18, height: 24)),
      ],
    );
  }
}

enum PillKind { ok, run, warn, err, mute }

/// Статус-«таблетка».
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.kind = PillKind.mute, this.icon});
  final String text;
  final PillKind kind;
  final String? icon;

  static (Color, Color) colors(PillKind kind) => switch (kind) {
    PillKind.ok => (Cs.successSoft, Cs.success),
    PillKind.run => (Cs.accentSoft, Cs.accentInk),
    PillKind.warn => (Cs.warnSoft, Cs.warn),
    PillKind.err => (Cs.dangerSoft, Cs.danger),
    PillKind.mute => (Cs.track, Cs.inkMuted),
  };

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = colors(kind);
    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[GIcon(icon!, size: 12, color: fg), const SizedBox(width: 6)],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: Cs.sans, fontSize: 12, fontWeight: FontWeight.w700, color: fg, height: 1),
            ),
          ),
        ],
      ),
    );
  }
}

/// Тонкая полоса прогресса.
class Bar extends StatelessWidget {
  const Bar({super.key, required this.value, this.height = 6, this.color = Cs.accent, this.width});
  final double? value;
  final double height;
  final Color color;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: value?.clamp(0, 1),
          minHeight: height,
          color: color,
          backgroundColor: Cs.track,
        ),
      ),
    );
  }
}

/// Белая панель со скруглением 20.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = EdgeInsets.zero, this.color = Cs.surface});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Cs.rLarge)),
    child: child,
  );
}

/// Переключатель-сегменты на сером треке (фильтры «Все / Проверить / Изменённые»).
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.value, required this.items, required this.onChanged});
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Cs.track, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (v, label) in items)
            Semantics(
              selected: v == value,
              button: true,
              child: GestureDetector(
                onTap: () => onChanged(v),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == value ? Cs.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: v == value
                          ? const [BoxShadow(color: Color(0x141C1B19), blurRadius: 2, offset: Offset(0, 1))]
                          : null,
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontFamily: Cs.sans,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: v == value ? Cs.ink : Cs.inkMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Поле поиска с лупой.
class SearchField extends StatelessWidget {
  const SearchField({super.key, required this.hint, required this.onChanged, this.width = 280, this.controller});
  final String hint;
  final ValueChanged<String> onChanged;
  final double width;
  final TextEditingController? controller;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 36,
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      style: Cs.body,
      decoration: InputDecoration(
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        prefixIcon: const Padding(
          padding: EdgeInsets.all(10),
          child: GIcon(GIcons.magnifier, color: Cs.inkFaint),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
    ),
  );
}

/// Кнопка с иконкой Gravity: основная (чёрная), обычная (белая с рамкой) или прозрачная.
enum BtnKind { primary, secondary, ghost }

class Btn extends StatelessWidget {
  const Btn(this.label, {super.key, this.icon, this.onPressed, this.kind = BtnKind.secondary, this.small = false});
  final String label;
  final String? icon;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final size = Size(0, small ? 30 : 36);
    final pad = EdgeInsets.symmetric(horizontal: small ? 10 : 14);
    final text = TextStyle(fontFamily: Cs.sans, fontSize: small ? 13 : 14, fontWeight: FontWeight.w700);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[GIcon(icon!), const SizedBox(width: 8)],
        Text(label),
      ],
    );
    return switch (kind) {
      BtnKind.primary => FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(minimumSize: size, padding: pad, textStyle: text),
        child: child,
      ),
      BtnKind.secondary => OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(minimumSize: size, padding: pad, textStyle: text),
        child: child,
      ),
      BtnKind.ghost => TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(minimumSize: size, padding: pad, textStyle: text),
        child: child,
      ),
    };
  }
}

/// Квадратная кнопка-иконка с подсказкой.
class IconBtn extends StatelessWidget {
  const IconBtn(this.icon, {super.key, required this.tooltip, this.onPressed, this.color, this.background});
  final String icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(backgroundColor: background),
    icon: GIcon(icon, color: onPressed == null ? Cs.dashed : (color ?? Cs.inkMuted)),
  );
}

/// Подпись поля формы.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: const TextStyle(
        fontFamily: Cs.sans,
        fontSize: 13,
        height: 18 / 13,
        fontWeight: FontWeight.w700,
        color: Cs.inkSoft,
      ),
    ),
  );
}

/// Подпись-капс (НАЧАЛО, ПЛАН…).
class CapsLabel extends StatelessWidget {
  const CapsLabel(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: color == null ? Cs.label : Cs.label.copyWith(color: color));
}

/// Модальное окно в стиле дизайна: круглая иконка, заголовок Lora, подзаголовок, тело и серый подвал.
class CsDialog extends StatelessWidget {
  const CsDialog({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconTone,
    required this.body,
    this.footerNote,
    this.actions = const [],
    this.width = 580,
    this.onClose,
  });

  final String title;
  final String? subtitle;
  final String? icon;

  /// Цветной круг под иконкой (предупреждение, ошибка); null — белый с рамкой.
  final PillKind? iconTone;
  final Widget body;
  final String? footerNote;
  final List<Widget> actions;
  final double width;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 22, 16, 20),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Cs.divider)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null) ...[
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: iconTone == null ? null : Pill.colors(iconTone!).$1,
                        border: iconTone == null ? Border.all(color: Cs.border) : null,
                      ),
                      alignment: Alignment.center,
                      child: GIcon(icon!, size: 18, color: iconTone == null ? Cs.ink : Pill.colors(iconTone!).$2),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: Cs.heading(20, height: 28)),
                        if (subtitle != null) Text(subtitle!, style: Cs.body.copyWith(color: Cs.inkMuted)),
                      ],
                    ),
                  ),
                  IconBtn(
                    GIcons.xmark,
                    tooltip: 'Закрыть',
                    onPressed: onClose ?? () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 22, 24, 22), child: body),
            ),
            if (actions.isNotEmpty || footerNote != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: const BoxDecoration(
                  color: Cs.surfaceMuted,
                  border: Border(top: BorderSide(color: Cs.divider)),
                ),
                child: Row(
                  children: [
                    Expanded(child: footerNote == null ? const SizedBox.shrink() : Text(footerNote!, style: Cs.small)),
                    const SizedBox(width: 12),
                    for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), a],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Тёмное уведомление внизу экрана.
void showToast(BuildContext context, String message, {String? action, VoidCallback? onAction}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      content: Text(message),
      action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
    ),
  );
}

/// Цветная точка (статус в списке недавних, легенда).
class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 8, this.square = false});
  final Color color;
  final double size;
  final bool square;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: square ? BoxShape.rectangle : BoxShape.circle,
      borderRadius: square ? BorderRadius.circular(2) : null,
    ),
  );
}
