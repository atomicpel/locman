import 'package:flutter/material.dart';

import '../core/node.dart';
import '../state.dart';
import 'sheets.dart';
import 'theme.dart';
import 'widgets.dart';

class NodesScreen extends StatefulWidget {
  const NodesScreen({super.key, required this.s});
  final AppState s;

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  late final TextEditingController _query = TextEditingController(text: widget.s.query);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  int _byLatency(AppState s, ProxyNode a, ProxyNode b) {
    final la = s.latencyOf(a.id);
    final lb = s.latencyOf(b.id);
    int rank(int l) => l > 0 ? 0 : (l == 0 ? 1 : 2);
    final r = rank(la).compareTo(rank(lb));
    if (r != 0) return r;
    return la.compareTo(lb);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final p = PaletteScope.of(context);
    final q = s.query.trim().toLowerCase();
    final list = s.visibleNodes().where((n) {
      if (s.filter == 'live' && s.latencyOf(n.id) <= 0) return false;
      if (s.filter == 'reality' && !n.isReality) return false;
      if (s.filter == 'xhttp' && !n.isXhttp) return false;
      if (q.isEmpty) return true;
      return '${n.name} ${n.title} ${n.place.code ?? ''} ${n.protocol.title} ${n.transportLabel}'.toLowerCase().contains(q);
    }).toList();
    final dead = list.where((n) => s.isDead(n.id)).toList()..sort((a, b) => _byLatency(s, a, b));
    final alive = list.where((n) => !s.isDead(n.id)).toList();

    final items = <Widget>[];
    for (final src in s.allSources) {
      if (!s.isEnabled(src)) continue;
      final group = alive.where((n) => n.sourceId == src.id).toList()..sort((a, b) => _byLatency(s, a, b));
      if (group.isEmpty) continue;
      final open = !(s.collapsed[src.id] ?? false);
      items.add(_GroupTitle(title: src.title, count: group.length, open: open, onTap: () => s.toggleCollapsed(src.id)));
      if (open) items.add(_Rows(s: s, nodes: group));
    }
    if (dead.isNotEmpty) {
      final open = !(s.collapsed['dead'] ?? true);
      items.add(_GroupTitle(title: 'Не отвечают', count: dead.length, open: open, onTap: () => s.toggleCollapsed('dead')));
      if (open) items.add(_Rows(s: s, nodes: dead));
    }

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          sliver: SliverList.list(children: [
            _SearchField(controller: _query, onChanged: s.setQuery),
            const SizedBox(height: 12),
            Segment<String>(
              value: s.filter,
              onChanged: s.setFilter,
              options: const [('all', 'Все'), ('live', 'Живые'), ('reality', 'Reality'), ('xhttp', 'XHTTP')],
            ),
            if (s.checkingAll > 0) ...[
              const SizedBox(height: 12),
              Text('Проверяем: ${s.checkingDone} из ${s.checkingAll}', style: p.text(13, color: p.muted)),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: s.checkingAll == 0 ? null : s.checkingDone / s.checkingAll,
                color: p.accent,
                backgroundColor: p.border,
              ),
            ],
            if (items.isEmpty) ...[
              const SizedBox(height: 32),
              Text(
                s.refreshing.isNotEmpty
                    ? 'Загружаем источники…'
                    : 'Ничего не нашлось. Включите источник или снимите фильтр.',
                textAlign: TextAlign.center,
                style: p.text(14, color: p.muted),
              ),
            ],
            const SizedBox(height: 16),
          ]),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverList.separated(
            itemCount: items.length,
            itemBuilder: (_, i) => items[i],
            separatorBuilder: (_, i) => SizedBox(height: items[i] is _GroupTitle ? 8 : 16),
          ),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(p.rPill),
        border: Border.all(color: p.border),
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.search_rounded, size: 18, color: p.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: p.text(14),
              cursorColor: p.accent,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Страна, город, протокол',
                hintStyle: p.text(14, color: p.muted),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            IconButton(
              tooltip: 'Очистить поиск',
              icon: Icon(Icons.close_rounded, size: 18, color: p.muted),
              onPressed: () {
                controller.clear();
                onChanged('');
              },
            ),
        ],
      ),
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.title, required this.count, required this.open, required this.onTap});
  final String title;
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        children: [
          Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(14, weight: FontWeight.w600))),
          const SizedBox(width: 8),
          Text('$count', style: p.text(12, color: p.muted)),
          const Spacer(),
          Text(open ? 'Скрыть' : 'Показать', style: p.text(12, color: p.muted)),
        ],
      ),
    );
  }
}

/// Группа строк в одной рамке. Большие группы показываем порциями, чтобы список не тормозил.
class _Rows extends StatefulWidget {
  const _Rows({required this.s, required this.nodes});
  final AppState s;
  final List<ProxyNode> nodes;

  @override
  State<_Rows> createState() => _RowsState();
}

class _RowsState extends State<_Rows> {
  int _limit = 30;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final shown = widget.nodes.take(_limit).toList();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(p.rCard),
        border: Border.all(color: p.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: p.border),
            NodeRow(s: widget.s, node: shown[i]),
          ],
          if (widget.nodes.length > _limit) ...[
            Divider(height: 1, thickness: 1, color: p.border),
            InkWell(
              onTap: () => setState(() => _limit += 60),
              child: SizedBox(
                height: 48,
                child: Center(
                  child: Text('Ещё ${widget.nodes.length - _limit}', style: p.text(14, weight: FontWeight.w500, color: p.accent)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class NodeRow extends StatelessWidget {
  const NodeRow({super.key, required this.s, required this.node});
  final AppState s;
  final ProxyNode node;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final latency = s.latencyOf(node.id);
    final checking = s.checkingId == node.id;
    return InkWell(
      onTap: () => showNodeSheet(context, s, node),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.surface2,
                  borderRadius: BorderRadius.circular(p.rCard * 0.75),
                  border: Border.all(color: p.border),
                ),
                child: Text(node.badge, style: p.text(12, weight: FontWeight.w600)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(node.place.city ?? node.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(15, weight: FontWeight.w500)),
                        ),
                        if (s.pinnedId == node.id) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.push_pin_rounded, size: 14, color: p.accent),
                        ],
                        if (s.activeId == node.id && s.phase == Phase.on) ...[
                          const SizedBox(width: 6),
                          Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: p.accent)),
                        ],
                      ],
                    ),
                    Text(node.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(12, color: p.muted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                checking ? '…' : (latency > 0 ? '$latency мс' : (latency < 0 ? 'нет ответа' : '—')),
                style: p.text(14, color: latency < 0 ? p.danger : p.fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
