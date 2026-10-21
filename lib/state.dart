import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core/b64.dart';
import 'core/catalog.dart';
import 'core/node.dart';
import 'core/ru.dart';
import 'core/subscription.dart';
import 'core/xray_config.dart';
import 'data/files.dart';
import 'engine/native.dart';
import 'engine/net.dart';

enum Skin { glass, paper, dot, signal, island }

enum Phase { off, seek, on, fail }

enum AppTab { home, nodes, sources, more }

enum SettingsPage { look, link, apps, safe, probe, about }

const skinMeta = {
  Skin.glass: ('Стекло', 'Прозрачные капсулы и холодный свет', false),
  Skin.paper: ('Чернила', 'Бумага, тушь и засечки', false),
  Skin.dot: ('Точка', 'Монохром и красная точка', true),
  Skin.signal: ('Сигнал', 'Плоский тёмный сигнал', true),
  Skin.island: ('Остров', 'Крупная плитка и живой остров', false),
};

/// auto — сами смотрим, allow — БС (белые списки), block — ЧС (обычные блокировки).
const modeMeta = {
  'auto': ('Авто', 'Сами смотрим, белый список в сети или чёрный'),
  'allow': ('БС', 'Белые списки: узлы, которые проходят через фильтр оператора'),
  'block': ('ЧС', 'Обычные блокировки: зарубежные узлы'),
};

/// Скорость проверки: сколько узлов проверяем через ядро одновременно.
const probeMeta = {
  'gentle': ('Бережная', 6),
  'normal': ('Обычная', 16),
  'fast': ('Быстрая', 32),
};

const dnsMeta = {'cloud': 'Cloudflare', 'quad': 'Quad9', 'google': 'Google'};

const intervalMeta = {'manual': 'Вручную', '1h': 'Каждый час', '6h': 'Каждые 6 ч', '24h': 'Раз в сутки'};
const intervalHours = {'manual': 0, '1h': 1, '6h': 6, '24h': 24};

const seekLabels = ['Смотрим сеть', 'Стучимся по TCP', 'Проверяем ответ', 'Выбираем ход'];

const repo = 'atomicpel/locman';
const testUrl = 'https://www.gstatic.com/generate_204';

class NodeCheck {
  NodeCheck(this.delay, this.at, this.fails, this.real);
  final int delay;
  final int at;
  final int fails;
  final bool real;

  bool get alive => delay > 0;
  List<Object> toJson() => [delay, at, fails, real ? 1 : 0];
  static NodeCheck? fromJson(Object? j) {
    if (j is! List || j.length < 4) return null;
    return NodeCheck((j[0] as num).toInt(), (j[1] as num).toInt(), (j[2] as num).toInt(), j[3] == 1);
  }
}

class SourceInfo {
  SourceInfo({this.updatedAt = 0, this.error, this.title, this.announce, this.usage, this.skipped = 0});
  int updatedAt;
  String? error;
  String? title;
  String? announce;
  String? usage;
  int skipped;

  Map<String, dynamic> toJson() => {
        'updatedAt': updatedAt,
        if (error != null) 'error': error,
        if (title != null) 'title': title,
        if (announce != null) 'announce': announce,
        if (usage != null) 'usage': usage,
        'skipped': skipped,
      };

  static SourceInfo fromJson(Map<String, dynamic>? j) => j == null
      ? SourceInfo()
      : SourceInfo(
          updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
          error: j['error'] as String?,
          title: j['title'] as String?,
          announce: j['announce'] as String?,
          usage: j['usage'] as String?,
          skipped: (j['skipped'] as num?)?.toInt() ?? 0,
        );
}

class UpdateInfo {
  UpdateInfo(this.versionCode, this.versionName, this.notes, this.url, this.sha256, this.size);
  final int versionCode;
  final String versionName;
  final List<String> notes;
  final String url;
  final String sha256;
  final int size;
}

class JournalEntry {
  JournalEntry(this.at, this.text);
  final int at;
  final String text;
}

class AppState extends ChangeNotifier {
  // ---------- сохраняемые настройки ----------
  bool onboarded = false;
  bool publicOn = true;
  Skin skin = Skin.glass;
  String scheme = 'dark';
  String mode = 'auto';
  String probe = 'normal';
  String dns = 'cloud';
  bool directRu = true;
  bool autoConnect = false;
  bool hideInsecure = true;
  bool hideDupes = false;
  bool fragment = true;
  String tunEngine = 'xray';

  /// К каким узлам подключаться при поиске: 'all' — ко всем подряд, 'reality' — только к Reality.
  String pickFrom = 'all';
  Set<String> noFrag = {};
  String? pinnedId;
  String? lastNodeId;
  Set<String> excludes = {};
  Map<String, bool> collapsed = {'dead': true};
  Map<String, bool> enabledOverrides = {};
  Map<String, String> intervals = {};
  List<Source> mine = [];
  List<JournalEntry> journal = [];

  // ---------- данные ----------
  NativeInfo? info;
  Files? files;
  Catalog? catalog;
  final Map<String, List<ProxyNode>> nodesBySource = {};
  final Map<String, SourceInfo> sourceInfo = {};
  final Map<String, NodeCheck> health = {};
  final Set<String> refreshing = {};
  NetKind? detected;
  UpdateInfo? update;
  double? updateProgress;
  String? updateError;
  bool checkingUpdate = false;

  // ---------- состояние экрана ----------
  bool ready = false;
  AppTab tab = AppTab.home;
  SettingsPage? settingsPage;
  String query = '';
  String filter = 'all';
  String? checkingId;
  int checkingAll = 0;
  int checkingDone = 0;
  String? toast;
  Phase phase = Phase.off;
  int seekStep = 0;
  String? activeId;
  String? failText;
  int? connectedAt;
  int now = 0;
  int down = 0;
  int up = 0;
  int sessionDown = 0;
  int sessionUp = 0;
  final List<int> history = [];

  int _seekGen = 0;

  /// Сколько TCP-проверок одновременно. В эмуляторе меньше: его сеть (slirp) захлёбывается.
  int _tcpParallel = 96;
  int _poolLimit = 240;
  bool _skipTcp = false;
  Timer? _toastTimer;
  Timer? _ticker;
  Timer? _periodic;
  int _probeFails = 0;
  bool _probing = false;
  StreamSubscription<Object>? _events;
  final Random _random = Random();

