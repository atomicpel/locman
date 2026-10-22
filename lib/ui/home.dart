import 'dart:math';

import 'package:flutter/material.dart';

import '../core/node.dart';
import '../engine/native.dart';
import '../state.dart';
import 'orb.dart';
import 'theme.dart';
import 'widgets.dart';

String phaseLabel(Phase phase) => switch (phase) {
      Phase.on => 'В сети',
      Phase.seek => 'Ищем ход',
      Phase.fail => 'Нет хода',
      Phase.off => 'Выключено',
    };

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final node = s.nodeById(s.activeId);
    final pinned = s.nodeById(s.pinnedId);
    final on = s.phase == Phase.on;
    final elapsed = on && s.connectedAt != null ? (s.now == 0 ? 0 : s.now - s.connectedAt!) : 0;
    final island = p.skin == Skin.island;

    final content = ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        if (s.update != null) ...[_UpdateBanner(s: s), const SizedBox(height: 12)],
        if (island) ...[
          Center(child: _LiveIsland(s: s, node: node)),
          const SizedBox(height: 20),
        ],
        const SizedBox(height: 8),
        Center(
          child: island ? _IslandPower(s: s, node: node) : Orb(phase: s.phase, onTap: s.togglePower),
        ),
        if (!island) ...[
          const SizedBox(height: 20),
          Text(
            s.phase == Phase.fail
                ? (s.failText ?? 'Узел не отвечает')
                : s.phase == Phase.seek
                    ? seekLabels[max(0, min(seekLabels.length - 1, s.seekStep - 1))]
                    : phaseLabel(s.phase),
            textAlign: TextAlign.center,
            style: p.text(14, weight: FontWeight.w500, color: s.phase == Phase.fail ? p.danger : p.muted),
          ),
        ],
        if (s.phase == Phase.seek) ...[
          const SizedBox(height: 16),
          for (var i = 0; i < seekLabels.length; i++) ...[
            _SeekStep(index: i, step: s.seekStep),
            const SizedBox(height: 8),
          ],
        ] else ...[
          const SizedBox(height: 16),
          Text(
            node?.place.city ?? node?.title ?? pinned?.title ?? 'Узел не выбран',
            textAlign: TextAlign.center,
            style: p.text(18, weight: FontWeight.w600),
          ),
          Text(
            node != null
                ? node.subtitle
                : pinned != null
                    ? 'Закреплён: ${pinned.subtitle}'
                    : 'Возьмём самый быстрый из включённых',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: p.text(14, color: p.muted),
          ),
          if (on && node != null)
            Center(
              child: Pressable(
                onTap: () => s.ban(node),
                label: 'Сервер в чёрный список',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.block_rounded, size: 14, color: p.danger),
                      const SizedBox(width: 4),
                      Text('В чёрный список', style: p.text(13, weight: FontWeight.w500, color: p.danger)),
                    ],
                  ),
                ),
              ),
            ),
        ],
        if (on && s.huntStatus != null) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: p.muted)),
              const SizedBox(width: 8),
              Flexible(child: Text(s.huntStatus!, style: p.text(13, color: p.muted))),
              const SizedBox(width: 8),
              Pressable(
                onTap: s.dismissOffer,
                label: 'Остановить поиск',
                child: Icon(Icons.close_rounded, size: 16, color: p.muted),
              ),
            ],
          ),
        ],
        if (on && s.offer != null) ...[
          const SizedBox(height: 16),
          _OfferCard(s: s),
        ],
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: StatTile('Вниз', on ? formatRate(s.down) : '—')),
          const SizedBox(width: 8),
          Expanded(child: StatTile('Вверх', on ? formatRate(s.up) : '—')),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: StatTile('За сессию', on ? formatBytes(s.sessionDown + s.sessionUp) : '—')),
          const SizedBox(width: 8),
          Expanded(child: StatTile('В сети', on ? formatClock(elapsed) : '—')),
        ]),
        if (on) ...[
          const SizedBox(height: 16),
          _IpCard(s: s),
        ],
        if (s.phase != Phase.seek) ...[
          const SizedBox(height: 16),
          PillButton(label: 'Найти рабочий узел', onTap: () => s.connect(ignorePin: true)),
        ],
        const SizedBox(height: 16),
        Panel(
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
                        Text('Свои сервисы напрямую', style: p.text(16, weight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                          s.directRu
                              ? 'Банки, Госуслуги, Яндекс, VK и маркетплейсы идут мимо узла.'
                              : 'Весь трафик идёт через выбранный узел.',
                          style: p.text(14, color: p.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  PillSwitch(on: s.directRu, onChanged: s.setDirectRu, label: 'Свои сервисы напрямую'),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Режим сети: ${modeMeta[s.mode]!.$1}. ${modeMeta[s.mode]!.$2}.'
                '${s.mode == 'auto' && s.detected != null ? ' Сейчас: ${s.detected!.name == 'white' ? 'белые списки' : 'обычные блокировки'}.' : ''}',
                style: p.text(12, color: p.muted),
              ),
              const SizedBox(height: 8),
              Pressable(
                onTap: () => s.setTab(AppTab.sources),
                label: 'Сменить режим',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('Сменить режим', style: p.text(14, weight: FontWeight.w500, color: p.accent)),
                ),
              ),
            ],
          ),
        ),
        if (s.directRu && s.phase == Phase.on) ...[
          const SizedBox(height: 8),
          Text(
            'Изменение «Свои сервисы напрямую» применится при следующем подключении.',
            textAlign: TextAlign.center,
            style: p.text(12, color: p.muted),
          ),
        ],
      ],
    );
    return p.skin == Skin.dot ? DotGrid(child: content) : content;
  }
}

