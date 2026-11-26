import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

enum SstvMode {
  martin1('Martin 1', 44),
  scottie1('Scottie 1', 60),
  robot36('Robot 36', 8);

  const SstvMode(this.label, this.visCode);
  final String label;
  final int visCode;
}

class SstvDecodedFrame {
  const SstvDecodedFrame({
    required this.width,
    required this.height,
    required this.rgba,
    int? linesDecoded,
  }) : linesDecoded = linesDecoded ?? height;

  final int width;
  final int height;
  final Uint8List rgba;
  final int linesDecoded;
}

class SstvModem {
  SstvModem._();

  static const int sampleRate = 8000;
  static const int _width = 320;
  static const int _martinHeight = 256;
  static const int _robotHeight = 240;
  static final Map<int, double> _toneCoefficients = {
    for (var frequency = 1500; frequency <= 2300; frequency += 50)
      frequency: 2 * math.cos(2 * math.pi * frequency / sampleRate),
    1200: 2 * math.cos(2 * math.pi * 1200 / sampleRate),
    1300: 2 * math.cos(2 * math.pi * 1300 / sampleRate),
    1900: 2 * math.cos(2 * math.pi * 1900 / sampleRate),
    1100: 2 * math.cos(2 * math.pi * 1100 / sampleRate),
  };

