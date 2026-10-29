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

/// Windows: как пускать трафик в узел и какие локальные порты открыть.
class WinTunnel {
  const WinTunnel({
    required this.tun,
    required this.httpPort,
    required this.socksPort,
    required this.metricsPort,
    this.leakBlock = false,
    this.logFile,
  });

  /// true — TUN (Wintun, весь трафик, нужны права администратора); false — системный прокси.
  final bool tun;

  /// HTTP- и SOCKS-прокси без пароля на 127.0.0.1 — для системного прокси и программ.
  final int httpPort;
  final int socksPort;

  /// Счётчики трафика ядра (/debug/vars) на 127.0.0.1.
  final int metricsPort;

  /// Фильтры WFP: DNS только через TUN.
  final bool leakBlock;
  final String? logFile;
}

/// Как подключаться к узлу, если обычный способ не пропускает данные:
/// другой отпечаток браузера, всё через одно соединение (mux), дробление первого пакета.
/// [dns] — какой DNS-сервер отвечает через этот узел.
class NodeProfile {
  const NodeProfile({this.fp, this.mux = false, this.frag, this.dns});
  final String? fp;
  final bool mux;

  /// null — как в настройках; true/false — принудительно.
  final bool? frag;
  final String? dns;

  bool get isPlain => fp == null && !mux && frag == null;

  NodeProfile withDns(String? d) => NodeProfile(fp: fp, mux: mux, frag: frag, dns: d);

  String get label => [
        if (fp != null) fp == 'firefox' ? 'Firefox' : (fp == 'edge' ? 'Edge' : fp!),
        if (mux) 'одно соединение',
        if (frag == true) 'дробление',
        if (frag == false) 'без дробления',
      ].join(', ');

  Map<String, Object> toJson() => {
        if (fp != null) 'fp': fp!,
        if (mux) 'mux': true,
        if (frag != null) 'frag': frag!,
        if (dns != null) 'dns': dns!,
      };

  static NodeProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    return NodeProfile(
      fp: j['fp'] as String?,
      mux: j['mux'] == true,
      frag: j['frag'] as bool?,
      dns: dnsServers.containsKey(j['dns']) ? j['dns'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NodeProfile && other.fp == fp && other.mux == mux && other.frag == frag && other.dns == dns;

  @override
  int get hashCode => Object.hash(fp, mux, frag, dns);
}

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
    NodeProfile? profile,
    bool udp = true,
    WinTunnel? win,
    List<String> tunRoutes = const [],
    bool joinConns = false,
  }) {
    final provider = node.isJson ? jsonDecode(node.raw) as Map<String, dynamic> : null;
    final frag = (profile?.frag ?? fragment) && node.canFragment;
    final fp = node.usesFingerprint ? profile?.fp : null;
    final mux = (profile?.mux == true || (joinConns && node.muxHelps)) && node.canMux;
    final proxies = provider != null ? List<dynamic>.from(provider['outbounds'] as List) : [_outbound(node, fp: fp, mux: mux)];
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
      'log': {
        'loglevel': 'warning',
        if (win?.logFile != null) ...{'access': 'none', 'error': win!.logFile},
      },
    };
    if (!forTest) {
      if (local == null) throw ArgumentError('нужен локальный вход');
      const sniffing = {
        'enabled': true,
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': true,
      };
      config['inbounds'] = [
        if (win != null && win.tun)
          {
            'tag': 'tun',
            'protocol': 'tun',
            'settings': {
              'name': 'Locman',
              'mtu': mtu,
              'gateway': ['172.19.255.1/30', 'fdfe:dcba:9876::1/126'],
              'dns': ['1.1.1.1'],
              'autoSystemRoutingTable': [...tunRoutes, '2000::/3'],
              if (win.leakBlock) 'autoSystemWfpBlockLeak': ['dns'],
            },
            'sniffing': sniffing,
          },
        if (win != null) ...[
          {
            'tag': 'sys',
            'listen': '127.0.0.1',
            'port': win.httpPort,
            'protocol': 'http',
            'settings': {'allowTransparent': false},
            'sniffing': sniffing,
          },
          {
            'tag': 'syssocks',
            'listen': '127.0.0.1',
            'port': win.socksPort,
            'protocol': 'socks',
            'settings': {'auth': 'noauth', 'udp': true},
            'sniffing': sniffing,
          },
        ],
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
            'udp': udp,
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
      if (win != null) config['metrics'] = {'listen': '127.0.0.1:${win.metricsPort}'};
      config['policy'] = {
        'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
      };
      config['dns'] = {
        'servers': [
          for (final s in dnsOrder(profile?.dns ?? dns))
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
              'inboundTag': ['socks', 'tun', 'syssocks'],
              'port': '53',
              'outboundTag': 'dns-out',
            },
          // Windows TUN: сам «Лоцман» и пробные ядра проверки ходят напрямую, а не через текущий узел.
          if (win != null && win.tun)
            {
              'type': 'field',
              'process': ['xray/', 'locman.exe'],
              'outboundTag': 'direct',
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

  static Map<String, dynamic> _outbound(ProxyNode n, {String? fp, bool mux = false}) {
    final o = _baseOutbound(n, fp);
    if (!mux) return o;
    return {
      ...o,
      'mux': {'enabled': true, 'concurrency': 8, 'xudpConcurrency': 8, 'xudpProxyUDP443': 'reject'},
    };
  }

  static Map<String, dynamic> _baseOutbound(ProxyNode n, String? fp) {
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
          'streamSettings': _stream(n, fp),
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
          'streamSettings': _stream(n, fp),
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
          'streamSettings': _stream(n, fp),
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
          'streamSettings': _stream(n, fp),
        };
    }
  }

  static Map<String, dynamic> _stream(ProxyNode n, String? fp) {
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
        if (!hysteria) 'fingerprint': fp ?? _nb(p['fp']) ?? 'chrome',
        if (alpn != null) 'alpn': alpn.split(',').map((e) => e.trim()).toList(),
        if (n.pinnedCert != null) 'pinnedPeerCertSha256': n.pinnedCert,
      };
    } else if (security == 'reality') {
      s['realitySettings'] = {
        'serverName': sni ?? '',
        'fingerprint': fp ?? _nb(p['fp']) ?? 'chrome',
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
