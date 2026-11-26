/// ZENTRALE KONFIGURATION - hier die Server-Daten eintragen.
/// Endnutzer koennen diese Werte in der App NICHT veraendern.
class AppConfig {
  AppConfig._();

  // >>> HIER die IP/Domain deines Linux-Servers eintragen <<<
  static const String mqttHost = 'svx.funknetzdeutschland.com';
  static const int mqttPort = 1883;

  // Optionale Zugangsdaten (leer lassen = anonym)
  static const String mqttUser = '';
  static const String mqttPassword = '';

  static const String topicPrefix = 'cbfunk';
  static const String appName = 'CB-Funk';
  static const String appVersion = '1.4.9';

  // ---- Audio ----
  /// Netz-/Wiedergaberate (Sprache, 8 kHz mu-law = 64 kbit/s, klingt "CB-typisch")
  static const int audioRate = 8000;

  /// Aufnahmerate des Mikrofons (wird auf audioRate heruntergerechnet)
  static const int micRate = 16000;

  /// Samples pro Paket (160 @ 8 kHz = 20 ms)
  static const int frameSamples = 160;

  /// TEST: true = eigene Sendung wird auch selbst abgespielt (nur mit Headset!)
  static const bool loopbackTest = false;

  // ---- Gateway ----
  /// Weckton fuer VOX-Box ("Tonschaltung")
  static const double gwKeyToneHz = 1000;

  /// Leiser Weckton fuer VOX am Funkgeraet
  static const double gwVoxToneHz = 400;

  /// Sicherheits-Sendezeitbegrenzung (Gateway sendet nie laenger am Stueck)
  static const int gwMaxTxSeconds = 180;
}