  static Future<Uint8List> normalizeImage(
    Uint8List encodedImage,
    SstvMode mode,
  ) async {
    final height = imageHeight(mode);
    final codec = await ui.instantiateImageCodec(
      encodedImage,
      targetWidth: _width,
      targetHeight: height,
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        // Der Codec liefert das Bild bereits in SSTV-Groesse. Erneutes
        // Zeichnen mit FilterQuality.high wuerde es auch bei 1:1 weichzeichnen.
        if (image.width == _width && image.height == height) {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) {
            throw StateError(
              'Das verkleinerte Bild konnte nicht kodiert werden',
            );
          }
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        }
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawImageRect(
          image,
          ui.Rect.fromLTWH(
            0,
            0,
            image.width.toDouble(),
            image.height.toDouble(),
          ),
          ui.Rect.fromLTWH(0, 0, _width.toDouble(), height.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.high,
        );
        final picture = recorder.endRecording();
        try {
          final resized = await picture.toImage(_width, height);
          try {
            final data = await resized.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null) {
              throw StateError(
                'Das verkleinerte Bild konnte nicht kodiert werden',
              );
            }
            return data.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
          } finally {
            resized.dispose();
          }
        } finally {
          picture.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  static int imageHeight(SstvMode mode) =>
      mode == SstvMode.robot36 ? _robotHeight : _martinHeight;

  static Future<(int, SstvDecodedFrame?)> decodeInIsolate(
    Int16List samples,
    SstvMode mode, {
    required int token,
  }) async {
    final modeIndex = mode.index;
    final transferredPcm = TransferableTypedData.fromList(<Uint8List>[
      Uint8List.view(
        samples.buffer,
        samples.offsetInBytes,
        samples.lengthInBytes,
      ),
    ]);
    final result = await Isolate.run<List<Object?>?>(() {
      final bytes = transferredPcm.materialize().asUint8List();
      final pcm = Int16List.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 2,
      );
      final frame = decode(pcm, SstvMode.values[modeIndex], autoSlant: true);
      if (frame == null) return <Object?>[token, null];
      return <Object?>[
        token,
        frame.width,
        frame.height,
        frame.rgba,
        frame.linesDecoded,
      ];
    });
    if (result == null || result.isEmpty || result[0] != token) {
      return (token, null);
    }
    if (result.length == 2 && result[1] == null) return (token, null);
    if (result.length != 5) {
      throw StateError('Ungültiges SSTV-Isolate-Ergebnis');
    }
    return (
      result[0] as int,
      SstvDecodedFrame(
        width: result[1] as int,
        height: result[2] as int,
        rgba: result[3] as Uint8List,
        linesDecoded: result[4] as int,
      ),
    );
  }

  static Stream<Int16List> encodeImage(
    Uint8List encodedImage,
    SstvMode mode, {
    void Function(double progress)? onProgress,
  }) async* {
    final height = imageHeight(mode);
    final codec = await ui.instantiateImageCodec(
      encodedImage,
      targetWidth: _width,
      targetHeight: height,
    );
    late final ByteData pixels;
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        // Bereits in SSTV-Groesse: Pixel direkt uebernehmen statt erneut mit
        // FilterQuality.high (weichzeichnend auch bei 1:1) zu zeichnen.
        final direct = image.width == _width && image.height == height
            ? await image.toByteData(format: ui.ImageByteFormat.rawRgba)
            : null;
        if (direct != null) {
          pixels = direct;
        } else {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.drawImageRect(
            image,
            ui.Rect.fromLTWH(
              0,
              0,
              image.width.toDouble(),
              image.height.toDouble(),
            ),
            ui.Rect.fromLTWH(0, 0, _width.toDouble(), height.toDouble()),
            ui.Paint()..filterQuality = ui.FilterQuality.high,
          );
          final picture = recorder.endRecording();
          try {
            final resized = await picture.toImage(_width, height);
            try {
              pixels = (await resized.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
            } finally {
              resized.dispose();
            }
          } finally {
            picture.dispose();
          }
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }

    final writer = _PcmWriter();
    _writeHeader(writer, mode);
    for (final chunk in writer.takeReady()) {
      yield chunk;
    }

    for (var y = 0; y < height; y++) {
      _encodeLine(writer, mode, pixels, y, height);
      onProgress?.call((y + 1) / height);
      for (final chunk in writer.takeReady()) {
        yield chunk;
      }
      await Future<void>.delayed(Duration.zero);
    }
    final tail = writer.takeRemainder();
    if (tail.isNotEmpty) yield tail;
  }

  static void _writeHeader(_PcmWriter writer, SstvMode mode) {
    writer.tone(1900, 0.3);
    writer.tone(1200, 0.01);
    writer.tone(1900, 0.3);
    writer.tone(1200, 0.03);
    writer.tone(1100, 0.03);
    for (var bit = 0; bit < 8; bit++) {
      writer.tone((mode.visCode & (1 << bit)) == 0 ? 1100 : 1300, 0.03);
    }
    writer.tone(1200, 0.03);
  }

  static void _encodeLine(
    _PcmWriter writer,
    SstvMode mode,
    ByteData pixels,
    int y,
    int height,
  ) {
    switch (mode) {
      case SstvMode.martin1:
        _encodeMartinLine(writer, pixels, y, height);
      case SstvMode.scottie1:
        _encodeScottieLine(writer, pixels, y, height);
      case SstvMode.robot36:
        _encodeRobotLine(writer, pixels, y, height);
    }
  }

  static void _encodeMartinLine(
    _PcmWriter writer,
    ByteData pixels,
    int y,
    int height,
  ) {
    writer.tone(1200, 0.004862);
    writer.tone(1500, 0.000572);
    _writeComponent(writer, pixels, y, height, 1, 0.146432);
    writer.tone(1500, 0.000572);
    _writeComponent(writer, pixels, y, height, 2, 0.146432);
    writer.tone(1500, 0.000572);
    _writeComponent(writer, pixels, y, height, 0, 0.146432);
  }

  static void _encodeScottieLine(
    _PcmWriter writer,
    ByteData pixels,
    int y,
    int height,
  ) {
    _writeComponent(writer, pixels, y, height, 1, 0.13824);
    writer.tone(1500, 0.0015);
    _writeComponent(writer, pixels, y, height, 2, 0.13824);
    writer.tone(1200, 0.009);
    writer.tone(1500, 0.0015);
    _writeComponent(writer, pixels, y, height, 0, 0.13824);
  }

  static void _encodeRobotLine(
    _PcmWriter writer,
    ByteData pixels,
    int y,
    int height,
  ) {
    writer.tone(1200, 0.009);
    writer.tone(1500, 0.003);
    for (var x = 0; x < _width; x++) {
      final (luma, _, _) = _yuv(pixels, x, y, height);
      writer.tone(_pixelFrequency(luma), 0.088 / _width);
    }
    writer.tone(1500, 0.0045);
    for (var x = 0; x < _width ~/ 2; x++) {
      final (_, u, v) = _yuv(pixels, x * 2, y, height);
      writer.tone(_pixelFrequency(y.isEven ? u : v), 0.044 / (_width / 2));
    }
  }

  static void _writeComponent(
    _PcmWriter writer,
    ByteData pixels,
    int y,
    int height,
    int component,
    double duration,
  ) {
    for (var x = 0; x < _width; x++) {
      final value = pixels.getUint8((y * _width + x) * 4 + component);
      writer.tone(_pixelFrequency(value), duration / _width);
    }
  }

  static (int, int, int) _yuv(ByteData pixels, int x, int y, int height) {
    final offset = (math.min(height - 1, y) * _width + x) * 4;
    final red = pixels.getUint8(offset).toDouble();
    final green = pixels.getUint8(offset + 1).toDouble();
    final blue = pixels.getUint8(offset + 2).toDouble();
    final luma = 0.299 * red + 0.587 * green + 0.114 * blue;
    final u = 128 + (blue - luma) * 0.565;
    final v = 128 + (red - luma) * 0.713;
    return (
      luma.round().clamp(0, 255),
      u.round().clamp(0, 255),
      v.round().clamp(0, 255),
    );
  }

  static double _pixelFrequency(int value) => 1500 + value / 255 * 800;

  static SstvDecodedFrame? decodeMartin1(
    Int16List samples, {
    bool autoSlant = true,
  }) => decode(samples, SstvMode.martin1, autoSlant: autoSlant);

  static SstvDecodedFrame? decode(
    Int16List samples,
    SstvMode mode, {
    bool autoSlant = true,
  }) {
    // Netzempfang: exakt nach dem Zeitraster des Senders. Passt das nicht
    // (z. B. Gateway-Audio vom Funkgeraet mit eigener Taktabweichung), greift
    // der bisherige, tolerante Decoder mit Sync-Suche je Zeile.
    return _decodeExact(samples, mode) ??
        _decodeFrame(samples, mode, autoSlant);
  }

  static int completeLineCount(int sampleCount, SstvMode mode) {
    const headerSamples = 7520;
    final lineSamples = switch (mode) {
      SstvMode.martin1 => 3567,
      SstvMode.scottie1 => 3414,
      SstvMode.robot36 => 1188,
    };
    return ((sampleCount - headerSamples) ~/ lineSamples)
        .clamp(0, imageHeight(mode))
        .toInt();
  }

  /// Mindestanteil der Zeilen mit erkanntem Sync, damit ein komplett
  /// empfangenes Signal als Bild gilt. Einzelne Zeilen ohne Sync (z. B. durch
  /// ein verlorenes Netzpaket) werden an ihrer Sollposition dekodiert, statt
  /// das ganze Bild zu verwerfen.
  static const double _minimumSyncedLineRatio = 0.5;

  /// Dekodiert eine Zeile. false nur, wenn die Zeile ungueltig ist oder noch
  /// nicht genug Samples vorliegen. Fehlt der Sync, wird die Zeile an ihrer
  /// Sollposition dekodiert (siehe [_decodeLine]).
  static bool decodeLine(
    List<int> samples,
    SstvMode mode,
    int line,
    Uint8List rgba, {
    bool autoSlant = true,
  }) {
    final height = imageHeight(mode);
    if (line < 0 || line >= height || rgba.length != _width * height * 4) {
      return false;
    }
    final exact = _decodeLineExact(samples, mode, line, rgba);
    if (exact != null) return exact;
    return _decodeLine(samples, mode, line, rgba, autoSlant: autoSlant) != null;
  }

  /// null = Zeile ungueltig/unvollstaendig, true = mit Sync dekodiert,
  /// false = ohne Sync an der Sollposition dekodiert.
  static bool? _decodeLine(
    List<int> samples,
    SstvMode mode,
    int line,
    Uint8List rgba, {
    required bool autoSlant,
  }) {
    final height = imageHeight(mode);
    if (line < 0 || line >= height || rgba.length != _width * height * 4) {
      return null;
    }
    var synced = true;
    int locate(int expected) {
      if (!autoSlant) return expected;
      final found = _findSync(samples, expected, 120);
      if (found >= 0) return found;
      synced = false;
      return expected;
    }

    late final Uint8List first;
    late final Uint8List second;
    late final Uint8List third;
    switch (mode) {
      case SstvMode.martin1:
        const syncLength = 39;
        const porch = 5;
        const componentSamples = 1171;
        final expected = 7520 + line * 3567;
        final sync = locate(expected);
        if (sync + syncLength + porch + componentSamples * 3 > samples.length) {
          return null;
        }
        var cursor = sync + syncLength + porch;
        first = _decodeComponent(samples, cursor, componentSamples / _width);
        cursor += componentSamples + porch;
        second = _decodeComponent(samples, cursor, componentSamples / _width);
        cursor += componentSamples + porch;
        third = _decodeComponent(samples, cursor, componentSamples / _width);
        _writeRgbLine(rgba, line, third, first, second);
      case SstvMode.scottie1:
        const componentSamples = 1106;
        const separator = 12;
        const syncLength = 72;
        const porch = 12;
        final expected = 7520 + line * 3414 + componentSamples * 2 + separator;
        final sync = locate(expected);
        final start = sync - componentSamples * 2 - separator;
        if (start < 0 ||
            sync + syncLength + porch + componentSamples > samples.length) {
          return null;
        }
        first = _decodeComponent(samples, start, componentSamples / _width);
        second = _decodeComponent(
          samples,
          start + componentSamples + separator,
          componentSamples / _width,
        );
        third = _decodeComponent(
          samples,
          sync + syncLength + porch,
          componentSamples / _width,
        );
        _writeRgbLine(rgba, line, third, first, second);
      case SstvMode.robot36:
        const syncLength = 72;
        const porch = 24;
        const lumaSamples = 704;
        const separator = 36;
        const chromaSamples = 352;
        final expected = 7520 + line * 1188;
        final sync = locate(expected);
        if (sync +
                syncLength +
                porch +
                lumaSamples +
                separator +
                chromaSamples >
            samples.length) {
          return null;
        }
        final luma = _decodeComponent(
          samples,
          sync + syncLength + porch,
          lumaSamples / _width,
          windowRadius: 3,
        );
        final chroma = _decodeComponent(
          samples,
          sync + syncLength + porch + lumaSamples + separator,
          chromaSamples / (_width / 2),
          outputWidth: _width ~/ 2,
          windowRadius: 3,
        );
        _writeYuvLine(rgba, line, luma, chroma);
    }
    return synced;
  }

  static void _writeRgbLine(
    Uint8List rgba,
    int line,
    Uint8List red,
    Uint8List green,
    Uint8List blue,
  ) {
    for (var x = 0; x < _width; x++) {
      final index = (line * _width + x) * 4;
      rgba[index] = red[x];
      rgba[index + 1] = green[x];
      rgba[index + 2] = blue[x];
      rgba[index + 3] = 255;
    }
  }

  static void _writeYuvLine(
    Uint8List rgba,
    int line,
    Uint8List luma,
    Uint8List chroma,
  ) {
    for (var x = 0; x < _width; x++) {
      final index = (line * _width + x) * 4;
      final y = luma[x].toDouble();
      final c = chroma[x ~/ 2] - 128;
      final u = line.isEven ? c.toDouble() : 0.0;
      final v = line.isOdd ? c.toDouble() : 0.0;
      rgba[index] = (y + 1.403 * v).round().clamp(0, 255);
      rgba[index + 1] = (y - 0.344 * u - 0.714 * v).round().clamp(0, 255);
      rgba[index + 2] = (y + 1.770 * u).round().clamp(0, 255);
      rgba[index + 3] = 255;
    }
  }

  // ---------------------------------------------------------------------------
  // Exakter Decoder fuer den Netzempfang
  //
  // Ueber MQTT kommen die PCM16-Samples bitgenau an. Der Empfaenger kennt
  // dasselbe Zeitraster wie der Sender (gleiche Rechnung in _PcmWriter) und
  // damit Anfang und Laenge jedes Pixeltons. Die Frequenz eines Tons wird nur
  // aus Samples innerhalb dieses Tons bestimmt: fuer einen phasenstetigen Sinus
  // gilt x[k-1] + x[k+1] = 2 cos(w) x[k], solange x[k-1] und x[k] zum selben
  // Ton gehoeren. So gibt es keine Unschaerfe ueber Pixelgrenzen und keinen
  // Zeilenversatz durch eine ungenaue Sync-Suche.
  // ---------------------------------------------------------------------------

  /// Erlaubte Abweichung eines Sync-Tons von 1200 Hz.
  static const double _syncToleranceHz = 60;

  /// Suchbereich, falls der Puffer nicht genau am Bildanfang beginnt (1 s).
  static const int _maximumExactOffset = sampleRate;

  /// Mindestanteil der Zeilen mit Sync am erwarteten Platz.
  static const double _minimumExactSyncRatio = 0.6;

  static final Map<SstvMode, _SstvLayout> _layouts = <SstvMode, _SstvLayout>{};

  static _SstvLayout _layoutFor(SstvMode mode) =>
      _layouts[mode] ??= _buildLayout(mode);

  static _SstvLayout _buildLayout(SstvMode mode) {
    final height = imageHeight(mode);
    final pixels = ByteData(_width * height * 4);
    final writer = _PcmWriter(recordOnly: true);
    _writeHeader(writer, mode);
    final headerTones = writer.toneStarts.length;
    for (var y = 0; y < height; y++) {
      _encodeLine(writer, mode, pixels, y, height);
    }
    final tonesPerLine = (writer.toneStarts.length - headerTones) ~/ height;
    final layout = _SstvLayout(
      mode: mode,
      starts: Int32List.fromList(<int>[...writer.toneStarts, writer.position]),
      headerTones: headerTones,
      tonesPerLine: tonesPerLine,
      height: height,
    );
    if (tonesPerLine != layout.expectedTonesPerLine) {
      throw StateError('Unerwartetes SSTV-Zeitraster fuer ${mode.label}');
    }
    return layout;
  }

  /// Frequenz eines Tons (NaN, wenn nicht messbar, z. B. Stille in einer
  /// durch Paketverlust gefuellten Luecke).
  static double _toneFrequency(List<int> samples, int start, int count) {
    var numerator = 0.0;
    var energy = 0.0;
    final first = math.max(start + 1, 1);
    final last = math.min(start + count - 1, samples.length - 2);
    for (var k = first; k <= last; k++) {
      final x = samples[k].toDouble();
      numerator += x * (samples[k - 1] + samples[k + 1]);
      energy += x * x;
    }
    // Sehr kurzer Ton mit Sample nahe dem Nulldurchgang: das erste Sample
    // (Uebergang vom vorigen Ton) als Naeherung mitnehmen.
    if (energy < 20000 && start >= 1 && start <= samples.length - 2) {
      final x = samples[start].toDouble();
      numerator += x * (samples[start - 1] + samples[start + 1]);
      energy += x * x;
    }
    if (energy < 20000) return double.nan;
    final cosine = (numerator / (2 * energy)).clamp(-1.0, 1.0);
    return math.acos(cosine) * sampleRate / (2 * math.pi);
  }

  static double _syncDeviation(
    List<int> samples,
    _SstvLayout layout,
    int line,
    int offset,
  ) {
    final tone = layout.lineTone(line, layout.syncTone);
    final frequency = _toneFrequency(
      samples,
      layout.starts[tone] + offset,
      layout.toneLength(tone),
    );
    return frequency.isNaN ? double.infinity : (frequency - 1200).abs();
  }

  /// Versatz des Puffers gegenueber dem Zeitraster (0 = Puffer beginnt genau
  /// am Bildanfang, wie beim Netzempfang). null = kein passendes Raster.
  static int? _findExactOffset(List<int> samples, _SstvLayout layout) {
    const probeCount = 12;
    final probes = <int>[
      for (var i = 0; i < probeCount; i++)
        (i * (layout.height - 1)) ~/ (probeCount - 1),
    ];
    const required = probeCount - 2;

    (int, double) score(int offset) {
      var hits = 0;
      var deviation = 0.0;
      for (final line in probes) {
        final d = _syncDeviation(samples, layout, line, offset);
        if (d <= _syncToleranceHz) {
          hits++;
          deviation += d;
        }
      }
      return (hits, deviation);
    }

    final (zeroHits, zeroDeviation) = score(0);
    if (zeroHits >= required && zeroDeviation / zeroHits < 5) return 0;

    var bestHits = 0;
    var bestDeviation = double.infinity;
    int? bestOffset;
    for (
      var offset = -_maximumExactOffset;
      offset <= _maximumExactOffset;
      offset++
    ) {
      final (hits, deviation) = score(offset);
      if (hits > bestHits || (hits == bestHits && deviation < bestDeviation)) {
        bestHits = hits;
        bestDeviation = deviation;
        bestOffset = offset;
      }
    }
    return bestHits >= required ? bestOffset : null;
  }

  /// Pixelwerte eines Bildanteils; -1 = nicht messbar.
  static Int16List _exactComponent(
    List<int> samples,
    _SstvLayout layout,
    int line,
    int firstTone,
    int pixelCount,
    int offset,
  ) {
    final values = Int16List(pixelCount);
    for (var x = 0; x < pixelCount; x++) {
      final tone = layout.lineTone(line, firstTone + x);
      final frequency = _toneFrequency(
        samples,
        layout.starts[tone] + offset,
        layout.toneLength(tone),
      );
      values[x] = frequency.isNaN
          ? -1
          : (((frequency - 1500) / 800) * 255).round().clamp(0, 255).toInt();
    }
    return values;
  }

  /// Nicht messbare Pixel (Luecke durch verlorenes Paket) aus der Zeile
  /// darueber bzw. dem linken Nachbarn uebernehmen.
  static void _fillMissing(Int16List values, Int16List? above) {
    for (var x = 0; x < values.length; x++) {
      if (values[x] >= 0) continue;
      final fromAbove = above == null ? -1 : above[x];
      if (fromAbove >= 0) {
        values[x] = fromAbove;
      } else if (x > 0) {
        values[x] = values[x - 1];
      }
    }
    // Fehlte der Zeilenanfang: vom ersten gueltigen Pixel nach links
    for (var x = values.length - 2; x >= 0; x--) {
      if (values[x] < 0) values[x] = values[x + 1];
    }
    for (var x = 0; x < values.length; x++) {
      if (values[x] < 0) values[x] = 0;
    }
  }

  static bool _lineComplete(
    List<int> samples,
    _SstvLayout layout,
    int line,
    int offset,
  ) {
    final end = layout.starts[layout.lineTone(line + 1, 0)] + offset;
    return end <= samples.length;
  }

  static SstvDecodedFrame? _decodeExact(List<int> samples, SstvMode mode) {
    final layout = _layoutFor(mode);
    final offset = _findExactOffset(samples, layout);
    if (offset == null) return null;
    final height = layout.height;
    if (!_lineComplete(samples, layout, height - 1, offset)) return null;

    var syncedLines = 0;
    for (var line = 0; line < height; line++) {
      if (_syncDeviation(samples, layout, line, offset) <= _syncToleranceHz) {
        syncedLines++;
      }
    }
    if (syncedLines < height * _minimumExactSyncRatio) return null;

    final rgba = Uint8List(_width * height * 4);
    if (mode == SstvMode.robot36) {
      final luma = <Int16List>[];
      final chroma = <Int16List>[];
      for (var line = 0; line < height; line++) {
        final y = _exactComponent(samples, layout, line, 2, _width, offset);
        final c = _exactComponent(
          samples,
          layout,
          line,
          323,
          _width ~/ 2,
          offset,
        );
        _fillMissing(y, line > 0 ? luma[line - 1] : null);
        _fillMissing(c, line > 1 ? chroma[line - 2] : null);
        luma.add(y);
        chroma.add(c);
      }
      for (var line = 0; line < height; line++) {
        _writeRobotLine(rgba, line, luma[line], chroma);
      }
    } else {
      Int16List? previousRed;
      Int16List? previousGreen;
      Int16List? previousBlue;
      for (var line = 0; line < height; line++) {
        final (red, green, blue) = _exactRgb(samples, layout, line, offset);
        _fillMissing(red, previousRed);
        _fillMissing(green, previousGreen);
        _fillMissing(blue, previousBlue);
        _writeRgbValues(rgba, line, red, green, blue);
        previousRed = red;
        previousGreen = green;
        previousBlue = blue;
      }
    }
    return SstvDecodedFrame(width: _width, height: height, rgba: rgba);
  }

  static (Int16List, Int16List, Int16List) _exactRgb(
    List<int> samples,
    _SstvLayout layout,
    int line,
    int offset,
  ) {
    // Martin 1 und Scottie 1 senden je Zeile Gruen, Blau, Rot
    final (greenTone, blueTone, redTone) = layout.mode == SstvMode.martin1
        ? (2, 323, 644)
        : (0, 321, 643);
    return (
      _exactComponent(samples, layout, line, redTone, _width, offset),
      _exactComponent(samples, layout, line, greenTone, _width, offset),
      _exactComponent(samples, layout, line, blueTone, _width, offset),
    );
  }

  static void _writeRgbValues(
    Uint8List rgba,
    int line,
    Int16List red,
    Int16List green,
    Int16List blue,
  ) {
    for (var x = 0; x < _width; x++) {
      final index = (line * _width + x) * 4;
      rgba[index] = red[x];
      rgba[index + 1] = green[x];
      rgba[index + 2] = blue[x];
      rgba[index + 3] = 255;
    }
  }

  /// Robot 36 sendet die Farbanteile abwechselnd: gerade Zeilen U, ungerade
  /// Zeilen V. Jede Zeile bekommt beide Anteile aus ihrem Zeilenpaar.
  /// [chroma] enthaelt die Farbzeilen ab Zeile 0 (fehlende = null).
  static void _writeRobotLine(
    Uint8List rgba,
    int line,
    Int16List luma,
    List<Int16List?> chroma,
  ) {
    Int16List? at(int index) =>
        index >= 0 && index < chroma.length ? chroma[index] : null;
    final Int16List? u;
    final Int16List? v;
    if (line.isEven) {
      u = at(line);
      v = at(line + 1) ?? at(line - 1);
    } else {
      u = at(line - 1) ?? at(line + 1);
      v = at(line);
    }
    for (var x = 0; x < _width; x++) {
      final index = (line * _width + x) * 4;
      final y = luma[x].toDouble();
      final cu = (u == null ? 128 : u[x ~/ 2]) - 128.0;
      final cv = (v == null ? 128 : v[x ~/ 2]) - 128.0;
      rgba[index] = (y + 1.403 * cv).round().clamp(0, 255);
      rgba[index + 1] = (y - 0.344 * cu - 0.714 * cv).round().clamp(0, 255);
      rgba[index + 2] = (y + 1.770 * cu).round().clamp(0, 255);
      rgba[index + 3] = 255;
    }
  }

  /// Live-Vorschau: eine Zeile exakt dekodieren (Puffer beginnt am
  /// Bildanfang). null = Sync nicht am erwarteten Platz (dann toleranter
  /// Decoder), false = noch nicht genug Samples.
  static bool? _decodeLineExact(
    List<int> samples,
    SstvMode mode,
    int line,
    Uint8List rgba,
  ) {
    final layout = _layoutFor(mode);
    if (!_lineComplete(samples, layout, line, 0)) return false;
    if (_syncDeviation(samples, layout, line, 0) > _syncToleranceHz) {
      return null;
    }
    if (mode != SstvMode.robot36) {
      final (red, green, blue) = _exactRgb(samples, layout, line, 0);
      Int16List? previous(int channel) {
        if (line == 0) return null;
        final values = Int16List(_width);
        for (var x = 0; x < _width; x++) {
          values[x] = rgba[((line - 1) * _width + x) * 4 + channel];
        }
        return values;
      }

      _fillMissing(red, previous(0));
      _fillMissing(green, previous(1));
      _fillMissing(blue, previous(2));
      _writeRgbValues(rgba, line, red, green, blue);
      return true;
    }

    Int16List decoded(int index, int firstTone, int pixelCount) {
      final values = _exactComponent(
        samples,
        layout,
        index,
        firstTone,
        pixelCount,
        0,
      );
      _fillMissing(values, null);
      return values;
    }

    final chroma = List<Int16List?>.filled(line + 1, null);
    chroma[line] = decoded(line, 323, _width ~/ 2);
    if (line > 0) chroma[line - 1] = decoded(line - 1, 323, _width ~/ 2);
    _writeRobotLine(rgba, line, decoded(line, 2, _width), chroma);
    // Die ungerade Zeile vervollstaendigt die Farbe der geraden Zeile davor
    if (line.isOdd) {
      _writeRobotLine(rgba, line - 1, decoded(line - 1, 2, _width), chroma);
    }
    return true;
  }

  static SstvDecodedFrame? _decodeFrame(
    Int16List samples,
    SstvMode mode,
    bool autoSlant,
  ) {
    final height = imageHeight(mode);
    final rgba = Uint8List(_width * height * 4);
    var syncedLines = 0;
    for (var y = 0; y < height; y++) {
      final result = _decodeLine(samples, mode, y, rgba, autoSlant: autoSlant);
      if (result == null) return null;
      if (result) syncedLines++;
    }
    if (syncedLines < height * _minimumSyncedLineRatio) return null;
    return SstvDecodedFrame(width: _width, height: height, rgba: rgba);
  }

  static int _findSync(List<int> samples, int expected, int radius) {
    final start = math.max(0, expected - radius);
    final end = math.min(samples.length - 40, expected + radius);
    for (var index = start; index <= end; index += 2) {
      if (_toneEnergy(samples, index, 38, 1200) >
          _toneEnergy(samples, index, 38, 1500) * 1.8) {
        return index;
      }
    }
    return -1;
  }

  static Uint8List _decodeComponent(
    List<int> samples,
    int start,
    double samplesPerPixel, {
    int outputWidth = _width,
    int windowRadius = 3,
  }) {
    final output = Uint8List(outputWidth);
    for (var x = 0; x < outputWidth; x++) {
      final center = start + ((x + 0.5) * samplesPerPixel).round();
      final windowStart = math.max(1, center - windowRadius);
      final windowEnd = math.min(samples.length - 1, center + windowRadius + 1);
      var recurrence = 0.0;
      var energy = 0.0;
      for (var i = windowStart; i < windowEnd; i++) {
        final sample = samples[i].toDouble();
        recurrence +=
            sample * (samples[i - 1].toDouble() + samples[i + 1].toDouble());
        energy += sample * sample;
      }
      if (energy <= 0) continue;
      final cosine = (recurrence / (2 * energy)).clamp(-1.0, 1.0);
      final frequency = math.acos(cosine) * sampleRate / (2 * math.pi);
      output[x] = (((frequency - 1500) / 800) * 255)
          .round()
          .clamp(0, 255)
          .toInt();
    }
    return output;
  }

  static double _toneEnergy(
    List<int> samples,
    int start,
    int length,
    int frequency,
  ) {
    if (length <= 0 || start < 0 || start + length > samples.length) return 0;
    final coefficient = _toneCoefficients[frequency]!;
    var previous = 0.0;
    var beforePrevious = 0.0;
    for (var i = start; i < start + length; i++) {
      final current = samples[i] + coefficient * previous - beforePrevious;
      beforePrevious = previous;
      previous = current;
    }
    return previous * previous +
        beforePrevious * beforePrevious -
        coefficient * previous * beforePrevious;
  }
}

class _PcmWriter {
  _PcmWriter({this.recordOnly = false});

  /// true: nur das Zeitraster (Beginn jedes Tons) aufzeichnen, keine Samples.
  /// Dieselbe Rechnung wie beim Senden, damit der Empfaenger jede
  /// Pixelgrenze exakt kennt.
  final bool recordOnly;
  final List<int> toneStarts = <int>[];
  int position = 0;
  final List<int> _samples = <int>[];
  double _phase = 0;
  double _sampleRemainder = 0;

  void tone(double frequency, double seconds) {
    final exact = seconds * SstvModem.sampleRate + _sampleRemainder;
    final adjusted = exact + 1e-9;
    final count = adjusted.floor();
    _sampleRemainder = adjusted - count;
    if (recordOnly) {
      toneStarts.add(position);
      position += count;
      return;
    }
    position += count;
    final increment = 2 * math.pi * frequency / SstvModem.sampleRate;
    for (var i = 0; i < count; i++) {
      _samples.add((math.sin(_phase) * 11000).round());
      _phase += increment;
      if (_phase >= 2 * math.pi) _phase -= 2 * math.pi;
    }
  }

  List<Int16List> takeReady() {
    final chunks = <Int16List>[];
    while (_samples.length >= 160) {
      chunks.add(Int16List.fromList(_samples.getRange(0, 160).toList()));
      _samples.removeRange(0, 160);
    }
    return chunks;
  }

  Int16List takeRemainder() {
    final tail = Int16List.fromList(_samples);
    _samples.clear();
    return tail;
  }
}

/// Zeitraster eines SSTV-Bildes: Beginn jedes Tons in Samples ab Bildanfang.
class _SstvLayout {
  _SstvLayout({
    required this.mode,
    required this.starts,
    required this.headerTones,
    required this.tonesPerLine,
    required this.height,
  });

  final SstvMode mode;

  /// Beginn jedes Tons; der letzte Eintrag ist das Ende der Sendung.
  final Int32List starts;
  final int headerTones;
  final int tonesPerLine;
  final int height;

  /// Martin: Sync, Porch, G, Trenner, B, Trenner, R.
  /// Scottie: G, Trenner, B, Sync, Porch, R. Robot: Sync, Porch, Y, Trenner, C.
  int get syncTone => mode == SstvMode.scottie1 ? 641 : 0;

  int get expectedTonesPerLine => switch (mode) {
    SstvMode.martin1 => 964,
    SstvMode.scottie1 => 963,
    SstvMode.robot36 => 483,
  };

  int lineTone(int line, int index) =>
      headerTones + line * tonesPerLine + index;

  int toneLength(int tone) => starts[tone + 1] - starts[tone];
}
