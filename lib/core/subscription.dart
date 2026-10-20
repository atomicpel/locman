import 'b64.dart';
import 'link_parser.dart';
import 'node.dart';
import 'xray_json.dart';

class Usage {
  const Usage(this.used, this.total, this.expire);
  final int used;
  final int total;

  /// Unix-время окончания, секунды; 0 — бессрочно.
  final int expire;
}

class ParsedSubscription {
  ParsedSubscription({
    required this.title,
    required this.updateIntervalHours,
    required this.announce,
    required this.nodes,
    required this.notices,
    required this.skipped,
    required this.usage,
  });

  final String? title;
  final int? updateIntervalHours;
  final String? announce;
  final List<ProxyNode> nodes;

  /// Заглушки вида «подписка истекла» (адрес 0.0.0.0).
  final List<String> notices;
  final Map<String, int> skipped;
  final Usage? usage;
}

class SubscriptionParser {
  static ParsedSubscription parse(String body, String sourceId, {Map<String, String> headers = const {}}) {
    var text = body.trim();
    if (text.startsWith('﻿')) text = text.substring(1);
    final json = XrayJsonParser.parse(text, sourceId);
    if (json == null && !text.contains('://')) {
      final decoded = decodeBase64(text);
      if (decoded != null && decoded.contains('://')) text = decoded;
    }

    final meta = <String, String>{for (final e in headers.entries) e.key.toLowerCase(): e.value};
    final nodes = <String, ProxyNode>{};
    final notices = <String>[];
    final skipped = <String, int>{};
    final announce = <String>[];

    void add(ProxyNode n) {
      if (n.address == '0.0.0.0' || n.address == '127.0.0.1') {
        notices.add(n.name);
      } else if (_privateLiteral(n.address)) {
        skipped['private'] = (skipped['private'] ?? 0) + 1;
      } else {
        nodes.putIfAbsent(n.id, () => n);
      }
    }

    if (json != null) {
      json.forEach(add);
    } else {
      for (final rawLine in text.split(RegExp(r'\r?\n'))) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        if (line.startsWith('{')) {
          XrayJsonParser.parse(line, sourceId)?.forEach(add);
          continue;
        }
        if (line.startsWith('#')) {
          final kv = line.substring(1).trim();
          final colon = kv.indexOf(':');
          if (colon > 0) {
            final key = kv.substring(0, colon).trim().toLowerCase();
            final value = kv.substring(colon + 1).trim();
            if (key == 'announce') {
              final v = _maybeBase64(value);
              if (v.trim().isNotEmpty) announce.add(v);
            } else if (key.isNotEmpty && !key.contains(' ')) {
              meta.putIfAbsent(key, () => value);
            }
          }
          continue;
        }
        final node = LinkParser.parse(line, sourceId: sourceId);
        if (node == null) {
          final sep = line.indexOf('://');
          if (sep > 0 && sep <= 16) {
            final scheme = line.substring(0, sep).toLowerCase();
            skipped[scheme] = (skipped[scheme] ?? 0) + 1;
          }
          continue;
        }
        add(node);
      }
    }

    final title = meta['profile-title'];
    final ann = meta['announce'] != null ? _maybeBase64(meta['announce']!) : announce.join('\n');
    return ParsedSubscription(
      title: title == null ? null : _maybeBase64(title),
      updateIntervalHours: int.tryParse(meta['profile-update-interval']?.trim() ?? ''),
      announce: ann.trim().isEmpty ? null : ann,
      nodes: nodes.values.toList(),
      notices: notices,
      skipped: skipped,
      usage: _usage(meta['subscription-userinfo']),
    );
  }

  /// Адрес-литерал из частной/локальной сети или localhost.
  static bool _privateLiteral(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true;
    final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$').firstMatch(h);
    if (m != null) {
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2)!);
      return a == 0 || a == 10 || a == 127 || a >= 224 ||
          (a == 100 && b >= 64 && b < 128) || (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b < 32) || (a == 192 && b == 168);
    }
    return h.startsWith('fc') || h.startsWith('fd') || h.startsWith('fe80') || h == '::1';
  }

  static Usage? _usage(String? value) {
    if (value == null) return null;
    final parts = <String, int>{};
    for (final part in value.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      final n = int.tryParse(part.substring(eq + 1).trim().split('.').first);
      if (key.isNotEmpty && n != null) parts[key] = n;
    }
    final u = Usage((parts['upload'] ?? 0) + (parts['download'] ?? 0), parts['total'] ?? 0, parts['expire'] ?? 0);
    return (u.used > 0 || u.total > 0 || u.expire > 0) ? u : null;
  }

  static String _maybeBase64(String value) {
    if (!value.startsWith('base64:')) return value;
    return decodeBase64(value.substring(7)) ?? value;
  }
}
