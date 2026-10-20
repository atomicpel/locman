import 'package:flutter/material.dart';

import '../state.dart';

/// Палитры обликов из макета (styles.css).
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.fg,
    required this.muted,
    required this.accent,
    required this.accentFg,
    required this.border,
    required this.danger,
    required this.rCard,
    required this.rPill,
    required this.dark,
    required this.skin,
  });

  final Color bg, surface, surface2, fg, muted, accent, accentFg, border, danger;
  final double rCard, rPill;
  final bool dark;
  final Skin skin;

  bool get serif => skin == Skin.paper;

  static const _bold = [FontWeight.w600, FontWeight.w700, FontWeight.w800, FontWeight.w900];

  static Palette of(Skin skin, bool dark) {
    switch (skin) {
      case Skin.glass:
        return dark
            ? Palette(
                bg: const Color(0xFF0B0E14), surface: const Color(0xFF151A24), surface2: const Color(0xFF1C2431),
                fg: const Color(0xFFE7EDF5), muted: const Color(0xFF8B97A8), accent: const Color(0xFF3EC6FF),
                accentFg: const Color(0xFF041018), border: const Color(0xFF2A3548), danger: const Color(0xFFE85D4C),
                rCard: 16, rPill: 999, dark: true, skin: skin)
            : Palette(
                bg: const Color(0xFFE7EEF5), surface: const Color(0xFFFFFFFF), surface2: const Color(0xFFF4F8FB),
                fg: const Color(0xFF121820), muted: const Color(0xFF526274), accent: const Color(0xFF007EAB),
                accentFg: const Color(0xFFF4FBFF), border: const Color(0xFFD3DEE8), danger: const Color(0xFFB4332A),
                rCard: 16, rPill: 999, dark: false, skin: skin);
      case Skin.paper:
        return dark
            ? Palette(
                bg: const Color(0xFF161410), surface: const Color(0xFF221F1A), surface2: const Color(0xFF2A261F),
                fg: const Color(0xFFF3EEE4), muted: const Color(0xFFA39888), accent: const Color(0xFFF3EEE4),
                accentFg: const Color(0xFF161410), border: const Color(0xFF3A342B), danger: const Color(0xFFE08978),
                rCard: 5.6, rPill: 6.4, dark: true, skin: skin)
            : Palette(
                bg: const Color(0xFFF3EEE4), surface: const Color(0xFFFFFAF2), surface2: const Color(0xFFF7F1E6),
                fg: const Color(0xFF1C1915), muted: const Color(0xFF6F675C), accent: const Color(0xFF1C1915),
                accentFg: const Color(0xFFF3EEE4), border: const Color(0xFFE0D6C6), danger: const Color(0xFF8C3A2F),
                rCard: 5.6, rPill: 6.4, dark: false, skin: skin);
      case Skin.dot:
        return Palette(
            bg: const Color(0xFF0A0A0A), surface: const Color(0xFF141414), surface2: const Color(0xFF1B1B1B),
            fg: const Color(0xFFF2F2F2), muted: const Color(0xFF8A8A8A), accent: const Color(0xFFFF3B30),
            accentFg: const Color(0xFF1A0504), border: const Color(0xFF2C2C2C), danger: const Color(0xFFFF3B30),
            rCard: 12, rPill: 999, dark: true, skin: skin);
      case Skin.signal:
        return Palette(
            bg: const Color(0xFF121417), surface: const Color(0xFF1C1F24), surface2: const Color(0xFF24282F),
            fg: const Color(0xFFE6E8EB), muted: const Color(0xFF9AA1AB), accent: const Color(0xFF4CC2FF),
            accentFg: const Color(0xFF041018), border: const Color(0xFF323842), danger: const Color(0xFFFF6B6B),
            rCard: 13.6, rPill: 11.2, dark: true, skin: skin);
      case Skin.island:
        return dark
            ? Palette(
                bg: const Color(0xFF10141C), surface: const Color(0xFF1A2130), surface2: const Color(0xFF232B3C),
                fg: const Color(0xFFEEF2F8), muted: const Color(0xFF93A0B5), accent: const Color(0xFFF0B429),
                accentFg: const Color(0xFF1A1406), border: const Color(0xFF314056), danger: const Color(0xFFE85D4C),
                rCard: 21.6, rPill: 999, dark: true, skin: skin)
            : Palette(
                bg: const Color(0xFFF4F1EA), surface: const Color(0xFFFFFCF7), surface2: const Color(0xFFF7F2E8),
                fg: const Color(0xFF1A1C22), muted: const Color(0xFF5E6574), accent: const Color(0xFF9A6B00),
                accentFg: const Color(0xFFFFF8E8), border: const Color(0xFFE3DCCF), danger: const Color(0xFFB4332A),
                rCard: 21.6, rPill: 999, dark: false, skin: skin);
    }
  }

  TextStyle text(double size, {FontWeight weight = FontWeight.w400, Color? color, bool display = false}) => TextStyle(
        fontFamily: display && serif ? 'Literata' : 'Manrope',
        fontSize: size,
        fontWeight: display && serif ? FontWeight.w600 : weight,
        color: color ?? fg,
        height: 1.4,
        letterSpacing: display || _bold.contains(weight) ? -0.2 : 0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  ThemeData get material => ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: bg,
        fontFamily: 'Manrope',
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: dark ? Brightness.dark : Brightness.light,
          primary: accent,
          onPrimary: accentFg,
          surface: surface,
          onSurface: fg,
          error: danger,
        ),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        textSelectionTheme: TextSelectionThemeData(cursorColor: accent, selectionHandleColor: accent),
      );
}

/// Доступ к палитре из любого виджета.
class PaletteScope extends InheritedWidget {
  const PaletteScope({super.key, required this.palette, required super.child});
  final Palette palette;

  static Palette of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PaletteScope>()!.palette;

  @override
  bool updateShouldNotify(PaletteScope old) => old.palette != palette;
}
