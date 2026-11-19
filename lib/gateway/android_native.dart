// Android: USB-Seriell (usb_serial) und USB-HID (eigener Kotlin-Code in
// android_native/MainActivity.kt, Kanal "de.cbfunk/ptt").
import 'package:flutter/services.dart';
import 'package:usb_serial/usb_serial.dart';
import 'device_info.dart';

class AndroidSerial {
  static Future<List<DeviceInfo>> list() async {
    final devs = await UsbSerial.listDevices();
    return [
      for (final d in devs)
        DeviceInfo('${hex4(d.vid)}:${hex4(d.pid)}',
            '${d.productName ?? 'USB-Seriell'} (${hex4(d.vid)}:${hex4(d.pid)})'),
    ];
  }
}

class AndroidSerialLine {
  AndroidSerialLine(this.key, this.useDtr);
  final String key; // "vvvv:pppp" oder leer = erstes Gerät
  final bool useDtr;
  UsbPort? _port;

  Future<void> open() async {
    final devs = await UsbSerial.listDevices();
    UsbDevice? dev;
    for (final d in devs) {
      if (key.isEmpty || '${hex4(d.vid)}:${hex4(d.pid)}' == key) {
        dev = d;
        break;
      }
    }
    if (dev == null) throw 'Kein USB-Seriell-Gerät gefunden';
    final port = await dev.create();
    if (port == null) throw 'Kein Treiber für das USB-Gerät verfügbar';
    final ok = await port.open();
    if (!ok) throw 'USB-Gerät konnte nicht geöffnet werden (Berechtigung?)';
    _port = port;
    await set(false);
  }

  Future<void> set(bool on) async {
    final p = _port;
    if (p == null) return;
    if (useDtr) {
      await p.setDTR(on);
    } else {
      await p.setRTS(on);
    }
  }

  Future<void> close() async {
    try {
      await set(false);
      await _port?.close();
    } catch (_) {}
    _port = null;
  }
}

class AndroidHid {
  static const MethodChannel _ch = MethodChannel('de.cbfunk/ptt');

  static Future<List<DeviceInfo>> list() async {
    final r = await _ch.invokeMethod<List<dynamic>>('listHid') ?? const [];
    return [
      for (final e in r)
        DeviceInfo('${hex4((e as Map)['vid'] as int)}:${hex4(e['pid'] as int)}',
            '${e['name']} (${hex4(e['vid'] as int)}:${hex4(e['pid'] as int)})'),
    ];
  }

  static Future<bool> open(int vid, int pid) async {
    try {
      return await _ch.invokeMethod<bool>('open', {'vid': vid, 'pid': pid}) ?? false;
    } on MissingPluginException {
      throw 'Android-USB-Code fehlt (android_native/MainActivity.kt nicht eingebaut)';
    } on PlatformException catch (e) {
      throw e.message ?? 'USB-Fehler';
    }
  }

  static Future<bool> setGpio(int gpio, bool on) async =>
      await _ch.invokeMethod<bool>('set', {'gpio': gpio, 'on': on}) ?? false;

  static Future<void> close() async {
    try {
      await _ch.invokeMethod<void>('close');
    } catch (_) {}
  }
}
