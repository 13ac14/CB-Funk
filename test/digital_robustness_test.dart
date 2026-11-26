import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:cb_funk/audio/audio_engine.dart';
import 'package:cb_funk/audio/audio_packet.dart';
import 'package:cb_funk/config/app_config.dart';
import 'package:cb_funk/services/sstv_modem.dart';
import 'package:cb_funk/services/sstv_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Sequenzlücken werden erkannt, Duplikate und Nachzügler verworfen', () {
    expect(SstvService.missingPackets(5, 6), 0);
    expect(SstvService.missingPackets(5, 8), 2);
    expect(SstvService.missingPackets(65535, 0), 0);
    expect(SstvService.missingPackets(65534, 1), 2);
    expect(SstvService.missingPackets(6, 6), -1);
    expect(SstvService.missingPackets(7, 6), -1);
  });

  for (final mode in SstvMode.values) {
    test(
      'SSTV ${mode.label}: verlorene Netzpakete brechen das Bild nicht ab',
      () async {
        final png = await _solidPng(height: SstvModem.imageHeight(mode));
        final chunks = await SstvModem.encodeImage(png, mode).toList();
        // Zwei Pakete gehen unterwegs verloren (QoS 0)
        final lost = <int>{chunks.length ~/ 3, chunks.length * 2 ~/ 3};
        final samples = _receiveWithGapFill(chunks, lost);

        final decoded = SstvModem.decode(samples, mode);
        final lossless = SstvModem.decode(
          Int16List.fromList(chunks.expand((chunk) => chunk).toList()),
          mode,
        );
        expect(lossless, isNotNull);
        expect(decoded, isNotNull);
        // Zeilen abseits der Luecken entsprechen der verlustfreien Dekodierung
        final height = SstvModem.imageHeight(mode);
        for (final row in <int>[5, height ~/ 2, height - 5]) {
          for (final x in <int>[20, 160, 300]) {
            final offset = (row * 320 + x) * 4;
            for (var c = 0; c < 3; c++) {
              expect(
                (decoded!.rgba[offset + c] - lossless!.rgba[offset + c]).abs(),
                lessThanOrEqualTo(12),
                reason: 'Zeile $row, x=$x, Kanal $c',
              );
            }
          }
        }

        // Zeilenweise Vorschau kommt ebenfalls bis zum Ende durch
        final rgba = Uint8List(320 * height * 4);
        for (var line = 0; line < height; line++) {
          expect(
            SstvModem.decodeLine(samples, mode, line, rgba),
            isTrue,
            reason: 'Zeile $line',
          );
        }
      },
    );
  }

  test('SSTV: Stille ergibt weiterhin kein Bild', () {
    const length = 7520 + 256 * 3567 + 8000;
    for (final mode in SstvMode.values) {
      expect(SstvModem.decode(Int16List(length), mode), isNull);
    }
  });

  group('Pegelschwelle für den digitalen Gateway-Eingang', () {
    const threshold = 0.35;
    const hang = 3;

    Float64List frame({int silentLead = 0, double amplitude = 12000}) {
      final f = Float64List(AppConfig.frameSamples);
      for (var i = silentLead; i < f.length; i++) {
        f[i] =
            math.sin(2 * math.pi * 1900 * (i - silentLead) / 8000) * amplitude;
      }
      return f;
    }

    double level(Float64List f) {
      var sum = 0.0;
      for (final x in f) {
        sum += x * x;
      }
      return (math.sqrt(sum / f.length) / 32768.0 / 0.2).clamp(0.0, 1.0);
    }

    List<Float64List> feed(DigitalInputGate gate, Float64List f) =>
        gate.process(f, level(f), threshold: threshold, hangFrames: hang);

    test('Stille und leises Rauschen werden nicht weitergegeben', () {
      final gate = DigitalInputGate();
      for (var i = 0; i < 50; i++) {
        expect(feed(gate, Float64List(AppConfig.frameSamples)), isEmpty);
        expect(feed(gate, frame(amplitude: 800)), isEmpty);
      }
      expect(gate.isOpen, isFalse);
    });

    test('Signal öffnet ab dem Signalbeginn und schließt nach dem Nachlauf', () {
      final gate = DigitalInputGate();
      expect(feed(gate, Float64List(AppConfig.frameSamples)), isEmpty);
      // Signal beginnt mitten im Frame
      expect(feed(gate, frame(silentLead: 60)), isEmpty);
      final opened = feed(gate, frame());
      expect(gate.isOpen, isTrue);
      expect(opened, hasLength(2));
      // Rauschanteil vor dem Signal ist abgeschnitten (±1 Sample am Nulldurchgang)
      expect(
        opened.first.length,
        inInclusiveRange(
          AppConfig.frameSamples - 62,
          AppConfig.frameSamples - 60,
        ),
      );
      expect(opened.last.length, AppConfig.frameSamples);

      expect(feed(gate, frame()), hasLength(1));
      // Nachlauf: noch [hang] Frames, dann geschlossen
      for (var i = 0; i < hang; i++) {
        expect(feed(gate, Float64List(AppConfig.frameSamples)), hasLength(1));
      }
      expect(gate.isOpen, isFalse);
      expect(feed(gate, Float64List(AppConfig.frameSamples)), isEmpty);
    });

    test('Einzelner Störimpuls öffnet den Eingang nicht', () {
      final gate = DigitalInputGate();
      expect(feed(gate, frame()), isEmpty);
      expect(feed(gate, Float64List(AppConfig.frameSamples)), isEmpty);
      expect(gate.isOpen, isFalse);
    });
  });
}

/// Simuliert den Netzempfang: Pakete mit Sequenznummer, einige gehen
/// verloren, Lücken werden wie im SstvService mit Stille gefüllt.
Int16List _receiveWithGapFill(List<Int16List> chunks, Set<int> lost) {
  final samples = <int>[];
  int? previous;
  for (var index = 0; index < chunks.length; index++) {
    if (lost.contains(index)) continue;
    final packet = AudioPacket.parse(
      AudioPacket(
        sender: 123,
        channel: 25,
        modulation: AudioPacket.sstvLinearPcmModulation,
        antennaDb: 0,
        seq: index & 0xffff,
        payload: AudioPacket.encodeLinearPcm(chunks[index]),
      ).toBytes(),
    )!;
    if (previous != null) {
      final missing = SstvService.missingPackets(previous, packet.seq);
      if (missing < 0) continue;
      samples.addAll(Int16List(missing * AppConfig.frameSamples));
    }
    previous = packet.seq;
    samples.addAll(AudioPacket.decodeLinearPcm(packet.payload)!);
  }
  return Int16List.fromList(samples);
}

Future<Uint8List> _solidPng({required int height}) async {
  const width = 320;
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 220;
    pixels[i + 1] = 90;
    pixels[i + 2] = 40;
    pixels[i + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
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
