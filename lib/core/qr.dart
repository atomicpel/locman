import 'dart:io';
import 'dart:typed_data';

/// QR-код без сторонних пакетов: байтовый режим, уровень коррекции L, версия и маска — сами.
/// Алгоритм — по спецификации ISO/IEC 18004 (как у Nayuki); сверено с библиотекой python-qrcode.
/// На Android QR рисует ZXing, этот кодер нужен Windows-версии.
class QrCode {
  QrCode._(this.version, this.mask, this.size, this._modules);

  final int version;
  final int mask;
  final int size;
  final List<bool> _modules;

  bool dark(int x, int y) => _modules[y * size + x];

  static const _eccPerBlock = [
    -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, //
    28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
  ];
  static const _blocks = [
    -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, //
    8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
  ];

  static int _rawModules(int ver) {
    var r = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
      final na = ver ~/ 7 + 2;
      r -= (25 * na - 10) * na - 55;
      if (ver >= 7) r -= 36;
    }
    return r;
  }

  static int _dataCodewords(int ver) => _rawModules(ver) ~/ 8 - _eccPerBlock[ver] * _blocks[ver];

  /// Максимум байт, который влезает (версия 40, уровень L).
  static const maxBytes = 2953;

  /// null — данные не помещаются в QR.
  static QrCode? encode(List<int> data) {
    int? ver;
    for (var v = 1; v <= 40; v++) {
      final need = 4 + (v <= 9 ? 8 : 16) + data.length * 8;
      if (need <= _dataCodewords(v) * 8) {
        ver = v;
        break;
      }
    }
    if (ver == null) return null;

    // Биты данных: режим «байты», длина, данные, терминатор, выравнивание, заполнители.
    final bits = <int>[];
    void put(int val, int n) {
      for (var i = n - 1; i >= 0; i--) {
        bits.add((val >> i) & 1);
      }
    }

    put(4, 4);
    put(data.length, ver <= 9 ? 8 : 16);
    for (final b in data) {
      put(b & 0xFF, 8);
    }
    final cap = _dataCodewords(ver) * 8;
    put(0, (cap - bits.length).clamp(0, 4));
    put(0, (8 - bits.length % 8) % 8);
    for (var pad = 0xEC; bits.length < cap; pad ^= 0xEC ^ 0x11) {
      put(pad, 8);
    }
    final codewords = List<int>.filled(bits.length ~/ 8, 0);
    for (var i = 0; i < bits.length; i++) {
      codewords[i >> 3] |= bits[i] << (7 - (i & 7));
    }

    // Коррекция ошибок Рида — Соломона по блокам и чередование.
    final nb = _blocks[ver];
    final blen = _eccPerBlock[ver];
    final raw = _rawModules(ver) ~/ 8;
    final nShort = nb - raw % nb;
    final shortLen = raw ~/ nb;
    final div = _rsDivisor(blen);
    final blocks = <List<int>>[];
    var k = 0;
    for (var i = 0; i < nb; i++) {
      final len = shortLen - blen + (i < nShort ? 0 : 1);
      final dat = codewords.sublist(k, k + len);
      k += len;
      final ecc = _rsRemainder(dat, div);
      blocks.add([...dat, if (i < nShort) 0, ...ecc]);
    }
    final result = <int>[];
    for (var i = 0; i < blocks[0].length; i++) {
      for (var j = 0; j < blocks.length; j++) {
        if (i != shortLen - blen || j >= nShort) result.add(blocks[j][i]);
      }
    }

    final size = ver * 4 + 17;
    final mod = List<bool>.filled(size * size, false);
    final fn = List<bool>.filled(size * size, false);
    void setF(int x, int y, bool d) {
      mod[y * size + x] = d;
      fn[y * size + x] = true;
    }

    for (var i = 0; i < size; i++) {
      setF(6, i, i % 2 == 0);
      setF(i, 6, i % 2 == 0);
    }
    void finder(int cx, int cy) {
      for (var dy = -4; dy <= 4; dy++) {
        for (var dx = -4; dx <= 4; dx++) {
          final dist = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
          final x = cx + dx, y = cy + dy;
          if (x >= 0 && x < size && y >= 0 && y < size) setF(x, y, dist != 2 && dist != 4);
        }
      }
    }

    finder(3, 3);
    finder(size - 4, 3);
    finder(3, size - 4);
    if (ver > 1) {
      final na = ver ~/ 7 + 2;
      final step = (ver * 8 + na * 3 + 5) ~/ (na * 4 - 4) * 2;
      final pos = [6, for (var i = na - 2; i >= 0; i--) size - 7 - i * step];
      for (var i = 0; i < na; i++) {
        for (var j = 0; j < na; j++) {
          if ((i == 0 && j == 0) || (i == 0 && j == na - 1) || (i == na - 1 && j == 0)) continue;
          for (var dy = -2; dy <= 2; dy++) {
            for (var dx = -2; dx <= 2; dx++) {
              final dist = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
              setF(pos[i] + dx, pos[j] + dy, dist != 1);
            }
          }
        }
      }
    }
    void format(int m) {
      final d = (1 << 3) | m; // уровень L = 01
      var rem = d;
      for (var i = 0; i < 10; i++) {
        rem = (rem << 1) ^ ((rem >> 9) * 0x537);
      }
      final b = ((d << 10) | rem) ^ 0x5412;
      bool g(int i) => ((b >> i) & 1) != 0;
      for (var i = 0; i < 6; i++) {
        setF(8, i, g(i));
      }
      setF(8, 7, g(6));
      setF(8, 8, g(7));
      setF(7, 8, g(8));
      for (var i = 9; i < 15; i++) {
        setF(14 - i, 8, g(i));
      }
      for (var i = 0; i < 8; i++) {
        setF(size - 1 - i, 8, g(i));
      }
      for (var i = 8; i < 15; i++) {
        setF(8, size - 15 + i, g(i));
      }
      setF(8, size - 8, true);
    }

    format(0);
    if (ver >= 7) {
      var rem = ver;
      for (var i = 0; i < 12; i++) {
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
      }
      final b = (ver << 12) | rem;
      for (var i = 0; i < 18; i++) {
        final bit = ((b >> i) & 1) != 0;
        final a = size - 11 + i % 3, c = i ~/ 3;
        setF(a, c, bit);
        setF(c, a, bit);
      }
    }

    // Данные — зигзагом снизу вверх, по два столбца.
    var bit = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = ((right + 1) & 2) == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!fn[y * size + x] && bit < result.length * 8) {
            mod[y * size + x] = ((result[bit >> 3] >> (7 - (bit & 7))) & 1) != 0;
            bit++;
          }
        }
      }
    }

    void applyMask(int m) {
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final inv = switch (m) {
            0 => (x + y) % 2 == 0,
            1 => y % 2 == 0,
            2 => x % 3 == 0,
            3 => (x + y) % 3 == 0,
            4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
            5 => x * y % 2 + x * y % 3 == 0,
            6 => (x * y % 2 + x * y % 3) % 2 == 0,
            _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
          };
          if (inv && !fn[y * size + x]) mod[y * size + x] = !mod[y * size + x];
        }
      }
    }

    var best = 0;
    int? bestPenalty;
    for (var m = 0; m < 8; m++) {
      applyMask(m);
      format(m);
      final p = _penalty(mod, size);
      if (bestPenalty == null || p < bestPenalty) {
        best = m;
        bestPenalty = p;
      }
      applyMask(m);
    }
    applyMask(best);
    format(best);
    return QrCode._(ver, best, size, mod);
  }

  static int _penalty(List<bool> mod, int size) {
    var res = 0;
    int line(bool Function(int) at) {
      var r = 0;
      var runColor = false;
      var run = 0;
      final hist = List<int>.filled(7, 0);
      void addHist(int cur) {
        if (hist[0] == 0) cur += size;
        for (var i = 6; i > 0; i--) {
          hist[i] = hist[i - 1];
        }
        hist[0] = cur;
      }

      int patterns() {
        final n = hist[1];
        final core = n > 0 && hist[2] == n && hist[3] == n * 3 && hist[4] == n && hist[5] == n;
        return (core && hist[0] >= n * 4 && hist[6] >= n ? 1 : 0) + (core && hist[6] >= n * 4 && hist[0] >= n ? 1 : 0);
      }

      for (var i = 0; i < size; i++) {
        final c = at(i);
        if (c == runColor) {
          run++;
          if (run == 5) {
            r += 3;
          } else if (run > 5) {
            r += 1;
          }
        } else {
          addHist(run);
          if (!runColor) r += patterns() * 40;
          runColor = c;
          run = 1;
        }
      }
      var cur = run;
      if (runColor) {
        addHist(cur);
        cur = 0;
      }
      cur += size;
      addHist(cur);
      r += patterns() * 40;
      return r;
    }

    for (var y = 0; y < size; y++) {
      res += line((x) => mod[y * size + x]);
    }
    for (var x = 0; x < size; x++) {
      res += line((y) => mod[y * size + x]);
    }
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final c = mod[y * size + x];
        if (c == mod[y * size + x + 1] && c == mod[(y + 1) * size + x] && c == mod[(y + 1) * size + x + 1]) res += 3;
      }
    }
    var dark = 0;
    for (final c in mod) {
      if (c) dark++;
    }
    final total = size * size;
    final k = ((dark * 20 - total * 10).abs() + total - 1) ~/ total - 1;
    return res + k * 10;
  }

  static int _rsMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = ((z << 1) ^ ((z >> 7) * 0x11D)) & 0xFFFF;
      z ^= ((y >> i) & 1) * x;
    }
    return z & 0xFF;
  }

  static List<int> _rsDivisor(int degree) {
    final r = List<int>.filled(degree, 0);
    r[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        r[j] = _rsMul(r[j], root);
        if (j + 1 < degree) r[j] ^= r[j + 1];
      }
      root = _rsMul(root, 0x02);
    }
    return r;
  }

  static List<int> _rsRemainder(List<int> data, List<int> div) {
    final r = List<int>.filled(div.length, 0);
    for (final b in data) {
      final factor = b ^ r[0];
      r.removeAt(0);
      r.add(0);
      for (var i = 0; i < div.length; i++) {
        r[i] ^= _rsMul(div[i], factor);
      }
    }
    return r;
  }

  /// Чёрно-белый PNG: [scale] пикселей на модуль, [border] модулей белого поля.
  Uint8List toPng({int scale = 8, int border = 4}) {
    final w = (size + border * 2) * scale;
    final rows = BytesBuilder(copy: false);
    for (var py = 0; py < w; py++) {
      final row = Uint8List(w + 1); // байт фильтра 0
      final my = py ~/ scale - border;
      for (var px = 0; px < w; px++) {
        final mx = px ~/ scale - border;
        final isDark = mx >= 0 && my >= 0 && mx < size && my < size && dark(mx, my);
        row[px + 1] = isDark ? 0 : 255;
      }
      rows.add(row);
    }
    final idat = ZLibCodec(level: 9).encode(rows.takeBytes());
    final out = BytesBuilder()..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
    void chunk(String type, List<int> data) {
      final t = type.codeUnits;
      out.add(_u32(data.length));
      out.add(t);
      out.add(data);
      out.add(_u32(_crc32([...t, ...data])));
    }

    chunk('IHDR', [..._u32(w), ..._u32(w), 8, 0, 0, 0, 0]); // 8 бит, оттенки серого
    chunk('IDAT', idat);
    chunk('IEND', const []);
    return out.takeBytes();
  }

  static List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

  static List<int>? _crcTable;

  static int _crc32(List<int> data) {
    final table = _crcTable ??= List<int>.generate(256, (n) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      return c;
    });
    var crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
