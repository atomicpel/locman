/// Маршруты в туннель: весь IPv4, кроме частных, служебных и групповых подсетей
/// (локальная сеть — роутер, камеры, принтеры — остаётся мимо узла). Как Routes.kt на Android.
const _excluded = [
  '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', //
  '172.16.0.0/12', '192.168.0.0/16', '224.0.0.0/3',
];

(int, int) _parse(String cidr) {
  final parts = cidr.split('/');
  final n = parts[0].split('.').fold<int>(0, (acc, p) => (acc << 8) | int.parse(p));
  return (n, int.parse(parts[1]));
}

String _format(int n) => [24, 16, 8, 0].map((s) => ((n >> s) & 0xFF).toString()).join('.');

List<String> publicIpv4() {
  final ex = _excluded.map(_parse).toList();
  final out = <String>[];
  bool overlaps(int start, int len, (int, int) e) {
    final l = len < e.$2 ? len : e.$2;
    final mask = l == 0 ? 0 : (0xFFFFFFFF << (32 - l)) & 0xFFFFFFFF;
    return (start & mask) == (e.$1 & mask);
  }

  void walk(int start, int len) {
    final hits = ex.where((e) => overlaps(start, len, e)).toList();
    if (hits.isEmpty) {
      out.add('${_format(start)}/$len');
    } else if (hits.any((e) => e.$2 <= len)) {
      return; // целиком исключённая сеть
    } else {
      walk(start, len + 1);
      walk(start | (1 << (31 - len)), len + 1);
    }
  }

  walk(0, 0);
  return out;
}
