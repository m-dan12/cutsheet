import 'package:flutter/material.dart';

/// Токены дизайна CutSheet: тёплый серый фон, белые панели, чёрная основная кнопка.
/// Синий акцент — правки человека, выделение и фокус; янтарный — низкая уверенность модели.
abstract final class Cs {
  static const bg = Color(0xFFF3F2EF);
  static const bgDeep = Color(0xFFECEAE5);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceMuted = Color(0xFFF8F7F4);
  static const surfaceSoft = Color(0xFFFCFBFA);
  static const track = Color(0xFFEFEEEA);
  static const border = Color(0xFFE8E6E1);
  static const borderStrong = Color(0xFFE3E1DC);
  static const divider = Color(0xFFEFEDE9);
  static const dashed = Color(0xFFD9D6CF);

  static const ink = Color(0xFF1C1B19);
  static const inkSoft = Color(0xFF3A3834);
  static const inkMuted = Color(0xFF5E5B55);
  static const inkFaint = Color(0xFF77736B);

  static const accent = Color(0xFF3358D4);
  static const accentInk = Color(0xFF2441A8);
  static const accentSoft = Color(0xFFEAF0FC);

  static const warn = Color(0xFF7A4A00);
  static const warnSoft = Color(0xFFFCF1DC);
  static const warnBar = Color(0xFFD99A2B);
  static const success = Color(0xFF1C6B43);
  static const successDot = Color(0xFF2E8B57);
  static const successSoft = Color(0xFFE6F4EC);
  static const danger = Color(0xFFA8301F);
  static const dangerSoft = Color(0xFFFBE9E7);

  static const stage = Color(0xFF23221F);
  static const stageInner = Color(0xFF2E2D29);
  static const stageMuted = Color(0xFF4A4842);
  static const stageText = Color(0xFFD9D6CF);

  static const rSmall = 8.0;
  static const rMedium = 14.0;
  static const rLarge = 20.0;

  static const serif = 'Lora';
  static const sans = 'Carlito';
  static const mono = 'IBM Plex Mono';

  static const shadowSoft = [
    BoxShadow(color: Color(0x0F1C1B19), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0D1C1B19), blurRadius: 8, offset: Offset(0, 2)),
  ];
  static const shadowModal = [
    BoxShadow(color: Color(0x0F1C1B19), blurRadius: 6, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x381C1B19), blurRadius: 64, offset: Offset(0, 24)),
  ];

  /// Заголовок Lora 600.
  static TextStyle heading(double size, {double? height}) => TextStyle(
    fontFamily: serif,
    fontSize: size,
    height: (height ?? size * 1.3) / size,
    fontWeight: FontWeight.w600,
    color: ink,
  );

  static const body = TextStyle(fontFamily: sans, fontSize: 14, height: 22 / 14, color: ink);
  static const small = TextStyle(fontFamily: sans, fontSize: 13, height: 18 / 13, color: inkMuted);
  static const caption = TextStyle(fontFamily: sans, fontSize: 12, height: 16 / 12, color: inkFaint);
  static const strong = TextStyle(
    fontFamily: sans,
    fontSize: 14,
    height: 22 / 14,
    fontWeight: FontWeight.w700,
    color: ink,
  );

  /// Подпись колонки: капс, разрядка.
  static const label = TextStyle(
    fontFamily: sans,
    fontSize: 11,
    height: 16 / 11,
    letterSpacing: 0.66,
    fontWeight: FontWeight.w700,
    color: inkFaint,
  );

  /// Таймкоды и числа.
  static const monoText = TextStyle(
    fontFamily: mono,
    fontSize: 13,
    height: 20 / 13,
    color: ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

ThemeData cutsheetTheme() {
  const scheme = ColorScheme.light(
    primary: Cs.ink,
    onPrimary: Colors.white,
    secondary: Cs.accent,
    onSecondary: Colors.white,
    tertiary: Cs.accent,
    surface: Cs.surface,
    onSurface: Cs.ink,
    onSurfaceVariant: Cs.inkMuted,
    surfaceContainerHighest: Cs.surfaceMuted,
    surfaceContainerHigh: Cs.surfaceMuted,
    surfaceContainer: Cs.surface,
    surfaceContainerLow: Cs.surface,
    outline: Cs.borderStrong,
    outlineVariant: Cs.divider,
    error: Cs.danger,
    errorContainer: Cs.dangerSoft,
    primaryContainer: Cs.accentSoft,
    onPrimaryContainer: Cs.accentInk,
    secondaryContainer: Cs.accentSoft,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: Cs.sans);
  final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Cs.rSmall));
  const buttonText = TextStyle(fontFamily: Cs.sans, fontSize: 14, fontWeight: FontWeight.w700);
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(Cs.rSmall),
    borderSide: BorderSide(color: c, width: w),
  );
  return base.copyWith(
    scaffoldBackgroundColor: Cs.bg,
    textTheme: base.textTheme.apply(fontFamily: Cs.sans, bodyColor: Cs.ink, displayColor: Cs.ink),
    dividerTheme: const DividerThemeData(color: Cs.divider, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Cs.ink,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Cs.ink.withValues(alpha: 0.35),
        disabledForegroundColor: Colors.white,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Cs.ink,
        backgroundColor: Cs.surface,
        side: const BorderSide(color: Cs.borderStrong),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Cs.inkMuted,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: buttonShape,
        textStyle: buttonText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: Cs.inkMuted, shape: buttonShape, minimumSize: const Size(36, 36)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Cs.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      hintStyle: const TextStyle(color: Cs.inkFaint),
      border: border(Cs.borderStrong),
      enabledBorder: border(Cs.borderStrong),
      focusedBorder: border(Cs.accent),
      errorBorder: border(Cs.danger),
      focusedErrorBorder: border(Cs.danger),
      disabledBorder: border(Cs.border),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Cs.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: Cs.heading(20, height: 28),
      contentTextStyle: Cs.body,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: Cs.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: const Color(0x331C1B19),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Cs.border),
      ),
      textStyle: Cs.body,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: Cs.ink, borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(fontFamily: Cs.sans, fontSize: 12, color: Colors.white),
      waitDuration: const Duration(milliseconds: 400),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Cs.ink,
      contentTextStyle: const TextStyle(fontFamily: Cs.sans, fontSize: 14, color: Colors.white),
      actionTextColor: Colors.white,
      behavior: SnackBarBehavior.floating,
      width: 440,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Cs.ink : Cs.dashed),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Cs.ink : Colors.transparent),
      side: const BorderSide(color: Cs.dashed, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Cs.ink : Cs.dashed),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Cs.accent,
      linearTrackColor: Cs.track,
      circularTrackColor: Colors.transparent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(const Color(0x331C1B19)),
      radius: const Radius.circular(8),
    ),
  );
}