class _SeekStep extends StatelessWidget {
  const _SeekStep({required this.index, required this.step});
  final int index;
  final int step;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final done = step > index + 1;
    final current = step == index + 1;
    return Panel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      highlight: current,
      color: current ? p.surface : p.surface2,
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? p.accent : Colors.transparent,
              border: Border.all(color: done ? p.accent : p.border),
            ),
            child: done
                ? Icon(Icons.check_rounded, size: 14, color: p.accentFg)
                : Text('${index + 1}', style: p.text(12, color: p.muted)),
          ),
          const SizedBox(width: 12),
          Text(seekLabels[index], style: p.text(14, color: done || current ? p.fg : p.muted)),
          if (current) ...[
            const Spacer(),
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent)),
          ],
        ],
      ),
    );
  }
}

class _LiveIsland extends StatelessWidget {
  const _LiveIsland({required this.s, required this.node});
  final AppState s;
  final ProxyNode? node;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: p.fg,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [BoxShadow(color: p.bg.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 10))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: s.phase == Phase.fail ? p.danger : p.accent),
          ),
          const SizedBox(width: 8),
          Text(
            s.phase == Phase.on && node != null ? node!.title : phaseLabel(s.phase),
            style: p.text(14, weight: FontWeight.w500, color: p.bg),
          ),
        ],
      ),
    );
  }
}

