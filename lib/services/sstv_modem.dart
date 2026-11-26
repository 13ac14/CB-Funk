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
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }

    final writer = _PcmWriter();
    writer.tone(1900, 0.3);
    writer.tone(1200, 0.01);
    writer.tone(1900, 0.3);
    writer.tone(1200, 0.03);
    writer.tone(1100, 0.03);
    for (var bit = 0; bit < 8; bit++) {
      writer.tone((mode.visCode & (1 << bit)) == 0 ? 1100 : 1300, 0.03);
    }
    writer.tone(1200, 0.03);
    for (final chunk in writer.takeReady()) {
      yield chunk;
    }

    for (var y = 0; y < height; y++) {
      if (mode == SstvMode.martin1) {
        _encodeMartinLine(writer, pixels, y, height);
      } else if (mode == SstvMode.scottie1) {
        _encodeScottieLine(writer, pixels, y, height);
      } else {
        _encodeRobotLine(writer, pixels, y, height);
      }
      onProgress?.call((y + 1) / height);
      for (final chunk in writer.takeReady()) {
        yield chunk;
      }
      await Future<void>.delayed(Duration.zero);
    }
    final tail = writer.takeRemainder();
    if (tail.isNotEmpty) yield tail;
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
    return switch (mode) {
      SstvMode.martin1 => _decodeMartin1(samples, autoSlant),
      SstvMode.scottie1 => _decodeScottie1(samples, autoSlant),
      SstvMode.robot36 => _decodeRobot36(samples, autoSlant),
    };
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

    late final Uint8List first;
    late final Uint8List second;
    late final Uint8List third;
    switch (mode) {
      case SstvMode.martin1:
        const syncLength = 39;
        const porch = 5;
        const componentSamples = 1171;
        final expected = 7520 + line * 3567;
        final sync = autoSlant ? _findSync(samples, expected, 120) : expected;
        if (sync < 0 ||
            sync + syncLength + porch + componentSamples * 3 > samples.length) {
          return false;
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
        final sync = autoSlant ? _findSync(samples, expected, 120) : expected;
        final start = sync - componentSamples * 2 - separator;
        if (sync < 0 ||
            start < 0 ||
            sync + syncLength + porch + componentSamples > samples.length) {
          return false;
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
        final sync = autoSlant ? _findSync(samples, expected, 120) : expected;
        if (sync < 0 ||
            sync +
                    syncLength +
                    porch +
                    lumaSamples +
                    separator +
                    chromaSamples >
                samples.length) {
          return false;
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
    return true;
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

  static SstvDecodedFrame? _decodeMartin1(Int16List samples, bool autoSlant) {
    final rgba = Uint8List(_width * _martinHeight * 4);
    for (var y = 0; y < _martinHeight; y++) {
      if (!decodeLine(
        samples,
        SstvMode.martin1,
        y,
        rgba,
        autoSlant: autoSlant,
      )) {
        return null;
      }
    }
    return SstvDecodedFrame(width: _width, height: _martinHeight, rgba: rgba);
  }

  static SstvDecodedFrame? _decodeScottie1(Int16List samples, bool autoSlant) {
    final rgba = Uint8List(_width * _martinHeight * 4);
    for (var y = 0; y < _martinHeight; y++) {
      if (!decodeLine(
        samples,
        SstvMode.scottie1,
        y,
        rgba,
        autoSlant: autoSlant,
      )) {
        return null;
      }
    }
    return SstvDecodedFrame(width: _width, height: _martinHeight, rgba: rgba);
  }

  static SstvDecodedFrame? _decodeRobot36(Int16List samples, bool autoSlant) {
    final rgba = Uint8List(_width * _robotHeight * 4);
    for (var y = 0; y < _robotHeight; y++) {
      if (!decodeLine(
        samples,
        SstvMode.robot36,
        y,
        rgba,
        autoSlant: autoSlant,
      )) {
        return null;
      }
    }
    return SstvDecodedFrame(width: _width, height: _robotHeight, rgba: rgba);
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
  final List<int> _samples = <int>[];
  double _phase = 0;
  double _sampleRemainder = 0;

  void tone(double frequency, double seconds) {
    final exact = seconds * SstvModem.sampleRate + _sampleRemainder;
    final adjusted = exact + 1e-9;
    final count = adjusted.floor();
    _sampleRemainder = adjusted - count;
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
