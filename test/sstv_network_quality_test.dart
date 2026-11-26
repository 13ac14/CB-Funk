import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:cb_funk/audio/audio_packet.dart';
import 'package:cb_funk/services/sstv_modem.dart';

/// Bildqualitaet bei direkter Netzuebertragung zwischen zwei Rechnern:
/// Die PCM16-Samples kommen bitgenau an, das Bild muss daher (bis auf die
/// halbierte Farbaufloesung von Robot 36) unveraendert ankommen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in SstvMode.values) {
    // Robot 36 uebertraegt Farbe nur mit halber Aufloesung.
    final tolerance = mode == SstvMode.robot36 ? 3.0 : 0.5;

    group('SSTV ${mode.label} über das Netz', () {
      late Uint8List source;
      late List<int> received;

      setUpAll(() async {
        final height = SstvModem.imageHeight(mode);
        source = _testPattern(height);
        final chunks = await SstvModem.encodeImage(
          await _png(source, height),
          mode,
        ).toList();
        received = _overNetwork(chunks);
      });

      test('kommt ohne Randstreifen, Versatz und Unschärfe an', () {
        final decoded = SstvModem.decode(Int16List.fromList(received), mode);
        expect(decoded, isNotNull);
        expect(_meanError(decoded!.rgba, source), lessThan(tolerance));
        // Linker und rechter Rand einzeln (dort lagen die Streifen)
        expect(
          _meanError(decoded.rgba, source, fromX: 0, toX: 12),
          lessThan(tolerance * 2),
        );
        expect(
          _meanError(decoded.rgba, source, fromX: 308, toX: 320),
          lessThan(tolerance * 2),
        );
      });

      test('Vorlauf oder fehlender Anfang im Puffer wird ausgeglichen', () {
        final withLead = <int>[...List<int>.filled(1000, 0), ...received];
        final withoutStart = received.sublist(480);
        for (final samples in <List<int>>[withLead, withoutStart]) {
          final decoded = SstvModem.decode(Int16List.fromList(samples), mode);
          expect(decoded, isNotNull);
          expect(_meanError(decoded!.rgba, source), lessThan(tolerance));
        }
      });

      test('Live-Vorschau entspricht dem fertigen Bild', () {
        final height = SstvModem.imageHeight(mode);
        final preview = Uint8List(320 * height * 4);
        for (var line = 0; line < height; line++) {
          expect(
            SstvModem.decodeLine(received, mode, line, preview),
            isTrue,
            reason: 'Zeile $line',
          );
        }
        expect(_meanError(preview, source), lessThan(tolerance));
      });
    });
  }

  test('Gateway-Audio mit Taktabweichung nutzt weiter den toleranten '
      'Decoder ohne Fehler', () async {
    const height = 256;
    final chunks = await SstvModem.encodeImage(
      await _png(_testPattern(height), height),
      SstvMode.martin1,
    ).toList();
    final clean = chunks.expand((chunk) => chunk).toList();
    // 200 ppm Taktabweichung wie bei einer fremden Soundkarte
    final drifted = <int>[];
    for (var t = 0.0; t < clean.length - 1; t += 1.0002) {
      final i = t.floor();
      final f = t - i;
      drifted.add((clean[i] * (1 - f) + clean[i + 1] * f).round());
    }
    expect(
      () => SstvModem.decode(Int16List.fromList(drifted), SstvMode.martin1),
      returnsNormally,
    );
  });
}

/// Simuliert MQTT: PCM16LE-Pakete mit Header hin und zurueck.
List<int> _overNetwork(List<Int16List> chunks) {
  final samples = <int>[];
  var sequence = 0;
  for (final chunk in chunks) {
    final packet = AudioPacket.parse(
      AudioPacket(
        sender: 42,
        channel: 25,
        modulation: AudioPacket.sstvLinearPcmModulation,
        antennaDb: 0,
        seq: sequence++ & 0xffff,
        payload: AudioPacket.encodeLinearPcm(chunk),
      ).toBytes(),
    )!;
    samples.addAll(AudioPacket.decodeLinearPcm(packet.payload)!);
  }
  return samples;
}

double _meanError(Uint8List a, Uint8List b, {int fromX = 0, int toX = 320}) {
  var sum = 0.0;
  var count = 0;
  final height = a.length ~/ (320 * 4);
  for (var y = 0; y < height; y++) {
    for (var x = fromX; x < toX; x++) {
      for (var c = 0; c < 3; c++) {
        final i = (y * 320 + x) * 4 + c;
        sum += (a[i] - b[i]).abs();
        count++;
      }
    }
  }
  return sum / count;
}

/// Farbbalken, Verlauf, 1-Pixel-Streifen und Ringe (Schaerfe und Farbe).
Uint8List _testPattern(int height) {
  const bars = <List<int>>[
    [255, 255, 255],
    [255, 255, 0],
    [0, 255, 255],
    [0, 255, 0],
    [255, 0, 255],
    [255, 0, 0],
    [0, 0, 255],
    [0, 0, 0],
  ];
  final pixels = Uint8List(320 * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < 320; x++) {
      final o = (y * 320 + x) * 4;
      List<int> rgb;
      if (y < height ~/ 4) {
        rgb = bars[x * 8 ~/ 320];
      } else if (y < height ~/ 2) {
        final red = x * 255 ~/ 319;
        rgb = [red, 255 - red, (y * 3) % 256];
      } else if (y < height * 3 ~/ 4) {
        final v = ((x ~/ (1 + (y % 4))) % 2) * 255;
        rgb = [v, v, v];
      } else {
        final d = math.sqrt(
          math.pow(x - 160, 2) + math.pow(y - height * 7 / 8, 2),
        );
        rgb = [
          (128 + 127 * math.sin(d / 6)).round(),
          (128 + 127 * math.cos(d / 9)).round(),
          140,
        ];
      }
      pixels[o] = rgb[0];
      pixels[o + 1] = rgb[1];
      pixels[o + 2] = rgb[2];
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
