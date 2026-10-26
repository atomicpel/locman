import 'dart:math';

import 'package:flutter/material.dart';

import '../state.dart';
import 'theme.dart';

/// Живой фон облика: у каждого свой — пятна света, сияние, звёзды, волны, закат, лепестки, радар…
/// Рисуется одним CustomPainter без размытия (только градиенты), чтобы не грузить телефон.
/// Выключается в «Оформлении» и сам замирает при системном «Убрать анимации».
class Backdrop extends StatefulWidget {
  const Backdrop({super.key, required this.live, this.phase = Phase.off});
  final bool live;
  final Phase phase;

  @override
  State<Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<Backdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: const Duration(seconds: 40));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(Backdrop old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final still = !widget.live || MediaQuery.maybeDisableAnimationsOf(context) == true;
    if (still) {
      _t.stop();
      if (_t.value == 0) _t.value = 0.3;
    } else if (!_t.isAnimating) {
      _t.repeat();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _t,
        builder: (_, __) => CustomPaint(
          painter: BackdropPainter(p, _t.value, on: widget.phase == Phase.on),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Отдельно — чтобы рисовать и превью обликов в «Оформлении».
class BackdropPainter extends CustomPainter {
  BackdropPainter(this.p, this.t, {this.on = false});
  final Palette p;

  /// 0…1 за 40 секунд.
  final double t;
  final bool on;

  static final _rnd = Random(7);
  static final List<List<double>> _starData = List.generate(140, (_) => List.generate(5, (_) => _rnd.nextDouble()));
  static final List<List<double>> _petalData = List.generate(28, (_) => List.generate(6, (_) => _rnd.nextDouble()));
  static final List<List<double>> _bokehData = List.generate(14, (_) => List.generate(5, (_) => _rnd.nextDouble()));

  double get _a => 2 * pi * t;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: p.sky.length > 1 ? p.sky : [p.sky.first, p.sky.first],
        ).createShader(rect),
    );
    switch (p.skin) {
      case Skin.glass:
        _blobs(canvas, size, [p.accent, p.accent2, Color.lerp(p.accent, p.accent2, 0.5)!], p.dark ? 0.20 : 0.16);
      case Skin.aurora:
        _stars(canvas, size, count: 60, alpha: 0.5);
        _aurora(canvas, size);
      case Skin.cosmos:
        _nebula(canvas, size);
        _stars(canvas, size, count: 140, alpha: 1);
        _meteor(canvas, size);
      case Skin.ocean:
        _blobs(canvas, size, [p.accent2], p.dark ? 0.12 : 0.10);
        _waves(canvas, size);
      case Skin.sunset:
        _sun(canvas, size);
        _clouds(canvas, size);
      case Skin.sakura:
        _blobs(canvas, size, [p.accent2, p.accent], 0.10);
        _petalsFall(canvas, size);
      case Skin.island:
        _bokehUp(canvas, size);
      case Skin.paper:
        _blobs(canvas, size, [p.fg, p.accent2], p.dark ? 0.05 : 0.045);
      case Skin.signal:
        _radar(canvas, size);
      case Skin.dot:
        _dots(canvas, size);
    }
  }

  /// Большие мягкие пятна света, плывущие по фигурам Лиссажу.
  void _blobs(Canvas canvas, Size size, List<Color> colors, double alpha) {
    final w = size.width, h = size.height;
    final r = max(w, h) * 0.55;
    for (var i = 0; i < colors.length; i++) {
      final k = i * 2.1;
      final c = Offset(
        w * (0.5 + 0.38 * sin(_a * (1 + i % 2) + k)),
        h * (0.35 + 0.30 * cos(_a * (1 + (i + 1) % 2) + k * 1.3)),
      );
      final a = alpha * (on ? 1.25 : 1);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [colors[i].withValues(alpha: a), colors[i].withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
  }

  void _stars(Canvas canvas, Size size, {required int count, required double alpha}) {
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final s = _starData[i];
      final tw = 0.35 + 0.65 * (0.5 + 0.5 * sin(_a * (3 + s[3] * 8) + s[4] * 6.28));
      paint.color = (i % 7 == 0 ? p.accent2 : p.fg).withValues(alpha: alpha * tw * (0.35 + s[2] * 0.6));
      canvas.drawCircle(Offset(s[0] * size.width, s[1] * size.height), 0.6 + s[2] * 1.4, paint);
    }
  }

  void _nebula(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    for (final (i, c) in [p.accent2, p.accent].indexed) {
      final center = Offset(w * (0.25 + 0.5 * i + 0.06 * sin(_a + i)), h * (0.3 + 0.35 * i + 0.04 * cos(_a + i)));
      final r = max(w, h) * 0.5;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(colors: [c.withValues(alpha: 0.16), c.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }
  }

  /// Метеор раз в ~10 секунд: короткий яркий след по диагонали.
  void _meteor(Canvas canvas, Size size) {
    final slot = (t * 4) % 1; // 4 метеора за круг
    if (slot > 0.12) return;
    final k = slot / 0.12;
    final n = (t * 4).floor();
    final x0 = size.width * (0.2 + 0.6 * ((n * 37) % 10) / 10);
    final y0 = size.height * (0.05 + 0.25 * ((n * 53) % 10) / 10);
    final head = Offset(x0 + k * size.width * 0.35, y0 + k * size.height * 0.18);
    final tail = head - Offset(size.width * 0.12, size.height * 0.06);
    final fade = sin(k * pi);
    canvas.drawLine(
      tail,
      head,
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(colors: [p.fg.withValues(alpha: 0), p.fg.withValues(alpha: 0.9 * fade)])
            .createShader(Rect.fromPoints(tail, head)),
    );
  }

  /// Ленты северного сияния: волнистые полосы с вертикальным градиентом.
  void _aurora(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final ribbons = [
      (p.accent, 0.22, 0.10, 1.0),
      (p.accent2, 0.30, 0.13, -1.0),
      (Color.lerp(p.accent, p.accent2, 0.5)!, 0.16, 0.08, 2.0),
    ];
    for (final (i, (color, base, amp, speed)) in ribbons.indexed) {
      final path = Path();
      final top = <Offset>[];
      for (double x = -10; x <= w + 10; x += 10) {
        final y = h * base +
            h * amp * sin(x / w * 2.6 * pi + _a * speed + i) +
            h * 0.03 * sin(x / w * 7 * pi - _a * speed * 2);
        top.add(Offset(x, y));
      }
      final thick = h * (0.16 + 0.05 * sin(_a * 2 + i));
      path.moveTo(top.first.dx, top.first.dy);
      for (final o in top.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      for (final o in top.reversed) {
        path.lineTo(o.dx, o.dy + thick);
      }
      path.close();
      final bounds = Rect.fromLTWH(0, h * (base - amp - 0.05), w, h * (2 * amp + 0.35));
      final a = on ? 0.42 : 0.32;
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0), color.withValues(alpha: a), color.withValues(alpha: 0)],
            stops: const [0, 0.35, 1],
          ).createShader(bounds),
      );
    }
  }

  /// Волны внизу экрана: три слоя с разной скоростью.
  void _waves(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final layers = [
      (p.accent2, 0.80, 0.022, 1.0, 0.22),
      (p.accent, 0.85, 0.018, -1.6, 0.20),
      (Color.lerp(p.accent, p.accent2, 0.4)!, 0.90, 0.014, 2.3, 0.28),
    ];
    for (final (color, base, amp, speed, alpha) in layers) {
      final path = Path()..moveTo(0, h);
      for (double x = 0; x <= w + 8; x += 8) {
        final y = h * base + h * amp * sin(x / w * 2 * pi * 1.4 + _a * speed * 3) + h * amp * 0.5 * sin(x / w * 2 * pi * 3.1 - _a * speed * 5);
        path.lineTo(x, y);
      }
      path
        ..lineTo(w, h)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: alpha * (on ? 1.3 : 1)), color.withValues(alpha: alpha * 0.4)],
          ).createShader(Rect.fromLTWH(0, h * (base - amp * 1.5), w, h * (1 - base + amp * 1.5))),
      );
    }
  }

  /// Солнце медленно садится и встаёт, вокруг — ореол.
  void _sun(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final y = h * (0.62 + 0.06 * sin(_a));
    final c = Offset(w * 0.5, y);
    final glow = w * 0.9;
    canvas.drawCircle(
      c,
      glow,
      Paint()
        ..shader = RadialGradient(colors: [p.accent.withValues(alpha: 0.35), p.accent2.withValues(alpha: 0.12), p.accent2.withValues(alpha: 0)], stops: const [0, 0.35, 1])
            .createShader(Rect.fromCircle(center: c, radius: glow)),
    );
    final r = w * 0.16;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFFFFD27A).withValues(alpha: 0.85), p.accent2.withValues(alpha: 0.75)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    // Горизонт: полосы «отражения» под солнцем.
    final horizon = h * 0.72;
    canvas.drawRect(
      Rect.fromLTWH(0, horizon, w, h - horizon),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [p.sky.first.withValues(alpha: 0.85), p.sky.first],
        ).createShader(Rect.fromLTWH(0, horizon, w, h - horizon)),
    );
    final line = Paint()..color = p.accent.withValues(alpha: 0.25);
    for (var i = 0; i < 6; i++) {
      final yy = horizon + 8 + i * 9.0;
      final half = r * (1.1 - i * 0.15) * (1 + 0.08 * sin(_a * 6 + i));
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(w / 2 - half, yy, w / 2 + half, yy + 2.5), const Radius.circular(2)), line);
    }
  }

  void _clouds(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final paint = Paint()..color = p.accent2.withValues(alpha: 0.10);
    for (var i = 0; i < 4; i++) {
      final x = ((t * (0.6 + i * 0.25) + i * 0.3) % 1.3 - 0.15) * w;
      final y = h * (0.12 + i * 0.09);
      final cw = w * (0.35 + 0.1 * i);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: cw, height: 14 + i * 3.0), const Radius.circular(20)), paint);
    }
  }

  /// Лепестки сакуры падают и покачиваются.
  void _petalsFall(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    for (final s in _petalData) {
      final speed = 0.6 + s[2] * 0.8;
      final y = ((s[1] + t * 6 * speed) % 1.1 - 0.05) * h;
      final x = s[0] * w + sin(_a * 8 * (0.5 + s[3]) + s[4] * 6) * 28;
      final rot = _a * 6 * (s[5] - 0.5) + s[4] * 6;
      final len = 7 + s[2] * 7;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(rot);
      final path = Path()
        ..moveTo(0, -len)
        ..quadraticBezierTo(len * 0.9, -len * 0.2, 0, len)
        ..quadraticBezierTo(-len * 0.9, -len * 0.2, 0, -len)
        ..close();
      canvas.drawPath(path, Paint()..color = (s[3] > 0.5 ? p.accent2 : p.accent).withValues(alpha: 0.35 + s[2] * 0.35));
      canvas.restore();
    }
  }

  /// Тёплые блики поднимаются вверх.
  void _bokehUp(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    for (final s in _bokehData) {
      final y = (1.1 - (s[1] + t * 2 * (0.4 + s[2])) % 1.2) * h;
      final x = s[0] * w + sin(_a * 3 + s[3] * 6) * 20;
      final r = 30 + s[2] * 70;
      final c = s[4] > 0.5 ? p.accent : p.accent2;
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..shader = RadialGradient(colors: [c.withValues(alpha: p.dark ? 0.16 : 0.12), c.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: Offset(x, y), radius: r)),
      );
    }
  }

  /// Радар: кольца и вращающийся луч вокруг кнопки.
  void _radar(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.33);
    final maxR = size.longestSide * 0.75;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = p.accent.withValues(alpha: 0.07);
    for (var r = 120.0; r < maxR; r += 90) {
      canvas.drawCircle(c, r, ring);
    }
    final angle = _a * 6;
    final rect = Rect.fromCircle(center: c, radius: maxR);
    canvas.drawCircle(
      c,
      maxR,
      Paint()
        ..shader = SweepGradient(
          colors: [p.accent.withValues(alpha: 0), p.accent.withValues(alpha: on ? 0.16 : 0.10), p.accent.withValues(alpha: 0)],
          stops: const [0, 0.08, 0.081],
          transform: GradientRotation(angle),
        ).createShader(rect),
    );
  }

  /// «Точка»: растр точек, по нему от центра бежит волна.
  void _dots(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.33);
    final wave = ((t * 10) % 1) * size.longestSide;
    final base = Paint()..color = p.fg.withValues(alpha: 0.16);
    final hot = Paint();
    for (double y = 9; y < size.height; y += 18) {
      for (double x = 9; x < size.width; x += 18) {
        final d = (Offset(x, y) - c).distance;
        final k = (1 - (d - wave).abs() / 40).clamp(0.0, 1.0);
        if (k > 0) {
          hot.color = Color.lerp(p.fg.withValues(alpha: 0.16), p.accent.withValues(alpha: on ? 0.9 : 0.55), k)!;
          canvas.drawCircle(Offset(x, y), 1 + k * 0.8, hot);
        } else {
          canvas.drawCircle(Offset(x, y), 1, base);
        }
      }
    }
  }

  @override
  bool shouldRepaint(BackdropPainter old) => old.t != t || old.p != p || old.on != on;
}
