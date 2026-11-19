import 'dart:io';
import '../models/enums.dart';
import 'android_native.dart';
import 'win_native.dart';

/// Schaltet die Sendetaste (PTT) des angeschlossenen Funkgeraets.
abstract class PttDriver {
  String get label;
  Future<void> open();
  Future<void> setPtt(bool on);
  Future<void> close();
}

class PttDriverFactory {
  /// null = kein PTT-Treiber noetig (VOX am Funkgeraet / VOX-Box / Bluetooth)
  static PttDriver? create({
    required GatewayMode mode,
    required String serialPort,
    required bool useDtr,
    required String hidKey,
    required int hidGpio,
  }) {
    switch (mode) {
      case GatewayMode.none:
      case GatewayMode.voxRadio:
      case GatewayMode.voxBox:
      case GatewayMode.bluetooth:
        return null;
      case GatewayMode.usbSerial:
        return SerialPttDriver(serialPort, useDtr);
      case GatewayMode.usbCard:
      case GatewayMode.aioc:
        return HidPttDriver(hidKey, hidGpio);
    }
  }
}

class SerialPttDriver implements PttDriver {
  SerialPttDriver(this.portKey, this.useDtr);
  final String portKey;
  final bool useDtr;
  WinSerialLine? _win;
  AndroidSerialLine? _android;

  @override
  String get label => 'Seriell ${useDtr ? 'DTR' : 'RTS'}';

  @override
  Future<void> open() async {
    if (Platform.isWindows) {
      if (portKey.isEmpty) throw 'Kein COM-Port gewählt';
      _win = WinSerialLine(portKey, useDtr)..open();
    } else if (Platform.isAndroid) {
      _android = AndroidSerialLine(portKey, useDtr);
      await _android!.open();
    } else {
      throw 'Serielle PTT wird auf dieser Plattform nicht unterstützt';
    }
  }

  @override
  Future<void> setPtt(bool on) async {
    _win?.set(on);
    await _android?.set(on);
  }

  @override
  Future<void> close() async {
    _win?.close();
    await _android?.close();
    _win = null;
    _android = null;
  }
}

/// CM108-kompatibles USB-HID-GPIO (Soundkarten mit CM108/CM119, AIOC-Kabel)
class HidPttDriver implements PttDriver {
  HidPttDriver(this.key, this.gpio);
  final String key; // "vvvv:pppp" oder leer = automatisch
  final int gpio;
  WinHidLine? _win;
  bool _androidOpen = false;

  @override
  String get label => 'USB-HID GPIO$gpio';

  (int, int) _parse() {
    if (key.isEmpty) return (0, 0);
    final p = key.split(':');
    return (int.parse(p[0], radix: 16), int.parse(p[1], radix: 16));
  }

  @override
  Future<void> open() async {
    final (vid, pid) = _parse();
    if (Platform.isWindows) {
      _win = WinHidLine(vid, pid, gpio)..open();
    } else if (Platform.isAndroid) {
      final ok = await AndroidHid.open(vid, pid);
      if (!ok) throw 'USB-Gerät nicht geöffnet (Berechtigung verweigert?)';
      _androidOpen = true;
      await AndroidHid.setGpio(gpio, false);
    } else {
      throw 'USB-HID-PTT wird auf dieser Plattform nicht unterstützt';
    }
  }

  @override
  Future<void> setPtt(bool on) async {
    _win?.set(on);
    if (_androidOpen) {
      final ok = await AndroidHid.setGpio(gpio, on);
      if (!ok) throw 'PTT über USB-HID fehlgeschlagen';
    }
  }

  @override
  Future<void> close() async {
    _win?.close();
    _win = null;
    if (_androidOpen) {
      try {
        await AndroidHid.setGpio(gpio, false);
      } catch (_) {}
      await AndroidHid.close();
      _androidOpen = false;
    }
  }
}
