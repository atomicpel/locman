import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../state.dart';

/// Палитра облика: цвета, второй акцент для градиентов, небо (фон) и скругления.
class Palette {
  const Palette({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.fg,
    required this.muted,
    required this.accent,
    required this.accent2,
    required this.accentFg,
    required this.border,
    required this.danger,
    required this.sky,
    required this.rCard,
    required this.rPill,
    required this.dark,
    required this.skin,
  });

  final Color bg, surface, surface2, fg, muted, accent, accent2, accentFg, border, danger;

  /// Фон сверху вниз (живой фон рисуется поверх).
  final List<Color> sky;
  final double rCard, rPill;
  final bool dark;
  final Skin skin;

  bool get serif => skin == Skin.paper;

  static const _bold = [FontWeight.w600, FontWeight.w700, FontWeight.w800, FontWeight.w900];

  static Palette _p(
    Skin skin,
    bool dark, {
    required int bg,
    required int surface,
    required int surface2,
    required int fg,
    required int muted,
    required int accent,
    required int accent2,
    required int accentFg,
    required int border,
    required int danger,
    required List<int> sky,
    double rCard = 18,
    double rPill = 999,
  }) =>
      Palette(
        bg: Color(bg),
        surface: Color(surface),
        surface2: Color(surface2),
        fg: Color(fg),
        muted: Color(muted),
        accent: Color(accent),
        accent2: Color(accent2),
        accentFg: Color(accentFg),
        border: Color(border),
        danger: Color(danger),
        sky: [for (final c in sky) Color(c)],
        rCard: rCard,
        rPill: rPill,
        dark: dark,
        skin: skin,
      );

  static Palette of(Skin skin, bool dark) {
    switch (skin) {
      case Skin.glass:
        return dark
            ? _p(skin, true,
                bg: 0xFF0B0E14, surface: 0xE6151A24, surface2: 0xE61C2431, fg: 0xFFE7EDF5, muted: 0xFF8B97A8,
                accent: 0xFF3EC6FF, accent2: 0xFF7C5CFF, accentFg: 0xFF041018, border: 0xFF2A3548, danger: 0xFFE85D4C,
                sky: [0xFF0B0E14, 0xFF0F1522, 0xFF0B0E14], rCard: 16)
            : _p(skin, false,
                bg: 0xFFE7EEF5, surface: 0xF2FFFFFF, surface2: 0xF2F4F8FB, fg: 0xFF121820, muted: 0xFF526274,
                accent: 0xFF007EAB, accent2: 0xFF6A4BD6, accentFg: 0xFFF4FBFF, border: 0xFFD3DEE8, danger: 0xFFB4332A,
                sky: [0xFFE9F1F8, 0xFFE2EAF4, 0xFFEDF2F7], rCard: 16);
      case Skin.aurora:
        return _p(skin, true,
            bg: 0xFF050A13, surface: 0xC70D1828, surface2: 0xC7122035, fg: 0xFFE8F3F5, muted: 0xFF8FA7B3,
            accent: 0xFF4BF0B5, accent2: 0xFF8B5CF6, accentFg: 0xFF03140E, border: 0x6E33506A, danger: 0xFFFF6B6B,
            sky: [0xFF030712, 0xFF071426, 0xFF0A1C2A], rCard: 20);
      case Skin.cosmos:
        return _p(skin, true,
            bg: 0xFF04050D, surface: 0xC70F1124, surface2: 0xC715183A, fg: 0xFFEDEBFF,
            muted: 0xFF9A97C0, accent: 0xFFB18CFF, accent2: 0xFF4CC9F0, accentFg: 0xFF140A2B, border: 0x6E34386A,
            danger: 0xFFFF6B8B, sky: [0xFF02030A, 0xFF070921, 0xFF0D0B26], rCard: 18);
      case Skin.ocean:
        return dark
            ? _p(skin, true,
                bg: 0xFF04121E, surface: 0xD90A2233, surface2: 0xD90E2B40, fg: 0xFFE3F4FA, muted: 0xFF86A9BB,
                accent: 0xFF2BD4E6, accent2: 0xFF1A7BFF, accentFg: 0xFF02161B, border: 0x77245068, danger: 0xFFFF7A6B,
                sky: [0xFF03101B, 0xFF062035, 0xFF07304A])
            : _p(skin, false,
                bg: 0xFFE6F4F8, surface: 0xE6FFFFFF, surface2: 0xE6F1FAFC, fg: 0xFF0B2433, muted: 0xFF4E6E80,
                accent: 0xFF0089A8, accent2: 0xFF1A5FD6, accentFg: 0xFFFFFFFF, border: 0x99A9CEDC, danger: 0xFFB4332A,
                sky: [0xFFF0FAFD, 0xFFDDF1F8, 0xFFC6E6F2]);
      case Skin.sunset:
        return _p(skin, true,
            bg: 0xFF1A0F1E, surface: 0xD1261729, surface2: 0xD12E1C31, fg: 0xFFFFF1E8, muted: 0xFFC3A39E,
            accent: 0xFFFF8A4C, accent2: 0xFFFF4F8B, accentFg: 0xFF2A0E05, border: 0x774E3049, danger: 0xFFFF5C5C,
            sky: [0xFF140B22, 0xFF3A1640, 0xFF8A3A4A], rCard: 22);
      case Skin.sakura:
        return _p(skin, false,
            bg: 0xFFFDF2F5, surface: 0xE6FFFFFF, surface2: 0xE6FFF7F9, fg: 0xFF2E1A22, muted: 0xFF8A6672,
            accent: 0xFFD94873, accent2: 0xFFF29BB3, accentFg: 0xFFFFFFFF, border: 0x99F0C9D4, danger: 0xFFC2334A,
            sky: [0xFFFFF7F9, 0xFFFCE8EE, 0xFFF9DCE6], rCard: 22);
      case Skin.island:
        return dark
            ? _p(skin, true,
                bg: 0xFF10141C, surface: 0xE61A2130, surface2: 0xE6232B3C, fg: 0xFFEEF2F8, muted: 0xFF93A0B5,
                accent: 0xFFF0B429, accent2: 0xFFFF7A45, accentFg: 0xFF1A1406, border: 0xFF314056, danger: 0xFFE85D4C,
                sky: [0xFF10141C, 0xFF151B27, 0xFF10141C], rCard: 21.6)
            : _p(skin, false,
                bg: 0xFFF4F1EA, surface: 0xF2FFFCF7, surface2: 0xF2F7F2E8, fg: 0xFF1A1C22, muted: 0xFF5E6574,
                accent: 0xFF9A6B00, accent2: 0xFFC2410C, accentFg: 0xFFFFF8E8, border: 0xFFE3DCCF, danger: 0xFFB4332A,
                sky: [0xFFF6F3EC, 0xFFF1ECE2, 0xFFF4F1EA], rCard: 21.6);
      case Skin.paper:
        return dark
            ? _p(skin, true,
                bg: 0xFF161410, surface: 0xF2221F1A, surface2: 0xF22A261F, fg: 0xFFF3EEE4, muted: 0xFFA39888,
                accent: 0xFFF3EEE4, accent2: 0xFFB8A88F, accentFg: 0xFF161410, border: 0xFF3A342B, danger: 0xFFE08978,
                sky: [0xFF161410, 0xFF1A1813, 0xFF161410], rCard: 5.6, rPill: 6.4)
            : _p(skin, false,
                bg: 0xFFF3EEE4, surface: 0xF2FFFAF2, surface2: 0xF2F7F1E6, fg: 0xFF1C1915, muted: 0xFF6F675C,
                accent: 0xFF1C1915, accent2: 0xFF6F675C, accentFg: 0xFFF3EEE4, border: 0xFFE0D6C6, danger: 0xFF8C3A2F,
                sky: [0xFFF5F0E6, 0xFFF0EADD, 0xFFF3EEE4], rCard: 5.6, rPill: 6.4);
      case Skin.signal:
        return _p(skin, true,
            bg: 0xFF0F1215, surface: 0xE61C1F24, surface2: 0xE624282F, fg: 0xFFE6E8EB, muted: 0xFF9AA1AB,
            accent: 0xFF4CC2FF, accent2: 0xFF3DDC97, accentFg: 0xFF041018, border: 0xFF323842, danger: 0xFFFF6B6B,
            sky: [0xFF0F1215, 0xFF12171C, 0xFF0F1215], rCard: 13.6, rPill: 11.2);
      case Skin.dot:
        return _p(skin, true,
            bg: 0xFF0A0A0A, surface: 0xEB141414, surface2: 0xEB1B1B1B, fg: 0xFFF2F2F2, muted: 0xFF8A8A8A,
            accent: 0xFFFF3B30, accent2: 0xFFFF8A80, accentFg: 0xFF1A0504, border: 0xFF2C2C2C, danger: 0xFFFF3B30,
            sky: [0xFF0A0A0A, 0xFF0A0A0A], rCard: 12);
    }
  }

