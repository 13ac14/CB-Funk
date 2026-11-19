import 'dart:typed_data';

/// G.711 mu-law: 16 Bit PCM <-> 8 Bit. Halbiert die Datenmenge, keine
/// native Codec-Abhaengigkeit, laeuft auf Android und Windows identisch.
class MuLaw {
  MuLaw._();
  static const int _bias = 0x84;
  static const int _clip = 32635;

  static final Int16List _decodeTable = () {
    final t = Int16List(256);
    for (var i = 0; i < 256; i++) {
      final u = ~i & 0xFF;
      final sign = u & 0x80;
      final exponent = (u >> 4) & 0x07;
      final mantissa = u & 0x0F;
      var sample = ((mantissa << 3) + _bias) << exponent;
      sample -= _bias;
      t[i] = sign != 0 ? -sample : sample;
    }
    return t;
  }();

  static int encode(int pcm) {
    final sign = (pcm >> 8) & 0x80;
    if (sign != 0) pcm = -pcm;
    if (pcm > _clip) pcm = _clip;
    pcm += _bias;
    var exponent = 7;
    for (var mask = 0x4000; (pcm & mask) == 0 && exponent > 0; mask >>= 1) {
      exponent--;
    }
    final mantissa = (pcm >> (exponent + 3)) & 0x0F;
    return ~(sign | (exponent << 4) | mantissa) & 0xFF;
  }

  static int decode(int u) => _decodeTable[u & 0xFF];
}
