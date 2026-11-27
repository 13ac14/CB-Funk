// Windows: Bild in die Zwischenablage kopieren (Win32 per FFI).
// Flutters Clipboard kann nur Text. Abgelegt werden zwei Formate:
//  - CF_DIB (24 Bit): versteht praktisch jedes Programm (Paint, Word, ...)
//  - "PNG": verlustfrei fuer Browser, Office, Bildbearbeitung
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class _User32 {
  _User32._();
  static final DynamicLibrary _lib = DynamicLibrary.open('user32.dll');
  static final int Function(int) openClipboard = _lib
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'OpenClipboard',
      );
  static final int Function() emptyClipboard = _lib
      .lookupFunction<Int32 Function(), int Function()>('EmptyClipboard');
  static final int Function() closeClipboard = _lib
      .lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
  static final int Function(int, int) setClipboardData = _lib
      .lookupFunction<IntPtr Function(Uint32, IntPtr), int Function(int, int)>(
        'SetClipboardData',
      );
  static final int Function(Pointer<Utf16>) registerClipboardFormat = _lib
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('RegisterClipboardFormatW');
  static final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
  findWindowEx = _lib
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  static final int Function(int, Pointer<Uint32>) getWindowThreadProcessId =
      _lib.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
}

class _Kernel32 {
  _Kernel32._();
  static final DynamicLibrary _lib = DynamicLibrary.open('kernel32.dll');
  static final int Function(int, int) globalAlloc = _lib
      .lookupFunction<IntPtr Function(Uint32, IntPtr), int Function(int, int)>(
        'GlobalAlloc',
      );
  static final Pointer<Void> Function(int) globalLock = _lib
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('GlobalLock');
  static final int Function(int) globalUnlock = _lib
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'GlobalUnlock',
      );
  static final int Function(int) globalFree = _lib
      .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GlobalFree');
}

const int _cfDib = 8;
const int _gmemMoveable = 0x0002;

/// 24-Bit-DIB (BITMAPINFOHEADER + Zeilen von unten nach oben, BGR) aus
/// RGBA-Pixeln. Oeffentlich fuer Tests.
Uint8List buildDib24(Uint8List rgba, int width, int height) {
  final stride = (width * 3 + 3) & ~3;
  final out = Uint8List(40 + stride * height);
  final header = ByteData.sublistView(out, 0, 40)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, width, Endian.little)
    ..setInt32(8, height, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 24, Endian.little)
    ..setUint32(16, 0, Endian.little)
    ..setUint32(20, stride * height, Endian.little)
    ..setInt32(24, 2835, Endian.little)
    ..setInt32(28, 2835, Endian.little);
  assert(header.lengthInBytes == 40);
  for (var y = 0; y < height; y++) {
    final row = 40 + (height - 1 - y) * stride;
    for (var x = 0; x < width; x++) {
      final source = (y * width + x) * 4;
      final target = row + x * 3;
      out[target] = rgba[source + 2];
      out[target + 1] = rgba[source + 1];
      out[target + 2] = rgba[source];
    }
  }
  return out;
}

int _ownWindow() {
  final className = 'CBFUNK_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final processId = calloc<Uint32>();
  try {
    var window = 0;
    while (true) {
      window = _User32.findWindowEx(0, window, className, nullptr);
      if (window == 0) return 0;
      _User32.getWindowThreadProcessId(window, processId);
      if (processId.value == pid) return window;
    }
  } finally {
    calloc.free(className);
    calloc.free(processId);
  }
}

int _globalCopy(Uint8List bytes) {
  final handle = _Kernel32.globalAlloc(_gmemMoveable, bytes.length);
  if (handle == 0) throw StateError('Kein Speicher für die Zwischenablage');
  final pointer = _Kernel32.globalLock(handle);
  if (pointer == nullptr) {
    _Kernel32.globalFree(handle);
    throw StateError('Zwischenablage-Speicher nicht verfügbar');
  }
  pointer.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
  _Kernel32.globalUnlock(handle);
  return handle;
}

/// Kopiert ein Bild in die Windows-Zwischenablage.
Future<void> copyImageToWindowsClipboard({
  required Uint8List rgba,
  required int width,
  required int height,
  required Uint8List png,
}) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Bild kopieren gibt es nur unter Windows');
  }
  final owner = _ownWindow();
  // Ein anderes Programm kann die Zwischenablage kurz belegen
  var opened = false;
  for (var attempt = 0; attempt < 10 && !opened; attempt++) {
    opened = _User32.openClipboard(owner) != 0;
    if (!opened) await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  if (!opened) {
    throw StateError(
      'Zwischenablage ist gerade von einem anderen Programm belegt',
    );
  }
  try {
    _User32.emptyClipboard();
    final dib = _globalCopy(buildDib24(rgba, width, height));
    if (_User32.setClipboardData(_cfDib, dib) == 0) {
      _Kernel32.globalFree(dib);
      throw StateError('Bild konnte nicht in die Zwischenablage gelegt werden');
    }
    final formatName = 'PNG'.toNativeUtf16();
    try {
      final pngFormat = _User32.registerClipboardFormat(formatName);
      if (pngFormat != 0) {
        final data = _globalCopy(png);
        if (_User32.setClipboardData(pngFormat, data) == 0) {
          _Kernel32.globalFree(data);
        }
      }
    } finally {
      calloc.free(formatName);
    }
  } finally {
    _User32.closeClipboard();
  }
}
