enum Modulation { fm, am, usb, lsb }

extension ModulationX on Modulation {
  String get label => name.toUpperCase();
  Modulation get next =>
      Modulation.values[(index + 1) % Modulation.values.length];
}

enum Antenna {
  handfunke('Handfunke (Wendel)', -9),
  mobil('Mobil (Dachantenne)', -2),
  feststation('Feststation (Groundplane)', 3),
  richtantenne('Richtantenne (Beam)', 9);

  const Antenna(this.label, this.db);
  final String label;
  final int db;
  String get title => '$label (${db > 0 ? '+' : ''}$db dB)';
}

enum GatewayMode {
  none('Ohne Kabel (Handy ans Funkgerät legen)'),
  voxRadio('Kabel + VOX am Funkgerät'),
  voxBox('Kabel + Tonschaltung (VOX-Box)'),
  aioc('AIOC-Kabel (USB)'),
  usbCard('USB-Soundkarte mit PTT (CM108, Digirig Lite)'),
  usbSerial('USB-Soundkarte + Seriell-PTT (Digirig)'),
  bluetooth('Bluetooth-Adapter am Funkgerät');

  const GatewayMode(this.label);
  final String label;
}