  /// Плавный переход между обликами: цвета перетекают, а не меняются рывком.
  static Palette lerp(Palette a, Palette b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t)!;
    final n = a.sky.length > b.sky.length ? a.sky.length : b.sky.length;
    Color at(List<Color> l, int i) => l[i < l.length ? i : l.length - 1];
    return Palette(
      bg: c(a.bg, b.bg),
      surface: c(a.surface, b.surface),
      surface2: c(a.surface2, b.surface2),
      fg: c(a.fg, b.fg),
      muted: c(a.muted, b.muted),
      accent: c(a.accent, b.accent),
      accent2: c(a.accent2, b.accent2),
      accentFg: c(a.accentFg, b.accentFg),
      border: c(a.border, b.border),
      danger: c(a.danger, b.danger),
      sky: [for (var i = 0; i < n; i++) c(at(a.sky, i), at(b.sky, i))],
      rCard: lerpDouble(a.rCard, b.rCard, t)!,
      rPill: lerpDouble(a.rPill, b.rPill, t)!,
      dark: t < 0.5 ? a.dark : b.dark,
      skin: t < 0.5 ? a.skin : b.skin,
    );
  }

  /// Градиент акцента — для кнопки, полосок и выделения.
  LinearGradient get accentGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [accent, accent2],
      );

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
          surface: Color.alphaBlend(surface, bg),
          onSurface: fg,
          error: danger,
        ),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        textSelectionTheme: TextSelectionThemeData(cursorColor: accent, selectionHandleColor: accent),
      );
}

/// Переход между палитрами для TweenAnimationBuilder.
class PaletteTween extends Tween<Palette> {
  PaletteTween({super.begin, super.end});

  @override
  Palette lerp(double t) => Palette.lerp(begin!, end!, t);
}

/// Доступ к палитре из любого виджета.
class PaletteScope extends InheritedWidget {
  const PaletteScope({super.key, required this.palette, required super.child});
  final Palette palette;

  static Palette of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PaletteScope>()!.palette;

  @override
  bool updateShouldNotify(PaletteScope old) => old.palette != palette;
}
