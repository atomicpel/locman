import 'dart:convert';

/// Терпимое к форматам декодирование Base64: обычный и URL-алфавит,
/// с переносами строк и без выравнивания `=`.
String? decodeBase64(String input) {
  final clean = input.replaceAll(RegExp(r'\s'), '');
  if (clean.isEmpty) return null;
  var normalized = clean.replaceAll('-', '+').replaceAll('_', '/');
  while (normalized.endsWith('=')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (!RegExp(r'^[A-Za-z0-9+/]*$').hasMatch(normalized)) return null;
  final padded = normalized + '=' * ((4 - normalized.length % 4) % 4);
  try {
    return utf8.decode(base64.decode(padded), allowMalformed: false);
  } catch (_) {
    return null;
  }
}

/// FNV-1a, 64 бита: короткий устойчивый идентификатор узла без внешних пакетов.
String stableId(String seed) {
  // Две 32-битные половины, чтобы не упираться в знаковый 64-битный int.
  var hi = 0xcbf29ce4;
  var lo = 0x84222325;
  for (final byte in utf8.encode(seed.trim())) {
    lo ^= byte;
    // (hi:lo) * 0x100000001b3 = (hi:lo) * 0x1b3 + (lo << 40)
    final loMul = lo * 0x1b3;
    final carry = loMul >> 32;
    final newLo = loMul & 0xFFFFFFFF;
    final newHi = (hi * 0x1b3 + carry + ((lo << 8) & 0xFFFFFFFF)) & 0xFFFFFFFF;
    hi = newHi;
    lo = newLo;
  }
  return hi.toRadixString(16).padLeft(8, '0') + lo.toRadixString(16).padLeft(8, '0');
}

/// Процентное декодирование без исключений; обычные символы (в том числе кириллица)
/// остаются как есть, %XX собираются в байты UTF-8.
String pctDecode(String s) {
  if (!s.contains('%')) return s;
  final bytes = <int>[];
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x25 && i + 2 < s.length) {
      final v = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
      if (v != null) {
        bytes.add(v);
        i += 2;
        continue;
      }
    }
    // Обычный символ (с учётом суррогатных пар) — в UTF-8.
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      bytes.addAll(utf8.encode(s.substring(i, i + 2)));
      i++;
    } else {
      bytes.addAll(utf8.encode(String.fromCharCode(c)));
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}