  // =====================================================================
  // Запуск
  // =====================================================================

  Future<void> init() async {
    try {
      info = await Native.info();
      files = Files(info!.filesDir);
    } catch (_) {
      // Без Android-части (тесты) работаем в памяти.
      files = Files(Directory.systemTemp.createTempSync('locman').path);
    }
    await _loadSettings();
    await _loadHealth();
    await _loadCatalog();
    await _loadCachedSubscriptions();
    ready = true;
    notifyListeners();

    _events = Native.events().listen(_onNative, onError: (_) {});
    try {
      _applyStatus(await Native.state());
    } catch (_) {}

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _periodic = Timer.periodic(const Duration(minutes: 15), (_) => unawaited(_background()));
    unawaited(_background());
    if (info?.smoke == true) {
      unawaited(_smoke());
    } else if (onboarded && autoConnect && phase == Phase.off) {
      unawaited(connect());
    }
  }

  /// Самопроверка в эмуляторе CI: `am start … --ez smoke true [--es skin island]`.
  /// Пишет в logcat строки «SMOKE: …», по ним скрипт делает снимки экрана.
  /// Снимок экрана для самопроверки; задаёт интерфейс.
  Future<Uint8List?> Function()? screenshot;

  Future<void> _smoke() async {
    final dir = info!.extDir;
    final logFile = dir == null ? null : File('$dir/smoke.txt');
    if (logFile != null && logFile.existsSync()) logFile.deleteSync();
    void say(String s) {
      debugPrint('SMOKE: $s');
      logFile?.writeAsStringSync('SMOKE: $s\n', mode: FileMode.append, flush: true);
      if (s.startsWith('shot ') && dir != null) {
        final name = s.substring(5);
        screenshot?.call().then((png) {
          if (png != null) File('$dir/${info!.smokeSkin ?? 'app'}-$name.png').writeAsBytesSync(png);
        });
      }
    }
    Future<void> pause(int s) => Future.delayed(Duration(seconds: s));
    try {
      final wanted = info!.smokeSkin;
      if (wanted != null) skin = Skin.values.firstWhere((s) => s.name == wanted, orElse: () => skin);
      probe = 'gentle';
      _tcpParallel = 6;
      _poolLimit = 16;
      _skipTcp = info!.smokeSkin == 'glass';
      _smokeSink = say;
      var beats = 0;
      Timer.periodic(const Duration(seconds: 5), (t) {
        beats++;
        say('beat $beats phase=${phase.name} step=$seekStep checking=$checkingDone');
        if (phase == Phase.on || phase == Phase.fail || beats > 120) t.cancel();
      });
      if (info!.smokeTun != null) tunEngine = info!.smokeTun == 'hev' ? 'hev' : 'xray';
      say('start xray=${info!.xray} version=${info!.versionName} tun=$tunEngine fragment=$fragment');
      if (!onboarded) {
        onboarded = true;
        publicOn = true;
        _save();
        notifyListeners();
      }
      await refreshAll();
      final perSource = [
        for (final s in allSources)
          if (isEnabled(s)) '${s.id}=${nodesBySource[s.id]?.length ?? 0}${sourceInfo[s.id]?.error != null ? '(!)' : ''}',
      ];
      say('sources ${perSource.join(' ')}');
      say('nodes $visibleCount');
      await pause(2);
      say('shot home-off');
      await pause(3);
      await connect();
      final n = nodeById(activeId);
      if (phase == Phase.on && n != null) {
        say('connected ${n.title} ${n.protocol.title}/${n.transportLabel} kind=${detected?.name}');
        say('probe ${await Net.probeTunnel()} noFrag=${noFrag.length}');
        String ip(String body) =>
            RegExp(r'^ip=(.+)$', multiLine: true).firstMatch(body)?.group(1) ?? '?';
        try {
          final via = await Net.get('https://www.cloudflare.com/cdn-cgi/trace', viaTunnel: true);
          final direct = await Net.get('https://www.cloudflare.com/cdn-cgi/trace');
          say('ip tunnel=${ip(via.body)} direct=${ip(direct.body)}');
        } catch (e) {
          say('ip error ${_short(e)}');
        }
      } else {
        say('fail ${failText ?? phase.name}');
      }
      await pause(5);
      say('shot home-on');
      await pause(3);
      setTab(AppTab.nodes);
      await pause(3);
      say('shot nodes');
      await pause(3);
      setTab(AppTab.sources);
      await pause(3);
      say('shot sources');
      await pause(3);
      setTab(AppTab.more);
      setSettingsPage(SettingsPage.about);
      await pause(3);
      say('shot about');
      await pause(3);
      setTab(AppTab.home);
      await pause(3);
      say('shot home-final');
      say('traffic down=$sessionDown up=$sessionUp');
      await pause(2);
      await disconnect();
      await pause(3);
      say('done');
    } catch (e, st) {
      say('error $e $st');
    }
  }

  /// Обновления по расписанию, пока приложение открыто.
  Future<void> _background() async {
    if (!onboarded) return;
    final catalogAge = DateTime.now().difference(catalog?.generatedAt ?? DateTime(2000));
    if (catalogAge > const Duration(hours: 12)) await refreshCatalog(quiet: true);
    await refreshDue();
    await checkUpdate(quiet: true);
  }

