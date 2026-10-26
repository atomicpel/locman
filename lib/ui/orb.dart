import 'dart:math';

import 'package:flutter/material.dart';

import '../state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Большая кнопка питания: ореол, расходящиеся волны при подключении, вращающаяся дуга во время
/// поиска, «дыхание» в покое. Цвета — из облика (градиент двух акцентов).
class Orb extends StatefulWidget {
  const Orb({super.key, required this.phase, required this.onTap, this.live = true});
  final Phase phase;
  final VoidCallback onTap;

  /// false — без постоянной анимации (бережём батарею); поиск всё равно крутится.
  final bool live;

  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(Orb old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final calm = !widget.live || MediaQuery.maybeDisableAnimationsOf(context) == true;
    if (widget.phase == Phase.seek) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
    if (calm) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final on = widget.phase == Phase.on;
    final label = switch (widget.phase) {
      Phase.on => 'Отключить',
      Phase.seek => 'Отменить поиск',
      _ => 'Подключить',
    };
    return Pressable(
      onTap: widget.onTap,
      label: label,
      child: SizedBox(
        width: 220,
        height: 220,
        child: AnimatedBuilder(
          animation: Listenable.merge([_spin, _pulse]),
          builder: (context, _) {
            final breath = sin(_pulse.value * 2 * pi);
            final scale = 1 + (on ? 0.015 : 0.02) * breath;
            return Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _HaloPainter(palette: p, phase: widget.phase, pulse: _pulse.value, turn: _spin.value),
                  ),
                ),
                Transform.scale(
                  scale: scale,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    width: 136,
                    height: 136,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: on ? null : Color.alphaBlend(p.surface, p.bg),
                      gradient: on ? p.accentGradient : null,
                      border: on || p.skin == Skin.dot ? null : Border.all(color: p.border),
                      boxShadow: [
                        BoxShadow(
                          color: (on ? p.accent : p.accent2).withValues(alpha: on ? 0.45 : 0.10 + 0.05 * breath),
                          blurRadius: on ? 36 : 22,
                          spreadRadius: on ? 2 : 0,
                        ),
                      ],
                    ),
                    child: CustomPaint(
                      painter: p.skin == Skin.dot && !on ? _DotCorePainter(p) : null,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          transitionBuilder: (child, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: child)),
                          child: Icon(
                            widget.phase == Phase.seek ? Icons.close_rounded : Icons.power_settings_new_rounded,
                            key: ValueKey('${widget.phase}'),
                            size: 36,
                            color: on ? p.accentFg : p.fg,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  _HaloPainter({required this.palette, required this.phase, required this.pulse, required this.turn});
  final Palette palette;
  final Phase phase;
  final double pulse;
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final c = size.center(Offset.zero);
    const core = 68.0;
    final outer = size.width / 2;
    final on = phase == Phase.on;

    // Ореол
    final glowR = outer;
    canvas.drawCircle(
      c,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            (on ? p.accent : p.accent2).withValues(alpha: on ? 0.22 : 0.08),
            (on ? p.accent2 : p.accent).withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: glowR)),
    );

    if (phase == Phase.seek) {
      final r = core + 14;
      final rect = Rect.fromCircle(center: c, radius: r);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            colors: [p.accent2.withValues(alpha: 0), p.accent2, p.accent],
            stops: const [0, 0.55, 0.7],
            transform: GradientRotation(turn * 2 * pi - pi / 2),
          ).createShader(rect),
      );
      final r2 = core + 26;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r2),
        -turn * 2 * pi * 0.7,
        pi * 0.6,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round
          ..color = p.accent.withValues(alpha: 0.45),
      );
      return;
    }

    if (on) {
      // Две волны расходятся от кнопки.
      for (final shift in [0.0, 0.5]) {
        final k = (pulse + shift) % 1;
        final r = core + 6 + k * (outer - core - 8);
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * (1 - k) + 0.5
            ..color = Color.lerp(p.accent, p.accent2, k)!.withValues(alpha: 0.55 * (1 - k)),
        );
      }
      return;
    }

    if (p.skin == Skin.paper) {
      // Мазок тушью: толстое кольцо без правой четверти, повёрнутое на −18°.
      final rot = -18 * pi / 180 + sin(pulse * 2 * pi) * 0.05;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: core + 12),
        pi / 4 + rot,
        3 * pi / 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = p.fg,
      );
      return;
    }
    // В покое — тонкое кольцо, по которому медленно ползёт блик.
    final r = core + 12;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = p.border,
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      pulse * 2 * pi,
      pi / 3,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [p.accent.withValues(alpha: 0), p.accent.withValues(alpha: 0.7), p.accent.withValues(alpha: 0)],
          transform: GradientRotation(pulse * 2 * pi),
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.turn != turn || old.pulse != pulse || old.phase != phase || old.palette != palette;
}

/// «Точка»: пунктирная рамка ядра и точечный растр внутри.
class _DotCorePainter extends CustomPainter {
  _DotCorePainter(this.p);
  final Palette p;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    final dot = Paint()..color = p.muted;
    for (double y = 4; y < size.height; y += 8) {
      for (double x = 4; x < size.width; x += 8) {
        canvas.drawCircle(Offset(x, y), 1, dot);
      }
    }
    canvas.restore();
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = p.border;
    const n = 48;
    for (var i = 0; i < n; i++) {
      final a = i * 2 * pi / n;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r - 0.5), a, pi / n, false, dash);
    }
  }

  @override
  bool shouldRepaint(_DotCorePainter old) => old.p != p;
}

/// Точечный фон «Точки» для главного экрана.
class DotGrid extends StatelessWidget {
  const DotGrid({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return CustomPaint(painter: _GridPainter(p.fg.withValues(alpha: 0.18)), child: child);
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double y = 9; y < size.height; y += 18) {
      for (double x = 9; x < size.width; x += 18) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}
