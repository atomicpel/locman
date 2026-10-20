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

/// Процентное декодирование без исключений.
String pctDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}
