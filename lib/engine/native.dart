import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../core/xray_config.dart';

/// Состояние службы VPN, как его видит Android-часть.
class VpnStatus {
  const VpnStatus(this.phase, {this.name, this.nodeId, this.since, this.error, this.local});

  /// idle, connecting, connected, failed
  final String phase;
  final String? name;
  final String? nodeId;
  final int? since;
  final String? error;

  /// Входы Xray поднятого туннеля (только из `state()`).
  final LocalProxy? local;

  static VpnStatus fromMap(Map m) => VpnStatus(
        (m['phase'] ?? 'idle') as String,
        name: m['name'] as String?,
        nodeId: m['nodeId'] as String?,
        since: (m['since'] as num?)?.toInt(),
        error: m['error'] as String?,
        local: (m['httpPort'] as num?) != null && (m['httpPort'] as num) > 0
            ? LocalProxy(
                socksPort: (m['socksPort'] as num).toInt(),
                httpPort: (m['httpPort'] as num).toInt(),
                user: m['user'] as String,
                pass: m['pass'] as String,
              )
            : null,
      );
}

class Traffic {
  const Traffic(this.up, this.down, this.upTotal, this.downTotal);
  final int up;
  final int down;
  final int upTotal;
  final int downTotal;
  static const zero = Traffic(0, 0, 0, 0);
}

class NativeInfo {
  NativeInfo(this.filesDir, this.cacheDir, this.versionName, this.versionCode, this.xray, this.abis,
      {this.smoke = false, this.smokeSkin, this.smokeTun, this.extDir});
  final String? extDir;
  final String? smokeTun;
  final bool smoke;
  final String? smokeSkin;
  final List<String> abis;
  final String filesDir;
  final String cacheDir;
  final String versionName;
  final int versionCode;
  final String? xray;
}

class InstalledApp {
  InstalledApp(this.package, this.label);
  final String package;
  final String label;
}

/// Мост к Kotlin: служба VPN, ядро Xray, системные настройки.
class Native {
  static const _core = MethodChannel('locman/core');
  static const _events = EventChannel('locman/events');

  static Stream<Object>? _stream;

  /// События службы: [VpnStatus] и [Traffic].
  static Stream<Object> events() => _stream ??= _events.receiveBroadcastStream().map((e) {
        final m = e as Map;
        if (m['type'] == 'traffic') {
          return Traffic(
            (m['up'] as num).toInt(),
            (m['down'] as num).toInt(),
            (m['upTotal'] as num).toInt(),
            (m['downTotal'] as num).toInt(),
          );
        }
        return VpnStatus.fromMap(m);
      }).asBroadcastStream();

  static Future<NativeInfo> info() async {
    final m = (await _core.invokeMethod<Map>('info'))!;
    return NativeInfo(
      m['filesDir'] as String,
      m['cacheDir'] as String,
      m['versionName'] as String,
      (m['versionCode'] as num).toInt(),
      m['xray'] as String?,
      ((m['abis'] as List?) ?? const []).map((e) => e.toString()).toList(),
      smoke: m['smoke'] == true,
      smokeSkin: m['skin'] as String?,
      smokeTun: m['tun'] as String?,
      extDir: m['extDir'] as String?,
    );
  }

  static Future<bool> prepare() async => (await _core.invokeMethod<bool>('prepare')) ?? false;

  static Future<void> requestNotifications() => _core.invokeMethod('notifications');

  static Future<void> start({
    required String config,
    required String name,
    required String nodeId,
    required int socksPort,
    required int httpPort,
    required String user,
    required String pass,
    required List<String> bypass,
    String tunMode = 'xray',
    int mtu = 1500,
  }) =>
      _core.invokeMethod('start', {
        'config': config,
        'name': name,
        'nodeId': nodeId,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'user': user,
        'pass': pass,
        'bypass': bypass,
        'mtu': mtu,
        'tunMode': tunMode,
      });

  static Future<void> stop() => _core.invokeMethod('stop');

  static Future<VpnStatus> state() async =>
      VpnStatus.fromMap((await _core.invokeMethod<Map>('state')) ?? const {'phase': 'idle'});

  /// Реальная задержка через узел (мс) или -1.
  static Future<int> measure(String config, String url) async {
    try {
      return (await _core.invokeMethod<int>('measure', {'config': config, 'url': url})) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// Отдельный экземпляр ядра для замера скорости узла; вернёт номер или null.
  static Future<int?> probeStart(String config) => _core.invokeMethod<int>('probeStart', {'config': config});
  static Future<void> probeStop(int id) => _core.invokeMethod('probeStop', {'id': id});

  static Future<List<InstalledApp>> apps() async {
    final list = (await _core.invokeMethod<List>('apps')) ?? const [];
    return list.whereType<Map>().map((m) => InstalledApp(m['package'] as String, m['label'] as String)).toList();
  }

  static Future<Uint8List?> appIcon(String package) =>
      _core.invokeMethod<Uint8List>('appIcon', {'package': package});

  static Future<bool> batteryRestricted() async => (await _core.invokeMethod<bool>('batteryRestricted')) ?? false;

  static Future<void> openBattery() => _core.invokeMethod('openBattery');
  static Future<void> openAutostart() => _core.invokeMethod('openAutostart');
  static Future<void> openVpnSettings() => _core.invokeMethod('openVpnSettings');
  static Future<void> openUrl(String url) => _core.invokeMethod('openUrl', {'url': url});

  /// null — APK наш, подпись и версия совпали; иначе текст ошибки.
  static Future<String?> verifyApk(String path, String sha256, int versionCode) => _core.invokeMethod<String>(
        'verifyApk',
        {'path': path, 'sha256': sha256, 'versionCode': versionCode},
      );

  /// false — нужно разрешение «Установка неизвестных приложений», экран уже открыт.
  static Future<bool> installApk(String path) async =>
      (await _core.invokeMethod<bool>('installApk', {'path': path})) ?? false;
}
