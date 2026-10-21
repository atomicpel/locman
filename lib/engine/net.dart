import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../core/catalog.dart';
import '../core/xray_config.dart';

/// Что видят сайты после подключения.
class IpInfo {
  const IpInfo({required this.ip, this.code, this.country, this.city, this.region, this.provider, this.asn, required this.source});
  final String ip;
  final String? code;
  final String? country;
  final String? city;
  final String? region;
  final String? provider;
  final String? asn;
  final String source;

  String get flag {
    final c = code?.toUpperCase();
    if (c == null || c.length != 2 || !RegExp(r'^[A-Z]{2}$').hasMatch(c)) return '';
    return String.fromCharCodes(c.codeUnits.map((u) => 0x1F1E6 + u - 65));
  }

  String get place => [city, if (region != null && region != city) region, country].whereType<String>().join(', ');
}

class HttpResult {
  HttpResult(this.status, this.body, this.headers);
  final int status;
  final String body;
  final Map<String, String> headers;
}

/// Сеть самого приложения. Приложение исключено из туннеля, поэтому
/// «напрямую» — это действительно напрямую, а «через узел» идёт через HTTP-вход Xray.
class Net {
  static const userAgent = 'Locman/1';
  static const maxBody = 8 * 1024 * 1024;

  /// Локальный вход Xray, пока туннель поднят.
  static LocalProxy? tunnel;

