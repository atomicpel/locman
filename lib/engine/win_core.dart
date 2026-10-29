import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../core/qr.dart';
import '../core/xray_config.dart';
import 'native.dart';
import 'net.dart';

/// Windows-часть «Лоцмана» — то, что на Android делает Kotlin (служба VPN, ядро, сторож).
/// Ядро — официальный xray.exe рядом с locman.exe; процессы запускает C++-раннер
/// (без окна консоли, в задании Windows: умирают вместе с приложением).
class WinCore {
  static const _win = MethodChannel('locman/win');

  /// Аргументы командной строки (--autostart, ссылка locman://…).
  static List<String> args = const [];

  static final _events = StreamController<Object>.broadcast();
  static Stream<Object> get events => _events.stream;

  static String get exeDir => File(Platform.resolvedExecutable).parent.path;
  static String get xray => '$exeDir\\xray.exe';

  static String get dataDir {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    final d = Directory('$base\\Locman');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  static String get _runDir {
    final d = Directory('$dataDir\\run');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  static bool _inited = false;

  static void init() {
    if (_inited) return;
    _inited = true;
    _win.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'tray':
          _events.add(TrayEvent((call.arguments as Map?)?['action'] as String? ?? 'show'));
        case 'link':
          final url = (call.arguments as Map?)?['url'] as String?;
          if (url != null) {
            _pendingLink = url;
            _events.add(LinkEvent(url));
          }
        case 'endSession':
          await stop();
      }
      return null;
    });
    // Старые файлы пробных конфигов от прошлого запуска.
    try {
      for (final f in Directory(_runDir).listSync()) {
        if (f is File && f.path.contains('probe-')) f.deleteSync();
      }
    } catch (_) {}
    for (final a in args) {
      if (a.toLowerCase().startsWith('locman://')) _pendingLink = a;
    }
  }

  static String? _pendingLink;

  static String? takeLink() {
    final l = _pendingLink;
    _pendingLink = null;
    if (l == null) return null;
    final uri = Uri.tryParse(l);
    final data = uri?.queryParameters['data'];
    if (data != null) return 'data:$data';
    return uri?.queryParameters['url'] ?? l.replaceFirst(RegExp(r'^locman://import/?', caseSensitive: false), '');
  }

  static bool get autostarted => args.contains('--autostart');

  // ---------------------------------------------------------------------------
  // Раннер (C++)
  // ---------------------------------------------------------------------------

  static Future<T?> _call<T>(String method, [Map<String, Object?>? a]) async {
    try {
      return await _win.invokeMethod<T>(method, a);
    } on MissingPluginException {
      return null;
    }
  }

  static Future<int?> _start(String config, String name) async {
    final path = '$_runDir\\$name.json';
    await File(path).writeAsString(config, flush: true);
    return _call<int>('startProcess', {
      'exe': xray,
      'args': 'run -c "$path"',
      'cwd': exeDir,
    });
  }

  static Future<void> _kill(int? pid) async {
    if (pid != null) await _call('killProcess', {'pid': pid});
  }

  static Future<bool> _alive(int? pid) async => pid != null && (await _call<bool>('alive', {'pid': pid}) ?? false);

  static Future<bool> isAdmin() async => await _call<bool>('isAdmin') ?? false;

  /// Перезапуск «Лоцмана» от имени администратора (для TUN). true — новый процесс запущен.
  static Future<bool> relaunchAdmin() async => await _call<bool>('relaunchAdmin') ?? false;

  static Future<void> quit() => _call('quit');
  static Future<void> showWindow() => _call('showWindow');
  static Future<void> setCloseToTray(bool on) => _call('setCloseToTray', {'on': on});
  static Future<void> openUrl(String url) => _call('openUrl', {'url': url});

  static Future<void> setAutostart(bool on, {required bool elevated}) =>
      _call('setAutostart', {'enable': on, 'elevated': elevated});

  static Future<void> _tray(String tooltip, bool connected) =>
      _call('tray', {'tooltip': tooltip, 'connected': connected});

  static Future<bool> _setProxy(bool on, {int port = 0}) async =>
      await _call<bool>('setProxy', {
        'enable': on,
        'server': '127.0.0.1:$port',
        'bypass': 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*;<local>',
      }) ??
      false;

  /// Включён ли наш системный прокси (после сбоя его надо снять).
  static Future<void> resetStaleProxy() async => _call('resetStaleProxy');

  // ---------------------------------------------------------------------------
  // Проверка узлов
  // ---------------------------------------------------------------------------

  static Future<bool> _waitPort(int port, int? pid, {Duration timeout = const Duration(seconds: 6)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(milliseconds: 300));
        s.destroy();
        return true;
      } catch (_) {}
      if (!await _alive(pid)) return false;
      await Future.delayed(const Duration(milliseconds: 120));
    }
    return false;
  }

  static int _probeSeq = 0;

  /// Задержка запроса [url] через узел из урезанного конфига, мс; -1 — не прошёл.
  /// Своё ядро на проверку: к конфигу добавляется HTTP-вход, первым выходом остаётся узел.
  static Future<int> measure(String config, String url) async {
    int? pid;
    final name = 'probe-${DateTime.now().microsecondsSinceEpoch}-${_probeSeq++}';
    try {
      final j = jsonDecode(config) as Map<String, dynamic>;
      final port = await Net.freePort();
      j['inbounds'] = [
        {'tag': 'm', 'listen': '127.0.0.1', 'port': port, 'protocol': 'http'},
      ];
      j['log'] = {'loglevel': 'none'};
      pid = await _start(jsonEncode(j), name);
      if (pid == null || !await _waitPort(port, pid, timeout: const Duration(seconds: 4))) return -1;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6)
        ..findProxy = (_) => 'PROXY 127.0.0.1:$port';
      try {
        final sw = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 6));
        req.followRedirects = false;
        final resp = await req.close().timeout(const Duration(seconds: 6));
        await resp.drain<void>().timeout(const Duration(seconds: 3));
        final ok = resp.statusCode >= 200 && resp.statusCode < 400;
        return ok ? max(1, sw.elapsedMilliseconds) : -1;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return -1;
    } finally {
      await _kill(pid);
      unawaited(Future.delayed(const Duration(seconds: 2), () {
        try {
          File('$_runDir\\$name.json').deleteSync();
        } catch (_) {}
      }));
    }
  }

  /// Пробное ядро для замера скорости и проверки пути (в конфиге уже есть локальные входы).
  static Future<int?> probeStart(String config) async {
    final j = jsonDecode(config) as Map<String, dynamic>;
    final http = (j['inbounds'] as List).cast<Map>().firstWhere((i) => i['protocol'] == 'http');
    final pid = await _start(config, 'probe-run-${DateTime.now().microsecondsSinceEpoch}');
    if (pid == null || !await _waitPort((http['port'] as num).toInt(), pid)) {
      await _kill(pid);
      return null;
    }
    return pid;
  }

  static Future<void> probeStop(int id) => _kill(id);

  // ---------------------------------------------------------------------------
  // Туннель (то, что на Android делает LocmanVpnService)
  // ---------------------------------------------------------------------------

  static VpnStatus _state = const VpnStatus('idle');
  static VpnStatus get state => _state;
  static _Spec? _spec;
  static int? _pid;
  static bool _proxyOn = false;
  static Timer? _monitor;
  static Timer? _watchdog;
  static int _gen = 0;

  static void _set(VpnStatus s) {
    _state = s;
    _events.add(s);
    final connected = s.phase == 'connected';
    unawaited(_tray(
      connected ? 'Лоцман — ${s.name ?? 'подключено'}' : (s.phase == 'connecting' ? 'Лоцман — подключение' : 'Лоцман — выключен'),
      connected,
    ));
  }

  static VpnStatus stateWithLocal() {
    final sp = _spec;
    if (_state.phase != 'connected' || sp == null) return _state;
    return VpnStatus(
      'connected',
      name: _state.name,
      nodeId: _state.nodeId,
      since: _state.since,
      local: LocalProxy(socksPort: sp.socksPort, httpPort: sp.httpPort, user: sp.user, pass: sp.pass),
    );
  }

  static Future<void> start(Map<String, Object?> a) async {
    final spec = _Spec.fromMap(a);
    await _connect(spec);
  }

  static Future<void> _connect(_Spec spec) async {
    final gen = ++_gen;
    _monitor?.cancel();
    _watchdog?.cancel();
    _set(VpnStatus('connecting', name: spec.name, nodeId: spec.nodeId));
    final old = _pid;
    _pid = null;
    // Новое ядро поднимаем после остановки старого: порты те же.
    await _kill(old);
    await Future.delayed(const Duration(milliseconds: 150));
    final pid = await _start(spec.config, 'active');
    if (gen != _gen) {
      await _kill(pid);
      return;
    }
    final ok = pid != null && await _waitPort(spec.httpPort, pid, timeout: const Duration(seconds: _specWait));
    if (gen != _gen) {
      await _kill(pid);
      return;
    }
    if (!ok) {
      await _kill(pid);
      await _unsetProxy();
      _spec = null;
      final log = _tail('$dataDir\\xray.log');
      final admin = spec.tun && !await isAdmin();
      _set(VpnStatus('failed',
          error: admin ? 'Для режима TUN нужны права администратора' : 'Ядро не запустилось${log.isEmpty ? '' : ': $log'}'));
      return;
    }
    _pid = pid;
    _spec = spec;
    if (!spec.tun) {
      _proxyOn = await _setProxy(true, port: spec.sysHttpPort);
    } else {
      await _unsetProxy();
    }
    unawaited(File('$dataDir\\last_start.json').writeAsString(jsonEncode(spec.toMap())));
    _set(VpnStatus('connected', name: spec.name, nodeId: spec.nodeId, since: DateTime.now().millisecondsSinceEpoch));
    _startMonitor(gen, spec);
    _startWatchdog(gen, spec);
  }

  static const _specWait = 10;

  static String _tail(String path) {
    try {
      final lines = File(path).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      if (lines.isEmpty) return '';
      final l = lines.last;
      return l.length > 160 ? '${l.substring(0, 159)}…' : l;
    } catch (_) {
      return '';
    }
  }

  static Future<void> _unsetProxy() async {
    if (_proxyOn) {
      await _setProxy(false);
      _proxyOn = false;
    }
  }

  static Future<void> stop() async {
    _gen++;
    _monitor?.cancel();
    _watchdog?.cancel();
    await _unsetProxy();
    final pid = _pid;
    _pid = null;
    _spec = null;
    await _kill(pid);
    _set(const VpnStatus('idle'));
  }

  static Future<void> setBackups(List<Map<String, String>> backups) async {
    final sp = _spec;
    if (sp != null) _spec = sp.copyWith(backups: backups);
  }

  /// Последний туннель — для автозапуска с Windows.
  static Map<String, Object?>? lastStart() {
    try {
      return Map<String, Object?>.from(jsonDecode(File('$dataDir\\last_start.json').readAsStringSync()) as Map);
    } catch (_) {
      return null;
    }
  }

  static void _startMonitor(int gen, _Spec spec) {
    int? lastUp;
    int? lastDown;
    int? baseUp;
    int? baseDown;
    _monitor = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (gen != _gen) return;
      if (!await _alive(_pid)) {
        if (gen != _gen) return;
        _monitor?.cancel();
        _watchdog?.cancel();
        await _unsetProxy();
        _set(VpnStatus('failed', error: 'Ядро остановилось${_tail('$dataDir\\xray.log').isEmpty ? '' : ': ${_tail('$dataDir\\xray.log')}'}'));
        return;
      }
      try {
        final j = jsonDecode(await _local('http://127.0.0.1:${spec.metricsPort}/debug/vars')) as Map;
        final out = ((j['stats'] as Map?)?['outbound'] as Map?) ?? const {};
        var up = 0;
        var down = 0;
        out.forEach((tag, v) {
          if (tag == 'direct' || tag == 'block' || tag == 'dns-out' || v is! Map) return;
          up += (v['uplink'] as num?)?.toInt() ?? 0;
          down += (v['downlink'] as num?)?.toInt() ?? 0;
        });
        baseUp ??= up;
        baseDown ??= down;
        final du = lastUp == null ? 0 : max(0, up - lastUp!);
        final dd = lastDown == null ? 0 : max(0, down - lastDown!);
        lastUp = up;
        lastDown = down;
        _events.add(Traffic(du, dd, up - baseUp!, down - baseDown!));
      } catch (_) {}
    });
  }

  /// Запрос к счётчикам ядра на 127.0.0.1 (Net.get адреса самого компьютера не пускает — и правильно).
  static Future<String> _local(String url) async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2)
      ..findProxy = (_) => 'DIRECT';
    try {
      final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 2));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      return await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 2));
    } finally {
      c.close(force: true);
    }
  }

  /// Сторож: раз в 20 секунд запрос через туннель; два провала подряд — запасные узлы.
  static void _startWatchdog(int gen, _Spec spec) {
    var fails = 0;
    var stalledAt = 0;
    var busy = false;
    _watchdog = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (gen != _gen || busy) return;
      busy = true;
      try {
        final ok = await Net.probeTunnel(url: spec.testUrl.startsWith('https') ? spec.testUrl : 'https://www.gstatic.com/generate_204') ||
            await Net.probeTunnel(url: 'https://cp.cloudflare.com/generate_204');
        if (gen != _gen) return;
        if (ok) {
          if (fails > 0 || stalledAt > 0) _events.add(WatchEvent('alive', null, spec.nodeId));
          fails = 0;
          stalledAt = 0;
          return;
        }
        fails++;
        if (fails < 2) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (stalledAt > 0 && now - stalledAt < 120000) return;
        if (!await _failover(gen)) {
          stalledAt = now;
          _events.add(WatchEvent('stalled', null, spec.nodeId));
        }
      } finally {
        busy = false;
      }
    });
  }

  static bool _switching = false;

  /// «Переключить узел» из меню у часов: на самый быстрый из запасных.
  static Future<void> switchNext() async {
    final sp = _spec;
    if (sp == null || _switching) return;
    _switching = true;
    try {
      if (!await _failover(_gen, manual: true)) {
        _events.add(WatchEvent('switchEmpty', null, sp.nodeId));
      }
    } finally {
      _switching = false;
    }
  }

  static Future<bool> _failover(int gen, {bool manual = false}) async {
    final sp = _spec;
    if (sp == null) return false;
    final cands = sp.backups.where((b) => b['nodeId'] != sp.nodeId).take(10).toList();
    if (cands.isEmpty) return false;
    final results = await Future.wait(cands.map((b) => measure(b['test']!, sp.testUrl)));
    if (gen != _gen) return true;
    var best = -1;
    for (var i = 0; i < cands.length; i++) {
      if (results[i] > 0 && (best < 0 || results[i] < results[best])) best = i;
    }
    if (best < 0) return false;
    final b = cands[best];
    final next = sp.copyWith(
      config: b['config'],
      name: b['name'],
      nodeId: b['nodeId'],
      backups: sp.backups.where((x) => x['nodeId'] != b['nodeId']).toList(),
    );
    _events.add(WatchEvent(manual ? 'switched' : 'failover', b['name'], b['nodeId']));
    unawaited(_connect(next));
    return true;
  }

  // ---------------------------------------------------------------------------
  // Прочее
  // ---------------------------------------------------------------------------

  static Future<Uint8List?> qr(String text) async => QrCode.encode(utf8.encode(text))?.toPng(scale: 8);

  /// SHA-256 файла (через Windows CNG в раннере). null — не удалось.
  static Future<String?> sha256(String path) => _call<String>('sha256', {'path': path});

  /// Проверка скачанного установщика. null — всё хорошо.
  static Future<String?> verifyInstaller(String path, String sha) async {
    final got = await sha256(path);
    if (got == null) return 'не удалось посчитать контрольную сумму';
    if (got.toLowerCase() != sha.toLowerCase()) return 'контрольная сумма не совпала';
    return null;
  }

  /// Запустить установщик обновления (тихо, «Лоцман» перезапустится сам).
  static Future<bool> runInstaller(String path) async =>
      await _call<bool>('runFile', {'path': path, 'args': '/SP- /SILENT /SUPPRESSMSGBOXES /NOCANCEL'}) ?? false;
}

