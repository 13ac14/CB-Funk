class DeviceInfo {
  const DeviceInfo(this.key, this.label);
  final String key;
  final String label;
}

String hex4(int? v) => (v ?? 0).toRadixString(16).padLeft(4, '0');

/// Bekannte USB-HID-PTT-Geraete (CM108-kompatibel)
String knownHidName(int vid, int pid) {
  if (vid == 0x0D8C) return 'C-Media CM108/CM119 (Soundkarte)';
  if (vid == 0x1209 && pid == 0x7388) return 'AIOC-Kabel';
  return 'USB-HID';
}