  void onResume() {
    unawaited(_background());
    Native.state().then(_applyStatus).catchError((_) {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _periodic?.cancel();
    _toastTimer?.cancel();
    _events?.cancel();
    super.dispose();
  }

  // =====================================================================
  // Настройки
  // =====================================================================

  Future<void> _loadSettings() async {
    final j = await files!.readJson('state.json');
    if (j == null) return;
    T pick<T>(String key, T fallback) => j[key] is T ? j[key] as T : fallback;
    onboarded = pick('onboarded', false);
    publicOn = pick('publicOn', true);
    skin = Skin.values.firstWhere((s) => s.name == j['skin'], orElse: () => Skin.glass);
    scheme = pick('scheme', 'dark');
    mode = modeMeta.containsKey(j['mode']) ? j['mode'] as String : 'auto';
    probe = probeMeta.containsKey(j['probe']) ? j['probe'] as String : 'normal';
    dns = dnsMeta.containsKey(j['dns']) ? j['dns'] as String : 'cloud';
    directRu = pick('directRu', true);
    autoConnect = pick('autoConnect', false);
    hideInsecure = pick('hideInsecure', true);
    hideDupes = pick('hideDupes', false);
    fragment = pick('fragment', true);
    tunEngine = j['tunEngine'] == 'hev' ? 'hev' : 'xray';
    pickFrom = j['pickFrom'] == 'reality' ? 'reality' : 'all';
    noFrag = ((j['noFrag'] as List?) ?? const []).map((e) => e.toString()).toSet();
    pinnedId = j['pinnedId'] as String?;
    lastNodeId = j['lastNodeId'] as String?;
    excludes = ((j['excludes'] as List?) ?? const []).map((e) => e.toString()).toSet();
    collapsed = Map<String, bool>.from((j['collapsed'] as Map?) ?? const {'dead': true});
    enabledOverrides = Map<String, bool>.from((j['enabled'] as Map?) ?? const {});
    intervals = Map<String, String>.from((j['intervals'] as Map?) ?? const {});
    mine = ((j['mine'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Source.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    journal = ((j['journal'] as List?) ?? const [])
        .whereType<List>()
        .map((e) => JournalEntry((e[0] as num).toInt(), e[1].toString()))
        .toList();
  }

  Timer? _saveTimer;

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(files?.writeJson('state.json', {
        'onboarded': onboarded,
        'publicOn': publicOn,
        'skin': skin.name,
        'scheme': scheme,
        'mode': mode,
        'probe': probe,
        'dns': dns,
        'directRu': directRu,
        'autoConnect': autoConnect,
        'hideInsecure': hideInsecure,
        'hideDupes': hideDupes,
        'fragment': fragment,
        'tunEngine': tunEngine,
        'pickFrom': pickFrom,
        'noFrag': noFrag.take(800).toList(),
        'pinnedId': pinnedId,
        'lastNodeId': lastNodeId,
        'excludes': excludes.toList(),
        'collapsed': collapsed,
        'enabled': enabledOverrides,
        'intervals': intervals,
        'mine': mine.map((s) => s.toJson()).toList(),
        'journal': journal.map((e) => [e.at, e.text]).toList(),
      }));
    });
  }

  void _set(VoidCallback change) {
    change();
    _save();
    notifyListeners();
  }

  /// В режиме самопроверки журнал дублируется в файл.
  void Function(String)? _smokeSink;

  void log(String text) {
    _smokeSink?.call('log $text');
    journal.insert(0, JournalEntry(DateTime.now().millisecondsSinceEpoch, text));
    if (journal.length > 40) journal.removeRange(40, journal.length);
    _save();
  }

  void flash(String text) {
    _toastTimer?.cancel();
    toast = text;
    notifyListeners();
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      toast = null;
      notifyListeners();
    });
  }

  void finishOnboarding(bool openSources) {
    _set(() {
      onboarded = true;
      publicOn = openSources;
      enabledOverrides.clear();
    });
    log(openSources ? 'Открытые источники включены' : 'Только свои источники');
    unawaited(Native.requestNotifications().catchError((_) {}));
    if (openSources) unawaited(refreshAll());
  }

  void setTab(AppTab t) {
    tab = t;
    settingsPage = null;
    notifyListeners();
  }

  void setSettingsPage(SettingsPage? p) {
    settingsPage = p;
    notifyListeners();
  }

  void setSkin(Skin s) => _set(() => skin = s);
  void setScheme(String s) => _set(() => scheme = s);
  void setMode(String m) {
    _set(() => mode = m);
    log('Режим сети: ${modeMeta[m]!.$1}');
  }

  void setProbe(String p) => _set(() => probe = p);
  void setDns(String d) {
    _set(() => dns = d);
    log('DNS: ${dnsMeta[d]}');
  }

  void setDirectRu(bool v) => _set(() => directRu = v);
  void setAutoConnect(bool v) => _set(() => autoConnect = v);
  void setHideInsecure(bool v) => _set(() => hideInsecure = v);
  void setHideDupes(bool v) => _set(() => hideDupes = v);
  void setFragment(bool v) => _set(() => fragment = v);
  void setTunEngine(String v) => _set(() => tunEngine = v);
  void setPickFrom(String v) {
    _set(() => pickFrom = v);
    log(v == 'reality' ? 'Подключаться только к живым Reality' : 'Подключаться к любым живым узлам');
  }
  void setQuery(String q) {
    query = q;
    notifyListeners();
  }

  void setFilter(String f) {
    filter = f;
    notifyListeners();
  }

  void toggleCollapsed(String id) => _set(() => collapsed[id] = !(collapsed[id] ?? false));

  void toggleExclude(String package) => _set(() {
        if (!excludes.remove(package)) excludes.add(package);
      });

  void resetAll() {
    unawaited(disconnect());
    _set(() {
      onboarded = false;
      skin = Skin.glass;
      scheme = 'dark';
      mode = 'auto';
      probe = 'normal';
      dns = 'cloud';
      directRu = true;
      autoConnect = false;
      hideInsecure = true;
      hideDupes = false;
      fragment = true;
      tunEngine = 'xray';
      pickFrom = 'all';
      pinnedId = null;
      excludes.clear();
      enabledOverrides.clear();
      intervals.clear();
      journal.clear();
      tab = AppTab.home;
      settingsPage = null;
    });
    health.clear();
    unawaited(_saveHealth());
    flash('Настройки сброшены');
  }

  // =====================================================================
  // Источники
  // =====================================================================

  List<Source> get catalogSources => catalog?.sources ?? const [];
  List<Source> get allSources => [...mine, ...catalogSources];

  Source? sourceById(String id) {
    for (final s in allSources) {
      if (s.id == id) return s;
    }
    return null;
  }

  bool isEnabled(Source s) {
    final o = enabledOverrides[s.id];
    if (o != null) return o;
    if (s.isMine) return true;
    return publicOn && s.recommended && s.status != 'empty' && s.status != 'stale';
  }

  String intervalOf(Source s) => intervals[s.id] ?? (s.hasUrl ? '6h' : 'manual');

  void toggleSource(Source s) {
    final on = !isEnabled(s);
    _set(() => enabledOverrides[s.id] = on);
    log('${s.title}: ${on ? 'вкл' : 'выкл'}');
    if (on && (nodesBySource[s.id]?.isEmpty ?? true) && s.hasUrl) unawaited(refreshSource(s));
  }

