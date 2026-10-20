import 'dart:convert';

import 'b64.dart';
import 'node.dart';

const manualSource = 'manual';

/// Разбор ссылок vless://, vmess://, trojan://, ss://, hysteria2:// (hy2://).
/// Логика повторяет проверенный разборщик Farvater (GPL-3.0).
class LinkParser {
  static ProxyNode? parse(String line, {String sourceId = manualSource}) {
    final raw = line.trim();
    if (raw.isEmpty || raw.startsWith('#')) return null;
    final sep = raw.indexOf('://');
    if (sep <= 0) return null;
    final scheme = raw.substring(0, sep).toLowerCase();
    try {
      return switch (scheme) {
        'vless' => _uriStyle(raw, Protocol.vless, sourceId),
        'trojan' => _uriStyle(raw, Protocol.trojan, sourceId),
        'hysteria2' || 'hy2' => _uriStyle(raw, Protocol.hysteria2, sourceId),
        'vmess' => _vmess(raw, sourceId),
        'ss' => _shadowsocks(raw, sourceId),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  static ProxyNode? _uriStyle(String raw, Protocol protocol, String sourceId) {
    final body = raw.substring(raw.indexOf('://') + 3);
    final (beforeFragment, fragment) = _splitOnce(body, '#');
    final (beforeQuery, query) = _splitOnce(beforeFragment, '?');
    final at = beforeQuery.lastIndexOf('@');
    if (at <= 0) return null;
    final secret = pctDecode(beforeQuery.substring(0, at));
    var authority = beforeQuery.substring(at + 1);
    while (authority.endsWith('/')) {
      authority = authority.substring(0, authority.length - 1);
    }
    String? hop;
    if (protocol == Protocol.hysteria2) {
      final (hp, h) = _hysteriaPorts(authority);
      authority = hp;
      hop = h;
    }
    final hostPort = _parseHostPort(authority);
    if (hostPort == null) return null;
    final params = _parseQuery(query);
    if (hop != null && !params.containsKey('mport')) params['mport'] = hop;
    return ProxyNode(
      id: stableId(_beforeHash(raw)),
      protocol: protocol,
      name: _displayName(fragment, hostPort.$1, hostPort.$2),
      address: hostPort.$1,
      port: hostPort.$2,
      secret: secret,
      params: params,
      raw: raw,
      sourceId: sourceId,
    );
  }

  static (String, String?) _hysteriaPorts(String authority) {
    final colon = authority.lastIndexOf(':');
    if (colon < 0 || authority.endsWith(']')) return ('$authority:443', null);
    final ports = authority.substring(colon + 1);
    if (RegExp(r'^\d+$').hasMatch(ports)) return (authority, null);
    final first = ports.split(',').first.split('-').first;
    return (authority.substring(0, colon + 1) + first, ports);
  }

  static ProxyNode? _vmess(String raw, String sourceId) {
    final encoded = _beforeHash(raw.substring(raw.indexOf('://') + 3));
    final payload = decodeBase64(encoded);
    if (payload == null) return null;
    final obj = jsonDecode(payload);
    if (obj is! Map) return null;
    String s(String key) => (obj[key]?.toString() ?? '').trim();

    final host = s('add');
    final port = int.tryParse(s('port'));
    final id = s('id');
    if (host.isEmpty || id.isEmpty || port == null || port < 1 || port > 65535) return null;
    final tls = s('tls').toLowerCase();
    final params = <String, String>{
      'type': s('net').isEmpty ? 'tcp' : s('net'),
      'security': (tls == 'tls' || tls == 'reality') ? tls : 'none',
    };
    const keys = {
      'headerType': 'type',
      'host': 'host',
      'path': 'path',
      'sni': 'sni',
      'alpn': 'alpn',
      'fp': 'fp',
      'aid': 'aid',
      'scy': 'scy',
    };
    keys.forEach((param, field) {
      final v = s(field);
      if (v.isNotEmpty && v != 'none') params[param] = v;
    });
    final withoutName = Map<String, dynamic>.from(obj)..remove('ps');
    final name = s('ps');
    return ProxyNode(
      id: stableId(jsonEncode(withoutName)),
      protocol: Protocol.vmess,
      name: name.isEmpty ? '$host:$port' : name,
      address: host,
      port: port,
      secret: id,
      params: params,
      raw: raw,
      sourceId: sourceId,
    );
  }

  static ProxyNode? _shadowsocks(String raw, String sourceId) {
    final (beforeFragment, fragment) = _splitOnce(raw.substring(raw.indexOf('://') + 3), '#');
    var main = beforeFragment.split('?').first;
    while (main.endsWith('/')) {
      main = main.substring(0, main.length - 1);
    }
    final at = main.lastIndexOf('@');
    String credentials;
    String hostPort;
    if (at > 0) {
      final userInfo = main.substring(0, at);
      final decoded = decodeBase64(userInfo);
      credentials = (decoded != null && decoded.contains(':')) ? decoded : pctDecode(userInfo);
      hostPort = main.substring(at + 1);
    } else {
      final decoded = decodeBase64(main);
      if (decoded == null) return null;
      final a = decoded.lastIndexOf('@');
      if (a <= 0) return null;
      credentials = decoded.substring(0, a);
      hostPort = decoded.substring(a + 1);
    }
    final colon = credentials.indexOf(':');
    if (colon < 0) return null;
    final hp = _parseHostPort(hostPort);
    if (hp == null) return null;
    return ProxyNode(
      id: stableId(_beforeHash(raw)),
      protocol: Protocol.shadowsocks,
      name: _displayName(fragment, hp.$1, hp.$2),
      address: hp.$1,
      port: hp.$2,
      secret: credentials.substring(colon + 1),
      params: {'method': credentials.substring(0, colon)},
      raw: raw,
      sourceId: sourceId,
    );
  }

  static String _beforeHash(String s) {
    final i = s.indexOf('#');
    return i < 0 ? s : s.substring(0, i);
  }

  static (String, String) _splitOnce(String s, String delimiter) {
    final i = s.indexOf(delimiter);
    return i < 0 ? (s, '') : (s.substring(0, i), s.substring(i + 1));
  }

  static (String, int)? _parseHostPort(String s) {
    String host;
    String portStr;
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end < 0) return null;
      host = s.substring(1, end);
      portStr = s.substring(end + 1);
      if (portStr.startsWith(':')) portStr = portStr.substring(1);
    } else {
      final colon = s.lastIndexOf(':');
      if (colon < 0) return null;
      host = s.substring(0, colon);
      portStr = s.substring(colon + 1);
    }
    final port = int.tryParse(portStr);
    if (host.trim().isEmpty || port == null || port < 1 || port > 65535) return null;
    return (host, port);
  }

  static Map<String, String> _parseQuery(String query) {
    final out = <String, String>{};
    for (final pair in query.split('&')) {
      if (pair.trim().isEmpty) continue;
      final eq = pair.indexOf('=');
      final k = pctDecode(eq < 0 ? pair : pair.substring(0, eq));
      final v = eq < 0 ? '' : pctDecode(pair.substring(eq + 1));
      if (k.trim().isNotEmpty) out[k] = v;
    }
    return out;
  }

  static String _displayName(String fragment, String host, int port) {
    final name = pctDecode(fragment).trim();
    return name.isEmpty ? '$host:$port' : name;
  }
}
