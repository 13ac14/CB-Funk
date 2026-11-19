// Windows: serielle PTT-Leitung (RTS/DTR) und USB-HID (CM108/AIOC) per Win32-FFI.
// Wird nur auf Windows aufgerufen.
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

typedef _CreateFileC = IntPtr Function(
    Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr);
typedef _CreateFileD = int Function(
    Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);

class _K32 {
  _K32._();
  static final DynamicLibrary _lib = DynamicLibrary.open('kernel32.dll');
  static final _CreateFileD createFile =
      _lib.lookupFunction<_CreateFileC, _CreateFileD>('CreateFileW');
  static final int Function(int) closeHandle =
      _lib.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  static final int Function(int, int) escape = _lib.lookupFunction<
      Int32 Function(IntPtr, Uint32), int Function(int, int)>('EscapeCommFunction');
  static final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)
      writeFile = _lib.lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
          int Function(int, Pointer<Uint8>, int, Pointer<Uint32>,
              Pointer<Void>)>('WriteFile');
  static final int Function() getLastError =
      _lib.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
}

int _openFile(String path, int access, int share) {
  final p = path.toNativeUtf16();
  final h = _K32.createFile(p, access, share, nullptr, 3, 0, 0);
  calloc.free(p);
  return h;
}

/// Requests a graceful close of the foreground CB-Funk window.
/// Call only from the Windows desktop UI while this app owns foreground focus.
void winRequestCloseApp() {
  final user32 = DynamicLibrary.open('user32.dll');
  final getForegroundWindow = user32.lookupFunction<
      IntPtr Function(), int Function()>('GetForegroundWindow');
  final postMessage = user32.lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)>('PostMessageW');
  final hwnd = getForegroundWindow();
  if (hwnd != 0) {
    postMessage(hwnd, 0x0010, 0, 0); // WM_CLOSE
  }
}

// ---------------- Seriell ----------------

/// Vorhandene COM-Ports laut Windows (HKLM\HARDWARE\DEVICEMAP\SERIALCOMM).
/// Die Ports werden dabei NICHT geoeffnet: Das Probe-Oeffnen von COM1..COM64
/// hing bei Bluetooth-COM-Ports sekundenlang (Oberflaeche und Ton standen)
/// und stoerte Ports, die gerade ein anderes Programm nutzt.
List<String> winListComPorts() {
  try {
    final fromRegistry = _comPortsFromRegistry();
    if (fromRegistry != null) return fromRegistry;
  } catch (_) {}
  return _comPortsByProbing();
}

List<String>? _comPortsFromRegistry() {
  final adv = DynamicLibrary.open('advapi32.dll');
  final regOpenKeyEx = adv.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
      int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW');
  final regEnumValue = adv.lookupFunction<
      Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
      int Function(int, int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)>('RegEnumValueW');
  final regCloseKey =
      adv.lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

  const hkeyLocalMachine = -2147483646; // (HKEY)0x80000002, vorzeichenerweitert
  const keyRead = 0x20019;
  const regSz = 1;
  const nameChars = 256;
  const dataBytes = 512;

  final subKey = r'HARDWARE\DEVICEMAP\SERIALCOMM'.toNativeUtf16();
  final hKey = calloc<IntPtr>();
  final name = calloc<Uint16>(nameChars).cast<Utf16>();
  final nameLen = calloc<Uint32>();
  final type = calloc<Uint32>();
  final data = calloc<Uint8>(dataBytes);
  final dataLen = calloc<Uint32>();
  try {
    final rc = regOpenKeyEx(hkeyLocalMachine, subKey, 0, keyRead, hKey);
    if (rc == 2) return <String>[]; // Schluessel fehlt = keine COM-Ports
    if (rc != 0) return null;
    final ports = <String>{};
    try {
      for (var i = 0; i < 256; i++) {
        nameLen.value = nameChars;
        dataLen.value = dataBytes - 2;
        final r = regEnumValue(hKey.value, i, name, nameLen, nullptr, type, data, dataLen);
        if (r == 259) break; // ERROR_NO_MORE_ITEMS
        if (r != 0 || type.value != regSz) continue;
        final chars = dataLen.value ~/ 2;
        final port = String.fromCharCodes(
          data.cast<Uint16>().asTypedList(chars).takeWhile((c) => c != 0),
        ).trim();
        if (port.isNotEmpty) ports.add(port);
      }
    } finally {
      regCloseKey(hKey.value);
    }
    final list = ports.toList()..sort(_comCompare);
    return list;
  } finally {
    calloc.free(subKey);
    calloc.free(hKey);
    calloc.free(name);
    calloc.free(nameLen);
    calloc.free(type);
    calloc.free(data);
    calloc.free(dataLen);
  }
}

