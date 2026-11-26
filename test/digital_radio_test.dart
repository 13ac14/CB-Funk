import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:cb_funk/audio/audio_packet.dart';
import 'package:cb_funk/data/cb_channels.dart';
import 'package:cb_funk/services/packet_radio_modem.dart';
import 'package:cb_funk/services/sstv_image_store.dart';
import 'package:cb_funk/services/sstv_modem.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SSTV und Packet Radio sind an die vorgesehenen Kanäle gebunden', () {
    expect(CbChannels.frequency(25), closeTo(27.245, 0.0001));
    expect(CbChannels.frequency(24), closeTo(27.235, 0.0001));
    expect(CbChannels.gatewayChannels, containsAll(<int>[24, 25]));
    expect(
      AudioPacket.sstvModulation,
      isNot(AudioPacket.packetRadioModulation),
    );
    expect(
      AudioPacket.digitalModulationForChannel(25),
      AudioPacket.sstvLinearPcmModulation,
    );
    expect(
      AudioPacket.digitalModulationForChannel(24),
      AudioPacket.packetRadioLinearPcmModulation,
    );
    expect(AudioPacket.isSstvModulation(AudioPacket.sstvModulation), isTrue);
    expect(
      AudioPacket.isPacketRadioModulation(AudioPacket.packetRadioModulation),
      isTrue,
    );
  });

  test('digitale MQTT-Audioframes transportieren PCM16 verlustfrei', () {
    final samples = Int16List.fromList(<int>[
      -32768,
      -12345,
      -1,
      0,
      1,
      12345,
      32767,
    ]);
    final packet = AudioPacket(
      sender: 123,
      channel: 25,
      modulation: AudioPacket.sstvLinearPcmModulation,
      antennaDb: 0,
      seq: 1,
      payload: AudioPacket.encodeLinearPcm(samples),
    );

    final decoded = AudioPacket.parse(packet.toBytes());
    expect(decoded, isNotNull);
    expect(decoded!.modulation, AudioPacket.sstvLinearPcmModulation);
    expect(
      AudioPacket.decodeLinearPcm(decoded.payload),
      orderedEquals(samples),
    );
  });

  test('AX.25 Bell-202-Audio lässt sich als Nachricht zurückdekodieren', () {
    final samples = PacketRadioModem.modulate(
      from: 'DO5VH',
      to: 'CQ',
      text: 'TEST 1200 BAUD',
    );

    final decoded = PacketRadioModem.decodePcm(samples);

    expect(decoded, isNotNull);
    expect(decoded!.from, 'DO5VH');
    expect(decoded.to, 'CQ');
    expect(decoded.text, 'TEST 1200 BAUD');
  });

  test(
    'Martin-1-Töne bauen Zeilen auf und Auto-Slant findet den Bildanfang',
    () async {
      final png = await _solidPng();
      final chunks = await SstvModem.encodeImage(
        png,
        SstvMode.martin1,
      ).toList();
      final samples = Int16List.fromList(
        chunks.expand((chunk) => chunk).toList(),
      );
      final (token, decoded) = await SstvModem.decodeInIsolate(
        samples,
        SstvMode.martin1,
        token: 25,
      );

      expect(token, 25);
      expect(decoded, isNotNull);
      expect(decoded!.width, 320);
      expect(decoded.height, 256);
      expect(decoded.rgba, hasLength(320 * 256 * 4));
    },
  );

  test(
    'Martin-1-Netzwerk-PCM decodiert Farben klar und ohne Körnung',
    () async {
      final png = await _gradientPng();
      final chunks = await SstvModem.encodeImage(
        png,
        SstvMode.martin1,
      ).toList();
      final samples = <int>[];
      var sequence = 0;
      for (final chunk in chunks) {
        final packet = AudioPacket(
          sender: 123,
          channel: 25,
          modulation: AudioPacket.sstvLinearPcmModulation,
          antennaDb: 0,
          seq: sequence++ & 0xffff,
          payload: AudioPacket.encodeLinearPcm(chunk),
        );
        final received = AudioPacket.parse(packet.toBytes());
        expect(received, isNotNull);
        samples.addAll(AudioPacket.decodeLinearPcm(received!.payload)!);
      }
      final decoded = SstvModem.decode(
        Int16List.fromList(samples),
        SstvMode.martin1,
      );

      expect(decoded, isNotNull);
      for (final x in <int>[24, 80, 160, 240, 300]) {
        final offset = (100 * 320 + x) * 4;
        final expectedRed = (x * 255 / 319).round();
        expect(
          (decoded!.rgba[offset] - expectedRed).abs(),
          lessThanOrEqualTo(24),
          reason: 'Rotwert an x=$x',
        );
        expect(
          (decoded.rgba[offset + 1] - (255 - expectedRed)).abs(),
          lessThanOrEqualTo(24),
          reason: 'Grünwert an x=$x',
        );
        expect(
          (decoded.rgba[offset + 2] - 100).abs(),
          lessThanOrEqualTo(24),
          reason: 'Blauwert an x=$x',
        );
      }
    },
  );

  test(
    'Scottie-1- und Robot-36-Töne lassen sich bildweise synchronisieren',
    () async {
      final png = await _solidPng();
      for (final mode in <SstvMode>[SstvMode.scottie1, SstvMode.robot36]) {
        final chunks = await SstvModem.encodeImage(png, mode).toList();
        final samples = Int16List.fromList(
          chunks.expand((chunk) => chunk).toList(),
        );
        final decoded = SstvModem.decode(samples, mode);

        expect(decoded, isNotNull, reason: mode.label);
        expect(decoded!.width, 320);
        expect(decoded.height, mode == SstvMode.robot36 ? 240 : 256);
      }
    },
  );

  test('SSTV-Isolate meldet fehlenden Sync als leeres Ergebnis', () async {
    final (token, decoded) = await SstvModem.decodeInIsolate(
      Int16List(SstvModem.sampleRate),
      SstvMode.martin1,
      token: 26,
    );

    expect(token, 26);
    expect(decoded, isNull);
  });

  test('SSTV-Bilder werden vor der Vorschau auf Sendegröße begrenzt', () async {
    final png = await _solidPng(width: 1600, height: 1200);
    final normalized = await SstvModem.normalizeImage(png, SstvMode.robot36);
    final codec = await ui.instantiateImageCodec(normalized);
    try {
      final frame = await codec.getNextFrame();
      try {
        expect(frame.image.width, 320);
        expect(frame.image.height, 240);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });

  test('SSTV-Speicher behält ausschließlich die letzten zwei Bilder', () async {
    final directory = await Directory.systemTemp.createTemp('cbfunk-sstv-');
    addTearDown(() => directory.delete(recursive: true));
    final store = SstvImageStore(localDirectory: directory);

    for (var i = 0; i < 3; i++) {
      await store.savePng(Uint8List.fromList(<int>[i]), sent: i.isEven);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }

    expect(await store.recent(), hasLength(2));
    expect(await directory.list().where((entity) => entity is File).length, 2);
  });
}

Future<Uint8List> _solidPng({int width = 320, int height = 256}) async {
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

Future<Uint8List> _gradientPng() async {
  const width = 320;
  const height = 256;
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      final red = (x * 255 / (width - 1)).round();
      pixels[offset] = red;
      pixels[offset + 1] = 255 - red;
      pixels[offset + 2] = y;
      pixels[offset + 3] = 255;
    }
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
