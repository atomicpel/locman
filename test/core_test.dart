import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:locman/core/b64.dart';
import 'package:locman/core/catalog.dart';
import 'package:locman/core/link_parser.dart';
import 'package:locman/core/node.dart';
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
}

