import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../state.dart';
import 'home.dart';
import 'more.dart';
import 'nodes.dart';
import 'orb.dart';
import 'sources.dart';
import 'theme.dart';
import 'widgets.dart';

class LocmanApp extends StatefulWidget {
  const LocmanApp({super.key, required this.state});
  final AppState state;

  @override
  State<LocmanApp> createState() => _LocmanAppState();
}

class _LocmanAppState extends State<LocmanApp> with WidgetsBindingObserver {
  final _boundary = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.screenshot = () async {
      final ro = _boundary.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;
      final image = await ro.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ImageByteFormat.png);
      return data?.buffer.asUint8List();
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.state.onResume();
  }

  @override
  void didChangePlatformBrightness() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final s = widget.state;
        final system = PlatformDispatcher.instance.platformBrightness == Brightness.dark;
        final locked = skinMeta[s.skin]!.$3;
        final dark = locked || (s.scheme == 'system' ? system : s.scheme == 'dark');
        final p = Palette.of(s.skin, dark);
        final overlay = (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
        );
        return RepaintBoundary(
          key: _boundary,
          child: PaletteScope(
          palette: p,
          child: MaterialApp(
            title: 'Лоцман',
            debugShowCheckedModeBanner: false,
            theme: p.material,
            home: AnnotatedRegion<SystemUiOverlayStyle>(
              value: overlay,
              child: !s.ready
                  ? const _Splash()
                  : s.onboarded
                      ? _Shell(s: s)
                      : _Onboarding(s: s),
            ),
            builder: (context, child) => PaletteScope(palette: p, child: child!),
          ),
          ),
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore_outlined, size: 32, color: p.accent),
            const SizedBox(height: 12),
            Text('Лоцман', style: p.text(18, weight: FontWeight.w600, display: true)),
          ],
        ),
      ),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final body = switch (s.tab) {
      AppTab.home => HomeScreen(s: s),
      AppTab.nodes => NodesScreen(s: s),
      AppTab.sources => SourcesScreen(s: s),
      AppTab.more => MoreScreen(s: s),
    };
    return PopScope(
      canPop: s.tab == AppTab.home && s.settingsPage == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (s.settingsPage != null) {
          s.setSettingsPage(null);
        } else {
          s.setTab(AppTab.home);
        }
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _Header(s: s),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: KeyedSubtree(key: ValueKey('${s.tab}/${s.settingsPage}'), child: body),
                    ),
                  ),
                ],
              ),
            ),
            if (s.toast != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: p.fg,
                        borderRadius: BorderRadius.circular(p.rPill),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12)],
                      ),
                      child: Text(s.toast!, textAlign: TextAlign.center, style: p.text(14, weight: FontWeight.w500, color: p.bg)),
                    ),
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: _TabBar(s: s),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    final page = s.settingsPage;
    final title = switch (s.tab) {
      AppTab.home => 'Лоцман',
      AppTab.nodes => 'Узлы',
      AppTab.sources => 'Источники',
      AppTab.more => page != null ? settingsTitle(page) : 'Ещё',
    };
    final sub = switch (s.tab) {
      AppTab.home => phaseLabel(s.phase),
      AppTab.nodes => '${s.visibleCount} в списке',
      AppTab.sources => 'Свои и каталог',
      AppTab.more => page != null ? 'Назад к разделам' : 'Облик, ход, проверка',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          if (s.tab == AppTab.more && page != null)
            RoundIconButton(icon: Icons.arrow_back_rounded, label: 'Назад', onTap: () => s.setSettingsPage(null))
          else
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(p.rPill),
                border: Border.all(color: p.border),
              ),
              child: Icon(Icons.explore_outlined, size: 20, color: p.accent),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(20, weight: FontWeight.w600, display: true)),
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.text(14, color: p.muted)),
              ],
            ),
          ),
          if (s.tab == AppTab.sources)
            RoundIconButton(
              icon: Icons.refresh_rounded,
              label: 'Обновить все',
              busy: s.refreshing.isNotEmpty,
              onTap: s.refreshAll,
            ),
          if (s.tab == AppTab.nodes)
            RoundIconButton(icon: Icons.speed_rounded, label: 'Проверить все', busy: s.checkingAll > 0, onTap: s.checkAll),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    const items = [
      (AppTab.home, 'Главная', Icons.power_settings_new_rounded),
      (AppTab.nodes, 'Узлы', Icons.hub_outlined),
      (AppTab.sources, 'Источники', Icons.shield_outlined),
      (AppTab.more, 'Ещё', Icons.tune_rounded),
    ];
    final bar = Container(
      decoration: BoxDecoration(
        color: p.skin == Skin.glass ? p.surface.withValues(alpha: 0.78) : p.bg,
        border: Border(top: BorderSide(color: p.border)),
      ),
      padding: EdgeInsets.fromLTRB(8, 4, 8, 8 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          for (final (tab, label, icon) in items)
            Expanded(
              child: Semantics(
                selected: s.tab == tab,
                button: true,
                label: label,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => s.setTab(tab),
                  child: SizedBox(
                    height: 56,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 20, color: s.tab == tab ? p.accent : p.muted),
                        const SizedBox(height: 2),
                        Text(label, style: p.text(12, color: s.tab == tab ? p.accent : p.muted)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    if (p.skin != Skin.glass) return bar;
    return ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: bar));
  }
}

class _Onboarding extends StatelessWidget {
  const _Onboarding({required this.s});
  final AppState s;

  @override
  Widget build(BuildContext context) {
    final p = PaletteScope.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: Column(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IgnorePointer(child: Orb(phase: Phase.off, onTap: () {})),
                    const SizedBox(height: 24),
                    Text('Лоцман', style: p.text(36, weight: FontWeight.w600, display: true)),
                    const SizedBox(height: 8),
                    Text('Один ход. Узел находится сам.', textAlign: TextAlign.center, style: p.text(16, color: p.muted)),
                  ],
                ),
              ),
              for (final line in const [
                'Кнопка включает ход или останавливает поиск.',
                'Сам понимает, белые списки сейчас или обычные блокировки.',
                'Банки и Госуслуги идут напрямую, мимо узла.',
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Icon(Icons.check_rounded, size: 16, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(child: Text(line, style: p.text(14, color: p.muted))),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
              PillButton(label: 'Открытые источники', primary: true, onTap: () => s.finishOnboarding(true)),
              const SizedBox(height: 12),
              PillButton(label: 'Только свои', onTap: () => s.finishOnboarding(false)),
              const SizedBox(height: 12),
              Text(
                'Открытые источники — бесплатные публичные подписки. Свои — ваша ссылка или ключи.',
                textAlign: TextAlign.center,
                style: p.text(12, color: p.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
