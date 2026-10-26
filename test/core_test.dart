import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:locman/core/b64.dart';
import 'package:locman/core/catalog.dart';
import 'package:locman/core/link_parser.dart';
import 'package:locman/core/node.dart';
import 'package:locman/core/qr.dart';
import 'package:locman/core/routes.dart';
import 'package:locman/core/subscription.dart';
import 'package:locman/core/xray_config.dart';
import 'package:locman/engine/net.dart';
import 'package:locman/state.dart';

const vless = 'vless://11111111-2222-3333-4444-555555555555@95.163.1.2:443'
    '?security=reality&sni=ok.ru&pbk=AbC-dEf_123&sid=ab12&fp=chrome&type=xhttp&path=%2Fapi&flow='
    '#%F0%9F%87%B7%F0%9F%87%BA%20Moscow%201';

const local = LocalProxy(socksPort: 10808, httpPort: 10809, user: 'u', pass: 'secretpass');

Map<String, dynamic> cfg(String link, {bool directRu = false, bool forTest = false, bool dns = true}) =>
    jsonDecode(XrayConfig.build(LinkParser.parse(link)!,
        local: forTest ? null : local, directRu: directRu, forTest: forTest, encryptedDns: dns)) as Map<String, dynamic>;

void main() {
  test('stableId — это FNV-1a 64', () {
    expect(stableId(''), 'cbf29ce484222325');
    expect(stableId('a'), 'af63dc4c8601ec8c');
    expect(stableId('foobar'), '85944171f73967e8');
  });

  test('VLESS Reality + XHTTP', () {
    final n = LinkParser.parse(vless)!;
    expect(n.protocol, Protocol.vless);
    expect(n.address, '95.163.1.2');
    expect(n.port, 443);
    expect(n.security, 'reality');
    expect(n.transport, 'xhttp');
    expect(n.params['path'], '/api');
    expect(n.params['pbk'], 'AbC-dEf_123');
    expect(n.name.endsWith('Moscow 1'), isTrue);
    expect(n.place.code, 'RU');
    expect(n.place.city, 'Москва');
    expect(n.transportLabel, 'Reality');
    expect(n.securityIssue, isNull);
  });

  test('одинаковый сервер с другим именем — тот же id', () {
    final a = LinkParser.parse(vless)!;
    final b = LinkParser.parse('${vless.split('#').first}#other')!;
    expect(a.id, b.id);
  });

  test('IPv6', () {
    final n = LinkParser.parse('trojan://pass@[2001:db8::1]:8443?sni=vk.com#t')!;
    expect(n.address, '2001:db8::1');
    expect(n.port, 8443);
  });

  test('VMess в base64', () {
    const json = '{"v":"2","ps":"vm","add":"1.2.3.4","port":"8080","id":"abc","net":"ws","path":"/ws","tls":"tls","sni":"ya.ru"}';
    final n = LinkParser.parse('vmess://${base64.encode(utf8.encode(json))}')!;
    expect(n.protocol, Protocol.vmess);
    expect(n.port, 8080);
    expect(n.transport, 'ws');
    expect(n.security, 'tls');
  });

  test('Shadowsocks SIP002', () {
    final user = base64Url.encode(utf8.encode('chacha20-ietf-poly1305:secret')).replaceAll('=', '');
    final n = LinkParser.parse('ss://$user@5.6.7.8:8388#ss')!;
    expect(n.params['method'], 'chacha20-ietf-poly1305');
    expect(n.secret, 'secret');
  });

  test('мусор не разбирается', () {
    expect(LinkParser.parse('vless://broken'), isNull);
    expect(LinkParser.parse('https://example.com'), isNull);
  });

  test('подписка в base64 с метаданными и заглушкой', () {
    final body = '#profile-title: base64:${base64.encode(utf8.encode('Тест'))}\n'
        '#profile-update-interval: 2\n'
        'vless://x@0.0.0.0:1#Подписка устарела\n$vless\n$vless\n';
    final s = SubscriptionParser.parse(base64.encode(utf8.encode(body)), 'src');
    expect(s.title, 'Тест');
    expect(s.updateIntervalHours, 2);
    expect(s.nodes.length, 1);
    expect(s.notices, ['Подписка устарела']);
  });

  test('неизвестные схемы считаются', () {
    final s = SubscriptionParser.parse('$vless\ntuic://a@1.2.3.4:443#t\ntuic://b@1.2.3.5:443#t\nwireguard://x@1.2.3.6:51820', 'src');
    expect(s.nodes.length, 1);
    expect(s.skipped, {'tuic': 2, 'wireguard': 1});
  });

  test('небезопасные узлы', () {
    expect(LinkParser.parse('vless://id@1.2.3.4:443?security=none#x')!.securityIssue, 'Без шифрования');
    expect(LinkParser.parse('trojan://p@1.2.3.4:443?allowInsecure=1#x')!.securityIssue, 'Без проверки сертификата');
    final weak = base64.encode(utf8.encode('rc4-md5:pw'));
    expect(LinkParser.parse('ss://$weak@1.2.3.4:8388#x')!.securityIssue, 'Устаревшее шифрование');
    expect(LinkParser.parse('hysteria2://p@hy.example.com:443/?insecure=1&pinSHA256=AB:CD#x')!.securityIssue, isNull);
  });

  test('Hysteria2: порты и конфиг', () {
    final n = LinkParser.parse('hysteria2://pa%40ss@hy.example.com:443,20000-30000/?sni=hy.example.com#hy')!;
    expect(n.protocol, Protocol.hysteria2);
    expect(n.port, 443);
    expect(n.secret, 'pa@ss');
    expect(n.params['mport'], '443,20000-30000');
    expect(LinkParser.parse('hy2://p@hy.example.com/?sni=x#n')!.port, 443);

    final c = cfg('hysteria2://pass@hy.example.com:443,20000-30000/?sni=hy.example.com&obfs=salamander&obfs-password=ob&pinSHA256=AB:CD#hy');
    final out = (c['outbounds'] as List).first as Map;
    expect(out['protocol'], 'hysteria');
    final stream = out['streamSettings'] as Map;
    expect(stream['network'], 'hysteria');
    expect((stream['hysteriaSettings'] as Map)['auth'], 'pass');
    expect((stream['tlsSettings'] as Map)['pinnedPeerCertSha256'], 'AB:CD');
    expect(((stream['finalmask'] as Map)['udp'] as List).map((e) => (e as Map)['type']), ['salamander', 'udphop']);
  });

  test('конфиг Xray: защищённые входы, DNS, прямые сервисы', () {
    final text = XrayConfig.build(LinkParser.parse(vless)!, local: local, directRu: true);
    expect(text.contains('"auth":"password"'), isTrue);
    expect(text.contains('secretpass'), isTrue);
    expect(text.contains('https://1.1.1.1/dns-query'), isTrue);
    expect(text.contains('"dns-out"'), isTrue);
    expect(text.contains('domain:gosuslugi.ru'), isTrue);
    expect(text.contains('"realitySettings"'), isTrue);
    expect(text.contains('"xhttpSettings"'), isTrue);
    final inbounds = (jsonDecode(text)['inbounds'] as List).map((e) => (e as Map)['protocol']).toList();
    expect(inbounds, ['socks', 'http']);
    expect(cfg(vless, dns: false).toString().contains('dns-out'), isFalse);
  });

  test('конфиг для проверки без входов и маршрутов', () {
    final c = cfg(vless, forTest: true);
    expect(c.containsKey('inbounds'), isFalse);
    expect(c.containsKey('routing'), isFalse);
  });

  test('allowInsecure не попадает в Xray, отпечаток по умолчанию chrome', () {
    final text = XrayConfig.build(LinkParser.parse('trojan://p@1.2.3.4:443?allowInsecure=1&sni=a.example.com#x')!, local: local);
    expect(text.contains('allowInsecure'), isFalse);
    expect(text.contains('"fingerprint":"chrome"'), isTrue);
  });

  test('JSON-подписка Xray', () {
    const json = '''[
      {"remarks":"Германия","outbounds":[
        {"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"de.example.com","port":443,"users":[{"id":"u1","encryption":"none","flow":"xtls-rprx-vision"}]}]},
         "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"ok.ru","publicKey":"pk","shortId":"ab"}}},
        {"tag":"direct","protocol":"freedom"}]},
      {"remarks":"Подписка истекла","outbounds":[{"tag":"proxy","protocol":"vless","settings":{"vnext":[{"address":"0.0.0.0","port":1,"users":[{"id":"x"}]}]}}]}
    ]''';
    final s = SubscriptionParser.parse(json, 'src', headers: {'profile-title': 'NoName'});
    expect(s.title, 'NoName');
    expect(s.nodes.map((n) => n.name), ['Германия']);
    expect(s.notices, ['Подписка истекла']);
    final de = s.nodes.first;
    expect(de.address, 'de.example.com');
    expect(de.params['sni'], 'ok.ru');
    expect(de.place.code, 'DE');
    final text = XrayConfig.build(de, local: local);
    expect(text.contains('de.example.com'), isTrue);
  });

  test('каталог читается и режимы сходятся', () {
    final c = Catalog.tryParse(jsonEncode({
      'version': 1,
      'generatedAt': '2026-10-20T00:00:00+00:00',
      'sources': [
        {'id': 'a', 'title': 'A', 'mode': 'white', 'mirrors': ['https://x/a'], 'recommended': true},
        {'id': 'b', 'title': 'B', 'mode': 'black', 'mirrors': ['https://x/b']},
      ],
    }))!;
    expect(c.sources.length, 2);
    expect(c.sources.first.fits(NetKind.white), isTrue);
    expect(c.sources.first.fits(NetKind.black), isFalse);
    expect(c.sources.last.fits(null), isTrue);
  });

  test('страна по флагу и названию', () {
    expect(LinkParser.parse('trojan://p@1.2.3.4:443#🇳🇱 Netherlands 1')!.place.country, 'Нидерланды');
    expect(LinkParser.parse('trojan://p@1.2.3.4:443#Frankfurt-02')!.place.city, 'Франкфурт');
    expect(LinkParser.parse('trojan://p@1.2.3.4:443#[FI] fast')!.place.code, 'FI');
    expect(LinkParser.parse('trojan://p@1.2.3.4:443#node')!.place.code, isNull);
  });

  test('фрагментация: отдельный выход и dialerProxy, не для Hysteria2', () {
    final c = jsonDecode(XrayConfig.build(LinkParser.parse(vless)!, local: local, fragment: true)) as Map;
    final outs = (c['outbounds'] as List).cast<Map>();
    expect(outs.map((o) => o['tag']), contains('fragment'));
    expect(((outs.first['streamSettings'] as Map)['sockopt'] as Map)['dialerProxy'], 'fragment');
    final hy = XrayConfig.build(LinkParser.parse('hy2://p@hy.example.com:443?sni=x#n')!, local: local, fragment: true);
    expect(hy.contains('dialerProxy'), isFalse);
  });

  test('TUN в Xray и счётчики трафика', () {
    final c = jsonDecode(XrayConfig.build(LinkParser.parse(vless)!, local: local, xrayTun: true)) as Map;
    final inbounds = (c['inbounds'] as List).cast<Map>();
    expect(inbounds.first['protocol'], 'tun');
    expect(c.containsKey('stats'), isTrue);
    final dnsRule = ((c['routing'] as Map)['rules'] as List).cast<Map>().first;
    expect(dnsRule['inboundTag'], ['socks', 'tun']);
  });

  test('найденный IP сохраняет домен в SNI и Host', () {
    final ws = LinkParser.parse('vless://u@cdn.example.com:443?security=tls&type=ws&path=%2Fws#x')!;
    expect(ws.needsResolve, isTrue);
    final r = ws.withAddress('1.2.3.4');
    expect(r.address, '1.2.3.4');
    expect(r.params['host'], 'cdn.example.com');
    expect(r.id, ws.id);
    final reality = LinkParser.parse(vless)!;
    expect(reality.needsResolve, isFalse);
    final named = LinkParser.parse('trojan://p@srv.example.com:443?sni=front.example.com#t')!.withAddress('5.6.7.8');
    expect(named.params['sni'], 'front.example.com');
  });

  test('узлы с локальными адресами отбрасываются', () {
    final s = SubscriptionParser.parse(
        '$vless\ntrojan://p@192.168.1.1:443#lan\ntrojan://p@10.0.2.2:5555#emu\ntrojan://p@localhost:443#me', 'src');
    expect(s.nodes.length, 1);
    expect(s.skipped['private'], 3);
  });

  test('плюсы в имени — это пробелы', () {
    final n = LinkParser.parse('trojan://p@1.2.3.4:443#%F0%9F%9B%A1+Белый+список+РФ+%2302')!;
    expect(n.name, '🛡 Белый список РФ #02');
  });

  test('много ссылок разом: подписки по отдельности, ключи вместе', () {
    final (urls, keys, crypt) = AppState.splitImport(
        'https://a.example.com/sub/1\nкакой-то текст\nhapp://add/https%3A%2F%2Fb.example.com%2Fs\n$vless\n'
        'trojan://p@1.2.3.4:443#t\nhapp://crypt5/abc');
    expect(urls, ['https://a.example.com/sub/1', 'https://b.example.com/s']);
    expect(keys.length, 2);
    expect(crypt, 1);
  });

  test('профиль узла: отпечаток, mux и DNS', () {
    const trojan = 'trojan://pass@93.184.216.34:443?security=tls&sni=example.com&type=ws&path=%2Fw#T';
    final n = LinkParser.parse(trojan)!;
    expect(n.canMux, isTrue);
    final c = jsonDecode(XrayConfig.build(n,
        local: local, profile: const NodeProfile(fp: 'firefox', mux: true, dns: 'quad'))) as Map<String, dynamic>;
    final out = (c['outbounds'] as List).first as Map;
    expect(out['mux']['enabled'], isTrue);
    expect(out['streamSettings']['tlsSettings']['fingerprint'], 'firefox');
    final servers = (c['dns']['servers'] as List).cast<Map>();
    expect(servers.first['address'], 'https://9.9.9.9/dns-query');
    // Vision и XHTTP не дружат с mux.
    expect(LinkParser.parse(vless)!.canMux, isFalse);
    final r = jsonDecode(XrayConfig.build(LinkParser.parse(vless)!, local: local, profile: const NodeProfile(mux: true)))
        as Map<String, dynamic>;
    expect(((r['outbounds'] as List).first as Map).containsKey('mux'), isFalse);
  });

  test('профиль сохраняется и читается', () {
    const p = NodeProfile(fp: 'edge', frag: false, dns: 'google');
    expect(NodeProfile.fromJson(p.toJson()), p);
    expect(const NodeProfile().isPlain, isTrue);
  });

  test('ссылка импорта: только http(s) и ключи, одной строкой', () {
    expect(AppState.checkImportLink('https://panel.example/sub/abc'), 'https://panel.example/sub/abc');
    expect(AppState.checkImportLink(vless), isNotNull);
    expect(AppState.checkImportLink('file:///sdcard/x'), isNull);
    expect(AppState.checkImportLink('content://x/y'), isNull);
    expect(AppState.checkImportLink('https://a\nhttps://b'), isNull);
    expect(AppState.checkImportLink('https://${'a' * 5000}'), isNull);
  });

  test('устойчивая сортировка', () {
    final l = mergeSortStable([3, 1, 2, 5, 4], (a, b) => (a % 2).compareTo(b % 2));
    expect(l, [2, 4, 3, 1, 5]);
  });

  test('DNS-запрос в формате wire и разбор ответа', () {
    final q = Net.dnsWire('telegram.org');
    expect(q.sublist(12, 13), [8]); // длина метки «telegram»
    expect(q.last, 1);
    final reply = [0, 0, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0];
    expect(Net.dnsAnswered(reply), isTrue);
    expect(Net.dnsAnswered([0, 0, 0x81, 0x83, 0, 1, 0, 0, 0, 0, 0, 0]), isFalse);
  });

  test('поделиться: ссылка locman://import?data= туда и обратно', () {
    final lines = ['https://a.example.com/sub/1', vless, 'https://b.example.com/s'];
    final link = AppState.packShare(lines);
    expect(link.startsWith('locman://import?data='), isTrue);
    expect(AppState.unpackShare(Uri.parse(link).queryParameters['data']!), lines);
    final (urls, keys, _) = AppState.splitImport('вот: $link');
    expect(urls, ['https://a.example.com/sub/1', 'https://b.example.com/s']);
    expect(keys, [vless]);
    expect(AppState.unpackShare('мусор'), isNull);
  });

  test('набор подписок узнаётся, даже если ссылку порезали переносами или потеряли начало', () {
    final lines = ['https://a.example.com/sub/1', vless];
    final link = AppState.packShare(lines);
    final data = Uri.parse(link).queryParameters['data']!;
    final wrapped = 'Подписки для «Лоцмана»:\n${link.substring(0, 40)}\n${link.substring(40, 90)} ${link.substring(90)}';
    final (u1, k1, _) = AppState.splitImport(wrapped);
    expect(u1, ['https://a.example.com/sub/1']);
    expect(k1, [vless]);
    final (u2, k2, _) = AppState.splitImport(data);
    expect(u2, ['https://a.example.com/sub/1']);
    expect(k2, [vless]);
    final (u3, _, _) = AppState.splitImport('$data https://b.example.com/x');
    expect(u3, ['https://a.example.com/sub/1', 'https://b.example.com/x']);
  });

  test('QR-код совпадает с эталоном (python-qrcode)', () {
    final q = QrCode.encode(utf8.encode('https://example.com/sub/123'))!;
    expect(q.version, 2);
    expect(q.mask, 1);
    final expected = [
      '1111111010011010001111111',
      '1000001011101110101000001',
      '1011101000111100101011101',
      '1011101000100110001011101',
      '1011101011110010001011101',
      '1000001010010010001000001',
      '1111111010101010101111111',
      '0000000010111011100000000',
      '1110011011101010111110011',
      '0010100001100101011101011',
      '0000011110010001010011101',
      '1101100111010010100101000',
      '0011111101010001101100001',
      '0010010011010011101100011',
      '1110101110111011111001101',
      '0010100110110010110111000',
      '1101111101010000111110010',
      '0000000010010010100010001',
      '1111111000110100101010001',
      '1000001010000011100010011',
      '1011101000110001111110010',
      '1011101001010000010010110',
      '1011101011010011110111011',
      '1000001011111001111110000',
      '1111111010101010101001001',
    ];
    final got = [
      for (var y = 0; y < q.size; y++) [for (var x = 0; x < q.size; x++) q.dark(x, y) ? '1' : '0'].join(),
    ];
    expect(got, expected);
    String digest(QrCode c) {
      var h = 0x811c9dc5;
      var n = 0;
      for (var y = 0; y < c.size; y++) {
        for (var x = 0; x < c.size; x++) {
          final b = c.dark(x, y) ? 0x31 : 0x30;
          if (b == 0x31) n++;
          h = ((h ^ b) * 0x01000193) & 0xffffffff;
        }
      }
      return '${c.version}/${c.mask}/${c.size}/$n/${h.toRadixString(16)}';
    }

    expect(digest(QrCode.encode(utf8.encode('x' * 933))!), '22/0/105/5610/acf3e035');
    expect(digest(QrCode.encode([for (var r = 0; r < 4; r++) ...List.generate(256, (i) => i)])!), '23/1/109/6025/73d6b49c');
    expect(QrCode.encode(List.filled(3000, 65)), isNull);
    final png = q.toPng(scale: 4);
    expect(png.sublist(0, 4), [137, 80, 78, 71]);
  });

  test('маршруты TUN: весь IPv4, кроме локальных сетей', () {
    final r = publicIpv4();
    bool covered(String ip) {
      final n = ip.split('.').fold<int>(0, (a, p) => (a << 8) | int.parse(p));
      for (final c in r) {
        final parts = c.split('/');
        final base = parts[0].split('.').fold<int>(0, (a, p) => (a << 8) | int.parse(p));
        final len = int.parse(parts[1]);
        final mask = len == 0 ? 0 : (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF;
        if ((n & mask) == (base & mask)) return true;
      }
      return false;
    }

    expect(covered('8.8.8.8'), isTrue);
    expect(covered('1.1.1.1'), isTrue);
    expect(covered('95.163.1.2'), isTrue);
    expect(covered('192.168.1.1'), isFalse);
    expect(covered('10.0.0.5'), isFalse);
    expect(covered('127.0.0.1'), isFalse);
    expect(covered('224.0.0.1'), isFalse);
  });

  test('Windows: конфиг TUN и системного прокси', () {
    final n = LinkParser.parse(vless)!;
    const w = WinTunnel(tun: true, httpPort: 10809, socksPort: 10808, metricsPort: 11111, leakBlock: true);
    final c = jsonDecode(XrayConfig.build(n, local: local, win: w, tunRoutes: const ['1.0.0.0/8'])) as Map<String, dynamic>;
    final tun = (c['inbounds'] as List).cast<Map>().firstWhere((i) => i['protocol'] == 'tun');
    expect(tun['settings']['autoSystemRoutingTable'], ['1.0.0.0/8', '2000::/3']);
    expect(tun['settings']['autoSystemWfpBlockLeak'], ['dns']);
    expect((c['inbounds'] as List).any((i) => i['tag'] == 'sys' && i['port'] == 10809), isTrue);
    expect(c['metrics'], {'listen': '127.0.0.1:11111'});
    final rules = (c['routing']['rules'] as List).cast<Map>();
    expect(rules.any((r) => (r['process'] as List?)?.contains('locman.exe') == true), isTrue);
  });
}

