import 'dart:math';

import 'package:flutter/material.dart';

import '../state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Большая кнопка питания: кольцо, ядро, вращающаяся дуга во время поиска.
class Orb extends StatefulWidget {
  const Orb({super.key, required this.phase, required this.onTap});
  final Phase phase;
  final VoidCallback onTap;

  @override
  State<Orb> createState() => _OrbState();
}

class _OrbState extends State<Orb> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(Orb old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.phase == Phase.seek) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
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
        width: 184,
        height: 184,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _spin,
                builder: (context, _) => CustomPaint(
                  painter: _RingPainter(palette: p, phase: widget.phase, turn: _spin.value),
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: 136,
              height: 136,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? p.accent : p.surface,
                border: on || p.skin == Skin.dot ? null : Border.all(color: p.border),
                boxShadow: on ? [BoxShadow(color: p.accent.withValues(alpha: 0.22), spreadRadius: 8)] : null,
              ),
              child: CustomPaint(
                painter: p.skin == Skin.dot && !on ? _DotCorePainter(p) : null,
                child: Center(
                  child: Icon(Icons.power_settings_new_rounded, size: 34, color: on ? p.accentFg : p.fg),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.palette, required this.phase, required this.turn});
  final Palette palette;
  final Phase phase;
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    if (phase == Phase.seek) {
      final rect = Rect.fromCircle(center: c, radius: r - 1.5);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..shader = SweepGradient(
          colors: [p.accent, p.accent.withValues(alpha: 0)],
          stops: const [0, 0.62],
          transform: GradientRotation(turn * 2 * pi - pi / 2),
        ).createShader(rect);
      canvas.drawCircle(c, r - 1.5, paint);
      return;
    }
    final on = phase == Phase.on;
    if (p.skin == Skin.paper) {
      // Мазок тушью: толстое кольцо без правой четверти, повёрнутое на −18°.
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = p.fg;
      final rot = -18 * pi / 180;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r - 1.5), pi / 4 + rot, 3 * pi / 2, false, paint);
      return;
    }
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = on ? Color.lerp(p.border, p.accent, 0.55)! : p.border;
    canvas.drawCircle(c, r - 0.5, ring);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.turn != turn || old.phase != phase || old.palette != palette;
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
