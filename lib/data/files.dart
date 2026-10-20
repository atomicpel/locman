import 'dart:convert';
import 'dart:io';

/// Файлы приложения в его закрытой папке. Запись атомарная: временный файл + переименование.
class Files {
  Files(this.root);

  final String root;

  File file(String name) => File('$root/$name');

  Future<String?> readText(String name) async {
    final f = file(name);
    try {
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> readJson(String name) async {
    final text = await readText(name);
    if (text == null) return null;
    try {
      final v = jsonDecode(text);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeText(String name, String text) async {
    final f = file(name);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }

  Future<void> writeJson(String name, Object value) => writeText(name, jsonEncode(value));

  Future<void> delete(String name) async {
    final f = file(name);
    if (await f.exists()) await f.delete();
  }
}