class _IslandPower extends StatelessWidget {
  const _IslandPower({required this.s, required this.node});
  final AppState s;
  final ProxyNode? node;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final on = s.phase == Phase.on;
    return Pressable(
      onTap: s.togglePower,
      label: on ? 'Отключить' : 'Подключить',
      child: Panel(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.phase == Phase.fail
                        ? (s.failText ?? 'Узел не отвечает')
                        : s.phase == Phase.seek
                            ? seekLabels[max(0, min(seekLabels.length - 1, s.seekStep - 1))]
                            : phaseLabel(s.phase),
                    style: p.text(14, color: s.phase == Phase.fail ? p.danger : p.muted),
                  ),
                ),
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? p.accent : p.surface2,
                    border: on ? null : Border.all(color: p.border),
                  ),
                  child: Icon(Icons.power_settings_new_rounded, size: 24, color: on ? p.accentFg : p.fg),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              on ? 'В сети' : (s.phase == Phase.seek ? 'Ищем' : 'Выключено'),
              style: p.text(30, weight: FontWeight.w600, display: true),
            ),
            const SizedBox(height: 4),
            Text(
              node != null ? '${node!.title} · ${node!.protocol.title}' : 'Нажмите, чтобы проложить ход',
              style: p.text(14, color: p.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final u = s.update!;
    final progress = s.updateProgress;
    return Panel(
      highlight: true,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Доступна версия ${u.versionName}', style: p.text(15, weight: FontWeight.w600)),
                if (u.notes.isNotEmpty)
                  Text(u.notes.first, maxLines: 2, overflow: TextOverflow.ellipsis, style: p.text(13, color: p.muted)),
                if (progress != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress, color: p.accent, backgroundColor: p.border),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 120,
            child: PillButton(label: progress != null ? 'Качаем…' : 'Обновить', primary: true, onTap: progress != null ? null : s.installUpdate),
          ),
        ],
      ),
    );
  }
}

/// «Как вас видят сайты» — проверка адреса через туннель сразу после подключения.
class _IpCard extends StatelessWidget {
  const _IpCard({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final i = s.ipInfo;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: p.text(12, color: p.muted)),
              const SizedBox(height: 2),
              SelectableText(value, style: p.text(16, weight: FontWeight.w600)),
            ],
          ),
        );
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Как вас видят сайты', style: p.text(16, weight: FontWeight.w600))),
              if (s.ipLoading)
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.accent))
              else
                Pressable(
                  onTap: s.refreshIp,
                  label: 'Проверить адрес ещё раз',
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.refresh_rounded, size: 20, color: p.muted),
                  ),
                ),
            ],
          ),
          if (i != null) ...[
            row('IP-адрес', i.ip),
            row('Местоположение', i.place.isEmpty ? '—' : '${i.flag.isEmpty ? '' : '${i.flag} '}${i.place}'),
            row('Провайдер', [i.provider, i.asn].whereType<String>().join(' · ').ifEmpty('—')),
            const SizedBox(height: 8),
            Text('по данным ${i.source}', style: p.text(12, color: p.muted)),
          ] else if (s.ipError != null) ...[
            const SizedBox(height: 8),
            Text('Не удалось проверить: ${s.ipError}', style: p.text(14, color: p.danger)),
          ] else ...[
            const SizedBox(height: 8),
            Text('Проверяем адрес через туннель…', style: p.text(14, color: p.muted)),
          ],
          const SizedBox(height: 4),
          Pressable(
            onTap: () => Native.openUrl('https://2ip.io/ru/'),
            label: 'Открыть 2ip.io',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('Открыть 2ip.io в браузере', style: p.text(14, weight: FontWeight.w500, color: p.accent)),
            ),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// «Нашёл быстрее» — переключиться или оставить текущий и искать дальше.
class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final o = s.offer!;
    return Panel(
      highlight: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bolt_rounded, color: p.accent, size: 20),
              const SizedBox(width: 6),
              Expanded(child: Text('Нашёл узел быстрее', style: p.text(16, weight: FontWeight.w600))),
              Pressable(
                onTap: s.dismissOffer,
                label: 'Закрыть',
                child: Icon(Icons.close_rounded, size: 18, color: p.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('${o.node.place.city ?? o.node.title} · ${o.node.protocol.title} · ${o.node.transportLabel}',
              style: p.text(15, weight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(
            '${formatRate(o.speed)}${o.delay > 0 ? ' · ${o.delay} мс' : ''}   ·   сейчас ${formatRate(o.currentSpeed)}',
            style: p.text(14, color: p.muted),
          ),
          const SizedBox(height: 12),
          PillButton(label: 'Переключиться', primary: true, onTap: s.acceptOffer),
          const SizedBox(height: 8),
          PillButton(label: 'Оставить текущий и искать дальше', onTap: s.keepAndSearch),
        ],
      ),
    );
  }
}
