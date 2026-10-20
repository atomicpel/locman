import 'dart:convert';

/// Режим сети: белые списки (БС) или обычные блокировки (ЧС).
enum NetKind { white, black }

/// Источник узлов: открытая подписка из каталога или своя.
class Source {
  Source({
    required this.id,
    required this.title,
    required this.author,
    required this.homepage,
    required this.license,
    required this.description,
    required this.mode,
    required this.mirrors,
    required this.origin,
    this.status = 'ok',
    this.recommended = false,
    this.catalogNodes = 0,
    this.links,
  });

  final String id;
  final String title;
  final String author;
  final String homepage;
  final String license;
  final String description;

  /// 'white', 'black' или 'any'.
  final String mode;
  final List<String> mirrors;

  /// 'curated', 'found' (найден автоматически) или 'mine'.
  final String origin;
  final String status;
  final bool recommended;
  final int catalogNodes;

  /// Для своих источников из вставленных ключей: сами ссылки.
  final String? links;

  bool get isMine => origin == 'mine';
  bool get isFound => origin == 'found';
  bool get hasUrl => mirrors.isNotEmpty;

  bool fits(NetKind? kind) {
    if (kind == null || mode == 'any') return true;
    return (mode == 'white') == (kind == NetKind.white);
  }

  String get modeLabel => switch (mode) { 'white' => 'БС', 'black' => 'ЧС', _ => 'Любой' };

  factory Source.fromJson(Map<String, dynamic> j) => Source(
        id: j['id'] as String,
        title: (j['title'] ?? j['id']) as String,
        author: (j['author'] ?? '') as String,
        homepage: (j['homepage'] ?? '') as String,
        license: (j['license'] ?? 'не указана') as String,
        description: (j['description'] ?? '') as String,
        mode: (j['mode'] ?? 'any') as String,
        mirrors: ((j['mirrors'] as List?) ?? const []).map((e) => e.toString()).toList(),
        origin: (j['origin'] ?? 'curated') as String,
        status: (j['status'] ?? 'ok') as String,
        recommended: j['recommended'] == true,
        catalogNodes: (j['secure'] as num?)?.toInt() ?? 0,
        links: j['links'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'homepage': homepage,
        'license': license,
        'description': description,
        'mode': mode,
        'mirrors': mirrors,
        'origin': origin,
        if (links != null) 'links': links,
      };
}

class Catalog {
  Catalog(this.generatedAt, this.sources);

  final DateTime generatedAt;
  final List<Source> sources;

  static Catalog? tryParse(String text) {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      if ((j['version'] as num?)?.toInt() != 1) return null;
      final list = (j['sources'] as List).whereType<Map>().map((e) => Source.fromJson(Map<String, dynamic>.from(e)));
      return Catalog(
        DateTime.tryParse(j['generatedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        list.where((s) => s.mirrors.isNotEmpty).toList(),
      );
    } catch (_) {
      return null;
    }
  }
}