  static HttpClient _client({required bool viaTunnel, Duration timeout = const Duration(seconds: 10)}) {
    final c = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 5)
      ..userAgent = userAgent
      ..autoUncompress = true;
    final t = tunnel;
    if (viaTunnel && t != null) {
      c.findProxy = (_) => 'PROXY ${t.user}:${t.pass}@127.0.0.1:${t.httpPort}';
    } else {
      c.findProxy = (_) => 'DIRECT';
    }
    return c;
  }

  /// Порядок попыток: через узел (если поднят), затем напрямую.
  static List<bool> get routes => tunnel != null ? const [true, false] : const [false];

  static Future<HttpResult> get(
    String url, {
    bool viaTunnel = false,
    Duration timeout = const Duration(seconds: 25),
    int maxBytes = maxBody,
  }) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' && uri.scheme != 'http') throw const FormatException('нужна ссылка http(s)');
    if (_isLocal(uri.host)) throw const FormatException('адрес указывает на сам телефон');
    final client = _client(viaTunnel: viaTunnel);
    Future<HttpResult> run() async {
      final req = await client.getUrl(uri);
      req.followRedirects = true;
      req.maxRedirects = 5;
      final resp = await req.close();
      final headers = <String, String>{};
      resp.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(', '));
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) throw const HttpException('ответ больше 8 МБ');
      }
      return HttpResult(resp.statusCode, utf8.decode(bytes.takeBytes(), allowMalformed: true), headers);
    }

    try {
      return await run().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  /// Пробуем зеркала и маршруты по очереди, первый удачный ответ 200.
  static Future<HttpResult> getAny(List<String> urls, {Duration timeout = const Duration(seconds: 25)}) async {
    Object? last;
    for (final via in routes) {
      for (final url in urls) {
        try {
          final r = await get(url, viaTunnel: via, timeout: timeout);
          if (r.status == 200) return r;
          last = 'HTTP ${r.status}';
        } catch (e) {
          last = e;
        }
      }
    }
    throw HttpException(_humanError(last));
  }

  static Future<void> download(
    String url,
    File target, {
    void Function(double)? onProgress,
    bool viaTunnel = false,
  }) async {
    final client = _client(viaTunnel: viaTunnel, timeout: const Duration(seconds: 20));
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
      final total = resp.contentLength;
      var read = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          read += chunk.length;
          if (total > 0) onProgress?.call(read / total);
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  static bool _isLocal(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    final ip = InternetAddress.tryParse(h);
    return ip != null && (ip.isLoopback || ip.isLinkLocal);
  }

  static String _humanError(Object? e) {
    if (e == null) return 'нет ответа';
    if (e is TimeoutException) return 'нет ответа вовремя';
    if (e is SocketException) return 'сеть недоступна';
    if (e is HandshakeException) return 'ошибка TLS';
    if (e is HttpException) return e.message;
    if (e is FormatException) return e.message;
    return e.toString();
  }

  /// Частные, локальные и служебные адреса: узлы с ними не проверяем и не используем,
  /// иначе чужая подписка может заставить телефон стучаться в домашнюю сеть.
  static bool isPrivate(InternetAddress a) {
    if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) {
      return b[0] == 0 ||
          b[0] == 10 ||
          b[0] == 127 ||
          (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168) ||
          b[0] >= 224;
    }
    return (b[0] & 0xfe) == 0xfc || a.address == '::';
  }

  /// TCP-рукопожатие с сервером узла, мс или -1.
  static Future<int> tcping(String host, int port, {Duration timeout = const Duration(milliseconds: 2500)}) async {
    final sw = Stopwatch()..start();
    try {
      final addrs = await InternetAddress.lookup(host).timeout(timeout);
      final target = addrs.where((a) => !isPrivate(a)).toList();
      if (target.isEmpty) return -1;
      final s = await Socket.connect(target.first, port, timeout: timeout);
      s.destroy();
      return max(1, sw.elapsedMilliseconds);
    } catch (_) {
      return -1;
    }
  }

  /// Проверка поднятого туннеля: ответ 204 через узел.
  static Future<bool> probeTunnel({String url = 'https://www.gstatic.com/generate_204'}) async {
    if (tunnel == null) return false;
    final client = _client(viaTunnel: true, timeout: const Duration(seconds: 8));
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      await resp.drain<void>();
      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Что за сеть сейчас: открывается зарубежное — обычные блокировки (ЧС),
  /// открываются только российские сайты — белые списки (БС), ничего — null.
  static Future<NetKind?> detectKind() async {
    const foreign = [
      'https://speed.cloudflare.com/__down?bytes=65536',
      'https://dl.google.com/chrome/install/latest/chrome_installer.exe',
      'https://raw.githubusercontent.com/atomicpel/locman/main/LICENSE',
    ];
    const domestic = ['https://ya.ru/', 'https://vk.com/', 'https://www.gosuslugi.ru/'];
    if (await _firstTrue(foreign.map(_downloads))) return NetKind.black;
    if (await _firstTrue(domestic.map(_reachable))) return NetKind.white;
    return null;
  }

  static Future<bool> _firstTrue(Iterable<Future<bool>> futures) {
    final list = futures.toList();
    final done = Completer<bool>();
    var left = list.length;
    for (final f in list) {
      f.then((ok) {
        if (ok && !done.isCompleted) done.complete(true);
      }).whenComplete(() {
        left--;
        if (left == 0 && !done.isCompleted) done.complete(false);
      });
    }
    return done.future;
  }

  static Future<bool> _reachable(String url) async {
    final client = _client(viaTunnel: false, timeout: const Duration(seconds: 4));
    try {
      final req = await client.headUrl(Uri.parse(url)).timeout(const Duration(seconds: 6));
      req.followRedirects = false;
      final resp = await req.close().timeout(const Duration(seconds: 6));
      await resp.drain<void>();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _downloads(String url) async {
    const enough = 32 * 1024;
    final client = _client(viaTunnel: false, timeout: const Duration(seconds: 4));
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
      final resp = await req.close().timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200 && resp.statusCode != 206) return false;
      var total = 0;
      await for (final chunk in resp.timeout(const Duration(seconds: 6))) {
        total += chunk.length;
        if (total >= enough) break;
      }
      return total >= enough;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Внешний IP, местоположение и провайдер — всё через туннель, как их видят сайты.
  /// Порядок: 2ip (api.2ip.me), затем ip-api.com (по-русски), затем ipwho.is.
  static Future<IpInfo> whoAmI() async {
    final via = tunnel != null;
    Future<Map<String, dynamic>?> json(String url) async {
      try {
        final r = await get(url, viaTunnel: via, timeout: const Duration(seconds: 10), maxBytes: 64 * 1024);
        if (r.status != 200) return null;
        final j = jsonDecode(r.body);
        return j is Map<String, dynamic> ? j : null;
      } catch (_) {
        return null;
      }
    }

    String? s(Object? v) => (v == null || v.toString().trim().isEmpty) ? null : v.toString().trim();

    // Сам адрес: Cloudflare trace, запасной — ipify.
    String? ip;
    try {
      final r = await get('https://www.cloudflare.com/cdn-cgi/trace', viaTunnel: via, timeout: const Duration(seconds: 10));
      ip = RegExp(r'^ip=(.+)$', multiLine: true).firstMatch(r.body)?.group(1)?.trim();
    } catch (_) {}
    ip ??= s((await json('https://api.ipify.org?format=json'))?['ip']);
    if (ip == null) throw const HttpException('сайты проверки адреса не ответили');

    final geo = await json('https://api.2ip.me/geo.json?ip=$ip');
    if (geo != null && s(geo['country_rus'] ?? geo['country']) != null) {
      final prov = await json('https://api.2ip.me/provider.json?ip=$ip');
      return IpInfo(
        ip: ip,
        code: s(geo['country_code']),
        country: s(geo['country_rus']) ?? s(geo['country']),
        city: s(geo['city_rus']) ?? s(geo['city']),
        region: s(geo['region_rus']) ?? s(geo['region']),
        provider: s(prov?['name_rus']) ?? s(prov?['name_ripe']),
        source: '2ip',
      );
    }
    final a = await json('http://ip-api.com/json/$ip?lang=ru&fields=status,countryCode,country,regionName,city,isp,org,as');
    if (a != null && a['status'] == 'success') {
      return IpInfo(
        ip: ip,
        code: s(a['countryCode']),
        country: s(a['country']),
        city: s(a['city']),
        region: s(a['regionName']),
        provider: s(a['isp']) ?? s(a['org']),
        asn: s(a['as']),
        source: 'ip-api.com',
      );
    }
    final w = await json('https://ipwho.is/$ip?lang=ru');
    if (w != null && w['success'] == true) {
      final c = w['connection'] is Map ? w['connection'] as Map : const {};
      return IpInfo(
        ip: ip,
        code: s(w['country_code']),
        country: s(w['country']),
        city: s(w['city']),
        region: s(w['region']),
        provider: s(c['isp']) ?? s(c['org']),
        asn: c['asn'] == null ? null : 'AS${c['asn']}',
        source: 'ipwho.is',
      );
    }
    return IpInfo(ip: ip, source: 'cloudflare');
  }

  /// Скорость скачивания, байт/с: через [proxy] (пробный экземпляр ядра) или через туннель.
  static Future<int> speedTest({LocalProxy? proxy}) async {
    final p = proxy ?? tunnel;
    if (p == null) return 0;
    const urls = [
      'https://speed.cloudflare.com/__down?bytes=4000000',
      'https://proof.ovh.net/files/10Mb.dat',
    ];
    for (final url in urls) {
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6)
        ..userAgent = userAgent
        ..findProxy = (_) => 'PROXY ${p.user}:${p.pass}@127.0.0.1:${p.httpPort}';
      try {
        final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
        final resp = await req.close().timeout(const Duration(seconds: 8));
        if (resp.statusCode != 200) continue;
        final sw = Stopwatch();
        var bytes = 0;
        final sub = resp.listen((chunk) {
          if (!sw.isRunning) sw.start();
          bytes += chunk.length;
        });
        // Качаем не дольше 5 секунд и не больше 4 МБ.
        final end = Completer<void>();
        sub.onDone(() {
          if (!end.isCompleted) end.complete();
        });
        sub.onError((Object _) {
          if (!end.isCompleted) end.complete();
        });
        await Future.any([end.future, Future.delayed(const Duration(seconds: 5))]);
        await sub.cancel();
        final ms = sw.elapsedMilliseconds;
        if (bytes > 64 * 1024 && ms > 0) return bytes * 1000 ~/ ms;
      } catch (_) {
        // следующий адрес
      } finally {
        c.close(force: true);
      }
    }
    return 0;
  }

  /// IPv4 домена через DNS-over-HTTPS — мимо подменённого DNS оператора.
  static Future<List<String>> resolveDoh(String host) async {
    final name = Uri.encodeQueryComponent(host);
    final urls = [
      'https://1.1.1.1/dns-query?name=$name&type=A',
      'https://dns.google/resolve?name=$name&type=A',
      'https://9.9.9.9:5053/dns-query?name=$name&type=A',
    ];
    for (final url in urls) {
      final client = _client(viaTunnel: false, timeout: const Duration(seconds: 4));
      try {
        final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 5));
        req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
        final resp = await req.close().timeout(const Duration(seconds: 5));
        final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
        final j = jsonDecode(body);
        final answers = (j is Map ? j['Answer'] : null) as List?;
        final ips = (answers ?? const [])
            .whereType<Map>()
            .where((a) => a['type'] == 1)
            .map((a) => a['data'].toString())
            .where((ip) => InternetAddress.tryParse(ip) != null && !isPrivate(InternetAddress(ip)))
            .toList();
        if (ips.isNotEmpty) return ips;
      } catch (_) {
        // следующий сервер
      } finally {
        client.close(force: true);
      }
    }
    return const [];
  }

  /// Свободный локальный порт для входов Xray.
  static Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  static String token(int length) {
    const alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(length, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }
}
