import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../engine/native.dart';
import '../state.dart';
import 'sheets.dart';
import 'theme.dart';
import 'widgets.dart';

class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key, required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final white = s.catalogSources.where((c) => c.mode == 'white').toList();
    final black = s.catalogSources.where((c) => c.mode != 'white').toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        const SectionTitle('Режим сети'),
        const SizedBox(height: 8),
        Segment<String>(
          value: s.mode,
          onChanged: s.setMode,
          options: [for (final e in modeMeta.entries) (e.key, e.value.$1)],
        ),
        const SizedBox(height: 8),
        Text('${modeMeta[s.mode]!.$2}.', style: p.text(14, color: p.muted)),
        const SizedBox(height: 24),
        Row(
          children: [
            const Expanded(child: SectionTitle('Мои источники')),
            Pressable(
              onTap: () => showAddSheet(context, s),
              label: 'Добавить',
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(p.rPill)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 18, color: p.accentFg),
                    const SizedBox(width: 4),
                    Text('Добавить', style: p.text(14, weight: FontWeight.w600, color: p.accentFg)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        PillButton(
          label: s.refreshing.isNotEmpty ? 'Обновляем подписки…' : 'Обновить все подписки',
          icon: Icons.refresh_rounded,
          onTap: s.refreshing.isNotEmpty ? null : s.refreshAll,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (s.mine.isNotEmpty) ...[
              Expanded(
                child: PillButton(
                  label: 'Поделиться',
                  icon: Icons.qr_code_2_rounded,
                  onTap: () => showShareSheet(context, s),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: PillButton(
                label: 'Сканировать QR',
                icon: Icons.qr_code_scanner_rounded,
                onTap: s.scanImport,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (s.mine.isEmpty)
          Panel(
            dashed: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Text(
              'Своих пока нет. Вставьте ссылку подписки или ключи vless://, vmess://, trojan://, ss://, hy2://.',
              style: p.text(14, color: p.muted),
            ),
          )
        else
          for (final m in s.mine) ...[_SourceCard(s: s, source: m), const SizedBox(height: 12)],
        const SizedBox(height: 12),
        SectionTitle(
          'Открытый каталог',
          line: s.publicOn
              ? 'Бесплатные публичные подписки. Каталог проверяется раз в 6 часов и обновляется сам.'
              : 'Открытые источники выключены. Включите нужные вручную.',
        ),
        if (s.catalog != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Каталог от ${formatUpdated(s.catalog!.generatedAt.millisecondsSinceEpoch)}',
                style: p.text(12, color: p.muted)),
          ),
        const SizedBox(height: 16),
        Text('Для белых списков (БС)', style: p.text(13, weight: FontWeight.w600, color: p.muted)),
        const SizedBox(height: 8),
        for (final c in white) ...[_SourceCard(s: s, source: c), const SizedBox(height: 12)],
        const SizedBox(height: 8),
        Text('Для обычных блокировок (ЧС)', style: p.text(13, weight: FontWeight.w600, color: p.muted)),
        const SizedBox(height: 8),
        for (final c in black) ...[_SourceCard(s: s, source: c), const SizedBox(height: 12)],
        const SizedBox(height: 8),
        Text(
          'Узлы открытых подписок держат неизвестные люди. Банки и Госуслуги лучше оставить «напрямую», '
          'а небезопасные узлы скрываются автоматически.',
          style: p.text(12, color: p.muted),
        ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.s, required this.source});
  final AppState s;
  final Source source;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final on = s.isEnabled(source);
    final info = s.sourceInfo[source.id];
    final count = s.nodesBySource[source.id]?.length ?? 0;
    final busy = s.refreshing.contains(source.id);
    final description = info?.announce ?? (source.description.isNotEmpty ? source.description : null);
    return Opacity(
      opacity: on ? 1 : 0.7,
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(source.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(16, weight: FontWeight.w600)),
                      Text('${source.author} · ${source.license}', maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(12, color: p.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                PillSwitch(on: on, onChanged: (_) => s.toggleSource(source), label: '${source.title}: включить'),
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(description, maxLines: 4, overflow: TextOverflow.ellipsis, style: p.text(14, color: p.muted)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Tag(busy ? 'обновляем…' : nodeCountLabel(count)),
                if (source.hasUrl) Tag(intervalMeta[s.intervalOf(source)]!, onTap: () => s.cycleInterval(source)),
                if (source.isFound) const Tag('найден сам', accent: true),
                if (source.status == 'empty') const Tag('сейчас пусто'),
                if (source.status == 'stale') const Tag('давно не обновлялся'),
                if (info?.usage != null) Tag(info!.usage!),
                if (source.hasUrl)
                  Text(
                    info?.error != null ? 'ошибка: ${info!.error}' : 'обновлено ${formatUpdated(info?.updatedAt ?? 0)}',
                    style: p.text(12, color: info?.error != null ? p.danger : p.muted),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (source.hasUrl)
                  _Link(label: 'Обновить', onTap: busy ? null : () => s.refreshSource(source)),
                if (source.homepage.startsWith('http')) ...[
                  const SizedBox(width: 16),
                  _Link(label: 'Страница', onTap: () => Native.openUrl(source.homepage)),
                ],
                const Spacer(),
                if (source.isMine)
                  _Link(label: 'Удалить', danger: true, onTap: () => _confirmRemove(context, p)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, Palette p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text('Удалить «${source.title}»?', style: p.text(18, weight: FontWeight.w600)),
        content: Text('Узлы и ключи этого источника пропадут с телефона.', style: p.text(14, color: p.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Отмена', style: p.text(14))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Удалить', style: p.text(14, color: p.danger))),
        ],
      ),
    );
    if (ok == true) s.removeMine(source);
  }
}

class _Link extends StatelessWidget {
  const _Link({required this.label, required this.onTap, this.danger = false});
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Pressable(
      onTap: onTap,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(label,
            style: p.text(13, weight: FontWeight.w500, color: onTap == null ? p.muted : (danger ? p.danger : p.accent))),
      ),
    );
  }
}