int _comCompare(String a, String b) {
  final na = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), ''));
  final nb = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), ''));
  if (na != null && nb != null && na != nb) return na.compareTo(nb);
  return a.compareTo(b);
}

/// Notloesung, falls die Registry nicht lesbar ist.
List<String> _comPortsByProbing() {
  final out = <String>[];
  for (var n = 1; n <= 64; n++) {
    final h = _openFile('\\\\.\\COM$n', 0xC0000000, 0);
    if (h != -1) {
      _K32.closeHandle(h);
      out.add('COM$n');
    } else if (_K32.getLastError() == 5) {
      out.add('COM$n'); // belegt, aber vorhanden
    }
  }
  return out;
}

class WinSerialLine {
  WinSerialLine(this.port, this.useDtr);
  final String port;
  final bool useDtr;
  int _h = -1;

  void open() {
    _h = _openFile('\\\\.\\$port', 0xC0000000, 0);
    if (_h == -1) throw 'Port $port konnte nicht geöffnet werden';
    set(false);
  }

  void set(bool on) {
    if (_h == -1) return;
    // SETRTS=3 CLRRTS=4 SETDTR=5 CLRDTR=6
    final code = useDtr ? (on ? 5 : 6) : (on ? 3 : 4);
    _K32.escape(_h, code);
  }

  void close() {
    if (_h != -1) {
      set(false);
      _K32.closeHandle(_h);
      _h = -1;
    }
  }
}

// ---------------- USB-HID (CM108 / AIOC) ----------------

class WinHidInfo {
  WinHidInfo(this.vid, this.pid, this.path);
  final int vid;
  final int pid;
  final String path;
}

