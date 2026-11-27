import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:cb_funk/services/sstv_modem.dart';
import 'package:cb_funk/services/sstv_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Einblendung zeigt Rufzeichen und Uhrzeit', () {
    expect(
      SstvOverlay.label(
        callSign: ' dk-alpha ',
        time: DateTime(2026, 11, 27, 14, 5),
      ),
      'DK-ALPHA · 14:05',
    );
    expect(
      SstvOverlay.label(callSign: '', time: DateTime(2026, 11, 27, 9, 7)),
      '09:07',
    );
  });

  for (final mode in SstvMode.values) {
    test('${mode.label}: Einblendung oben links, Motiv unverzerrt', () async {
      final height = SstvModem.imageHeight(mode);
      final source = _gradient(height);
      final stamped = await SstvOverlay.stamp(
        await _png(source, height),
        callSign: 'DK-ALPHA',
        time: DateTime(2026, 11, 27, 14, 5),
      );
      final (width, stampedHeight, pixels) = await _decode(stamped);
      expect(width, 320);
      expect(stampedHeight, height);

      // Ausserhalb des Balkens (untere Haelfte, rechter Rand) pixelgenau gleich
      for (var y = height ~/ 2; y < height; y += 7) {
        for (var x = 0; x < 320; x += 5) {
          final i = (y * 320 + x) * 4;
          for (var c = 0; c < 3; c++) {
            expect(pixels[i + c], source[i + c], reason: 'x=$x y=$y');
          }
        }
      }
      for (var y = 0; y < height; y += 5) {
        final i = (y * 320 + 318) * 4;
        expect(pixels[i], source[i], reason: 'rechter Rand y=$y');
      }

      // Im Balken oben links: abgedunkelt bzw. Schrift
      var changed = 0;
      for (var y = 6; y < 22; y++) {
        for (var x = 6; x < 60; x++) {
          final i = (y * 320 + x) * 4;
          if ((pixels[i] - source[i]).abs() > 40) changed++;
        }
      }
      expect(changed, greaterThan(16 * 54 ~/ 2));
    });
  }
}

Uint8List _gradient(int height) {
  final pixels = Uint8List(320 * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < 320; x++) {
      final o = (y * 320 + x) * 4;
      pixels[o] = 120 + (x * 135 ~/ 319);
      pixels[o + 1] = 200 - (y * 100 ~/ height);
      pixels[o + 2] = 160;
      pixels[o + 3] = 255;
    }
  }
  return pixels;
}

Future<Uint8List> _png(Uint8List rgba, int height) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    320,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<(int, int, Uint8List)> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (image.width, image.height, data!.buffer.asUint8List());
  image.dispose();
  codec.dispose();
  return result;
}
