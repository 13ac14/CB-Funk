import 'dart:io';
import 'package:record/record.dart';
import 'android_native.dart';
import 'device_info.dart';
import 'win_native.dart';

/// Listen fuer die Auswahl im Einstellungsdialog
class GatewayDevices {
  static Future<List<DeviceInfo>> listSerial() async {
    try {
      if (Platform.isWindows) {
        return winListComPorts().map((n) => DeviceInfo(n, n)).toList();
      }
      if (Platform.isAndroid) return await AndroidSerial.list();
    } catch (_) {}
    return [];
  }

  static Future<List<DeviceInfo>> listHid() async {
    try {
      if (Platform.isWindows) {
        final seen = <String>{};
        final out = <DeviceInfo>[];
        for (final d in winEnumerateHid()) {
          final k = '${hex4(d.vid)}:${hex4(d.pid)}';
          if (seen.add(k)) {
            out.add(DeviceInfo(k, '${knownHidName(d.vid, d.pid)} ($k)'));
          }
        }
        return out;
      }
      if (Platform.isAndroid) return await AndroidHid.list();
    } catch (_) {}
    return [];
  }

  static Future<List<DeviceInfo>> listInputs() async {
    final rec = AudioRecorder();
    try {
      final l = await rec.listInputDevices().timeout(
        const Duration(seconds: 3),
        onTimeout: () => [],
      );
      return l.map((d) => DeviceInfo(d.id, d.label.isNotEmpty ? d.label : d.id)).toList();
    } catch (_) {
      return [];
    } finally {
      try {
        await rec.dispose().timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  }
}
