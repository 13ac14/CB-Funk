import 'dart:math' as math;
import 'dart:typed_data';

/// Kleiner Baseline-JPEG-Encoder (JFIF, 4:4:4 ohne Farb-Unterabtastung).
/// dart:ui kann nur PNG schreiben; fuer "Speichern als JPG" im SSTV-Fenster
/// reicht dieser Encoder ohne zusaetzliche Bibliothek.
class JpegEncoder {
  JpegEncoder._();

  static const List<int> _lumaQuant = <int>[
    16, 11, 10, 16, 24, 40, 51, 61, //
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
  ];

  static const List<int> _chromaQuant = <int>[
    17, 18, 24, 47, 99, 99, 99, 99, //
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
  ];

  static const List<int> _dcLumaBits = <int>[
    0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, //
  ];
  static const List<int> _dcChromaBits = <int>[
    0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, //
  ];
  static const List<int> _dcValues = <int>[
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    11,
  ];

  static const List<int> _acLumaBits = <int>[
    0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d, //
  ];
  static const List<int> acLumaValues = <int>[
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, //
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
    0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
    0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
    0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ];

  static const List<int> _acChromaBits = <int>[
    0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77, //
  ];
  static const List<int> acChromaValues = <int>[
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, //
    0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
    0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
    0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
    0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
    0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
  ];

  /// Reihenfolge der Koeffizienten im Zickzack (Index im 8x8-Block).
  static final List<int> _zigzag = () {
    final order = <int>[];
    for (var sum = 0; sum < 15; sum++) {
      final cells = <int>[];
      for (var row = 0; row < 8; row++) {
        final column = sum - row;
        if (column >= 0 && column < 8) cells.add(row * 8 + column);
      }
      // gerade Diagonalen von unten nach oben, ungerade von oben nach unten
      order.addAll(sum.isEven ? cells.reversed : cells);
    }
    return order;
  }();

  static final List<double> _cosines = <double>[
    for (var x = 0; x < 8; x++)
      for (var u = 0; u < 8; u++) math.cos((2 * x + 1) * u * math.pi / 16),
  ];

