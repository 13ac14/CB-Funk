import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

class PacketRadioMessage {
  const PacketRadioMessage({
    required this.from,
    required this.to,
    required this.text,
  });

  final String from;
  final String to;
  final String text;
}

class PacketRadioModem {
  PacketRadioModem._();

  static const int sampleRate = 8000;
  static const int baud = 1200;
  static const int _markHz = 1200;
  static const int _spaceHz = 2200;
  static const int _flag = 0x7e;

  static Uint8List encodeFrame({
    required String from,
    required String to,
    required String text,
  }) {
    final bytes = <int>[
      ..._address(to, last: false),
      ..._address(from, last: true),
      0x03,
      0xf0,
      ...utf8.encode(text),
    ];
    final fcs = _fcs(bytes);
    bytes
      ..add(fcs & 0xff)
      ..add((fcs >> 8) & 0xff);
    return Uint8List.fromList(bytes);
  }

  static Int16List modulate({
    required String from,
    required String to,
    required String text,
  }) {
    final frame = encodeFrame(from: from, to: to, text: text);
    final bits = <bool>[];
    for (var i = 0; i < 20; i++) {
      _appendByteBits(bits, _flag);
    }
    var ones = 0;
    for (final byte in frame) {
      for (var bit = 0; bit < 8; bit++) {
        final value = (byte & (1 << bit)) != 0;
        bits.add(value);
        if (value) {
          ones++;
          if (ones == 5) {
            bits.add(false);
            ones = 0;
          }
        } else {
          ones = 0;
        }
      }
    }
    for (var i = 0; i < 3; i++) {
      _appendByteBits(bits, _flag);
    }

    final sampleCount = (bits.length * sampleRate / baud).ceil();
    final pcm = Int16List(sampleCount);
    var tone = _markHz;
    var phase = 0.0;
    var previousBitIndex = -1;
    for (var i = 0; i < sampleCount; i++) {
      final bitIndex = i * baud ~/ sampleRate;
      if (bitIndex != previousBitIndex &&
          bitIndex < bits.length &&
          !bits[bitIndex]) {
        tone = tone == _markHz ? _spaceHz : _markHz;
      }
      previousBitIndex = bitIndex;
      phase += 2 * math.pi * tone / sampleRate;
      if (phase >= 2 * math.pi) phase -= 2 * math.pi;
      pcm[i] = (math.sin(phase) * 12000).round();
    }
    return pcm;
  }

  static PacketRadioMessage? decodePcm(Int16List samples) {
    for (var offset = 0; offset < 7; offset++) {
      final bits = <bool>[];
      var previousTone = _markHz;
      var position = offset.toDouble();
      while (position + 7 < samples.length) {
        final start = position.round();
        final end = math.min(
          samples.length,
          (position + sampleRate / baud).round(),
        );
        if (end - start < 5) break;
        final mark = _toneEnergy(samples, start, end, _markHz);
        final space = _toneEnergy(samples, start, end, _spaceHz);
        final tone = mark >= space ? _markHz : _spaceHz;
        bits.add(tone == previousTone);
        previousTone = tone;
        position += sampleRate / baud;
      }
      final decoded = decodeBits(bits);
      if (decoded != null) return decoded;
    }
    return null;
  }

  static PacketRadioMessage? decodeBits(List<bool> bits) {
    final flagBits = List<bool>.generate(8, (i) => (_flag & (1 << i)) != 0);
    final frameBits = <bool>[];
    var inFrame = false;
    for (var i = 0; i + 8 <= bits.length; i++) {
      var matchesFlag = true;
      for (var j = 0; j < 8; j++) {
        if (bits[i + j] != flagBits[j]) {
          matchesFlag = false;
          break;
        }
      }
      if (!matchesFlag) {
        if (inFrame) frameBits.add(bits[i]);
        continue;
      }
      if (inFrame && frameBits.length >= 112) {
        final result = _decodeFrameBits(frameBits);
        if (result != null) return result;
      }
      frameBits.clear();
      inFrame = true;
      i += 7;
    }
    if (inFrame && frameBits.length >= 112) {
      return _decodeFrameBits(frameBits);
    }
    return null;
  }

  static PacketRadioMessage? _decodeFrameBits(List<bool> stuffed) {
    final raw = <bool>[];
    var ones = 0;
    for (final bit in stuffed) {
      if (ones == 5) {
        if (bit) return null;
        ones = 0;
        continue;
      }
      raw.add(bit);
      if (bit) {
        ones++;
      } else {
        ones = 0;
      }
    }
    if (raw.length < 112 || raw.length % 8 != 0) return null;
    final bytes = <int>[];
    for (var i = 0; i < raw.length; i += 8) {
      var byte = 0;
      for (var bit = 0; bit < 8; bit++) {
        if (raw[i + bit]) byte |= 1 << bit;
      }
      bytes.add(byte);
    }
    if (_crc(bytes) != 0xf0b8 || bytes.length < 18) return null;
    final to = _decodeAddress(bytes, 0);
    final from = _decodeAddress(bytes, 7);
    if (to == null || from == null || bytes[14] != 0x03) return null;
    final infoStart = bytes[15] == 0xf0 ? 16 : 15;
    final infoEnd = bytes.length - 2;
    if (infoEnd < infoStart) return null;
    return PacketRadioMessage(
      from: from,
      to: to,
      text: utf8.decode(
        bytes.sublist(infoStart, infoEnd),
        allowMalformed: true,
      ),
    );
  }

  static List<int> _address(String call, {required bool last}) {
    final normalized = call.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{1,6}$').hasMatch(normalized)) {
      throw ArgumentError.value(
        call,
        'callsign',
        'Must be 1-6 letters or digits',
      );
    }
    final address = <int>[
      for (var i = 0; i < 6; i++)
        (i < normalized.length ? normalized.codeUnitAt(i) : 0x20) << 1,
      0x60 | (last ? 1 : 0),
    ];
    return address;
  }

  static String? _decodeAddress(List<int> bytes, int start) {
    if (start + 7 > bytes.length) return null;
    final call = String.fromCharCodes(
      bytes
          .skip(start)
          .take(6)
          .map((byte) => byte >> 1)
          .where((char) => char != 0x20),
    );
    return call.isEmpty ? null : call;
  }

  static int _fcs(List<int> bytes) => (~_crc(bytes)) & 0xffff;

  static int _crc(List<int> bytes) {
    var crc = 0xffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1;
      }
    }
    return crc & 0xffff;
  }

  static void _appendByteBits(List<bool> bits, int byte) {
    for (var bit = 0; bit < 8; bit++) {
      bits.add((byte & (1 << bit)) != 0);
    }
  }

  static double _toneEnergy(Int16List samples, int start, int end, int hz) {
    final omega = 2 * math.pi * hz / sampleRate;
    final coeff = 2 * math.cos(omega);
    var s0 = 0.0;
    var s1 = 0.0;
    var s2 = 0.0;
    for (var i = start; i < end; i++) {
      s0 = samples[i] + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    return s1 * s1 + s2 * s2 - coeff * s1 * s2;
  }
}
