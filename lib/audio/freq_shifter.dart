import 'dart:math' as math;
import 'dart:typed_data';

/// Frequenzverschiebung (Einseitenband-Mischer) per Hilbert-FIR.
/// Simuliert den CLARIFIER: bei SSB verschiebt eine Verstimmung die gesamte
/// Sprache nach oben/unten ("Mickey-Mouse"/"Brummbaer"-Effekt).
class FreqShifter {
  FreqShifter(this.sampleRate) {
    for (var k = 0; k < taps; k++) {
      final m = k - _mid;
      if (m.isOdd) {
        final w = 0.54 - 0.46 * math.cos(2 * math.pi * k / (taps - 1));
        _h[k] = 2.0 / (math.pi * m) * w;
      }
    }
  }

  static const int taps = 31;
  static const int _mid = 15;

  final int sampleRate;
  /// Verschiebung in Hz (positiv = hoeher)
  double hz = 0;

  final Float64List _h = Float64List(taps);
  final Float64List _x = Float64List(taps);
  int _pos = 0;
  double _phase = 0;

  double process(double x) {
    _x[_pos] = x;
    var im = 0.0;
    for (var k = 0; k < taps; k++) {
      final h = _h[k];
      if (h != 0) im += h * _x[(_pos - k) % taps];
    }
    final re = _x[(_pos - _mid) % taps];
    _phase += 2 * math.pi * hz / sampleRate;
    if (_phase > 2 * math.pi) _phase -= 2 * math.pi;
    if (_phase < -2 * math.pi) _phase += 2 * math.pi;
    _pos = (_pos + 1) % taps;
    return re * math.cos(_phase) - im * math.sin(_phase);
  }
}
