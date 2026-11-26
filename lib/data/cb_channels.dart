/// Kanaltabelle: Kanal 1-40 (26.965-27.405 MHz, Standard-EU-Raster mit
/// den bekannten Luecken) und Kanal 41-80 (deutsches Raster, 400 kHz tiefer).
/// HINWEIS: Raster 41-80 bitte gegen deine Vorlage pruefen.
class CbChannels {
  CbChannels._();

  static const List<double> _base40 = [
    26.965,
    26.975,
    26.985,
    27.005,
    27.015,
    27.025,
    27.035,
    27.055,
    27.065,
    27.075,
    27.085,
    27.105,
    27.115,
    27.125,
    27.135,
    27.155,
    27.165,
    27.175,
    27.185,
    27.205,
    27.215,
    27.225,
    27.255,
    27.235,
    27.245,
    27.265,
    27.275,
    27.285,
    27.295,
    27.305,
    27.315,
    27.325,
    27.335,
    27.345,
    27.355,
    27.365,
    27.375,
    27.385,
    27.395,
    27.405,
  ];

  static const int count = 80;

  static double frequency(int channel) {
    assert(channel >= 1 && channel <= count);
    if (channel <= 40) return _base40[channel - 1];
    return double.parse((_base40[channel - 41] - 0.400).toStringAsFixed(3));
  }

  static String frequencyLabel(int channel) =>
      '${frequency(channel).toStringAsFixed(3)} MHz';

  /// Kanaele, auf denen der Gateway laut Vorlage laufen darf.
  static const List<int> gatewayChannels = [
    11,
    24,
    25,
    29,
    34,
    39,
    40,
    41,
    61,
    71,
    80,
  ];

  /// Davon nur FM:
  static const List<int> gatewayFmOnly = [41, 61, 71, 80];
}