  void cycleInterval(Source s) {
    const order = ['manual', '1h', '6h', '24h'];
    final next = order[(order.indexOf(intervalOf(s)) + 1) % order.length];
    _set(() => intervals[s.id] = next);
  }

  Future<void> _loadCatalog() async {
    Catalog? builtIn;
    try {
      builtIn = Catalog.tryParse(await rootBundle.loadString('assets/catalog.json'));
    } catch (_) {}
    final cachedText = await files!.readText('catalog.json');
    final cached = cachedText == null ? null : Catalog.tryParse(cachedText);
    if (cached != null && (builtIn == null || cached.generatedAt.isAfter(builtIn.generatedAt))) {
      catalog = cached;
    } else {
      catalog = builtIn;
    }
  }

  Future<void> refreshCatalog({bool quiet = false}) async {
    try {
      final r = await Net.getAny([
        'https://raw.githubusercontent.com/$repo/main/catalog/catalog.json',
        'https://cdn.jsdelivr.net/gh/$repo@main/catalog/catalog.json',
      ]);
      final fresh = Catalog.tryParse(r.body);
      if (fresh == null) throw const FormatException('каталог не разобрался');
      final before = catalogSources.map((s) => s.id).toSet();
      catalog = fresh;
      await files!.writeText('catalog.json', r.body);
      final added = fresh.sources.where((s) => !before.contains(s.id)).length;
      if (added > 0) log('В каталоге новых источников: $added');
      notifyListeners();
    } catch (e) {
      if (!quiet) flash('Каталог не обновился: ${_short(e)}');
    }
  }

  Future<void> _loadCachedSubscriptions() async {
    final inputs = <(String, String, Map<String, String>)>[];
    for (final s in allSources) {
      final meta = await files!.readJson('subs/${s.id}.json');
      sourceInfo[s.id] = SourceInfo.fromJson(meta);
      if (s.links != null) {
        inputs.add((s.id, s.links!, const {}));
        continue;
      }
      final body = await files!.readText('subs/${s.id}.txt');
      if (body != null) inputs.add((s.id, body, const {}));
    }
    final parsed = await _parseMany(inputs);
    nodesBySource
      ..clear()
      ..addAll(parsed);
  }

  static Future<Map<String, List<ProxyNode>>> _parseMany(List<(String, String, Map<String, String>)> inputs) =>
      compute(_parseManySync, inputs);

