import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cb_funk/platform/win_clipboard_image.dart';
import 'package:cb_funk/services/jpeg_encoder.dart';
import 'package:cb_funk/ui/sstv_image_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('JPG-Export', () {
    test('Huffman-Tabellen enthalten jedes AC-Symbol genau einmal', () {
      final expected = <int>{
        0x00,
        0xf0,
        for (var run = 0; run < 16; run++)
          for (var size = 1; size <= 10; size++) (run << 4) | size,
      };
      for (final values in [
        JpegEncoder.acLumaValues,
        JpegEncoder.acChromaValues,
      ]) {
        expect(values, hasLength(162));
        expect(values.toSet(), expected);
      }
    });

    for (final (width, height) in [(320, 256), (320, 240), (37, 21)]) {
      test('${width}x$height lässt sich wieder dekodieren', () async {
        final rgba = _pattern(width, height);
        final jpeg = JpegEncoder.encode(rgba, width, height);
        expect(jpeg.sublist(0, 2), [0xff, 0xd8]);
        expect(jpeg.sublist(jpeg.length - 2), [0xff, 0xd9]);

        final (w, h, decoded) = await decodeSstvPng(jpeg);
        expect(w, width);
        expect(h, height);
        var sum = 0.0;
        for (var i = 0; i < rgba.length; i++) {
          if (i % 4 == 3) continue;
          sum += (decoded[i] - rgba[i]).abs();
        }
        // Qualitaet 92: kaum sichtbare Abweichung
        expect(sum / (width * height * 3), lessThan(6));
      });
    }
  });

  test('Zwischenablage-DIB: 24 Bit, Zeilen von unten, BGR', () {
    // 2x2: oben rot, gruen; unten blau, weiss
    final rgba = Uint8List.fromList([
      255, 0, 0, 255, 0, 255, 0, 255, //
      0, 0, 255, 255, 255, 255, 255, 255,
    ]);
    final dib = buildDib24(rgba, 2, 2);
    final header = ByteData.sublistView(dib);
    expect(header.getUint32(0, Endian.little), 40);
    expect(header.getInt32(4, Endian.little), 2);
    expect(header.getInt32(8, Endian.little), 2);
    expect(header.getUint16(14, Endian.little), 24);
    const stride = 8; // 2 * 3 Byte, auf 4 aufgerundet
    expect(dib, hasLength(40 + stride * 2));
    // Erste gespeicherte Zeile = untere Bildzeile (blau, weiss)
    expect(dib.sublist(40, 46), [255, 0, 0, 255, 255, 255]);
    // Zweite = obere Zeile (rot, gruen) in BGR
    expect(dib.sublist(48, 54), [0, 0, 255, 0, 255, 0]);
  });

  test('Dateinamen werden für Windows bereinigt', () {
    expect(sstvSafeFileName(' Mein:Bild?.png '), 'Mein_Bild_');
    expect(sstvSafeFileName('Foto.JPG'), 'Foto');
    expect(sstvSafeFileName('a/b\\c'), 'a_b_c');
    expect(
      sstvSuggestedBaseName(null, now: DateTime(2026, 11, 27, 14, 5, 9)),
      'sstv_2026-11-27_14-05-09',
    );
    expect(sstvSuggestedBaseName('sstv_xyz_rx'), 'sstv_xyz_rx');
  });

  test('Speichern als PNG (unverändert) und JPG', () async {
    final png = await _png(_pattern(320, 256), 320, 256);
    final folder = await Directory.systemTemp.createTemp('cbfunk_sstv_');
    try {
      final pngFile = File('${folder.path}${Platform.pathSeparator}a.png');
      await writeSstvImageFile(png, pngFile, jpeg: false);
      expect(await pngFile.readAsBytes(), png);

      final jpgFile = File('${folder.path}${Platform.pathSeparator}a.jpg');
      await writeSstvImageFile(png, jpgFile, jpeg: true);
      final (w, h, _) = await decodeSstvPng(await jpgFile.readAsBytes());
      expect((w, h), (320, 256));
    } finally {
      await folder.delete(recursive: true);
    }
  });

  group('Bedienung im SSTV-Fenster', () {
    late Uint8List png;

    setUpAll(() async {
      png = await _png(_pattern(32, 24), 32, 24);
    });

    Widget app() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            height: 120,
            child: SstvImageActions(
              title: 'Empfangen · Test',
              loadPng: () async => png,
              child: const ColoredBox(color: Colors.teal),
            ),
          ),
        ),
      ),
    );

    testWidgets('Klick vergrößert das Bild', (tester) async {
      await tester.pumpWidget(app());
      await tester.tap(find.byType(ColoredBox).first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Empfangen · Test'), findsOneWidget);
      expect(find.text('Kopieren'), findsOneWidget);
      expect(find.text('Speichern unter …'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('Doppelklick vergrößert das Bild', (tester) async {
      await tester.pumpWidget(app());
      final target = find.byType(ColoredBox).first;
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('Rechtsklick zeigt Vergrößern, Kopieren, Speichern', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.tap(
        find.byType(ColoredBox).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Vergrößern'), findsOneWidget);
      expect(find.text('Bild kopieren'), findsOneWidget);
      expect(find.text('Speichern unter …'), findsOneWidget);

      await tester.tap(find.text('Vergrößern'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });
  });
}

Uint8List _pattern(int width, int height) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      pixels[o] = x * 255 ~/ (width - 1);
      pixels[o + 1] = y * 255 ~/ (height - 1);
      pixels[o + 2] = ((x ~/ 8 + y ~/ 8) % 2) * 200 + 20;
      pixels[o + 3] = 255;
    }
  }
  return pixels;
}

Future<Uint8List> _png(Uint8List rgba, int width, int height) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
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