List<WinHidInfo> winEnumerateHid() {
  final result = <WinHidInfo>[];
  final hid = DynamicLibrary.open('hid.dll');
  final setup = DynamicLibrary.open('setupapi.dll');

  final getGuid = hid.lookupFunction<Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)>('HidD_GetHidGuid');
  final getAttr = hid.lookupFunction<Uint8 Function(IntPtr, Pointer<Uint8>),
      int Function(int, Pointer<Uint8>)>('HidD_GetAttributes');
  final getClassDevs = setup.lookupFunction<
      IntPtr Function(Pointer<Uint8>, Pointer<Utf16>, IntPtr, Uint32),
      int Function(Pointer<Uint8>, Pointer<Utf16>, int, int)>('SetupDiGetClassDevsW');
  final enumIf = setup.lookupFunction<
      Int32 Function(IntPtr, Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint8>),
      int Function(int, Pointer<Void>, Pointer<Uint8>, int,
          Pointer<Uint8>)>('SetupDiEnumDeviceInterfaces');
  final getDetail = setup.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Pointer<Uint8>, Uint32, Pointer<Uint32>,
          Pointer<Void>),
      int Function(int, Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint32>,
          Pointer<Void>)>('SetupDiGetDeviceInterfaceDetailW');
  final destroy = setup.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetupDiDestroyDeviceInfoList');

  final guid = calloc<Uint8>(16);
  getGuid(guid);
  // DIGCF_PRESENT | DIGCF_DEVICEINTERFACE
  final devs = getClassDevs(guid, nullptr, 0, 0x12);
  if (devs == -1) {
    calloc.free(guid);
    return result;
  }

  final is64 = sizeOf<IntPtr>() == 8;
  final ifData = calloc<Uint8>(32);
  final req = calloc<Uint32>();
  final attr = calloc<Uint8>(12);
  try {
    for (var i = 0; i < 128; i++) {
      ifData.cast<Uint32>().value = is64 ? 32 : 28;
      if (enumIf(devs, nullptr, guid, i, ifData) == 0) break;
      req.value = 0;
      getDetail(devs, ifData, nullptr, 0, req, nullptr);
      final size = req.value;
      if (size < 8) continue;
      final detail = calloc<Uint8>(size);
      detail.cast<Uint32>().value = is64 ? 8 : 6;
      final ok = getDetail(devs, ifData, detail, size, nullptr, nullptr);
      if (ok != 0) {
        final path = Pointer<Utf16>.fromAddress(detail.address + 4).toDartString();
        final h = _openFile(path, 0, 3);
        if (h != -1) {
          attr.cast<Uint32>().value = 12;
          if (getAttr(h, attr) != 0) {
            final bd = ByteData.sublistView(attr.asTypedList(12));
            result.add(WinHidInfo(
                bd.getUint16(4, Endian.little), bd.getUint16(6, Endian.little), path));
          }
          _K32.closeHandle(h);
        }
      }
      calloc.free(detail);
    }
  } finally {
    destroy(devs);
    calloc.free(guid);
    calloc.free(ifData);
    calloc.free(req);
    calloc.free(attr);
  }
  return result;
}

/// CM108-kompatibles HID-GPIO als PTT (Report: [0, 0, Zustand, Maske, 0])
class WinHidLine {
  WinHidLine(this.vid, this.pid, this.gpio);
  final int vid; // 0 = automatisch (CM108 / AIOC)
  final int pid;
  final int gpio; // 1..4
  int _h = -1;

  void open() {
    final devs = winEnumerateHid().where((d) {
      if (vid != 0) return d.vid == vid && d.pid == pid;
      return d.vid == 0x0D8C || (d.vid == 0x1209 && d.pid == 0x7388);
    }).toList();
    if (devs.isEmpty) throw 'Kein passendes USB-HID-Gerät gefunden';
    for (final d in devs) {
      final h = _openFile(d.path, 0xC0000000, 3);
      if (h != -1) {
        _h = h;
        break;
      }
    }
    if (_h == -1) throw 'USB-HID-Gerät konnte nicht geöffnet werden';
    set(false);
  }

  void set(bool on) {
    if (_h == -1) return;
    final mask = 1 << (gpio - 1);
    final buf = calloc<Uint8>(5);
    buf[0] = 0; // Report-ID
    buf[1] = 0;
    buf[2] = on ? mask : 0; // Ausgangszustand
    buf[3] = mask; // Richtung = Ausgang
    buf[4] = 0;
    final wrote = calloc<Uint32>();
    var ok = _K32.writeFile(_h, buf, 5, wrote, nullptr) != 0;
    if (!ok) {
      final hid = DynamicLibrary.open('hid.dll');
      final setOut = hid.lookupFunction<
          Uint8 Function(IntPtr, Pointer<Uint8>, Uint32),
          int Function(int, Pointer<Uint8>, int)>('HidD_SetOutputReport');
      ok = setOut(_h, buf, 5) != 0;
    }
    calloc.free(buf);
    calloc.free(wrote);
    if (!ok) throw 'PTT über USB-HID fehlgeschlagen';
  }

  void close() {
    if (_h != -1) {
      try {
        set(false);
      } catch (_) {}
      _K32.closeHandle(_h);
      _h = -1;
    }
  }
}