/// Нажатие в меню значка у часов: toggle, show, exit.
class TrayEvent {
  const TrayEvent(this.action);
  final String action;
}

class _Spec {
  _Spec({
    required this.config,
    required this.name,
    required this.nodeId,
    required this.socksPort,
    required this.httpPort,
    required this.user,
    required this.pass,
    required this.tun,
    required this.sysHttpPort,
    required this.metricsPort,
    required this.testUrl,
    required this.backups,
  });

  final String config;
  final String name;
  final String nodeId;
  final int socksPort;
  final int httpPort;
  final String user;
  final String pass;
  final bool tun;
  final int sysHttpPort;
  final int metricsPort;
  final String testUrl;
  final List<Map<String, String>> backups;

  static _Spec fromMap(Map<String, Object?> m) => _Spec(
        config: m['config'] as String,
        name: (m['name'] as String?) ?? 'Лоцман',
        nodeId: (m['nodeId'] as String?) ?? '',
        socksPort: (m['socksPort'] as num).toInt(),
        httpPort: (m['httpPort'] as num).toInt(),
        user: m['user'] as String,
        pass: m['pass'] as String,
        tun: m['tunMode'] == 'tun',
        sysHttpPort: (m['sysHttpPort'] as num?)?.toInt() ?? 0,
        metricsPort: (m['metricsPort'] as num?)?.toInt() ?? 0,
        testUrl: (m['testUrl'] as String?) ?? 'https://www.gstatic.com/generate_204',
        backups: ((m['backups'] as List?) ?? const [])
            .whereType<Map>()
            .map((b) => b.map((k, v) => MapEntry(k.toString(), v.toString())))
            .toList(),
      );

  Map<String, Object?> toMap() => {
        'config': config,
        'name': name,
        'nodeId': nodeId,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'user': user,
        'pass': pass,
        'tunMode': tun ? 'tun' : 'proxy',
        'sysHttpPort': sysHttpPort,
        'metricsPort': metricsPort,
        'testUrl': testUrl,
        'backups': backups,
      };

  _Spec copyWith({String? config, String? name, String? nodeId, List<Map<String, String>>? backups}) => _Spec(
        config: config ?? this.config,
        name: name ?? this.name,
        nodeId: nodeId ?? this.nodeId,
        socksPort: socksPort,
        httpPort: httpPort,
        user: user,
        pass: pass,
        tun: tun,
        sysHttpPort: sysHttpPort,
        metricsPort: metricsPort,
        testUrl: testUrl,
        backups: backups ?? this.backups,
      );
}
