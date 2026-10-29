import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ru.dart';
import '../engine/native.dart';
import '../state.dart';
import 'backdrop.dart';
import 'theme.dart';
import 'widgets.dart';

String settingsTitle(SettingsPage page) => switch (page) {
      SettingsPage.look => 'Оформление',
      SettingsPage.link => 'Подключение',
      SettingsPage.apps => 'Мимо узла',
      SettingsPage.safe => 'Безопасность',
      SettingsPage.probe => 'Проверка узлов',
      SettingsPage.radio => 'Скрытые настройки сети',
      SettingsPage.about => 'О клиенте',
    };

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key, required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    return switch (s.settingsPage) {
      SettingsPage.look => _LookPage(s: s),
      SettingsPage.link => _LinkPage(s: s),
      SettingsPage.apps => _AppsPage(s: s),
      SettingsPage.safe => _SafePage(s: s),
      SettingsPage.probe => _ProbePage(s: s),
      SettingsPage.radio => _RadioPage(s: s),
      SettingsPage.about => _AboutPage(s: s),
      null => _MoreIndex(s: s),
    };
  }
}

class _MoreIndex extends StatelessWidget {
  const _MoreIndex({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final rows = [
      (SettingsPage.look, 'Оформление', skinMeta[s.skin]!.$1),
      (SettingsPage.link, 'Подключение', 'Режим ${modeMeta[s.mode]!.$1}${s.pickFrom == 'reality' ? ', только Reality' : ''}${s.countries == 'noRu' ? ', без RU' : ''}${Native.win ? (s.winMode == 'tun' ? ', TUN' : ', системный прокси') : ', работа в фоне'}'),
      if (!Native.win) (SettingsPage.apps, 'Мимо узла', s.excludes.isEmpty ? 'Приложения без туннеля' : 'Выбрано: ${s.excludes.length}'),
      (SettingsPage.safe, 'Безопасность', 'DNS ${dnsMeta[s.dns]} и скрытие слабых узлов'),
      (SettingsPage.probe, 'Проверка узлов', probeMeta[s.probe]!.$1),
      if (!Native.win) (SettingsPage.radio, 'Скрытые настройки сети', 'Экран *#*#4636#*#*: тип сети, LTE/5G'),
      (SettingsPage.about, 'О клиенте', s.update != null ? 'Доступна версия ${s.update!.versionName}' : 'Версия, обновления, журнал'),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        for (final (page, title, line) in rows) ...[
          Pressable(
            onTap: () => s.setSettingsPage(page),
            label: title,
            child: Panel(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: p.text(16, weight: FontWeight.w500)),
                        Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(14, color: p.muted)),
                      ],
                    ),
                  ),
                  Text('→', style: p.text(16, color: p.muted)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _LookPage extends StatelessWidget {
  const _LookPage({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final lock = skinMeta[s.skin]!.$3;
    final system = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final wantDark = s.scheme == 'system' ? system : s.scheme == 'dark';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text('Облик — ${Skin.values.length} вариантов, у каждого свой живой фон.', style: p.text(14, color: p.muted)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.92,
          children: [
            for (final (i, skin) in Skin.values.indexed)
              Appear(
                index: i,
                child: _SkinTile(
                  skin: skin,
                  selected: s.skin == skin,
                  palette: Palette.of(
                    skin,
                    skinMeta[skin]!.$3 != null ? skinMeta[skin]!.$3 == 'dark' : wantDark,
                  ),
                  onTap: () => s.setSkin(skin),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        SettingRow(
          title: 'Живой фон и анимации',
          line: 'Фон облика двигается, кнопка «дышит» и расходится волнами. Выключите — всё замрёт, '
              'так бережнее к батарее. При системном «Убрать анимации» фон замирает сам.',
          control: PillSwitch(on: s.liveBackground, onChanged: s.setLiveBackground),
        ),
        const SizedBox(height: 16),
        const SectionTitle('Тема'),
        const SizedBox(height: 8),
        if (lock != null)
          Text(lock == 'dark' ? 'У этого облика только тёмная тема.' : 'У этого облика только светлая тема.',
              style: p.text(14, color: p.muted))
        else
          Segment<String>(
            value: s.scheme,
            onChanged: s.setScheme,
            options: const [('dark', 'Тёмная'), ('light', 'Светлая'), ('system', 'Система')],
          ),
      ],
    );
  }
}

/// Плитка облика: превью его фона с кнопкой, название и описание.
class _SkinTile extends StatelessWidget {
  const _SkinTile({required this.skin, required this.selected, required this.palette, required this.onTap});
  final Skin skin;
  final bool selected;
  final Palette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final q = palette;
    return Pressable(
      onTap: onTap,
      label: skinMeta[skin]!.$1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? p.accent : p.border, width: selected ? 2 : 1),
          boxShadow: selected ? [BoxShadow(color: p.accent.withValues(alpha: 0.30), blurRadius: 18)] : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: BackdropPainter(q, 0.27, on: selected))),
              // Мини-кнопка облика
              Positioned(
                left: 0,
                right: 0,
                top: 22,
                child: Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: q.accentGradient,
                      boxShadow: [BoxShadow(color: q.accent.withValues(alpha: 0.45), blurRadius: 16)],
                    ),
                    child: Icon(Icons.power_settings_new_rounded, size: 22, color: q.accentFg),
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(q.surface, q.bg).withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(q.rCard.clamp(6, 14)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(skinMeta[skin]!.$1,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: q.text(14, weight: FontWeight.w600, display: true)),
                            Text(skinMeta[skin]!.$2,
                                maxLines: 2, overflow: TextOverflow.ellipsis, style: q.text(11, color: q.muted).copyWith(height: 1.25)),
                          ],
                        ),
                      ),
                      AnimatedScale(
                        scale: selected ? 1 : 0,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutBack,
                        child: Icon(Icons.check_circle_rounded, size: 20, color: q.accent),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkPage extends StatefulWidget {
  const _LinkPage({required this.s});
  final AppState s;

  @override
  State<_LinkPage> createState() => _LinkPageState();
}

class _LinkPageState extends State<_LinkPage> with WidgetsBindingObserver {
  bool? _restricted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    try {
      final r = await Native.batteryRestricted();
      if (mounted) setState(() => _restricted = r);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final p = PaletteScope.of(context);
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
        const SizedBox(height: 16),
        SettingRow(
          title: 'Российские сервисы напрямую',
          line: 'Банки, Госуслуги, Яндекс, VK и маркетплейсы не идут в узел — ни сайты, ни приложения.',
          control: PillSwitch(on: s.directRu, onChanged: s.setDirectRu),
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'Включать при открытии',
          line: 'Открыли «Лоцман» — он сам прокладывает ход.',
          control: PillSwitch(on: s.autoConnect, onChanged: s.setAutoConnect),
        ),
        const SizedBox(height: 16),
        const SectionTitle('К каким узлам подключаться'),
        const SizedBox(height: 8),
        Segment<String>(
          value: s.pickFrom,
          onChanged: s.setPickFrom,
          options: const [('all', 'Ко всем живым'), ('reality', 'Только Reality')],
        ),
        const SizedBox(height: 8),
        Text(
          s.pickFrom == 'reality'
              ? 'Кнопка и «Найти рабочий узел» выбирают только среди Reality, и только среди ответивших на проверку. '
                  'Reality маскируется под обычный сайт, такие узлы дольше живут под блокировками.'
              : 'Берём самый быстрый из ответивших, любого протокола: VLESS, Trojan, Shadowsocks, Hysteria2.',
          style: p.text(14, color: p.muted),
        ),
        const SizedBox(height: 16),
        const SectionTitle('Страны узлов'),
        const SizedBox(height: 8),
        Segment<String>(
          value: s.countries,
          onChanged: s.setCountries,
          options: const [('all', 'Все серверы'), ('noRu', 'Только не из России')],
        ),
        const SizedBox(height: 8),
        Text(
          s.countries == 'noRu'
              ? 'Российские узлы пропускаются при подключении, автопереключении и поиске быстрее. Страну узнаём по имени узла; '
                  'узлы без страны в имени не отсеиваются. При белых списках (БС) рабочие узлы часто именно российские — '
                  'если не находится ничего, верните «Все серверы».'
              : 'Подключаемся к узлам любых стран, включая российские.',
          style: p.text(14, color: p.muted),
        ),
        const SizedBox(height: 16),
        SettingRow(
          title: 'При переключении оставаться в той же стране',
          line: 'Если узел перестанет отвечать, «Лоцман» перейдёт только на узел той же страны, и поиск быстрее '
              'тоже ищет в ней. Нужно приложениям, которые следят за страной: ТикТок, стриминг.',
          control: PillSwitch(on: s.sameCountry, onChanged: s.setSameCountry),
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'Свой узел для БС и для ЧС',
          line: 'Запоминаем узел, который вы выбрали при белых списках и при обычных блокировках, и сами '
              'переходим на него, когда меняется сеть (Wi-Fi ↔ мобильная) или при подключении.'
              '${s.modeNodes.isEmpty ? '' : ' Сейчас: ${[
                  if (s.nodeById(s.modeNodes['white']) != null) 'БС — ${s.nodeById(s.modeNodes['white'])!.title}',
                  if (s.nodeById(s.modeNodes['black']) != null) 'ЧС — ${s.nodeById(s.modeNodes['black'])!.title}',
                ].join(', ')}.'}',
          control: PillSwitch(on: s.modeNodesOn, onChanged: s.setModeNodesOn),
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'Искать узел быстрее в фоне',
          line: 'Сразу подключаемся к первому ответившему узлу, а потом проверяем остальные и меряем скорость лучших. '
              'Нашли заметно быстрее — предложим переключиться. Тратит около 15–20 МБ за поиск.',
          control: PillSwitch(on: s.autoFaster, onChanged: s.setAutoFaster),
        ),
        if (Native.win) ..._windowsBlock(s, p) else ...[
        const SizedBox(height: 16),
        const SectionTitle('Движок туннеля'),
        const SizedBox(height: 8),
        Segment<String>(
          value: s.tunEngine,
          onChanged: s.setTunEngine,
          options: const [('xray', 'TUN в Xray'), ('hev', 'hev + SOCKS5')],
        ),
        const SizedBox(height: 8),
        Text(
          s.tunEngine == 'xray'
              ? 'Ядро Xray само читает трафик телефона — меньше звеньев, как в Happ.'
              : 'Запасной вариант, как в Farvater: TUN → hev-socks5-tunnel → SOCKS5 → Xray.',
          style: p.text(14, color: p.muted),
        ),
        const SizedBox(height: 24),
        const SectionTitle(
          'Работа в фоне',
          line: 'HyperOS на Poco любит выключать фоновые приложения. Чтобы VPN не отваливался, разрешите три вещи.',
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'Без ограничений батареи',
          line: _restricted == null
              ? 'Разрешить работу в фоне'
              : (_restricted! ? 'Сейчас ограничено — нажмите и выберите «Разрешить»' : 'Готово: ограничений нет'),
          control: Icon(
            _restricted == false ? Icons.check_circle_rounded : Icons.battery_alert_rounded,
            color: _restricted == false ? p.accent : p.muted,
          ),
          onTap: Native.openBattery,
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'Автозапуск',
          line: 'В настройках Xiaomi включите автозапуск для «Лоцмана».',
          control: Icon(Icons.open_in_new_rounded, color: p.muted),
          onTap: Native.openAutostart,
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'Постоянный VPN',
          line: 'Настройки Android → VPN → шестерёнка у «Лоцмана» → «Постоянная VPN». Тогда туннель поднимется сам после перезагрузки.',
          control: Icon(Icons.open_in_new_rounded, color: p.muted),
          onTap: Native.openVpnSettings,
        ),
        ],
      ],
    );
  }
}

class _AppsPage extends StatefulWidget {
  const _AppsPage({required this.s});
  final AppState s;

  @override
  State<_AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<_AppsPage> {
  List<InstalledApp>? _apps;
  String _q = '';
  static final Map<String, Uint8List?> _icons = {};

  @override
  void initState() {
    super.initState();
    Native.apps().then((a) {
      if (mounted) setState(() => _apps = a);
    }).catchError((_) {
      if (mounted) setState(() => _apps = const []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final p = PaletteScope.of(context);
    final apps = (_apps ?? const <InstalledApp>[])
        .where((a) => _q.isEmpty || a.label.toLowerCase().contains(_q) || a.package.contains(_q))
        .toList()
      ..sort((a, b) {
        int rank(InstalledApp x) => s.excludes.contains(x.package) || (s.directRu && directApps.contains(x.package)) ? 0 : 1;
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Отмеченные приложения не заходят в туннель. При «Российские сервисы напрямую» '
                'банки и маркетплейсы уже идут мимо — они отмечены сами.',
                style: p.text(14, color: p.muted),
              ),
              const SizedBox(height: 12),
              TextField(
                onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                style: p.text(14),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search_rounded, color: p.muted, size: 18),
                  hintText: 'Поиск приложения',
                  hintStyle: p.text(14, color: p.muted),
                  filled: true,
                  fillColor: p.surface,
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(p.rPill), borderSide: BorderSide(color: p.border)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(p.rPill), borderSide: BorderSide(color: p.accent)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _apps == null
              ? Center(child: CircularProgressIndicator(color: p.accent))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: apps.length,
                  separatorBuilder: (_, __) => Divider(height: 1, color: p.border),
                  itemBuilder: (context, i) {
                    final a = apps[i];
                    final auto = s.directRu && directApps.contains(a.package);
                    final on = auto || s.excludes.contains(a.package);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          _AppIcon(package: a.package, cache: _icons),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(15)),
                                if (auto) Text('напрямую как российский сервис', style: p.text(12, color: p.muted)),
                              ],
                            ),
                          ),
                          PillSwitch(on: on, onChanged: auto ? (_) {} : (_) => s.toggleExclude(a.package), label: a.label),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AppIcon extends StatefulWidget {
  const _AppIcon({required this.package, required this.cache});
  final String package;
  final Map<String, Uint8List?> cache;

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  @override
  void initState() {
    super.initState();
    if (!widget.cache.containsKey(widget.package)) {
      Native.appIcon(widget.package).then((b) {
        widget.cache[widget.package] = b;
        if (mounted) setState(() {});
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.cache[widget.package];
    return SizedBox(
      width: 36,
      height: 36,
      child: bytes == null ? const SizedBox() : Image.memory(bytes, gaplessPlayback: true),
    );
  }
}

class _SafePage extends StatelessWidget {
  const _SafePage({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        SettingRow(
          title: 'Скрывать небезопасные',
          line: 'Узлы без шифрования, без проверки сертификата и со старым шифрованием не попадают в список.',
          control: PillSwitch(on: s.hideInsecure, onChanged: s.setHideInsecure),
        ),
        const SizedBox(height: 12),
        SettingRow(
          title: 'Фрагментация TLS',
          line: 'Первый пакет рукопожатия режется на куски, и фильтр оператора хуже его узнаёт. '
              'Если узлу это мешает, «Лоцман» сам отключит её для него.',
          control: PillSwitch(on: s.fragment, onChanged: s.setFragment),
        ),
        SettingRow(
          title: 'Объединять соединения',
          line: 'Вместо десятков одновременных подключений к серверу — одно (mux). Фильтр оператора '
              'замораживает узел, к которому разом открывается много соединений. Работает для узлов без Vision; '
              'XHTTP и gRPC объединяют сами. Если серверу это мешает, «Лоцман» отключит для него сам.',
          control: PillSwitch(on: s.joinConns, onChanged: s.setJoinConns),
        ),
        const SizedBox(height: 16),
        const SectionTitle('DNS по HTTPS', line: 'Запросы имён идут зашифрованными через узел — провайдер их не видит.'),
        const SizedBox(height: 8),
        Segment<String>(
          value: s.dns,
          onChanged: s.setDns,
          options: [for (final e in dnsMeta.entries) (e.key, e.value)],
        ),
        const SizedBox(height: 16),
        SettingRow(
          title: 'Отправлять HWID своим подпискам',
          line: 'Платные панели с лимитом устройств (Remnawave, Marzban) по случайному номеру устройства, '
              'версии Android и модели телефона считают, сколько устройств пользуется подпиской. '
              'Публичные подписки из каталога этих данных не получают.',
          control: PillSwitch(on: s.sendHwid, onChanged: s.setSendHwid),
        ),
        const SizedBox(height: 16),
        const SettingRow(
          title: 'Локальный прокси под паролем',
          line: 'Входы ядра Xray слушают только 127.0.0.1 и закрыты одноразовым паролем — другие приложения ими не воспользуются.',
        ),
      ],
    );
  }
}

class _ProbePage extends StatelessWidget {
  const _ProbePage({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        const SectionTitle('Скорость проверки'),
        const SizedBox(height: 8),
        Segment<String>(
          value: s.probe,
          onChanged: s.setProbe,
          options: [for (final e in probeMeta.entries) (e.key, e.value.$1)],
        ),
        const SizedBox(height: 8),
        Text(
          'Сколько узлов проверяем одновременно: ${probeMeta[s.probe]!.$2}. Быстрая сильнее грузит сеть и батарею.',
          style: p.text(14, color: p.muted),
        ),
        const SizedBox(height: 16),
        const SectionTitle('Адрес проверки'),
        const SizedBox(height: 8),
        Segment<String>(
          value: s.testKey,
          onChanged: s.setTestKey,
          options: [for (final e in testUrls.entries) (e.key, e.value.$1)],
        ),
        const SizedBox(height: 8),
        Text(
          'Через узел открывается этот адрес, по ответу считается задержка. Им же сторож проверяет туннель, '
          'пока VPN включён. Если проверка врёт на вашей сети — попробуйте другой.',
          style: p.text(14, color: p.muted),
        ),
        const SizedBox(height: 16),
        SettingRow(
          title: 'Рабочие профили узлов',
          line: s.profiles.values.where((x) => !x.isPlain).isEmpty
              ? 'Если узел не пропускает данные, «Лоцман» пробует подключиться к нему иначе: как Firefox или Edge, '
                  'всё через одно соединение, с дроблением или без. Найденный способ запоминается.'
              : 'Узлов с особым профилем: ${s.profiles.values.where((x) => !x.isPlain).length}. '
                  'Они подключаются найденным способом.',
          control: s.profiles.isEmpty
              ? null
              : TextButton(
                  onPressed: s.clearProfiles,
                  child: Text('Забыть', style: p.text(14, color: p.danger)),
                ),
        ),
        const SizedBox(height: 16),
        SettingRow(
          title: 'Чёрный список серверов',
          line: s.banned.isEmpty
              ? 'Пусто. Добавить сервер — кнопка «В чёрный список» на главной или в карточке узла.'
              : 'Серверов: ${s.banned.length}. Они не участвуют в подключении, поиске и автопереключении. '
                  'Посмотреть и убрать по одному — вкладка «Узлы», группа «Чёрный список».',
          control: s.banned.isEmpty
              ? null
              : TextButton(
                  onPressed: s.clearBans,
                  child: Text('Очистить', style: p.text(14, color: p.danger)),
                ),
        ),
        const SizedBox(height: 16),
        SettingRow(
          title: 'Группа «Не отвечают»',
          line: 'Узлы, не ответившие на двух проверках подряд, собираются внизу в свёрнутую группу. '
              'Выключите — они останутся в своих подписках. В поиск они не попадают в любом случае.',
          control: PillSwitch(on: s.deadGroup, onChanged: s.setDeadGroup),
        ),
        const SizedBox(height: 16),
        SettingRow(
          title: 'Скрывать дубли',
          line: 'Один и тот же сервер из разных подписок — одна строка.',
          control: PillSwitch(on: s.hideDupes, onChanged: s.setHideDupes),
        ),
      ],
    );
  }
}

class _AboutPage extends StatelessWidget {
  const _AboutPage({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final info = s.info;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Лоцман', style: p.text(24, weight: FontWeight.w600, display: true)),
              const SizedBox(height: 4),
              Text(
                'Версия ${info?.versionName ?? '—'} · ядро Xray ${info?.xray ?? '—'}',
                style: p.text(14, color: p.muted),
              ),
              const SizedBox(height: 8),
              Text(
                'VPN-клиент на ядре Xray: одна кнопка, рабочий узел находится сам. '
                'Без аналитики и рекламы. Код открыт под GPL-3.0, основан на Farvater.',
                style: p.text(14, color: p.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (s.update != null)
          Panel(
            highlight: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Доступна версия ${s.update!.versionName}', style: p.text(16, weight: FontWeight.w600)),
                for (final n in s.update!.notes) Text('• $n', style: p.text(14, color: p.muted)),
                const SizedBox(height: 12),
                if (s.updateProgress != null)
                  LinearProgressIndicator(value: s.updateProgress, color: p.accent, backgroundColor: p.border)
                else
                  PillButton(label: 'Скачать и установить', primary: true, onTap: s.installUpdate),
              ],
            ),
          )
        else
          PillButton(
            label: s.checkingUpdate ? 'Проверяем…' : 'Проверить обновления',
            onTap: s.checkingUpdate ? null : () => s.checkUpdate(),
          ),
        if (s.updateError != null) ...[
          const SizedBox(height: 8),
          Text('Обновления: ${s.updateError}', style: p.text(13, color: p.danger)),
        ],
        const SizedBox(height: 12),
        SettingRow(
          title: 'Проверять обновления автоматически',
          line: 'При запуске и раз в 15 минут, пока «Лоцман» открыт, — небольшой файл с GitHub или jsDelivr. '
              'Само обновление скачивается, только когда вы нажмёте «Скачать и установить».',
          control: PillSwitch(on: s.autoUpdateCheck, onChanged: s.setAutoUpdateCheck),
        ),
        const SizedBox(height: 12),
        PillButton(label: 'История изменений', onTap: s.openChangelog),
        const SizedBox(height: 12),
        PillButton(label: 'Условия использования', onTap: () => s.openLegal('terms')),
        const SizedBox(height: 12),
        PillButton(label: 'Политика конфиденциальности', onTap: () => s.openLegal('privacy')),
        const SizedBox(height: 12),
        PillButton(label: 'Страница проекта', onTap: () => Native.openUrl('https://github.com/$repo')),
        const SizedBox(height: 24),
        const SectionTitle('Журнал'),
        const SizedBox(height: 8),
        if (s.journal.isEmpty)
          Text('Пока пусто.', style: p.text(14, color: p.muted))
        else
          for (final e in s.journal.take(30))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(_time(e.at), style: p.text(12, color: p.muted)),
                  ),
                  Expanded(child: Text(e.text, style: p.text(13))),
                ],
              ),
            ),
        const SizedBox(height: 24),
        PillButton(label: 'Сбросить настройки', danger: true, onTap: s.resetAll),
      ],
    );
  }

  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// Скрытые экраны настроек сети: «Информация о телефоне» (*#*#4636#*#*) и инженерное меню MediaTek.
class _RadioPage extends StatefulWidget {
  const _RadioPage({required this.s});
  final AppState s;

  @override
  State<_RadioPage> createState() => _RadioPageState();
}

class _RadioPageState extends State<_RadioPage> with WidgetsBindingObserver {
  static const adb = 'adb shell am start -n com.android.phone/com.android.phone.settings.RadioInfo';
  List<Map>? _list;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final l = await Native.hiddenScreens();
      if (mounted) setState(() => _list = l);
    } catch (e) {
      if (mounted) setState(() => _list = const []);
    }
  }

  Future<void> _open(Map c) async {
    final err = await Native.openHidden(c['pkg'] as String, c['cls'] as String);
    if (!mounted) return;
    setState(() => _error = err == null ? null : '${c['title']}: $err');
  }

  /// Пробуем по порядку: сначала доступные, потом закрытые (иногда прошивка всё же пускает).
  Future<void> _openFirst() async {
    final list = _list ?? const [];
    final order = [
      ...list.where((c) => c['status'] == 'available'),
      ...list.where((c) => c['status'] == 'closed'),
    ];
    final errors = <String>[];
    for (final c in order) {
      final err = await Native.openHidden(c['pkg'] as String, c['cls'] as String);
      if (err == null) {
        if (mounted) setState(() => _error = null);
        return;
      }
      errors.add('${c['title']}: $err');
    }
    if (mounted) {
      setState(() => _error = errors.isEmpty ? 'На этом телефоне таких экранов нет' : errors.join('\n'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final list = _list;
    final anyOpen = list?.any((c) => c['status'] == 'available') ?? false;
    const ok = Color(0xFF34C759);
    const warn = Color(0xFFFFB020);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text(
          'Системный экран «Информация о телефоне» — тот, что открывает код *#*#4636#*#*. В нём можно выбрать '
          'предпочтительный тип сети (например, только LTE или LTE/NR) и посмотреть сигнал. На realme, Xiaomi/HyperOS '
          'и Samsung код часто не срабатывает, а экран в прошивке есть — «Лоцман» откроет его напрямую.',
          style: p.text(14, color: p.muted),
        ),
        const SizedBox(height: 16),
        PillButton(
          label: 'Открыть',
          icon: Icons.settings_input_antenna_rounded,
          primary: true,
          onTap: list == null ? null : _openFirst,
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: p.text(13, color: p.danger)),
        ],
        const SizedBox(height: 20),
        const SectionTitle('Что есть на этом телефоне'),
        const SizedBox(height: 8),
        if (list == null)
          Center(child: Padding(padding: const EdgeInsets.all(16), child: CircularProgressIndicator(color: p.accent)))
        else
          for (final c in list) ...[
            Pressable(
              onTap: () => _open(c),
              label: c['title'] as String,
              child: Panel(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: switch (c['status']) {
                            'available' => ok,
                            'closed' => warn,
                            _ => p.muted,
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c['title'] as String, style: p.text(15, weight: FontWeight.w500)),
                          Text(
                            switch (c['status']) {
                              'available' => 'Доступен — нажмите, чтобы открыть',
                              'closed' => 'Есть, но закрыт${c['reason'] == null ? '' : ': ${c['reason']}'}',
                              _ => 'Отсутствует в прошивке',
                            },
                            style: p.text(13, color: p.muted),
                          ),
                          Text('${c['pkg']}/${c['cls']}', style: p.text(11, color: p.muted)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        if (list != null && !anyOpen) ...[
          const SizedBox(height: 12),
          const SectionTitle('Открыть с компьютера'),
          const SizedBox(height: 8),
          Text(
            'Если прошивка не пускает приложения, экран можно открыть через ADB: включите отладку по USB '
            'в «Для разработчиков», подключите телефон к компьютеру и выполните:',
            style: p.text(14, color: p.muted),
          ),
          const SizedBox(height: 8),
          Panel(
            padding: const EdgeInsets.all(12),
            child: SelectableText(adb, style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: p.fg)),
          ),
          const SizedBox(height: 8),
          PillButton(
            label: 'Скопировать',
            icon: Icons.copy_rounded,
            onTap: () {
              Clipboard.setData(const ClipboardData(text: adb));
              widget.s.flash('Команда скопирована');
            },
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Меняйте тип сети осторожно: неподходящий режим может оставить телефон без связи. '
          'Вернуть — на том же экране. «Лоцман» сам ничего в этих экранах не меняет.',
          style: p.text(13, color: p.muted),
        ),
      ],
    );
  }
}

/// Настройки Windows-версии: режим, автозапуск, значок у часов.
List<Widget> _windowsBlock(AppState s, Palette p) => [
      const SizedBox(height: 16),
      const SectionTitle('Как пускать трафик'),
      const SizedBox(height: 8),
      Segment<String>(
        value: s.winMode,
        onChanged: (v) => s.setWinMode(v),
        options: const [('proxy', 'Системный прокси'), ('tun', 'TUN — весь трафик')],
      ),
      const SizedBox(height: 8),
      Text(
        s.winMode == 'tun'
            ? 'Через узел идёт весь трафик компьютера, включая игры и программы, которые не слушают прокси. '
                'Нужны права администратора и драйвер Wintun (он рядом с программой). Локальная сеть идёт мимо узла.'
            : 'Через узел идут браузеры и программы, которые берут системный прокси Windows. Права администратора не нужны. '
                'Для остальных программ — HTTP 127.0.0.1:${s.winHttpPort} и SOCKS5 127.0.0.1:${s.winSocksPort}.',
        style: p.text(14, color: p.muted),
      ),
      if (s.winMode == 'tun') ...[
        const SizedBox(height: 12),
        SettingRow(
          title: 'Не пускать DNS мимо туннеля',
          line: 'Фильтры Windows: запросы DNS других программ идут только через TUN. Может помешать локальному DNS, '
              'виртуальным машинам и входу в гостевые Wi-Fi.',
          control: PillSwitch(on: s.winLeakBlock, onChanged: s.setWinLeakBlock),
        ),
      ],
      const SizedBox(height: 16),
      SettingRow(
        title: 'Запускать вместе с Windows',
        line: s.winMode == 'tun'
            ? 'Через планировщик заданий с правами администратора — и сразу подключаться.'
            : 'При входе в Windows «Лоцман» запустится свёрнутым к часам и подключится.',
        control: PillSwitch(on: s.winAutostart, onChanged: s.setWinAutostart),
      ),
      const SizedBox(height: 12),
      SettingRow(
        title: 'Сворачивать к часам',
        line: 'Крестик прячет окно в значок у часов, VPN продолжает работать. Выйти — правой кнопкой по значку → «Выход».',
        control: PillSwitch(on: s.winTray, onChanged: s.setWinTray),
      ),
    ];

