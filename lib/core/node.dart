import 'geo.dart';

enum Protocol { vless, vmess, trojan, shadowsocks, hysteria2 }

extension ProtocolTitle on Protocol {
  String get title => switch (this) {
        Protocol.vless => 'VLESS',
        Protocol.vmess => 'VMess',
        Protocol.trojan => 'Trojan',
        Protocol.shadowsocks => 'SS',
        Protocol.hysteria2 => 'Hy2',
      };
}

const _aeadMethods = {
  'aes-128-gcm',
  'aes-192-gcm',
  'aes-256-gcm',
  'chacha20-ietf-poly1305',
  'chacha20-poly1305',
  'xchacha20-ietf-poly1305',
  'xchacha20-poly1305',
};

class ProxyNode {
  ProxyNode({
    required this.id,
    required this.protocol,
    required this.name,
    required this.address,
    required this.port,
    required this.secret,
    required this.params,
    required this.raw,
    required this.sourceId,
  }) : place = Place.fromName(name);

  final String id;
  final Protocol protocol;
  final String name;
  final String address;
  final int port;
  final String secret;
  final Map<String, String> params;
  final String raw;
  final String sourceId;

  /// Страна, угаданная по имени узла (флаг, код, название).
  final Place place;

  String get security => (params['security'] ?? '').toLowerCase();

  String get transport {
    final t = (params['type'] ?? '').toLowerCase();
    return t.isEmpty ? 'tcp' : t;
  }

  bool get isJson => raw.startsWith('{');

  String? get pinnedCert {
    final v = params['pcs'] ?? params['pinSHA256'];
    return (v == null || v.trim().isEmpty) ? null : v;
  }

  String? get securityIssue {
    final insecureFlag = params['allowInsecure'] == '1' || params['insecure'] == '1';
    if (insecureFlag && pinnedCert == null) return 'Без проверки сертификата';
    switch (protocol) {
      case Protocol.vless:
        if (security.isEmpty || security == 'none') return 'Без шифрования';
      case Protocol.trojan:
        if (security == 'none') return 'Без шифрования';
      case Protocol.vmess:
        final scy = (params['scy'] ?? '').toLowerCase();
        if (scy == 'none' || scy == 'zero') return 'Без шифрования';
      case Protocol.shadowsocks:
        final method = (params['method'] ?? '').toLowerCase();
        if (method.isEmpty || method == 'none' || method == 'plain' || method == 'table') {
          return 'Без шифрования';
        }
        if (!_aeadMethods.contains(method) && !method.startsWith('2022-blake3-')) {
          return 'Устаревшее шифрование';
        }
      case Protocol.hysteria2:
        break;
    }
    return null;
  }

  bool get isInsecure => securityIssue != null;

  /// Подпись транспорта, как в макете: Reality, XHTTP, WS, gRPC, TCP…
  String get transportLabel {
    if (protocol == Protocol.hysteria2) return 'QUIC';
    if (security == 'reality') return 'Reality';
    return switch (transport) {
      'xhttp' || 'splithttp' => 'XHTTP',
      'ws' => 'WS',
      'grpc' => 'gRPC',
      'httpupgrade' => 'HTTPUpgrade',
      'tcp' || 'raw' => security == 'tls' ? 'TLS' : 'TCP',
      _ => transport.toUpperCase(),
    };
  }

  bool get isReality => security == 'reality';
  bool get isXhttp => transport == 'xhttp' || transport == 'splithttp';

  /// Узлы, которые нельзя проверить простым TCP-подключением.
  bool get coreOnly => protocol == Protocol.hysteria2 || isJson;

  /// Можно ли резать TLS ClientHello на куски (фрагментация против DPI).
  bool get canFragment =>
      !isJson &&
      protocol != Protocol.hysteria2 &&
      protocol != Protocol.shadowsocks &&
      (security == 'tls' || security == 'reality' || (protocol == Protocol.trojan && security.isEmpty));

  /// Подставляется ли отпечаток браузера (TLS и Reality).
  bool get usesFingerprint => canFragment;

  /// Можно ли пустить всё через одно соединение (mux): не с Vision, XHTTP, Hysteria2 и SS.
  bool get canMux =>
      !isJson &&
      protocol != Protocol.hysteria2 &&
      protocol != Protocol.shadowsocks &&
      (params['flow'] ?? '').trim().isEmpty &&
      !isXhttp;

  /// Вид соединения: провайдер обычно режет целый вид, а не один сервер.
  String get kind => '${protocol.name}/$security/$transport';

  bool get _isIp => RegExp(r'^[\d.]+$').hasMatch(address) || address.contains(':');

  /// Нужно ли заранее искать IP сервера (адрес — домен).
  bool get needsResolve => !isJson && !_isIp;

  /// Тот же узел, но с уже найденным IP; домен остаётся в SNI и Host,
  /// чтобы рукопожатие не изменилось.
  ProxyNode withAddress(String ip) {
    final p = Map<String, String>.from(params);
    String v(String k) => (p[k] ?? '').trim();
    final tlsLike = security == 'tls' || security == 'reality' || protocol == Protocol.trojan || protocol == Protocol.hysteria2;
    if (tlsLike && v('sni').isEmpty && v('peer').isEmpty && v('host').isEmpty) p['sni'] = address;
    if (v('host').isEmpty && const {'ws', 'httpupgrade', 'xhttp', 'splithttp'}.contains(transport)) p['host'] = address;
    return ProxyNode(
      id: id,
      protocol: protocol,
      name: name,
      address: ip,
      port: port,
      secret: secret,
      params: p,
      raw: raw,
      sourceId: sourceId,
    );
  }

  /// Ключ «одинакового» узла для скрытия дублей.
  String get endpointKey => isJson ? id : '${protocol.name}/${address.toLowerCase()}/$port';

  String get title => place.country ?? _shortName;

  String get _shortName {
    final cleaned = name.replaceAll(RegExp(r'[\u{1F1E6}-\u{1F1FF}]', unicode: true), '').trim();
    return cleaned.isEmpty ? '$address:$port' : cleaned;
  }

  /// Короткая метка для значка: код страны или протокол.
  String get badge =>
      place.code ??
      switch (protocol) {
        Protocol.vless => 'VL',
        Protocol.vmess => 'VM',
        Protocol.trojan => 'TR',
        Protocol.shadowsocks => 'SS',
        Protocol.hysteria2 => 'HY',
      };

  String get subtitle {
    final n = _shortName.length > 28 ? '${_shortName.substring(0, 27)}…' : _shortName;
    return '$n · ${protocol.title} · $transportLabel';
  }
}