  /// Обновляем источники, которым пора по их интервалу.
  Future<void> refreshDue() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final due = allSources.where((s) {
      if (!s.hasUrl || !isEnabled(s)) return false;
      final info = sourceInfo[s.id];
      final hours = intervalHours[intervalOf(s)] ?? 0;
      if ((nodesBySource[s.id]?.isEmpty ?? true) && (info?.updatedAt ?? 0) == 0) return true;
      return hours > 0 && nowMs - (info?.updatedAt ?? 0) > hours * 3600 * 1000;
    }).toList();
    await _refreshMany(due);
  }

  Future<void> refreshAll() async {
    flash('Обновляем источники');
    await refreshCatalog(quiet: true);
    await _refreshMany(allSources.where((s) => s.hasUrl && isEnabled(s)).toList());
    log('Источники обновлены');
    flash('Источники обновлены');
  }

  Future<void> _refreshMany(List<Source> list) async {
    var i = 0;
    Future<void> worker() async {
      while (i < list.length) {
        final s = list[i++];
        await refreshSource(s, quiet: true);
      }
    }

    await Future.wait(List.generate(min(4, list.length), (_) => worker()));
  }

  Future<void> refreshSource(Source s, {bool quiet = false}) async {
    if (!s.hasUrl || refreshing.contains(s.id)) return;
    refreshing.add(s.id);
    notifyListeners();
    final info = sourceInfo.putIfAbsent(s.id, SourceInfo.new);
    try {
      final r = await Net.getAny(s.mirrors);
      final body = r.body;
      final parsed = await compute(_parseOneSync, (body, s.id, r.headers));
      if (parsed.nodes.isEmpty) {
        throw HttpException(body.trimLeft().startsWith('<') ? 'вместо подписки пришла веб-страница' : 'в подписке сейчас нет узлов');
      }
      await files!.writeText('subs/${s.id}.txt', body);
      nodesBySource[s.id] = parsed.nodes;
      info
        ..updatedAt = DateTime.now().millisecondsSinceEpoch
        ..error = null
        ..title = parsed.title
        ..announce = parsed.announce
        ..skipped = parsed.skipped.values.fold(0, (a, b) => a + b)
        ..usage = _usageText(parsed.usage);
      if (s.isMine && parsed.updateIntervalHours != null && !intervals.containsKey(s.id)) {
        final h = parsed.updateIntervalHours!;
        intervals[s.id] = h <= 1 ? '1h' : (h <= 6 ? '6h' : '24h');
      }
    } catch (e) {
      info.error = _short(e);
      if (!quiet) flash('${s.title}: ${info.error}');
    } finally {
      refreshing.remove(s.id);
      await files!.writeJson('subs/${s.id}.json', info.toJson());
      notifyListeners();
    }
  }

  String? _usageText(Usage? u) {
    if (u == null) return null;
    final parts = <String>[];
    if (u.total > 0) parts.add('${formatBytes(u.used)} из ${formatBytes(u.total)}');
    if (u.expire > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(u.expire * 1000);
      parts.add('до ${d.day}.${d.month.toString().padLeft(2, '0')}.${d.year}');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Добавить свой источник: ссылка подписки или ключи (по одному в строке).
  Future<String?> addMine(String text, String name) async {
    final input = text.trim();
    if (input.isEmpty) return 'Вставьте ссылку подписки или ключи';
    final lines = input.split(RegExp(r'\s+')).where((l) => l.isNotEmpty).toList();
    final isUrl = lines.length == 1 && RegExp(r'^https?://', caseSensitive: false).hasMatch(lines.first);
    String? links;
    if (!isUrl) {
      var body = input;
      if (!body.contains('://')) body = decodeBase64(body) ?? body;
      final parsed = SubscriptionParser.parse(body, 'probe');
      if (parsed.nodes.isEmpty) return 'Не нашёл ни одного ключа vless, vmess, trojan, ss или hy2';
      links = parsed.nodes.map((n) => n.raw).join('\n');
    }
    final id = 'mine-${stableId(isUrl ? lines.first : links!)}';
    if (mine.any((s) => s.id == id)) return 'Такой источник уже есть';
    final title = name.trim().isNotEmpty
        ? name.trim()
        : (isUrl ? (Uri.tryParse(lines.first)?.host ?? 'Моя подписка') : 'Мои ключи');
    final source = Source(
      id: id,
      title: title,
      author: 'Вы',
      homepage: '',
      license: 'своё',
      description: isUrl ? 'Подписка по ссылке' : 'Ключи, вставленные вручную',
      mode: 'any',
      mirrors: isUrl ? [lines.first] : const [],
      origin: 'mine',
      links: links,
    );
    _set(() {
      mine.insert(0, source);
      tab = AppTab.sources;
    });
    if (links != null) {
      nodesBySource[id] = SubscriptionParser.parse(links, id).nodes;
      sourceInfo[id] = SourceInfo(updatedAt: DateTime.now().millisecondsSinceEpoch);
      notifyListeners();
    } else {
      await refreshSource(source);
    }
    log('Добавлен «$title»');
    flash('Источник добавлен');
    return null;
  }

  void removeMine(Source s) {
    if (!s.isMine) return;
    final ids = nodesBySource[s.id]?.map((n) => n.id).toSet() ?? {};
    _set(() {
      mine.removeWhere((m) => m.id == s.id);
      if (ids.contains(pinnedId)) pinnedId = null;
    });
    nodesBySource.remove(s.id);
    unawaited(files!.delete('subs/${s.id}.txt'));
    unawaited(files!.delete('subs/${s.id}.json'));
    if (ids.contains(activeId)) unawaited(disconnect());
    log('Удалён источник «${s.title}»');
  }

  void removeNode(ProxyNode n) {
    final s = sourceById(n.sourceId);
    if (s == null || !s.isMine || s.links == null) return;
    final rest = (nodesBySource[s.id] ?? const <ProxyNode>[]).where((x) => x.id != n.id).toList();
    final updated = Source(
      id: s.id,
      title: s.title,
      author: s.author,
      homepage: s.homepage,
      license: s.license,
      description: s.description,
      mode: s.mode,
      mirrors: s.mirrors,
      origin: s.origin,
      links: rest.map((x) => x.raw).join('\n'),
    );
    _set(() {
      mine = [for (final m in mine) m.id == s.id ? updated : m];
      nodesBySource[s.id] = rest;
      if (pinnedId == n.id) pinnedId = null;
    });
    if (activeId == n.id) unawaited(disconnect());
  }

  // =====================================================================
  // Узлы
  // =====================================================================

  String get _healthKind => (detected ?? (mode == 'allow' ? NetKind.white : NetKind.black)).name;

  NodeCheck? checkOf(String nodeId) => health['$_healthKind/$nodeId'];

  /// Результат проверки считается свежим 20 минут — потом узел снова «не проверен».
  static const freshMs = 20 * 60 * 1000;

  int latencyOf(String nodeId) {
    final c = checkOf(nodeId);
    if (c == null) return 0;
    if (DateTime.now().millisecondsSinceEpoch - c.at > freshMs) return 0;
    return c.delay;
  }

  /// Есть ли вообще свежие проверки — тогда фильтры показывают только живые узлы.
  bool get hasFreshChecks {
    final cutoff = DateTime.now().millisecondsSinceEpoch - freshMs;
    final prefix = '$_healthKind/';
    return health.entries.any((e) => e.key.startsWith(prefix) && e.value.at > cutoff);
  }

  bool isDead(String nodeId) => (checkOf(nodeId)?.fails ?? 0) >= 2;

  ProxyNode? nodeById(String? id) {
    if (id == null) return null;
    for (final list in nodesBySource.values) {
      for (final n in list) {
        if (n.id == id) return n;
      }
    }
    return null;
  }

  List<ProxyNode> visibleNodes() {
    final out = <ProxyNode>[];
    final seen = <String>{};
    for (final s in allSources) {
      if (!isEnabled(s)) continue;
      for (final n in nodesBySource[s.id] ?? const <ProxyNode>[]) {
        if (hideInsecure && n.isInsecure) continue;
        if (!seen.add(hideDupes ? n.endpointKey : n.id)) continue;
        out.add(n);
      }
    }
    return out;
  }

  int get visibleCount => visibleNodes().length;

  void _record(String nodeId, int delay, {required bool real}) {
    final key = '$_healthKind/$nodeId';
    final prev = health[key];
    health[key] = NodeCheck(delay, DateTime.now().millisecondsSinceEpoch, delay > 0 ? 0 : (prev?.fails ?? 0) + 1, real);
  }

  Future<void> _loadHealth() async {
    final j = await files!.readJson('health.json');
    if (j == null) return;
    final cutoff = DateTime.now().millisecondsSinceEpoch - 24 * 3600 * 1000;
    j.forEach((k, v) {
      final c = NodeCheck.fromJson(v);
      if (c != null && c.at > cutoff) health[k] = c;
    });
  }

  Future<void> _saveHealth() async {
    if (health.length > 4000) {
      final sorted = health.entries.toList()..sort((a, b) => b.value.at.compareTo(a.value.at));
      health
        ..clear()
        ..addEntries(sorted.take(4000));
    }
    await files?.writeJson('health.json', {for (final e in health.entries) e.key: e.value.toJson()});
  }

  bool _fragFor(ProxyNode n) => fragment && n.canFragment && !noFrag.contains(n.id);

  String _testConfig(ProxyNode n, {required bool frag}) => XrayConfig.build(n, forTest: true, dns: dns, fragment: frag);

  /// Настоящая проверка: запрос через узел силами Xray; для Hysteria2 и JSON — только так.
  /// С фрагментацией не прошёл — пробуем без неё и запоминаем, что этому узлу она мешает.
  Future<int> _realTest(ProxyNode n) async {
    final frag = _fragFor(n);
    final d = await Native.measure(_testConfig(n, frag: frag), testUrl);
    if (d > 0 || !frag) return d;
    final plain = await Native.measure(_testConfig(n, frag: false), testUrl);
    if (plain > 0) noFrag.add(n.id);
    return plain;
  }

  Future<int> _testOne(ProxyNode n) async {
    if (!n.coreOnly) {
      final tcp = await Net.tcping(n.address, n.port);
      if (tcp < 0) return -1;
    }
    return _realTest(n);
  }

  Future<void> checkNode(ProxyNode n) async {
    checkingId = n.id;
    notifyListeners();
    final delay = await _testOne(n);
    _record(n.id, delay, real: true);
    checkingId = null;
    unawaited(_saveHealth());
    flash(delay > 0 ? '${n.title} · $delay мс' : 'Нет ответа');
  }

  Future<void> checkAll() async {
    if (checkingAll > 0) return;
    // На вкладке Reality/XHTTP проверяем только их — так в разы быстрее.
    final list = visibleNodes().where((n) {
      if (filter == 'reality') return n.isReality;
      if (filter == 'xhttp') return n.isXhttp;
      return true;
    }).toList();
    if (list.isEmpty) {
      flash('Нет узлов для проверки');
      return;
    }
    checkingAll = list.length;
    checkingDone = 0;
    notifyListeners();
    // Конвейер: TCP-проверка и настоящая проверка идут одновременно, а не по очереди.
    // Один сервер (адрес:порт) пингуем по TCP один раз, даже если он в списке много раз.
    final tcpCache = <String, Future<int>>{};
    final real = _Gate(probeMeta[probe]!.$2);
    await _pool(list, _tcpParallel, (n) async {
      if (!n.coreOnly) {
        final key = '${n.address.toLowerCase()}:${n.port}';
        final tcp = await (tcpCache[key] ??= Net.tcping(n.address, n.port, timeout: const Duration(milliseconds: 1500)));
        if (tcp < 0) {
          _record(n.id, -1, real: false);
          checkingDone++;
          _throttledNotify();
          return;
        }
      }
      final d = await real.run(() => Native.measure(_testConfig(n, frag: _fragFor(n)), testUrl));
      _record(n.id, d, real: true);
      checkingDone++;
      _throttledNotify();
    });
    checkingAll = 0;
    unawaited(_saveHealth());
    final alive = list.where((n) => latencyOf(n.id) > 0).length;
    log('Проверены узлы: живых $alive из ${list.length}');
    flash('Живых узлов: $alive из ${list.length}');
  }

  int _lastNotify = 0;
  void _throttledNotify() {
    final t = DateTime.now().millisecondsSinceEpoch;
    if (t - _lastNotify > 250) {
      _lastNotify = t;
      notifyListeners();
    }
  }

  static Future<void> _pool<T>(List<T> items, int concurrency, Future<void> Function(T) task) async {
    var i = 0;
    Future<void> worker() async {
      while (i < items.length) {
        final item = items[i++];
        await task(item);
      }
    }

    await Future.wait(List.generate(min(concurrency, items.length), (_) => worker()));
  }

  void togglePin(ProxyNode n) {
    final pin = pinnedId == n.id ? null : n.id;
    _set(() => pinnedId = pin);
    log(pin != null ? 'Закреплён ${n.title}' : 'Снят пин ${n.title}');
  }

  // =====================================================================
  // Подключение
  // =====================================================================

  void togglePower() {
    if (phase == Phase.on || phase == Phase.seek) {
      unawaited(disconnect());
    } else {
      unawaited(connect());
    }
  }

  Future<void> disconnect() async {
    _seekGen++;
    final n = nodeById(activeId);
    phase = Phase.off;
    seekStep = 0;
    connectedAt = null;
    down = 0;
    up = 0;
    notifyListeners();
    try {
      await Native.stop();
    } catch (_) {}
    Net.tunnel = null;
    log(n != null ? 'Отключено · ${n.title}' : 'Отключено');
  }

  NetKind? _kindForMode() => switch (mode) {
        'allow' => NetKind.white,
        'block' => NetKind.black,
        _ => detected,
      };

  /// Кандидаты для поиска: включённые источники под нужный режим, без мёртвых и небезопасных.
  List<ProxyNode> _candidates(NetKind? kind) {
    final fits = <ProxyNode>[];
    final seen = <String>{};
    for (final s in allSources) {
      if (!isEnabled(s) || !s.fits(kind)) continue;
      for (final n in nodesBySource[s.id] ?? const <ProxyNode>[]) {
        if (hideInsecure && n.isInsecure) continue;
        if (pickFrom == 'reality' && !n.isReality) continue;
        if (isDead(n.id)) continue;
        if (!seen.add(n.endpointKey)) continue;
        fits.add(n);
      }
    }
    // Сначала недавно живые (по задержке), потом остальные вперемешку.
    final known = fits.where((n) => latencyOf(n.id) > 0).toList()
      ..sort((a, b) => latencyOf(a.id).compareTo(latencyOf(b.id)));
    final rest = fits.where((n) => latencyOf(n.id) <= 0).toList()..shuffle(_random);
    return [...known, ...rest];
  }

  Future<void> connect({bool ignorePin = false, String? nodeId}) async {
    final token = ++_seekGen;
    bool cancelled() => token != _seekGen;

    if (!allSources.any(isEnabled)) {
      _fail('Нет включённых источников');
      flash('Включите источник');
      return;
    }
    phase = Phase.seek;
    seekStep = 1;
    failText = null;
    tab = AppTab.home;
    notifyListeners();
    log(ignorePin ? 'Ищем рабочий узел' : 'Прокладываем ход');

    bool permitted;
    try {
      permitted = await Native.prepare();
    } catch (_) {
      permitted = false;
    }
    if (cancelled()) return;
    if (!permitted) {
      _fail('Нужно разрешение на VPN');
      return;
    }

    // Шаг 1: смотрим сеть. Если туннель уже поднят, проверка напрямую всё равно честная:
    // само приложение в туннель не заходит.
    if (mode == 'auto') {
      detected = await Net.detectKind();
      if (cancelled()) return;
    }
    final kind = _kindForMode();

    final tried = <String>{};
    var started = false;
    ProxyNode? chosen;
    if (nodeId != null) {
      chosen = nodeById(nodeId);
    } else if (!ignorePin && pinnedId != null) {
      chosen = nodeById(pinnedId);
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      if (chosen == null) {
        chosen = await _seek(kind, tried, cancelled);
        if (cancelled()) return;
        if (chosen == null) {
          _fail('Рабочий узел не найден', stopTunnel: started);
          return;
        }
      }
      tried.add(chosen.id);
      seekStep = 4;
      notifyListeners();
      started = true;
      final ok = await _bring(chosen, cancelled);
      if (cancelled()) return;
      if (ok) return;
      _record(chosen.id, -1, real: true);
      log('${chosen.title} не пропускает трафик, ищем другой');
      chosen = null;
    }
    _fail('Узлы не пропускают трафик', stopTunnel: started);
  }

  Future<ProxyNode?> _seek(NetKind? kind, Set<String> tried, bool Function() cancelled) async {
    final pool = _candidates(kind).where((n) => !tried.contains(n.id)).take(_poolLimit).toList();
    if (pool.isEmpty) return null;

    seekStep = 2;
    notifyListeners();
    _smokeSink?.call('seek pool=${pool.length}');
    final tcp = <ProxyNode, int>{};
    await _pool(pool, _tcpParallel, (n) async {
      if (cancelled()) return;
      tcp[n] = (n.coreOnly || _skipTcp) ? 0 : await Net.tcping(n.address, n.port);
      if (tcp[n]! < 0) _record(n.id, -1, real: false);
    });
    if (cancelled()) return null;

    seekStep = 3;
    notifyListeners();
    final alive = tcp.entries.where((e) => e.value >= 0).toList()..sort((a, b) => a.value.compareTo(b.value));
    final shortlist = alive.take(24).map((e) => e.key).toList();
    _smokeSink?.call('tcp alive=${alive.length} shortlist=${shortlist.length}');
    final real = <ProxyNode, int>{};
    await _pool(shortlist, probeMeta[probe]!.$2, (n) async {
      if (cancelled()) return;
      _smokeSink?.call('measure ${n.protocol.title} ${n.transportLabel} ${n.address}');
      final d = await _realTest(n);
      _smokeSink?.call('measured ${n.address} = $d');
      _record(n.id, d, real: true);
      if (d > 0) real[n] = d;
    });
    unawaited(_saveHealth());
    if (cancelled() || real.isEmpty) return null;
    return real.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
  }

  /// Поднимаем туннель через узел и проверяем, что трафик идёт.
  Future<bool> _bring(ProxyNode n, bool Function() cancelled) async {
    final local = LocalProxy(
      socksPort: await Net.freePort(),
      httpPort: await Net.freePort(),
      user: Net.token(12),
      pass: Net.token(24),
    );
    // Адрес сервера ищем через DoH и берём самый быстрый IP — как Happ.
    var target = n;
    if (n.needsResolve) {
      final ips = (await Net.resolveDoh(n.address)).take(4).toList();
      if (cancelled()) return false;
      if (ips.length == 1 || (ips.isNotEmpty && n.coreOnly)) {
        target = n.withAddress(ips.first);
      } else if (ips.length > 1) {
        final pings = await Future.wait(ips.map((ip) => Net.tcping(ip, n.port)));
        var best = -1;
        for (var i = 0; i < ips.length; i++) {
          if (pings[i] > 0 && (best < 0 || pings[i] < pings[best])) best = i;
        }
        target = n.withAddress(ips[best < 0 ? 0 : best]);
      }
    }
    final xrayTun = tunEngine == 'xray';
    final config = XrayConfig.build(target,
        local: local, directRu: directRu, dns: dns, fragment: _fragFor(n), xrayTun: xrayTun);
    final bypass = {...excludes, if (directRu) ...directApps}.toList();
    _smokeSink?.call('bring ${target.address} tun=$tunEngine');
    // Ждём статус именно этого узла, чтобы не принять «подключено» от предыдущего.
    final waiter = Native.events()
        .where((e) => e is VpnStatus && e.phase != 'connecting' && (e.phase != 'connected' || e.nodeId == n.id))
        .first;
    try {
      await Native.start(
        config: config,
        name: n.title,
        nodeId: n.id,
        socksPort: local.socksPort,
        httpPort: local.httpPort,
        user: local.user,
        pass: local.pass,
        bypass: bypass,
        tunMode: tunEngine,
      );
    } catch (e) {
      log('Служба VPN не запустилась: ${_short(e)}');
      return false;
    }
    Object status;
    try {
      status = await waiter.timeout(const Duration(seconds: 20));
    } catch (_) {
      status = const VpnStatus('failed', error: 'служба не ответила');
    }
    if (cancelled()) return false;
    if (status is! VpnStatus || status.phase != 'connected') {
      log('Туннель не поднялся: ${(status as VpnStatus).error ?? ''}');
      return false;
    }
    Net.tunnel = local;
    var ok = false;
    for (var i = 0; i < 2 && !ok; i++) {
      ok = await Net.probeTunnel();
      if (cancelled()) return false;
    }
    if (!ok) return false;

    activeId = n.id;
    lastNodeId = n.id;
    phase = Phase.on;
    seekStep = 0;
    connectedAt = DateTime.now().millisecondsSinceEpoch;
    sessionDown = 0;
    sessionUp = 0;
    history.clear();
    _probeFails = 0;
    _save();
    final kind = detected == null ? '' : ' · ${detected == NetKind.white ? 'БС' : 'ЧС'}';
    final ms = latencyOf(n.id);
    log('${n.title} · ${n.protocol.title}${ms > 0 ? ' · $ms мс' : ''}$kind');
    notifyListeners();
    return true;
  }

  void _fail(String text, {bool stopTunnel = false}) {
    if (stopTunnel) {
      // Служба осталась на неработающем узле — гасим, чтобы не держать телефон без сети.
      Net.tunnel = null;
      unawaited(Native.stop().catchError((_) {}));
    }
    phase = Phase.fail;
    seekStep = 0;
    failText = text;
    activeId = null;
    connectedAt = null;
    log(text);
    notifyListeners();
  }

  void _onNative(Object e) {
    if (e is Traffic) {
      if (phase != Phase.on) return;
      down = e.down;
      up = e.up;
      sessionDown = e.downTotal;
      sessionUp = e.upTotal;
      history.add(e.down);
      if (history.length > 28) history.removeAt(0);
      notifyListeners();
    } else if (e is VpnStatus) {
      _applyStatus(e);
    }
  }

  void _applyStatus(VpnStatus s) {
    if (phase == Phase.seek) return; // поиск сам разбирается со статусами
    if (s.phase == 'connected' && phase != Phase.on) {
      // Служба поднята без экрана (плитка, загрузка, постоянный VPN).
      phase = Phase.on;
      activeId = s.nodeId;
      connectedAt = s.since ?? DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
    }
    if (s.phase == 'connected' && phase == Phase.on && s.nodeId != null && s.nodeId!.isNotEmpty && s.nodeId != activeId) {
      // Служба — источник правды о том, какой узел реально поднят.
      log('Сверка с туннелем: активен ${s.name ?? s.nodeId}');
      activeId = s.nodeId;
      notifyListeners();
    }
    if (s.phase == 'connected' && s.local != null && Net.tunnel == null) {
      Net.tunnel = s.local;
    } else if ((s.phase == 'idle' || s.phase == 'failed') && phase == Phase.on) {
      phase = s.phase == 'failed' ? Phase.fail : Phase.off;
      failText = s.error;
      connectedAt = null;
      Net.tunnel = null;
      notifyListeners();
    }
  }

  void _tick() {
    now = DateTime.now().millisecondsSinceEpoch;
    if (phase == Phase.on) {
      notifyListeners();
      // Раз в 30 секунд проверяем, что узел жив; два провала подряд — ищем новый.
      if (Net.tunnel != null && now ~/ 1000 % 30 == 0 && !_probing) {
        _probing = true;
        Net.probeTunnel().then((ok) {
          _probing = false;
          if (phase != Phase.on) return;
          _probeFails = ok ? 0 : _probeFails + 1;
          if (_probeFails >= 2) {
            final n = nodeById(activeId);
            if (n != null) _record(n.id, -1, real: true);
            log('Узел перестал отвечать, ищем другой');
            flash('Узел не отвечает — ищем другой');
            unawaited(connect(ignorePin: true));
          }
        });
      }
    }
  }

  // =====================================================================
  // Обновления приложения
  // =====================================================================

  Future<void> checkUpdate({bool quiet = false}) async {
    if (info == null || checkingUpdate) return;
    checkingUpdate = true;
    updateError = null;
    notifyListeners();
    try {
      final r = await Net.getAny([
        'https://github.com/$repo/releases/latest/download/update.json',
        'https://raw.githubusercontent.com/$repo/updates/update.json',
        'https://cdn.jsdelivr.net/gh/$repo@updates/update.json',
      ]);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final code = (j['versionCode'] as num).toInt();
      if (code <= info!.versionCode) {
        update = null;
        if (!quiet) flash('Установлена последняя версия');
      } else {
        final assets = Map<String, dynamic>.from(j['assets'] as Map);
        Map? asset;
        for (final abi in [...info!.abis, 'universal']) {
          if (assets[abi] is Map) {
            asset = assets[abi] as Map;
            break;
          }
        }
        if (asset == null) throw const FormatException('в релизе нет APK для этого телефона');
        update = UpdateInfo(
          code,
          j['versionName'] as String,
          ((j['notes'] as List?) ?? const []).map((e) => e.toString()).toList(),
          asset['url'] as String,
          asset['sha256'] as String,
          (asset['size'] as num?)?.toInt() ?? 0,
        );
        if (!quiet) flash('Доступна версия ${update!.versionName}');
      }
    } catch (e) {
      updateError = _short(e);
      if (!quiet) flash('Не удалось проверить: $updateError');
    } finally {
      checkingUpdate = false;
      notifyListeners();
    }
  }

  Future<void> installUpdate() async {
    final u = update;
    if (u == null || updateProgress != null) return;
    if (!u.url.startsWith('https://')) {
      flash('Ссылка на APK должна быть https');
      return;
    }
    updateProgress = 0;
    updateError = null;
    notifyListeners();
    final target = File('${info!.cacheDir}/updates/locman-${u.versionCode}.apk');
    try {
      await target.parent.create(recursive: true);
      Object? last;
      var done = false;
      for (final via in Net.routes) {
        try {
          await Net.download(u.url, target, viaTunnel: via, onProgress: (p) {
            updateProgress = p;
            _throttledNotify();
          });
          done = true;
          break;
        } catch (e) {
          last = e;
        }
      }
      if (!done) throw last ?? const HttpException('не скачалось');
      final problem = await Native.verifyApk(target.path, u.sha256, u.versionCode);
      if (problem != null) {
        await target.delete();
        throw HttpException(problem);
      }
      final started = await Native.installApk(target.path);
      if (!started) flash('Разрешите установку из «Лоцмана» и нажмите «Обновить» ещё раз');
    } catch (e) {
      updateError = _short(e);
      flash('Обновление: $updateError');
    } finally {
      updateProgress = null;
      notifyListeners();
    }
  }

  static String _short(Object e) {
    var s = e is HttpException
        ? e.message
        : e is FormatException
            ? e.message
            : e is PlatformException
                ? (e.message ?? e.code)
                : e.toString();
    s = s.replaceFirst(RegExp(r'^(Exception|HttpException|FormatException):\s*'), '');
    return s.length > 90 ? '${s.substring(0, 89)}…' : s;
  }
}

Map<String, List<ProxyNode>> _parseManySync(List<(String, String, Map<String, String>)> inputs) => {
      for (final (id, body, headers) in inputs) id: SubscriptionParser.parse(body, id, headers: headers).nodes,
    };

ParsedSubscription _parseOneSync((String, String, Map<String, String>) input) =>
    SubscriptionParser.parse(input.$1, input.$2, headers: input.$3);

/// Ограничитель одновременных задач.
class _Gate {
  _Gate(this.limit);
  final int limit;
  int _busy = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_busy >= limit) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _busy++;
    try {
      return await task();
    } finally {
      _busy--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }
}

String formatRate(int bytesPerSec) {
  if (bytesPerSec < 1024) return '$bytesPerSec Б/с';
  if (bytesPerSec < 1024 * 1024) return '${(bytesPerSec / 1024).round()} КБ/с';
  final mega = bytesPerSec / (1024 * 1024);
  return '${mega >= 10 ? mega.toStringAsFixed(0) : mega.toStringAsFixed(1)} МБ/с';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
}

String formatClock(int ms) {
  final total = max(0, ms ~/ 1000);
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String formatUpdated(int ms) {
  if (ms <= 0) return 'ещё не обновлялся';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const months = ['янв', 'фев', 'мар', 'апр', 'мая', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'];
  final hh = d.hour.toString().padLeft(2, '0');
  final mi = d.minute.toString().padLeft(2, '0');
  return '${d.day} ${months[d.month - 1]}, $hh:$mi';
}

String nodeCountLabel(int count) {
  final m10 = count % 10;
  final m100 = count % 100;
  if (m10 == 1 && m100 != 11) return '$count узел';
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return '$count узла';
  return '$count узлов';
}