  /// Kodiert RGBA-Pixel (Alpha wird ignoriert) als JPEG.
  static Uint8List encode(
    Uint8List rgba,
    int width,
    int height, {
    int quality = 92,
  }) {
    final q = quality.clamp(1, 100);
    final scale = q < 50 ? 5000 ~/ q : 200 - 2 * q;
    List<int> scaled(List<int> base) => <int>[
      for (final value in base) ((value * scale + 50) ~/ 100).clamp(1, 255),
    ];
    final lumaQuant = scaled(_lumaQuant);
    final chromaQuant = scaled(_chromaQuant);

    final dcLuma = _codes(_dcLumaBits, _dcValues);
    final dcChroma = _codes(_dcChromaBits, _dcValues);
    final acLuma = _codes(_acLumaBits, acLumaValues);
    final acChroma = _codes(_acChromaBits, acChromaValues);

    final out = BytesBuilder(copy: false);
    void marker(int code, List<int> body) {
      out.add(<int>[
        0xff,
        code,
        (body.length + 2) >> 8,
        (body.length + 2) & 0xff,
      ]);
      out.add(body);
    }

    out.add(<int>[0xff, 0xd8]);
    marker(0xe0, <int>[0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
    marker(0xdb, <int>[
      0,
      for (final i in _zigzag) lumaQuant[i],
      1,
      for (final i in _zigzag) chromaQuant[i],
    ]);
    marker(0xc0, <int>[
      8,
      height >> 8,
      height & 0xff,
      width >> 8,
      width & 0xff,
      3,
      1, 0x11, 0, //
      2, 0x11, 1,
      3, 0x11, 1,
    ]);
    marker(0xc4, <int>[
      0x00, ..._dcLumaBits, ..._dcValues, //
      0x10, ..._acLumaBits, ...acLumaValues,
      0x01, ..._dcChromaBits, ..._dcValues,
      0x11, ..._acChromaBits, ...acChromaValues,
    ]);
    marker(0xda, <int>[3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]);

    final writer = _BitWriter();
    final blockY = Float64List(64);
    final blockCb = Float64List(64);
    final blockCr = Float64List(64);
    final coefficients = Float64List(64);
    var previousY = 0;
    var previousCb = 0;
    var previousCr = 0;
    for (var by = 0; by < height; by += 8) {
      for (var bx = 0; bx < width; bx += 8) {
        for (var y = 0; y < 8; y++) {
          final sy = math.min(by + y, height - 1);
          for (var x = 0; x < 8; x++) {
            final sx = math.min(bx + x, width - 1);
            final o = (sy * width + sx) * 4;
            final r = rgba[o].toDouble();
            final g = rgba[o + 1].toDouble();
            final b = rgba[o + 2].toDouble();
            blockY[y * 8 + x] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
            blockCb[y * 8 + x] = -0.168736 * r - 0.331264 * g + 0.5 * b;
            blockCr[y * 8 + x] = 0.5 * r - 0.418688 * g - 0.081312 * b;
          }
        }
        previousY = _encodeBlock(
          writer,
          blockY,
          coefficients,
          lumaQuant,
          previousY,
          dcLuma,
          acLuma,
        );
        previousCb = _encodeBlock(
          writer,
          blockCb,
          coefficients,
          chromaQuant,
          previousCb,
          dcChroma,
          acChroma,
        );
        previousCr = _encodeBlock(
          writer,
          blockCr,
          coefficients,
          chromaQuant,
          previousCr,
          dcChroma,
          acChroma,
        );
      }
    }
    writer.flush();
    out.add(writer.bytes.takeBytes());
    out.add(<int>[0xff, 0xd9]);
    return out.takeBytes();
  }

  static int _encodeBlock(
    _BitWriter writer,
    Float64List block,
    Float64List coefficients,
    List<int> quant,
    int previousDc,
    Map<int, (int, int)> dc,
    Map<int, (int, int)> ac,
  ) {
    // 2D-DCT (getrennt nach Zeilen und Spalten)
    final rows = Float64List(64);
    for (var y = 0; y < 8; y++) {
      for (var u = 0; u < 8; u++) {
        var sum = 0.0;
        for (var x = 0; x < 8; x++) {
          sum += block[y * 8 + x] * _cosines[x * 8 + u];
        }
        rows[y * 8 + u] = sum * (u == 0 ? math.sqrt1_2 : 1.0) / 2;
      }
    }
    for (var u = 0; u < 8; u++) {
      for (var v = 0; v < 8; v++) {
        var sum = 0.0;
        for (var y = 0; y < 8; y++) {
          sum += rows[y * 8 + u] * _cosines[y * 8 + v];
        }
        coefficients[v * 8 + u] = sum * (v == 0 ? math.sqrt1_2 : 1.0) / 2;
      }
    }

    final quantized = List<int>.generate(64, (k) {
      final index = _zigzag[k];
      return (coefficients[index] / quant[index]).round().clamp(-2047, 2047);
    });

    final dcValue = quantized[0];
    final diff = dcValue - previousDc;
    final dcCategory = _category(diff);
    writer.write(dc[dcCategory]!);
    if (dcCategory > 0) {
      writer.writeBits(_magnitude(diff, dcCategory), dcCategory);
    }

    var run = 0;
    for (var k = 1; k < 64; k++) {
      final value = quantized[k].clamp(-1023, 1023);
      if (value == 0) {
        run++;
        continue;
      }
      while (run > 15) {
        writer.write(ac[0xf0]!);
        run -= 16;
      }
      final category = _category(value);
      writer.write(ac[(run << 4) | category]!);
      writer.writeBits(_magnitude(value, category), category);
      run = 0;
    }
    if (run > 0) writer.write(ac[0x00]!);
    return dcValue;
  }

  static int _category(int value) {
    var magnitude = value.abs();
    var bits = 0;
    while (magnitude > 0) {
      bits++;
      magnitude >>= 1;
    }
    return bits;
  }

  static int _magnitude(int value, int category) =>
      value >= 0 ? value : value + (1 << category) - 1;

  /// Kanonische Huffman-Codes: Symbol -> (Code, Laenge).
  static Map<int, (int, int)> _codes(List<int> bits, List<int> values) {
    final codes = <int, (int, int)>{};
    var code = 0;
    var index = 0;
    for (var length = 1; length <= 16; length++) {
      for (var i = 0; i < bits[length - 1]; i++) {
        codes[values[index++]] = (code, length);
        code++;
      }
      code <<= 1;
    }
    return codes;
  }
}

class _BitWriter {
  final BytesBuilder bytes = BytesBuilder(copy: false);
  final List<int> _pending = <int>[];
  int _buffer = 0;
  int _count = 0;

  void write((int, int) code) => writeBits(code.$1, code.$2);

  void writeBits(int value, int length) {
    for (var i = length - 1; i >= 0; i--) {
      _buffer = (_buffer << 1) | ((value >> i) & 1);
      if (++_count == 8) {
        _pending.add(_buffer);
        // Byte-Stuffing: 0xFF in den Bilddaten wird von 0x00 gefolgt
        if (_buffer == 0xff) _pending.add(0);
        _buffer = 0;
        _count = 0;
        if (_pending.length >= 4096) {
          bytes.add(Uint8List.fromList(_pending));
          _pending.clear();
        }
      }
    }
  }

  void flush() {
    if (_count > 0) writeBits(0x7f, 8 - _count);
    bytes.add(Uint8List.fromList(_pending));
    _pending.clear();
  }
}
