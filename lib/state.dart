import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

const seekLabels = ['Смотрим сеть', 'Стучимся по TCP', 'Проверяем ответ', 'Качаем через узел', 'Выбираем ход'];

/// Шаг «Выбираем ход» — последний.
const seekFinal = 5;

const repo = 'atomicpel/locman';

/// Адрес проверки: через узел открывается он, по ответу считается задержка.
/// Тот же адрес проверяет туннель, пока VPN включён.
const testUrls = {
  'google': ('Google', 'https://www.gstatic.com/generate_204'),
  'cloudflare': ('Cloudflare', 'https://cp.cloudflare.com/generate_204'),
  'apple': ('Apple', 'http://captive.apple.com/hotspot-detect.html'),
  'firefox': ('Firefox', 'http://detectportal.firefox.com/success.txt'),
};

/// Предложение переключиться на узел быстрее.
class Offer {
  Offer(this.node, this.speed, this.currentSpeed, this.delay);
  final ProxyNode node;
  final int speed;
  final int currentSpeed;
  final int delay;
}

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

  /// 'all' — любые страны, 'noRu' — только узлы не из России (по имени узла).
  String countries = 'all';

  /// Чёрный список серверов (адрес:порт): к ним не подключаемся ни из какой подписки.
  Set<String> banned = {};

  /// Рабочий «профиль» узла (отпечаток, mux, дробление) и DNS, который через него отвечает.
  Map<String, NodeProfile> profiles = {};

  /// Свой узел для белых списков и для обычных блокировок: 'white'/'black' → id узла.
  Map<String, String> modeNodes = {};
  bool modeNodesOn = true;

  /// При автопереключении оставаться в стране текущего узла (для ТикТока и т. п.).
  bool sameCountry = false;

  /// Адрес проверки узлов (ключ из [testUrls]).
  String testKey = 'google';

  /// Случайный номер устройства для платных панелей с ограничением числа устройств (HWID).
  String hwid = '';

  /// Последняя версия, для которой показали «Что нового».
  String? seenVersion;

  /// Проверять новые версии сами (раз в 15 минут, пока приложение открыто, и при запуске).
  bool autoUpdateCheck = true;

  /// Отправлять HWID и модель телефона своим подпискам (нужно панелям с лимитом устройств).
  bool sendHwid = true;

  /// Собирать узлы без ответа в отдельную группу «Не отвечают».
  bool deadGroup = true;

  /// Принятая редакция условий и политики (0 — ещё не принимали).
  int legalAccepted = 0;
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

  /// Фоновый поиск узла быстрее текущего.
  bool autoFaster = true;
  String? huntStatus;
  Offer? offer;
  int _huntGen = 0;
  final Set<String> _huntSeen = {};
  int _huntBar = 0;

  /// Внешний адрес после подключения (2ip / ip-api / ipwho.is).
  IpInfo? ipInfo;
  bool ipLoading = false;
  String? ipError;
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
    if (hwid.isEmpty) {
      hwid = Net.token(32);
      _save();
    }
    await _loadHealth();
    await _loadCatalog();
    await _loadCachedSubscriptions();
    ready = true;
    notifyListeners();

    _events = Native.events().listen(_onNative, onError: (_) {});
    try {
      _applyStatus(await Native.state());
    } catch (_) {}
    await _loadChangelog();
    final v = info?.versionName;
    if (v != null && info?.smoke != true) {
      if (seenVersion != null && seenVersion != v && onboarded) whatsNew = true;
      if (seenVersion != v) {
        seenVersion = v;
        _save();
      }
    }
    unawaited(_takeLink());

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _periodic = Timer.periodic(const Duration(minutes: 15), (_) => unawaited(_background()));
    unawaited(_background());
    if (info?.smoke == true) {
      unawaited(_smoke());
    } else if (onboarded && autoConnect && phase == Phase.off) {
      // Чужой VPN уже включён — не перебиваем его.
      if (await Native.otherVpn()) {
        log('Другой VPN уже включён — автоподключение пропущено');
      } else {
        unawaited(connect());
      }
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
    // При низком заряде фоновую проверку обновлений откладываем.
    final (level, charging) = await Native.battery();
    if (autoUpdateCheck && (charging || level < 0 || level > 20)) await checkUpdate(quiet: true);
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
    autoFaster = j['autoFaster'] != false;
    countries = j['countries'] == 'noRu' ? 'noRu' : 'all';
    profiles = {
      for (final e in ((j['profiles'] as Map?) ?? const {}).entries)
        if (NodeProfile.fromJson(e.value) != null) e.key.toString(): NodeProfile.fromJson(e.value)!,
    };
    modeNodes = Map<String, String>.from((j['modeNodes'] as Map?) ?? const {});
    modeNodesOn = j['modeNodesOn'] != false;
    sameCountry = j['sameCountry'] == true;
    testKey = testUrls.containsKey(j['testKey']) ? j['testKey'] as String : 'google';
    hwid = (j['hwid'] as String?) ?? '';
    seenVersion = j['seenVersion'] as String?;
    autoUpdateCheck = j['autoUpdateCheck'] != false;
    sendHwid = j['sendHwid'] != false;
    deadGroup = j['deadGroup'] != false;
    legalAccepted = (j['legalAccepted'] as num?)?.toInt() ?? 0;
    banned = ((j['banned'] as List?) ?? const []).map((e) => e.toString()).toSet();
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
        'autoFaster': autoFaster,
        'countries': countries,
        'profiles': {
          for (final e in profiles.entries.toList().reversed.take(800)) e.key: e.value.toJson(),
        },
        'modeNodes': modeNodes,
        'modeNodesOn': modeNodesOn,
        'sameCountry': sameCountry,
        'testKey': testKey,
        'hwid': hwid,
        'seenVersion': seenVersion,
        'autoUpdateCheck': autoUpdateCheck,
        'sendHwid': sendHwid,
        'deadGroup': deadGroup,
        'legalAccepted': legalAccepted,
        'banned': banned.toList(),
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
    _reapply();
  }

  void setAutoUpdateCheck(bool v) => _set(() => autoUpdateCheck = v);
  void setSendHwid(bool v) => _set(() => sendHwid = v);
  void setDeadGroup(bool v) => _set(() => deadGroup = v);

  // ---------- Условия и политика ----------

  /// Номер текущей редакции условий использования и политики конфиденциальности.
  static const legalRevision = 2;

  bool get needsLegal => legalAccepted < legalRevision;

  /// Открытый документ: 'terms' или 'privacy'.
  String? legalOpen;
  final Map<String, String> _legalText = {};

  String legalText(String doc) => _legalText[doc] ?? '';

  Future<void> openLegal(String doc) async {
    if (!_legalText.containsKey(doc)) {
      try {
        _legalText[doc] = await rootBundle.loadString('assets/legal/$doc.md');
      } catch (_) {
        _legalText[doc] = 'Документ не открылся. Он есть на странице проекта: github.com/$repo/tree/main/assets/legal';
      }
    }
    legalOpen = doc;
    notifyListeners();
  }

  void closeLegal() {
    legalOpen = null;
    notifyListeners();
  }

  void acceptLegal() {
    _set(() => legalAccepted = legalRevision);
    log('Приняты условия и политика, редакция $legalRevision');
  }

  void setSameCountry(bool v) {
    _set(() => sameCountry = v);
    log(v ? 'При переключении оставаться в той же стране' : 'При переключении — любая страна');
    _pushBackups();
  }

  void setModeNodesOn(bool v) {
    _set(() => modeNodesOn = v);
    log(v ? 'Свой узел для БС и ЧС' : 'Без своих узлов для БС и ЧС');
  }

  void setTestKey(String k) {
    _set(() => testKey = k);
    log('Адрес проверки: ${testUrls[k]!.$1}');
  }

  String get testUrl => testUrls[testKey]!.$2;

  Timer? _reapplyTimer;

  /// Настройки, влияющие на сам туннель, применяем сразу — переподключаемся на тот же узел.
  void _reapply() {
    if (phase != Phase.on || activeId == null) return;
    _reapplyTimer?.cancel();
    _reapplyTimer = Timer(const Duration(milliseconds: 800), () {
      if (phase == Phase.on && activeId != null) unawaited(connect(nodeId: activeId, force: true));
    });
  }

  void setDirectRu(bool v) {
    _set(() => directRu = v);
    _reapply();
  }
  void setAutoConnect(bool v) => _set(() => autoConnect = v);
  void setHideInsecure(bool v) => _set(() => hideInsecure = v);
  void setHideDupes(bool v) => _set(() => hideDupes = v);
  void setFragment(bool v) {
    _set(() => fragment = v);
    _reapply();
  }
  void setTunEngine(String v) => _set(() => tunEngine = v);
  void setAutoFaster(bool v) {
    _set(() => autoFaster = v);
    if (!v) stopHunt();
  }

  void setCountries(String v) {
    _set(() => countries = v);
    log(v == 'noRu' ? 'Подключаться только к узлам не из России' : 'Подключаться к узлам любых стран');
  }

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

  void toggleExclude(String package) {
    _set(() {
      if (!excludes.remove(package)) excludes.add(package);
    });
    _reapply();
  }

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
      countries = 'all';
      sameCountry = false;
      modeNodesOn = true;
      modeNodes.clear();
      profiles.clear();
      testKey = 'google';
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
      final r = await Net.getAny(s.mirrors, headers: s.isMine && sendHwid ? _deviceHeaders : const {});
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

  /// Заголовки для платных панелей (Remnawave, Marzban) с ограничением числа устройств.
  /// Уходят только самой панели: при перенаправлении на другой сайт не передаются.
  Map<String, String> get _deviceHeaders => {
        'x-hwid': hwid,
        'x-device-os': 'Android',
        if (info != null && info!.release.isNotEmpty) 'x-ver-os': info!.release,
        if (info != null && info!.model.isNotEmpty) 'x-device-model': info!.model,
      };

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
  /// Разбор вставленного текста: (ссылки подписок, строки ключей, число зашифрованных ссылок Happ).
  static (List<String>, List<String>, int) splitImport(String input) {
    final urls = <String>[];
    final keyLines = <String>[];
    var crypt = 0;
    final expanded = <String>[];
    // Сжатый набор из «Поделиться своими». Мессенджеры и сканеры любят резать длинную ссылку
    // переносами строк или терять её начало, поэтому берём данные после «data=» вместе с переносами,
    // а голый набор узнаём по началу gzip в base64 («H4sI»).
    var rest = input.replaceAllMapped(
      RegExp(r'(?:locman://import\?)?data=([A-Za-z0-9_\-=\s]{16,})|\bH4sI[A-Za-z0-9_\-=\s]{12,}'),
      (m) {
        // Хвост совпадения может захватить посторонние латинские слова — отрезаем их по одному.
        final parts = (m.group(1) ?? m.group(0)!).trim().split(RegExp(r'\s+'));
        for (var k = parts.length; k > 0; k--) {
          final lines = unpackShare(parts.take(k).join());
          if (lines != null && lines.isNotEmpty) {
            expanded.addAll(lines);
            return ' ${parts.skip(k).join(' ')} ';
          }
        }
        return m.group(0)!;
      },
    );
    final tokens = RegExp(r'[A-Za-z][A-Za-z0-9+.-]*://[^\s"<>]+').allMatches(rest).map((m) => m.group(0)!);
    for (var t in tokens) {
      t = t.replaceAll(RegExp(r'[),.;]+$'), '');
      final lower = t.toLowerCase();
      if (lower.startsWith('locman://import')) {
        // Ссылка «Поделиться» из другого «Лоцмана»: внутри сжатый набор или одна ссылка.
        final uri = Uri.tryParse(t);
        final data = uri?.queryParameters['data'];
        final one = uri?.queryParameters['url'];
        if (data != null) expanded.addAll(unpackShare(data) ?? const []);
        if (one != null) expanded.add(one);
        continue;
      }
      expanded.add(t);
    }
    for (var t in expanded) {
      final lower = t.toLowerCase();
      if (lower.startsWith('happ://add/')) {
        t = pctDecode(t.substring(11));
      } else if (lower.startsWith('happ://')) {
        crypt++;
        continue;
      }
      if (RegExp(r'^https?://', caseSensitive: false).hasMatch(t)) {
        if (!urls.contains(t)) urls.add(t);
      } else if (!keyLines.contains(t)) {
        keyLines.add(t);
      }
    }
    // Не нашли схем — может, это base64-подписка, вставленная целиком.
    if (urls.isEmpty && keyLines.isEmpty && crypt == 0) {
      rest = rest.trim();
      final decoded = rest.isEmpty ? null : decodeBase64(rest);
      if (decoded != null && decoded.contains('://')) keyLines.addAll(decoded.split(RegExp(r'\s+')));
    }
    return (urls, keyLines, crypt);
  }

  /// Добавить свои источники: можно вставить сразу много — ссылки подписок (каждая станет
  /// отдельным источником) вперемешку с ключами vless://… (они соберутся в один источник).
  /// Понимает и ссылки импорта вида happ://add/https://…
  Future<String?> addMine(String text, String name) async {
    final input = text.trim();
    if (input.isEmpty) return 'Вставьте ссылки подписок или ключи';

    final split = splitImport(input);
    final urls = split.$1;
    final keyLines = split.$2;
    final crypt = split.$3;

    final added = <Source>[];
    var duplicates = 0;
    final single = urls.length + (keyLines.isEmpty ? 0 : 1) == 1;

    for (final url in urls) {
      final id = 'mine-${stableId(url)}';
      if (mine.any((m) => m.id == id) || added.any((m) => m.id == id)) {
        duplicates++;
        continue;
      }
      added.add(Source(
        id: id,
        title: single && name.trim().isNotEmpty ? name.trim() : (Uri.tryParse(url)?.host ?? 'Моя подписка'),
        author: 'Вы',
        homepage: '',
        license: 'своё',
        description: 'Подписка по ссылке',
        mode: 'any',
        mirrors: [url],
        origin: 'mine',
      ));
    }

    var keys = 0;
    if (keyLines.isNotEmpty) {
      final parsed = SubscriptionParser.parse(keyLines.join('\n'), 'probe');
      if (parsed.nodes.isNotEmpty) {
        final links = parsed.nodes.map((n) => n.raw).join('\n');
        final id = 'mine-${stableId(links)}';
        if (mine.any((m) => m.id == id)) {
          duplicates++;
        } else {
          keys = parsed.nodes.length;
          added.add(Source(
            id: id,
            title: single && name.trim().isNotEmpty ? name.trim() : 'Мои ключи',
            author: 'Вы',
            homepage: '',
            license: 'своё',
            description: 'Ключи, вставленные вручную',
            mode: 'any',
            mirrors: const [],
            origin: 'mine',
            links: links,
          ));
        }
      }
    }

    if (added.isEmpty) {
      if (crypt > 0) {
        return 'Это зашифрованные ссылки Happ (happ://crypt…): их может открыть только Happ. '
            'Попросите у владельца подписки обычную ссылку https://…';
      }
      if (duplicates > 0) return 'Эти источники уже добавлены';
      return 'Не нашёл ни ссылок подписок, ни ключей vless, vmess, trojan, ss или hy2';
    }

    _set(() {
      mine.insertAll(0, added);
      tab = AppTab.sources;
    });
    for (final src in added.where((x) => x.links != null)) {
      nodesBySource[src.id] = SubscriptionParser.parse(src.links!, src.id).nodes;
      sourceInfo[src.id] = SourceInfo(updatedAt: DateTime.now().millisecondsSinceEpoch);
    }
    notifyListeners();
    final subs = added.where((x) => x.hasUrl).toList();
    final parts = [
      if (subs.isNotEmpty) 'подписок: ${subs.length}',
      if (keys > 0) 'ключей: $keys',
      if (duplicates > 0) 'уже были: $duplicates',
      if (crypt > 0) 'зашифрованных Happ пропущено: $crypt',
    ];
    log('Добавлено — ${parts.join(', ')}');
    flash('Добавлено — ${parts.join(', ')}');
    unawaited(_refreshMany(subs));
    return null;
  }

  // ---------- Поделиться своими подписками ----------

  /// Все свои источники: ссылки подписок и ключи, по одной строке.
  List<String> shareLines() {
    final out = <String>[];
    for (final m in mine) {
      if (m.links != null) {
        for (final l in m.links!.split('\n')) {
          final t = l.trim();
          if (t.isNotEmpty && !out.contains(t)) out.add(t);
        }
      } else if (m.mirrors.isNotEmpty && !out.contains(m.mirrors.first)) {
        out.add(m.mirrors.first);
      }
    }
    return out;
  }

  /// Ссылка locman://import?data=… — весь набор, сжатый gzip и в base64url.
  static String packShare(List<String> lines) {
    final packed = base64Url.encode(gzip.encode(utf8.encode(lines.join('\n')))).replaceAll('=', '');
    return 'locman://import?data=$packed';
  }

  /// Обратно из data=…; null — не разобралось. Больше 1 МБ не распаковываем.
  static List<String>? unpackShare(String data) {
    try {
      final clean = data.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      final padded = clean.padRight((clean.length + 3) ~/ 4 * 4, '=');
      final raw = gzip.decode(base64Url.decode(padded));
      if (raw.length > 1024 * 1024) return null;
      return utf8
          .decode(raw, allowMalformed: true)
          .split(RegExp(r'\s+'))
          .where((l) => l.isNotEmpty && l.length <= 4096 && checkImportLink(l) != null)
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Сканировать QR-код с другого телефона и предложить добавить всё, что в нём есть.
  Future<void> scanImport() async {
    String? text;
    try {
      text = await Native.scanQr();
    } on PlatformException catch (e) {
      flash(e.code == 'camera' ? 'Нужно разрешение на камеру' : 'Камера не открылась: ${e.message ?? e.code}');
      return;
    }
    if (text == null || text.trim().isEmpty) return;
    final (urls, keys, crypt) = splitImport(text);
    final lines = [...urls, ...keys];
    if (lines.isEmpty) {
      flash(crypt > 0 ? 'Это зашифрованная ссылка Happ — её открывает только Happ' : 'В QR-коде нет подписок и ключей');
      return;
    }
    pendingImport = lines.join('\n');
    notifyListeners();
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

  static String banKey(ProxyNode n) => '${n.address.toLowerCase()}:${n.port}';

  bool isBanned(ProxyNode n) => banned.contains(banKey(n));

  /// В чёрный список: сервер больше не участвует в подключении, поиске и автопереключении.
  /// Если через него сейчас идёт трафик — сразу ищем другой.
  void ban(ProxyNode n) {
    _set(() {
      banned.add(banKey(n));
      if (pinnedId == n.id) pinnedId = null;
    });
    log('В чёрный список: ${n.title} (${banKey(n)})');
    if (phase == Phase.on && activeId == n.id) {
      flash('${n.title} в чёрном списке — ищем другой узел');
      unawaited(connect(ignorePin: true));
    } else {
      flash('${n.title} — в чёрном списке');
      _pushBackups();
    }
  }

  void unban(ProxyNode n) {
    _set(() => banned.remove(banKey(n)));
    log('Из чёрного списка: ${n.title}');
    flash('${n.title} убран из чёрного списка');
  }

  void clearProfiles() {
    _set(() {
      profiles.clear();
      noFrag.clear();
    });
    log('Профили узлов забыты');
    flash('Профили узлов забыты');
  }

  void clearBans() {
    final count = banned.length;
    _set(() => banned.clear());
    log('Чёрный список очищен ($count)');
    flash('Чёрный список очищен');
  }

  /// Узлы из чёрного списка (для отдельной группы на вкладке «Узлы»).
  List<ProxyNode> bannedNodes() {
    final out = <ProxyNode>[];
    final seen = <String>{};
    for (final s in allSources) {
      if (!isEnabled(s)) continue;
      for (final n in nodesBySource[s.id] ?? const <ProxyNode>[]) {
        if (isBanned(n) && seen.add(n.id)) out.add(n);
      }
    }
    return out;
  }

  List<ProxyNode> visibleNodes() {
    final out = <ProxyNode>[];
    final seen = <String>{};
    for (final s in allSources) {
      if (!isEnabled(s)) continue;
      for (final n in nodesBySource[s.id] ?? const <ProxyNode>[]) {
        if (hideInsecure && n.isInsecure) continue;
        if (banned.isNotEmpty && isBanned(n)) continue;
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

  NodeProfile? profileOf(ProxyNode n) => profiles[n.id];

  String _testConfig(ProxyNode n, {required bool frag, NodeProfile? profile}) =>
      XrayConfig.build(n, forTest: true, dns: dns, fragment: frag, profile: profile ?? profiles[n.id]);

  /// Не больше 3 одновременных проверок к одному серверу: провайдер реже замечает проверку,
  /// а рабочие узлы реже получают ложное «нет ответа».
  final Map<String, _Gate> _hostGates = {};

  /// [gate] — общий ограничитель проверок; берётся уже внутри очереди к серверу,
  /// чтобы ожидание одного сервера не занимало места других.
  Future<int> _measure(ProxyNode n, String config, {_Gate? gate}) =>
      (_hostGates[n.address.toLowerCase()] ??= _Gate(3)).run(() {
        final url = testUrl;
        return gate == null ? Native.measure(config, url) : gate.run(() => Native.measure(config, url));
      });

  /// Настоящая проверка: запрос через узел силами Xray; для Hysteria2 и JSON — только так.
  /// С фрагментацией не прошёл — пробуем без неё и запоминаем, что этому узлу она мешает.
  Future<int> _realTest(ProxyNode n, {_Gate? gate}) async {
    final frag = _fragFor(n);
    final d = await _measure(n, _testConfig(n, frag: frag), gate: gate);
    if (d > 0 || !frag || profiles[n.id]?.frag != null) return d;
    final plain = await _measure(n, _testConfig(n, frag: false), gate: gate);
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

  /// Варианты подключения к узлу, по порядку: сохранённый, обычный, с другим дроблением,
  /// отпечатки Firefox и Edge, всё через одно соединение.
  List<NodeProfile> _variants(ProxyNode n) {
    final out = <NodeProfile>[];
    void add(NodeProfile p) {
      if (!out.contains(p)) out.add(p);
    }

    final saved = profiles[n.id];
    if (saved != null) add(saved.withDns(null));
    add(const NodeProfile());
    if (n.canFragment) add(NodeProfile(frag: !_fragFor(n)));
    if (n.usesFingerprint) {
      add(const NodeProfile(fp: 'firefox'));
      add(const NodeProfile(fp: 'edge'));
    }
    if (n.canMux) add(const NodeProfile(mux: true));
    return out;
  }

  /// Проверка пути через узел отдельным экземпляром ядра: данные больше 16 КБ, Telegram, DNS.
  /// Пробует до [limit] вариантов подключения; рабочий запоминается для узла.
  Future<_PathResult> _path(ProxyNode n, {int limit = 2, bool Function()? cancelled}) async {
    final saved = profiles[n.id];
    for (final variant in _variants(n).take(limit)) {
      if (cancelled?.call() == true) return const _PathResult(_Verdict.noData);
      final check = await _probePath(n, variant, dnsOrder(saved?.dns ?? dns));
      if (check == null) continue;
      if (check.data && check.telegram && check.dns != null) {
        final found = variant.withDns(check.dns);
        if (profiles[n.id] != found) {
          profiles[n.id] = found;
          if (!found.isPlain) log('${n.title}: рабочий профиль — ${found.label}');
          _save();
        }
        return _PathResult(_Verdict.ok, speed: check.speed);
      }
      if (check.data && !check.telegram) return _PathResult(_Verdict.noTelegram, speed: check.speed);
      if (check.data) return _PathResult(_Verdict.noDns, speed: check.speed);
    }
    return const _PathResult(_Verdict.noData);
  }

  Future<PathCheck?> _probePath(ProxyNode n, NodeProfile variant, List<String> dnsList) async {
    final local = LocalProxy(
      socksPort: await Net.freePort(),
      httpPort: await Net.freePort(),
      user: Net.token(12),
      pass: Net.token(24),
    );
    final config = XrayConfig.build(n,
        local: local, directRu: false, dns: dns, fragment: _fragFor(n), profile: variant, encryptedDns: false, udp: false);
    int? id;
    try {
      id = await Native.probeStart(config);
      if (id == null) return null;
      await Future.delayed(const Duration(milliseconds: 300));
      return await Net.checkPath(local, dns: dnsList);
    } catch (_) {
      return null;
    } finally {
      if (id != null) unawaited(Native.probeStop(id).catchError((_) {}));
    }
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

  int _checkGen = 0;

  /// Остановить проверку всех узлов (кнопка «Остановить» и большая кнопка во время проверки).
  void stopCheck() {
    if (checkingAll == 0) return;
    _checkGen++;
    checkingAll = 0;
    checkingDone = 0;
    log('Проверка остановлена');
    notifyListeners();
  }

  /// Пока VPN включён, узлы своей подписки, через которую он поднят, не считаем мёртвыми
  /// по одной неудачной проверке: платные подписки часто не пускают второе подключение.
  bool _sameSubAsActive(ProxyNode n) {
    if (phase != Phase.on) return false;
    final a = nodeById(activeId);
    if (a == null || a.sourceId != n.sourceId) return false;
    return sourceById(n.sourceId)?.isMine == true;
  }

  void _recordCheck(ProxyNode n, int delay, {required bool real}) {
    if (delay < 0 && _sameSubAsActive(n)) return;
    _record(n.id, delay, real: real);
  }

  Future<void> checkAll() async {
    if (checkingAll > 0) return;
    final gen = ++_checkGen;
    bool stopped() => gen != _checkGen;
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
      if (stopped()) return;
      // Узел, к которому подключены, проверяем через сам туннель — второе подключение
      // к нему могло бы дать ложное «нет ответа».
      if (phase == Phase.on && n.id == activeId) {
        final sw = Stopwatch()..start();
        final ok = await Net.probeTunnel();
        if (stopped()) return;
        _record(n.id, ok ? max(1, sw.elapsedMilliseconds) : -1, real: true);
        checkingDone++;
        _throttledNotify();
        return;
      }
      if (!n.coreOnly) {
        final key = '${n.address.toLowerCase()}:${n.port}';
        final tcp = await (tcpCache[key] ??= Net.tcping(n.address, n.port, timeout: const Duration(milliseconds: 1500)));
        if (stopped()) return;
        if (tcp < 0) {
          _recordCheck(n, -1, real: false);
          checkingDone++;
          _throttledNotify();
          return;
        }
      }
      if (stopped()) return;
      final d = await _measure(n, _testConfig(n, frag: _fragFor(n)), gate: real);
      if (stopped()) return;
      _recordCheck(n, d, real: true);
      checkingDone++;
      _throttledNotify();
    });
    if (stopped()) {
      unawaited(_saveHealth());
      return;
    }
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
    // Во время проверки узлов большая кнопка останавливает проверку, а не VPN.
    if (checkingAll > 0) {
      stopCheck();
      return;
    }
    if (phase == Phase.on || phase == Phase.seek) {
      unawaited(disconnect());
    } else {
      unawaited(connect());
    }
  }

  // ---------- Поиск узла быстрее ----------

  void stopHunt() {
    _huntGen++;
    huntStatus = null;
    offer = null;
  }

  /// Проверяем остальные узлы в фоне: сначала задержку, потом настоящую скорость
  /// у лучших по задержке. Нашли заметно быстрее текущего — предлагаем переключиться.
  Future<void> _hunt() async {
    final gen = ++_huntGen;
    bool stale() => gen != _huntGen || phase != Phase.on;
    final current = nodeById(activeId);
    if (current == null) return;
    await Future.delayed(const Duration(seconds: 3));
    if (stale()) return;

    final country = _stickCountry;
    final cands = _candidates(_kindForMode())
        .where((n) => !_huntSeen.contains(n.id) && (country == null || n.place.code == country))
        .take(200)
        .toList();
    if (cands.isEmpty) {
      huntStatus = null;
      flash('Других живых узлов не осталось');
      notifyListeners();
      return;
    }
    var checked = 0;
    huntStatus = 'Ищем узел быстрее: 0 из ${cands.length}';
    notifyListeners();
    final delays = <ProxyNode, int>{};
    final gate = _Gate(probeMeta[probe]!.$2);
    await _pool(cands, 32, (n) async {
      if (stale()) return;
      if (!n.coreOnly && await Net.tcping(n.address, n.port, timeout: const Duration(milliseconds: 1500)) < 0) {
        _recordCheck(n, -1, real: false);
      } else {
        final d = stale() ? 0 : await _realTest(n, gate: gate);
        if (d != 0) _recordCheck(n, d, real: true);
        if (d > 0) delays[n] = d;
      }
      checked++;
      if (!stale()) {
        huntStatus = 'Ищем узел быстрее: $checked из ${cands.length}';
        _throttledNotify();
      }
    });
    unawaited(_saveHealth());
    if (stale()) return;
    _huntSeen.addAll(cands.map((n) => n.id));
    _pushBackups();

    // Скорость: текущий через туннель, лучшие 4 по задержке — каждый через отдельный экземпляр ядра.
    huntStatus = 'Меряем скорость лучших узлов';
    notifyListeners();
    final mine = await Net.speedTest();
    if (stale()) return;
    final top = (delays.entries.toList()..sort((a, b) => a.value.compareTo(b.value))).take(4).toList();
    ProxyNode? best;
    var bestSpeed = 0;
    for (final e in top) {
      if (stale()) return;
      final sp = await _speedOf(e.key);
      if (sp > bestSpeed) {
        bestSpeed = sp;
        best = e.key;
      }
    }
    if (stale()) return;
    huntStatus = null;
    final bar = max(mine, _huntBar);
    if (best != null && bestSpeed > bar * 1.3 && bestSpeed - bar > 256 * 1024) {
      offer = Offer(best, bestSpeed, mine, delays[best] ?? 0);
      log('Нашёл быстрее: ${best.title} ${formatRate(bestSpeed)} (сейчас ${formatRate(mine)})');
    } else {
      log('Быстрее текущего не нашлось (сейчас ${formatRate(mine)})');
      flash('Текущий узел — самый быстрый из проверенных');
    }
    notifyListeners();
  }

  /// Скорость скачивания через узел, байт/с; 0 — не смогли.
  Future<int> _speedOf(ProxyNode n) async {
    final local = LocalProxy(
      socksPort: await Net.freePort(),
      httpPort: await Net.freePort(),
      user: Net.token(12),
      pass: Net.token(24),
    );
    final config = XrayConfig.build(n,
        local: local, directRu: false, dns: dns, fragment: _fragFor(n), profile: profiles[n.id], udp: false);
    int? id;
    try {
      id = await Native.probeStart(config);
      if (id == null) return 0;
      await Future.delayed(const Duration(milliseconds: 400));
      // Предлагаем только узел, через который идут данные, открывается Telegram и работает DNS.
      final path = await Net.checkPath(local, dns: dnsOrder(profiles[n.id]?.dns ?? dns));
      if (!path.data || !path.telegram || path.dns == null) return 0;
      final saved = profiles[n.id] ?? const NodeProfile();
      if (saved.dns != path.dns) profiles[n.id] = saved.withDns(path.dns);
      return await Net.speedTest(proxy: local);
    } catch (_) {
      return 0;
    } finally {
      if (id != null) unawaited(Native.probeStop(id).catchError((_) {}));
    }
  }

  void acceptOffer() {
    final o = offer;
    if (o == null) return;
    offer = null;
    log('Переключаемся на ${o.node.title}');
    unawaited(connect(nodeId: o.node.id));
  }

  /// Оставить текущий и искать дальше — среди ещё не проверенных, быстрее предложенного.
  void keepAndSearch() {
    final o = offer;
    offer = null;
    if (o != null) {
      _huntSeen.add(o.node.id);
      _huntBar = max(_huntBar, o.speed);
    }
    notifyListeners();
    unawaited(_hunt());
  }

  void dismissOffer() {
    stopHunt();
    notifyListeners();
  }

  /// Проверка адреса через туннель: IP, место, провайдер.
  Future<void> refreshIp() async {
    if (ipLoading) return;
    ipLoading = true;
    ipError = null;
    notifyListeners();
    try {
      final info = await Net.whoAmI();
      if (phase == Phase.on) {
        ipInfo = info;
        log('Адрес: ${info.ip}${info.place.isEmpty ? '' : ' · ${info.place}'}${info.provider == null ? '' : ' · ${info.provider}'}');
      }
    } catch (e) {
      ipError = _short(e);
    } finally {
      ipLoading = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _seekGen++;
    stopHunt();
    ipInfo = null;
    ipError = null;
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
        if (banned.isNotEmpty && isBanned(n)) continue;
        if (countries == 'noRu' && n.place.code == 'RU') continue;
        if (isDead(n.id)) continue;
        if (!seen.add(n.endpointKey)) continue;
        fits.add(n);
      }
    }
    // Сначала недавно живые (по задержке), потом остальные вперемешку.
    final known = fits.where((n) => latencyOf(n.id) > 0).toList()
      ..sort((a, b) => latencyOf(a.id).compareTo(latencyOf(b.id)));
    final rest = fits.where((n) => latencyOf(n.id) <= 0).toList()..shuffle(_random);
    final all = [...known, ...rest];
    // Вид соединения, который провайдер сейчас режет, — в конец: обычно режут вид целиком.
    // С «той же страной» узлы этой страны — вперёд.
    final country = _stickCountry;
    int rank(ProxyNode n) => (failedKinds.contains(n.kind) ? 2 : 0) + (country != null && n.place.code != country ? 1 : 0);
    return mergeSortStable(all, (a, b) => rank(a).compareTo(rank(b)));
  }

  /// Виды соединений, через которые в этом поиске не пошли данные.
  final Set<String> failedKinds = {};

  /// Страна, в которой оставаться при переключении (если включено).
  String? get _stickCountry {
    if (!sameCountry) return null;
    return nodeById(activeId ?? lastNodeId)?.place.code;
  }

  Future<void> connect({bool ignorePin = false, String? nodeId, bool force = false}) async {
    // Уже подключены к этому узлу — ядро не перезапускаем.
    if (!force && nodeId != null && nodeId == activeId && phase == Phase.on) {
      flash('Уже подключены к этому узлу');
      return;
    }
    final token = ++_seekGen;
    bool cancelled() => token != _seekGen;
    stopHunt();

    if (!allSources.any(isEnabled)) {
      _fail('Нет включённых источников');
      flash('Включите источник');
      return;
    }
    final quiet = force && phase == Phase.on;
    phase = Phase.seek;
    seekStep = 1;
    failText = null;
    if (!quiet) tab = AppTab.home;
    notifyListeners();
    log(force ? 'Применяем настройки' : (ignorePin ? 'Ищем рабочий узел' : 'Прокладываем ход'));

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
    if (mode == 'auto' && !force) {
      detected = await Net.detectKind();
      if (cancelled()) return;
    }
    final kind = _kindForMode();
    failedKinds.clear();

    final tried = <String>{};
    var started = false;
    ProxyNode? chosen;
    var userPick = false;
    if (nodeId != null) {
      chosen = nodeById(nodeId);
      userPick = !force;
    } else if (!ignorePin && pinnedId != null) {
      chosen = nodeById(pinnedId);
      if (chosen != null && isBanned(chosen)) chosen = null;
    }
    // Свой узел для этого режима сети (белые списки / обычные блокировки).
    if (chosen == null && !ignorePin && modeNodesOn && kind != null) {
      final m = nodeById(modeNodes[kind.name]);
      if (m != null && !isBanned(m) && !isDead(m.id)) {
        chosen = m;
        log('Узел для ${kind == NetKind.white ? 'белых списков' : 'обычных блокировок'}: ${m.title}');
      }
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
      seekStep = seekFinal;
      notifyListeners();
      started = true;
      final ok = await _bring(chosen, cancelled);
      if (cancelled()) return;
      if (ok) {
        if (userPick && kind != null) {
          modeNodes[kind.name] = chosen.id;
          _save();
        }
        return;
      }
      _record(chosen.id, -1, real: true);
      failedKinds.add(chosen.kind);
      log('${chosen.title} не пропускает трафик, ищем другой');
      chosen = null;
      userPick = false;
    }
    _fail('Узлы не пропускают трафик', stopTunnel: started);
  }

  /// Поиск, как Галс в Фарватере:
  /// 1) TCP → короткий запрос через ядро → загрузка больше 16 КБ, Telegram и DNS через узел.
  ///    Первый прошедший всё — наш, самый быстрый ищется потом в фоне (_hunt).
  /// 2) Если таких нет — пробуем у ответивших другие профили (Firefox, Edge, mux, дробление).
  /// 3) Если и так нет — берём самый быстрый узел, через который хотя бы идут данные.
  Future<ProxyNode?> _seek(NetKind? kind, Set<String> tried, bool Function() cancelled) async {
    final pool = _candidates(kind).where((n) => !tried.contains(n.id)).take(_poolLimit).toList();
    if (pool.isEmpty) return null;

    seekStep = 2;
    notifyListeners();
    _smokeSink?.call('seek pool=${pool.length}');
    final done = Completer<ProxyNode?>();
    final gate = _Gate(probeMeta[probe]!.$2);
    final paths = _Gate(3);
    final answered = <ProxyNode, int>{};
    final partial = <ProxyNode, int>{};
    final noData = <ProxyNode>[];
    bool over() => cancelled() || done.isCompleted;
    unawaited(_pool(pool, _tcpParallel, (n) async {
      if (over()) return;
      final tcp = (n.coreOnly || _skipTcp) ? 0 : await Net.tcping(n.address, n.port);
      if (tcp < 0) {
        _record(n.id, -1, real: false);
        return;
      }
      if (seekStep < 3) {
        seekStep = 3;
        notifyListeners();
      }
      final d = over() ? 0 : await _realTest(n, gate: gate);
      if (d == 0 || over()) return;
      _record(n.id, d, real: true);
      if (d < 0) return;
      answered[n] = d;
      if (seekStep < 4) {
        seekStep = 4;
        notifyListeners();
      }
      final r = await paths.run(() async => over() ? const _PathResult(_Verdict.noData) : await _path(n, cancelled: over));
      if (over()) return;
      switch (r.verdict) {
        case _Verdict.ok:
          done.complete(n);
        case _Verdict.noTelegram:
          partial[n] = r.speed;
          _smokeSink?.call('seek ${n.title}: нет Telegram');
        case _Verdict.noDns:
          partial[n] = r.speed;
          _smokeSink?.call('seek ${n.title}: нет DNS');
        case _Verdict.noData:
          noData.add(n);
          failedKinds.add(n.kind);
      }
    }).then((_) {
      if (!done.isCompleted) done.complete(null);
      unawaited(_saveHealth());
    }));
    final first = await done.future;
    if (cancelled()) return null;
    if (first != null) return first;

    // Шаг 2: другие профили у ответивших, но не пропустивших данные — сначала быстрые.
    if (noData.isNotEmpty) {
      seekStep = 4;
      log('Ищем рабочий профиль у ${min(6, noData.length)} узлов');
      notifyListeners();
      noData.sort((a, b) => (answered[a] ?? 9999).compareTo(answered[b] ?? 9999));
      for (final n in noData.take(6)) {
        if (cancelled()) return null;
        final r = await _path(n, limit: 6, cancelled: cancelled);
        if (r.verdict == _Verdict.ok) return n;
        if (r.verdict != _Verdict.noData) partial[n] = r.speed;
      }
    }
    if (cancelled()) return null;
    // Шаг 3: лучше узел без Telegram/DNS-проверки, чем никакого.
    if (partial.isNotEmpty) {
      final best = (partial.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
      log('${best.title}: данные идут, но Telegram или DNS через него не работают — берём, раз лучше нет');
      return best;
    }
    return null;
  }

  /// Запасные узлы для сторожа в службе: свежие живые, кроме текущего, лучшие по задержке.
  /// Конфиги собираются с теми же локальными входами, что у поднятого туннеля.
  List<Map<String, String>> _backups(ProxyNode current, LocalProxy local) {
    // С «той же страной» сторож переключается только на узлы страны текущего.
    final country = sameCountry ? current.place.code : null;
    final list = _candidates(_kindForMode())
        .where((n) => n.id != current.id && latencyOf(n.id) > 0 && (country == null || n.place.code == country))
        .toList()
      // Сначала из той же подписки (там обычно те же условия), потом остальные — по задержке.
      ..sort((a, b) {
        final sa = a.sourceId == current.sourceId ? 0 : 1;
        final sb = b.sourceId == current.sourceId ? 0 : 1;
        return sa != sb ? sa.compareTo(sb) : latencyOf(a.id).compareTo(latencyOf(b.id));
      });
    return [
      for (final n in list.take(10))
        {
          'config': XrayConfig.build(n,
              local: local,
              directRu: directRu,
              dns: dns,
              fragment: _fragFor(n),
              xrayTun: tunEngine == 'xray',
              profile: profiles[n.id]),
          'test': _testConfig(n, frag: _fragFor(n)),
          'name': n.title,
          'nodeId': n.id,
        },
    ];
  }

  void _pushBackups() {
    final n = nodeById(activeId);
    final local = Net.tunnel;
    if (phase != Phase.on || n == null || local == null) return;
    unawaited(Native.setBackups(_backups(n, local)).catchError((_) {}));
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
        local: local, directRu: directRu, dns: dns, fragment: _fragFor(n), xrayTun: xrayTun, profile: profiles[n.id]);
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
        backups: _backups(n, local),
        testUrl: testUrl,
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
      ok = await Net.probeTunnel(url: testUrl.startsWith('https') ? testUrl : 'https://www.gstatic.com/generate_204');
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
    _save();
    unawaited(refreshIp());
    _huntSeen
      ..clear()
      ..add(n.id);
    _huntBar = 0;
    offer = null;
    if (autoFaster && info?.smoke != true) unawaited(_hunt());
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
    } else if (e is WatchEvent) {
      _onWatch(e);
    } else if (e is NetworkEvent) {
      _onNetwork();
    } else if (e is LinkEvent) {
      unawaited(_takeLink());
    }
  }

  Timer? _netTimer;

  /// Сменилась сеть. В режиме «Авто» смотрим, не сменились ли белые списки на обычные
  /// блокировки (или наоборот), и переходим на узел для нового режима.
  void _onNetwork() {
    if (phase != Phase.on || mode != 'auto') return;
    _netTimer?.cancel();
    _netTimer = Timer(const Duration(seconds: 4), () async {
      if (phase != Phase.on) return;
      final before = detected;
      final kindNow = await Net.detectKind();
      if (kindNow == null || kindNow == before || phase != Phase.on) return;
      detected = kindNow;
      final label = kindNow == NetKind.white ? 'белые списки' : 'обычные блокировки';
      log('Сеть сменилась: $label');
      final target = modeNodesOn ? nodeById(modeNodes[kindNow.name]) : null;
      final active = nodeById(activeId);
      final source = active == null ? null : sourceById(active.sourceId);
      if (target != null && target.id != activeId && !isBanned(target)) {
        flash('Сеть сменилась ($label) — переходим на ${target.title}');
        unawaited(connect(nodeId: target.id, force: true));
      } else if (source != null && !source.fits(kindNow)) {
        flash('Сеть сменилась ($label) — ищем подходящий узел');
        unawaited(connect(ignorePin: true));
      }
    });
  }

  // ---------- Импорт по ссылке locman://import ----------

  /// Ссылка, которую предлагаем добавить (показывается окном подтверждения).
  String? pendingImport;

  Future<void> _takeLink() async {
    final raw = await Native.takeLink();
    if (raw == null) return;
    if (raw.startsWith('data:')) {
      final lines = unpackShare(raw.substring(5));
      if (lines == null || lines.isEmpty) {
        flash('В ссылке нет подписок');
        return;
      }
      pendingImport = lines.join('\n');
      notifyListeners();
      return;
    }
    final link = checkImportLink(raw);
    if (link == null) {
      flash('Ссылка импорта не подошла');
      return;
    }
    pendingImport = link;
    notifyListeners();
  }

  /// Принимаем только http(s) и ключи узлов, одной строкой, не длиннее 4096 символов.
  static String? checkImportLink(String raw) {
    final v = raw.trim();
    if (v.isEmpty || v.length > 4096 || v.contains('\n') || v.contains('\r')) return null;
    final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://').firstMatch(v)?.group(1)?.toLowerCase();
    const allowed = {'http', 'https', 'vless', 'vmess', 'trojan', 'ss', 'hysteria2', 'hy2'};
    return allowed.contains(scheme) ? v : null;
  }

  Future<void> acceptImport() async {
    final link = pendingImport;
    pendingImport = null;
    notifyListeners();
    if (link == null) return;
    final error = await addMine(link, '');
    if (error != null) flash(error);
  }

  void dismissImport() {
    pendingImport = null;
    notifyListeners();
  }

  // ---------- Что нового ----------

  /// Показать окно «Что нового» после обновления (один раз на версию).
  bool whatsNew = false;

  /// История изменений, встроенная в приложение: [(версия, дата, [пункты])].
  List<(String, String, List<String>)> changelog = const [];

  Future<void> _loadChangelog() async {
    try {
      final j = jsonDecode(await rootBundle.loadString('assets/changelog.json')) as List;
      changelog = [
        for (final e in j.whereType<Map>())
          (e['version'].toString(), (e['date'] ?? '').toString(), ((e['notes'] as List?) ?? const []).map((x) => x.toString()).toList()),
      ];
    } catch (_) {}
  }

  /// Открыта вся история изменений (из «О приложении»).
  bool changelogOpen = false;

  void openChangelog() {
    changelogOpen = true;
    notifyListeners();
  }

  void closeWhatsNew() {
    whatsNew = false;
    changelogOpen = false;
    notifyListeners();
  }

  /// Сторож в службе сам переключил узел или не нашёл живых запасных.
  void _onWatch(WatchEvent e) {
    switch (e.kind) {
      case 'failover':
        final old = activeId;
        if (old != null && old != e.nodeId) _record(old, -1, real: true);
        log('Узел перестал отвечать — сторож переключил на ${e.name ?? 'запасной'}');
        flash('Узел отвалился — переключились на ${e.name ?? 'запасной'}');
        stopHunt();
      case 'stalled':
        log('Узел не отвечает, запасные тоже — ищем заново');
        if (phase == Phase.on) {
          final n = nodeById(activeId);
          if (n != null) _record(n.id, -1, real: true);
          unawaited(connect(ignorePin: true));
        }
      case 'alive':
        break;
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
      connectedAt = s.since ?? connectedAt;
      ipInfo = null;
      unawaited(refreshIp());
      _pushBackups();
      notifyListeners();
    }
    if (s.phase == 'connected' && s.local != null && Net.tunnel == null) {
      Net.tunnel = s.local;
      if (ipInfo == null) unawaited(refreshIp());
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
      // За живостью туннеля следит сторож в службе VPN (работает и без открытого приложения).
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

enum _Verdict { ok, noData, noTelegram, noDns }

class _PathResult {
  const _PathResult(this.verdict, {this.speed = 0});
  final _Verdict verdict;
  final int speed;
}

/// Устойчивая сортировка: равные элементы сохраняют порядок.
List<T> mergeSortStable<T>(List<T> list, int Function(T, T) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}
