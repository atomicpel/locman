import 'dart:convert';

import 'b64.dart';
import 'node.dart';

/// Подписки в формате готовых конфигов Xray (Remnawave, Marzban v2ray-json).
class XrayJsonParser {
  static const _protocols = {
    'vless': Protocol.vless,
    'vmess': Protocol.vmess,
    'trojan': Protocol.trojan,
    'shadowsocks': Protocol.shadowsocks,
    'hysteria': Protocol.hysteria2,
  };
  static const _reserved = {'direct', 'block', 'dns-out'};

  static List<ProxyNode>? parse(String text, String sourceId) {
    if (!text.startsWith('[') && !text.startsWith('{')) return null;
    dynamic root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      return null;
    }
    final configs = root is List ? root.whereType<Map>().toList() : (root is Map ? [root] : <Map>[]);
    final out = <ProxyNode>[];
    for (final c in configs) {
      final n = _node(Map<String, dynamic>.from(c), sourceId);
      if (n != null) out.add(n);
    }
    return out;
  }

  static String? _str(Map? m, String key) {
    final v = m?[key];
    if (v == null || v is Map || v is List) return null;
    final s = v.toString();
    return s.trim().isEmpty ? null : s;
  }

  static int? _int(Map? m, String key) {
    final v = m?[key];
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '');
  }

  static Map? _obj(Map? m, String key) => m?[key] is Map ? m![key] as Map : null;
  static List _arr(Map? m, String key) => m?[key] is List ? m![key] as List : const [];

  static ProxyNode? _node(Map<String, dynamic> config, String sourceId) {
    final original = _arr(config, 'outbounds')
        .whereType<Map>()
        .where((o) => !_reserved.contains(_str(o, 'tag')) && _str(o, 'protocol') != 'dns')
        .toList();
    Map? main;
    for (final o in original) {
      if (_str(o, 'tag') == 'proxy' && _protocols.containsKey(_str(o, 'protocol'))) {
        main = o;
        break;
      }
    }
    main ??= original.cast<Map?>().firstWhere((o) => _protocols.containsKey(_str(o, 'protocol')), orElse: () => null);
    if (main == null) return null;
    final protocol = _protocols[_str(main, 'protocol')]!;
    final settings = _obj(main, 'settings') ?? const {};
    final firstVnext = _arr(settings, 'vnext').isNotEmpty ? _arr(settings, 'vnext').first : null;
    final firstServer = _arr(settings, 'servers').isNotEmpty ? _arr(settings, 'servers').first : null;
    final server = (firstVnext ?? firstServer) is Map ? (firstVnext ?? firstServer) as Map : settings;
    final firstUser = _arr(server, 'users').isNotEmpty ? _arr(server, 'users').first : null;
    final user = firstUser is Map ? firstUser : server;
    final stream = _obj(main, 'streamSettings');
    final tls = _obj(stream, 'tlsSettings');
    final reality = _obj(stream, 'realitySettings');
    final address = _str(server, 'address');
    final port = _int(server, 'port');
    if (address == null || port == null) return null;

    final outbounds = [main, ...original.where((o) => !identical(o, main))].map(_withoutInsecure).toList();
    final proxyTags = outbounds
        .where((o) => _protocols.containsKey(_str(o, 'protocol')))
        .map((o) => _str(o, 'tag'))
        .whereType<String>()
        .toList();
    final routing = _obj(config, 'routing');
    String? balancerTag;
    for (final r in _arr(routing, 'rules').whereType<Map>()) {
      final t = _str(r, 'balancerTag');
      if (t != null) balancerTag = t;
    }
    Map? balancer;
    for (final b in _arr(routing, 'balancers').whereType<Map>()) {
      if (_str(b, 'tag') == balancerTag) {
        balancer = b;
        break;
      }
    }
    final prefixes = _arr(balancer, 'selector').map((e) => e.toString()).toList();
    final selected = proxyTags.where((t) => prefixes.any(t.startsWith)).toList();
    final leaks = outbounds.any((o) =>
        !_protocols.containsKey(_str(o, 'protocol')) && selected.any((s) => (_str(o, 'tag') ?? '').startsWith(s)));

    final body = <String, dynamic>{'outbounds': outbounds};
    if (balancer != null && selected.isNotEmpty && !leaks) {
      body['routing'] = {
        'rules': [
          {'type': 'field', 'network': 'tcp,udp', 'balancerTag': balancerTag},
        ],
        'balancers': [
          {
            'tag': balancerTag,
            'selector': selected,
            if (balancer['strategy'] != null) 'strategy': balancer['strategy'],
            if (proxyTags.contains(_str(balancer, 'fallbackTag'))) 'fallbackTag': _str(balancer, 'fallbackTag'),
          },
        ],
      };
      if (config['observatory'] != null) body['observatory'] = config['observatory'];
      if (config['burstObservatory'] != null) body['burstObservatory'] = config['burstObservatory'];
    }
    final remarks = (_str(config, 'remarks') ?? '').trim();
    final name = remarks.isEmpty ? '$address:$port' : remarks;
    final params = <String, String>{
      if (_str(stream, 'security') != null) 'security': _str(stream, 'security')!,
      if (_str(stream, 'network') != null && protocol != Protocol.hysteria2) 'type': _str(stream, 'network')!,
      if (_str(tls ?? reality, 'serverName') != null) 'sni': _str(tls ?? reality, 'serverName')!,
      if (_str(reality, 'publicKey') != null) 'pbk': _str(reality, 'publicKey')!,
      if (_str(user, 'flow') != null) 'flow': _str(user, 'flow')!,
      if (_str(server, 'method') != null) 'method': _str(server, 'method')!,
      if (_str(user, 'security') != null) 'scy': _str(user, 'security')!,
      if (tls?['allowInsecure'] == true || tls?['allowInsecure']?.toString() == '1') 'allowInsecure': '1',
      if (_str(tls, 'pinnedPeerCertSha256') != null) 'pcs': _str(tls, 'pinnedPeerCertSha256')!,
    };
    final bodyJson = jsonEncode(body);
    return ProxyNode(
      id: stableId(bodyJson),
      protocol: protocol,
      name: name,
      address: address,
      port: port,
      secret: _str(user, 'id') ?? _str(user, 'password') ?? _str(_obj(stream, 'hysteriaSettings'), 'auth') ?? '',
      params: params,
      raw: jsonEncode({'remarks': name, ...body}),
      sourceId: sourceId,
    );
  }

  static Map _withoutInsecure(Map outbound) {
    final stream = _obj(outbound, 'streamSettings');
    final tls = _obj(stream, 'tlsSettings');
    if (stream == null || tls == null || !tls.containsKey('allowInsecure')) return outbound;
    return {
      ...outbound,
      'streamSettings': {
        ...stream,
        'tlsSettings': Map.of(tls)..remove('allowInsecure'),
      },
    };
  }
}
