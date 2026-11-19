/// Tasten-Aktionen, die der Nutzer anlernen kann (Reihenfolge wie im Dialog).
enum KeyAction {
  ptt('Sendetaste'),
  parrot('Papagei an/aus'),
  switchKnob('Regler wechseln (◄►)'),
  scan('Suchlauf an/aus'),
  channel9('Kanal 9 (Notruf)'),
  channel19('Kanal 19'),
  mode('Betriebsart wechseln'),
  channelUp('Kanal hoch'),
  channelDown('Kanal runter'),
  volumeUp('Lautstärke +'),
  volumeDown('Lautstärke −'),
  squelchUp('Squelch +'),
  squelchDown('Squelch −'),
  txLevelUp('Sendepegel +'),
  txLevelDown('Sendepegel −'),
  echo('Echo an/aus'),
  rogerBeep('Roger-Beep wechseln'),
  powerToggle('Ein/Aus'),
  menu('Menü öffnen');

  const KeyAction(this.label);
  final String label;
}
