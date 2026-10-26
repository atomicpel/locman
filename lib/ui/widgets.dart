import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Кнопка с лёгким «нажатием» (scale 0.96), как в макете.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.label, this.enabled = true});
  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onTap != null;
    return Semantics(
      button: true,
      label: widget.label,
      enabled: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: active ? (_) => setState(() => _down = true) : null,
        onTapCancel: active ? () => setState(() => _down = false) : null,
        onTapUp: active ? (_) => setState(() => _down = false) : null,
        onTap: active
            ? () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              }
            : null,
        child: AnimatedScale(
          scale: _down ? 0.96 : 1,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Карточка: поверхность + рамка.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.highlight = false, this.dashed = false, this.color});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool highlight;
  final bool dashed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? (dashed ? Colors.transparent : p.surface),
        borderRadius: BorderRadius.circular(p.rCard),
        border: Border.all(color: highlight ? p.accent : p.border),
      ),
      child: child,
    );
  }
}

/// Сегментированный переключатель (Авто / БС / ЧС и т. п.).
class Segment<T> extends StatelessWidget {
  const Segment({super.key, required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: BorderRadius.circular(p.rPill),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          for (final (id, label) in options)
            Expanded(
              child: Semantics(
                selected: id == value,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(id),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: id == value ? p.fg : Colors.transparent,
                      borderRadius: BorderRadius.circular(p.rPill),
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: p.text(14, weight: FontWeight.w500, color: id == value ? p.bg : p.muted),
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

/// Переключатель 48×28, как в макете.
class PillSwitch extends StatelessWidget {
  const PillSwitch({super.key, required this.on, required this.onChanged, this.label});
  final bool on;
  final ValueChanged<bool> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Semantics(
      toggled: on,
      label: label,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onChanged(!on);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 48,
          height: 28,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: on ? p.accent : p.border, borderRadius: BorderRadius.circular(14)),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(color: on ? p.accentFg : p.surface, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: p.text(12, color: p.muted)),
          const SizedBox(height: 4),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(18, weight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Строка настроек: заголовок, пояснение и элемент справа.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.title, required this.line, this.control, this.onTap});
  final String title;
  final String line;
  final Widget? control;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final body = Panel(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: p.text(16, weight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(line, style: p.text(14, color: p.muted)),
              ],
            ),
          ),
          if (control != null) ...[const SizedBox(width: 12), control!],
        ],
      ),
    );
    return onTap == null ? body : Pressable(onTap: onTap, label: title, child: body);
  }
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.label, required this.onTap, this.busy = false});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Pressable(
      onTap: busy ? null : onTap,
      label: label,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(p.rPill),
          border: Border.all(color: p.border),
        ),
        child: busy
            ? Padding(
                padding: const EdgeInsets.all(13),
                child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
              )
            : Icon(icon, size: 20, color: p.fg),
      ),
    );
  }
}

/// Широкая кнопка-«пилюля».
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onTap, this.primary = false, this.danger = false, this.icon});
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final fg = primary ? p.accentFg : (danger ? p.danger : p.fg);
    return Pressable(
      onTap: onTap,
      label: label,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: primary ? null : p.surface,
            gradient: primary ? p.accentGradient : null,
            boxShadow: primary && onTap != null ? [BoxShadow(color: p.accent.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 4))] : null,
            borderRadius: BorderRadius.circular(p.rPill),
            border: primary ? null : Border.all(color: p.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.text(15, weight: primary ? FontWeight.w600 : FontWeight.w500, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Маленькая метка с рамкой.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.onTap, this.accent = false, this.danger = false});
  final String text;
  final VoidCallback? onTap;
  final bool accent;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final color = danger ? p.danger : (accent ? p.accent : p.muted);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(p.rPill),
        border: Border.all(color: accent || danger ? color : p.border),
      ),
      child: Text(text, style: p.text(12, color: color)),
    );
    return onTap == null ? chip : Pressable(onTap: onTap, label: text, child: chip);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.line});
  final String text;
  final String? line;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: p.text(14, weight: FontWeight.w600)),
        if (line != null) ...[
          const SizedBox(height: 4),
          Text(line!, style: p.text(14, color: p.muted)),
        ],
      ],
    );
  }
}

/// Появление при открытии экрана: снизу вверх и из прозрачности, по очереди.
class Appear extends StatelessWidget {
  const Appear({super.key, required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) == true) return child;
    final start = (index < 8 ? index : 8) * 0.06;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 750),
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      builder: (_, v, c) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, (1 - v) * 16), child: c)),
      child: child,
    );
  }
}

