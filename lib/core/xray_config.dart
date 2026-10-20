import 'dart:convert';

import 'node.dart';
import 'ru.dart';

/// Локальные входы Xray: SOCKS для TUN-моста и HTTP для запросов самого приложения.
/// Оба только на 127.0.0.1 и с одноразовым паролем — чужие приложения ими не воспользуются.
class LocalProxy {
  const LocalProxy({required this.socksPort, required this.httpPort, required this.user, required this.pass});
  final int socksPort;
  final int httpPort;
  final String user;
  final String pass;
}

const dnsServers = {'cloud': '1.1.1.1', 'google': '8.8.8.8', 'quad': '9.9.9.9'};

List<String> dnsOrder(String preferred) =>
    [preferred, ...dnsServers.keys.where((k) => k != preferred)].where(dnsServers.containsKey).toList();

const fragmentTag = 'fragment';

class XrayConfig {
  static const _privateCidrs = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', '169.254.0.0/16'];

  /// Полный конфиг для туннеля или урезанный ([forTest]) для замера задержки.
  static String build(
    ProxyNode node, {
    LocalProxy? local,
    bool directRu = true,
    bool forTest = false,
    bool encryptedDns = true,
    String dns = 'cloud',
    bool fragment = false,
    bool xrayTun = false,
    int mtu = 1500,
  }) {
    final provider = node.isJson ? jsonDecode(node.raw) as Map<String, dynamic> : null;
    final frag = fragment && node.canFragment;
    final proxies = provider != null ? List<dynamic>.from(provider['outbounds'] as List) : [_outbound(node)];
    if (frag) {
      // Фрагментация TLS ClientHello: ТСПУ хуже узнаёт рукопожатие. Как в Happ — по умолчанию.
      final proxy = proxies.first as Map<String, dynamic>;
      final stream = Map<String, dynamic>.from((proxy['streamSettings'] as Map?) ?? const {});
      stream['sockopt'] = {...?(stream['sockopt'] as Map?), 'dialerProxy': fragmentTag};
      proxies[0] = {...proxy, 'streamSettings': stream};
    }
    final providerRouting = provider?['routing'] as Map?;
    final balancers = providerRouting?['balancers'] as List?;
    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
    };
    if (!forTest) {
      if (local == null) throw ArgumentError('нужен локальный вход');
      const sniffing = {
        'enabled': true,
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': true,
      };
      config['inbounds'] = [
        if (xrayTun)
          {
            'tag': 'tun',
            'protocol': 'tun',
            'settings': {'name': 'xray0', 'mtu': mtu},
            'sniffing': sniffing,
          },
        {
          'tag': 'socks',
          'listen': '127.0.0.1',
          'port': local.socksPort,
          'protocol': 'socks',
          'settings': {
            'auth': 'password',
            'accounts': [
              {'user': local.user, 'pass': local.pass},
            ],
            'udp': true,
          },
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
            'routeOnly': true,
          },
        },
        {
          'tag': 'app',
          'listen': '127.0.0.1',
          'port': local.httpPort,
          'protocol': 'http',
          'settings': {
            'accounts': [
              {'user': local.user, 'pass': local.pass},
            ],
            'allowTransparent': false,
          },
        },
      ];
      // Счётчики трафика для уведомления и экрана (QueryAllOutboundTrafficStats).
      config['stats'] = <String, dynamic>{};
      config['policy'] = {
        'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
      };
      config['dns'] = {
        'servers': [
          for (final s in dnsOrder(dns))
            {
              'address': encryptedDns ? 'https://${dnsServers[s]}/dns-query' : dnsServers[s],
              'timeoutMs': 2500,
            },
        ],
        'queryStrategy': 'UseIPv4',
        'serveStale': true,
        'serveExpiredTTL': 3600,
      };
    }
    config['outbounds'] = [
      ...proxies,
      if (frag)
        {
          'tag': fragmentTag,
          'protocol': 'freedom',
          'settings': {
            'fragment': {'packets': 'tlshello', 'length': '100-200', 'interval': '10-20'},
          },
        },
      {'tag': 'direct', 'protocol': 'freedom'},
      {'tag': 'block', 'protocol': 'blackhole'},
      if (!forTest && encryptedDns) {'tag': 'dns-out', 'protocol': 'dns'},
    ];
    if (!forTest) {
      final balancerTag = (balancers != null && balancers.isNotEmpty) ? (balancers.first as Map)['tag'] : null;
      config['routing'] = {
        'domainStrategy': 'AsIs',
        'rules': [
          if (encryptedDns)
            {
              'type': 'field',
              'inboundTag': ['socks', 'tun'],
              'port': '53',
              'outboundTag': 'dns-out',
            },
          {'type': 'field', 'ip': _privateCidrs, 'outboundTag': 'direct'},
          if (directRu)
            {
              'type': 'field',
              'domain': [for (final d in directDomains) 'domain:$d'],
              'outboundTag': 'direct',
            },
          if (balancerTag != null) {'type': 'field', 'network': 'tcp,udp', 'balancerTag': balancerTag},
        ],
        if (balancers != null) 'balancers': balancers,
      };
      if (provider?['observatory'] != null) config['observatory'] = provider!['observatory'];
      if (provider?['burstObservatory'] != null) config['burstObservatory'] = provider!['burstObservatory'];
    }
    return jsonEncode(config);
  }

  static String? _nb(String? s) => (s == null || s.trim().isEmpty) ? null : s;

  static Map<String, dynamic> _outbound(ProxyNode n) {
    final p = n.params;
    switch (n.protocol) {
      case Protocol.vless:
        return {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': n.address,
                'port': n.port,
                'users': [
                  {
                    'id': n.secret,
                    'encryption': _nb(p['encryption']) ?? 'none',
                    if (_nb(p['flow']) != null) 'flow': p['flow'],
                  },
                ],
              },
            ],
          },
          'streamSettings': _stream(n),
        };
      case Protocol.vmess:
        return {
          'tag': 'proxy',
          'protocol': 'vmess',
          'settings': {
            'vnext': [
              {
                'address': n.address,
                'port': n.port,
                'users': [
                  {
                    'id': n.secret,
                    'alterId': int.tryParse(p['aid'] ?? '') ?? 0,
                    'security': _nb(p['scy']) ?? 'auto',
                  },
                ],
              },
            ],
          },
          'streamSettings': _stream(n),
        };
      case Protocol.trojan:
        return {
          'tag': 'proxy',
          'protocol': 'trojan',
          'settings': {
            'servers': [
              {'address': n.address, 'port': n.port, 'password': n.secret},
            ],
          },
          'streamSettings': _stream(n),
        };
      case Protocol.shadowsocks:
        return {
          'tag': 'proxy',
          'protocol': 'shadowsocks',
          'settings': {
            'servers': [
              {'address': n.address, 'port': n.port, 'method': p['method'] ?? '', 'password': n.secret},
            ],
          },
          'streamSettings': {'network': 'tcp'},
        };
      case Protocol.hysteria2:
        return {
          'tag': 'proxy',
          'protocol': 'hysteria',
          'settings': {'version': 2, 'address': n.address, 'port': n.port},
          'streamSettings': _stream(n),
        };
    }
  }

  static Map<String, dynamic> _stream(ProxyNode n) {
    final p = n.params;
    final hysteria = n.protocol == Protocol.hysteria2;
    final network = hysteria ? 'hysteria' : n.transport;
    final security = hysteria
        ? 'tls'
        : n.security.isNotEmpty
            ? n.security
            : (n.protocol == Protocol.trojan ? 'tls' : 'none');
    final sni = _nb(p['sni']) ?? _nb(p['peer']) ?? _nb(p['host']);
    final path = _nb(p['path']);
    final host = _nb(p['host']);
    final s = <String, dynamic>{'network': network, 'security': security};

    if (security == 'tls') {
      final alpn = _nb(p['alpn']) ?? (hysteria ? 'h3' : null);
      s['tlsSettings'] = {
        if (sni != null) 'serverName': sni,
        if (!hysteria) 'fingerprint': _nb(p['fp']) ?? 'chrome',
        if (alpn != null) 'alpn': alpn.split(',').map((e) => e.trim()).toList(),
        if (n.pinnedCert != null) 'pinnedPeerCertSha256': n.pinnedCert,
      };
    } else if (security == 'reality') {
      s['realitySettings'] = {
        'serverName': sni ?? '',
        'fingerprint': _nb(p['fp']) ?? 'chrome',
        'publicKey': p['pbk'] ?? '',
        'shortId': p['sid'] ?? '',
        if (_nb(p['spx']) != null) 'spiderX': p['spx'],
        if (_nb(p['pqv']) != null) 'mldsa65Verify': p['pqv'],
      };
    }

    switch (network) {
      case 'hysteria':
        s['hysteriaSettings'] = {'version': 2, 'auth': n.secret};
        final obfsType = _nb(p['obfs']) ?? 'salamander';
        final obfs = obfsType == 'salamander' ? _nb(p['obfs-password']) : null;
        final hop = _nb(p['mport']);
        if (obfs != null || hop != null) {
          s['finalmask'] = {
            'udp': [
              if (obfs != null)
                {
                  'type': 'salamander',
                  'settings': {'password': obfs},
                },
              if (hop != null)
                {
                  'type': 'udphop',
                  'settings': {'mode': 'intervallocal,intervalremote', 'remotePorts': hop},
                },
            ],
          };
        }
      case 'ws':
        s['wsSettings'] = {if (path != null) 'path': path, if (host != null) 'host': host};
      case 'httpupgrade':
        s['httpupgradeSettings'] = {if (path != null) 'path': path, if (host != null) 'host': host};
      case 'xhttp' || 'splithttp':
        Map<String, dynamic>? extra;
        final rawExtra = _nb(p['extra']);
        if (rawExtra != null) {
          try {
            final decoded = jsonDecode(rawExtra);
            if (decoded is Map<String, dynamic>) extra = decoded;
          } catch (_) {}
        }
        s['xhttpSettings'] = {
          if (path != null) 'path': path,
          if (host != null) 'host': host,
          if (_nb(p['mode']) != null) 'mode': p['mode'],
          if (extra != null) 'extra': extra,
        };
      case 'grpc':
        s['grpcSettings'] = {
          'serviceName': _nb(p['serviceName']) ?? path ?? '',
          if (p['mode'] == 'multi') 'multiMode': true,
          if (_nb(p['authority']) != null) 'authority': p['authority'],
        };
      case 'tcp' || 'raw':
        if (p['headerType'] == 'http') {
          s['tcpSettings'] = {
            'header': {
              'type': 'http',
              'request': {
                'path': [path ?? '/'],
                'headers': {
                  'Host': host?.split(',').map((e) => e.trim()).toList() ?? <String>[],
                },
              },
            },
          };
        }
    }
    return s;
  }
}
