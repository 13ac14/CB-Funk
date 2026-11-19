import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/app_config.dart';
import '../data/cb_channels.dart';
import '../gateway/device_info.dart';
import '../gateway/gateway_devices.dart';
import '../models/enums.dart';
import '../models/key_action.dart';
import '../state/radio_controller.dart';
import 'theme.dart';

const _amber = Color(0xFFFFB300);
const _lilac = Color(0xFFB9A8FF);
const _rogerBeepModes = <String>[
  'Aus',
  'Klassisch',
  'Zwei-Ton',
  'Triller',
  'Morse',
  'Papagei (Modulationstest)',
];

Future<void> showSettings(BuildContext context) async {
  final r = context.read<RadioController>();
  r.dialogOpen = true;
  try {
    await showDialog<void>(
        context: context, builder: (_) => const _SettingsDialog());
  } finally {
    r.dialogOpen = false;
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();
  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  final ScrollController _sc = ScrollController();
  late final TextEditingController _callSignController;
  bool _up = false;
  bool _down = true;
  String? _gwHint;

  @override
  void initState() {
    super.initState();
    _callSignController =
        TextEditingController(text: context.read<RadioController>().callSign);
    _sc.addListener(_scrollChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollChanged());
  }

  @override
  void dispose() {
    _sc.dispose();
    _callSignController.dispose();
    super.dispose();
  }

  void _scrollChanged() {
    if (!mounted || !_sc.hasClients) return;
    final p = _sc.position;
    final up = p.pixels > 8;
    final down = p.pixels < p.maxScrollExtent - 8;
    if (up != _up || down != _down) {
      setState(() {
        _up = up;
        _down = down;
      });
    }
  }

  void _scrollTo(double offset) {
    if (!mounted || !_sc.hasClients) return;
    final position = _sc.position;
    final target = offset.clamp(0.0, position.maxScrollExtent).toDouble();
    _sc.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // ---------- Bausteine ----------
  Widget _hint(String text, bool visible, VoidCallback onTap) => SizedBox(
        height: 26,
        child: visible
            ? InkWell(
                onTap: onTap,
                child: Center(
                  child: Text(text,
                      style: const TextStyle(
                          color: _amber, fontSize: 12.5, letterSpacing: 0.3)),
                ),
              )
            : null,
      );

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(t,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      );

  Widget _small(String t, {Color color = CbColors.textDim}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: TextStyle(fontSize: 13.5, color: color, height: 1.35)),
      );

  Widget _switchRow(String title, String? sub, bool value,
          ValueChanged<bool> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 17)),
              if (sub != null)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(sub,
                      style: const TextStyle(
                          fontSize: 12.5,
                          color: CbColors.textDim,
                          height: 1.3)),
                ),
            ]),
          ),
          const SizedBox(width: 10),
          Switch(value: value, onChanged: onChanged),
        ]),
      );

  Widget _radioRow(
          {required String label,
          required bool selected,
          required VoidCallback onTap,
          VoidCallback? onHelp}) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(children: [
            Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 26,
                color: selected ? _lilac : CbColors.textDim),
            const SizedBox(width: 16),
            Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 16, height: 1.25))),
            if (onHelp != null)
              InkWell(
                onTap: onHelp,
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(14, 8, 8, 8),
                  child: Text('?',
                      style: TextStyle(
                          color: _lilac,
                          fontSize: 18,
                          fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ),
      );

  Widget _keyRow(RadioController r, KeyAction a, String title) {
    final bound = r.keys.idFor(a) != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 17)),
            Text(r.keys.labelFor(a),
                style:
                    const TextStyle(fontSize: 12.5, color: CbColors.textDim)),
          ]),
        ),
        if (bound)
          IconButton(
            tooltip: 'Taste entfernen',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: CbColors.textDim),
            onPressed: () => r.unbindKey(a),
          ),
        TextButton(
          onPressed: () => _learn(r, a),
          child: const Text('Anlernen',
              style: TextStyle(
                  color: _lilac, fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  // ---------- Dialoge ----------
  Future<void> _learn(RadioController r, KeyAction a) async {
    BuildContext? dctx;
    final fut = r.keys.beginLearn();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        dctx = c;
        return AlertDialog(
          title: const Text('Taste anlernen'),
          content: Text('Drücke jetzt die Taste für „${a.label}“ …'),
          actions: [
            TextButton(
                onPressed: r.keys.cancelLearn, child: const Text('Abbrechen')),
          ],
        );
      },
    );
    final id = await fut;
    final c = dctx;
    if (c != null && c.mounted) Navigator.of(c).pop();
    if (id != null) r.bindKey(a, id);
  }

  static String _helpText(GatewayMode m) {
    switch (m) {
      case GatewayMode.none:
        return 'Das Handy liegt direkt am Lautsprecher und Mikrofon des Funkgeräts. '
            'Kein Kabel nötig, aber die Tonqualität hängt von der Umgebung ab und '
            'gesendet wird nur, wenn das Funkgerät selbst per VOX schaltet. '
            'Gut zum Ausprobieren.';
      case GatewayMode.voxRadio:
        return 'Handy und Funkgerät sind per Audiokabel verbunden. Das Funkgerät '
            'schaltet mit seiner eigenen VOX-Funktion auf Senden, sobald das Handy '
            'Ton liefert. Lautstärke und VOX-Empfindlichkeit am Funkgerät passend einstellen.';
      case GatewayMode.voxBox:
        return 'Zwischen Handy und Funkgerät sitzt eine VOX-Box (Tonschaltung). '
            'Sie erkennt den Ton vom Handy und löst die Sendetaste des Funkgeräts aus.';
      case GatewayMode.aioc:
        return 'Das AIOC-Kabel verbindet Funkgerät und Handy/PC per USB und '
            'überträgt Audio und PTT gemeinsam.';
      case GatewayMode.usbCard:
        return 'USB-Soundkarte mit CM108-Chip (z. B. Digirig Lite): Audio läuft über '
            'die Soundkarte, die Sendetaste (PTT) wird über einen Steuerpin der Karte geschaltet.';
      case GatewayMode.usbSerial:
        return 'USB-Soundkarte plus serielle Schnittstelle (z. B. Digirig): Audio über die '
            'Soundkarte, PTT über die RTS- oder DTR-Leitung der seriellen Schnittstelle.';
      case GatewayMode.bluetooth:
        return 'Ein Bluetooth-Adapter am Mikrofon-/Lautsprecheranschluss des Funkgeräts '
            'überträgt Audio drahtlos zum Handy. Zum Senden wird meist VOX oder die '
            'PTT-Taste des Adapters genutzt.';
    }
  }

  void _showHelp(GatewayMode m) => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(m.label, style: const TextStyle(fontSize: 18)),
          content: Text(_helpText(m)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('OK'))
          ],
        ),
      );

  void _showGuide() => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Anleitung für Anfänger'),
          content: SizedBox(
            height: (MediaQuery.sizeOf(c).height * 0.6)
                .clamp(0.0, 420.0)
                .toDouble(),
            child: const SingleChildScrollView(
              child: Text(
                'Mit dem Gateway verbindest du ein echtes CB-Funkgerät mit der App: '
                'Was auf dem Funk gesprochen wird, hören alle in der App – und umgekehrt.\n\n'
                '1. Stelle das Funkgerät auf einen erlaubten Kanal '
                '(11, 29, 34, 39, 40, 41, 61, 71, 80; 41/61/71/80 nur FM).\n'
                '2. Wähle die Anschlussart, die zu deinem Aufbau passt. '
                'Mit dem „?“ neben jeder Art bekommst du eine Kurzerklärung.\n'
                '3. Verbinde Handy/PC und Funkgerät wie gewählt (Kabel, VOX-Box, USB-Soundkarte …).\n'
                '4. Schalte „Gateway einschalten“ ein.\n'
                '5. Prüfe mit einem zweiten Gerät, ob die Sprache in beide Richtungen ankommt, '
                'und stelle Lautstärke und VOX-Empfindlichkeit am Funkgerät nach.\n\n'
                'Hinweis: Das Senden über ein Funkgerät ist nur mit entsprechender '
                'Zulassung und nach den geltenden CB-Funk-Regeln erlaubt.',
                style: TextStyle(height: 1.4),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('OK'))
          ],
        ),
      );

  // ---------- Gateway-Feineinstellungen ----------
  Widget _slider(String title, String valueText, double v, double min,
          double max, ValueChanged<double> onChanged, VoidCallback onEnd) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
          Text(valueText, style: const TextStyle(color: CbColors.textDim)),
        ]),
        Slider(
          value: v.clamp(min, max).toDouble(),
          min: min,
          max: max,
          onChanged: onChanged,
          onChangeEnd: (_) => onEnd(),
        ),
      ]);

  List<Widget> _gatewayTuning(RadioController r) {
    final mode = r.gatewayMode;
    final usesSerial = mode == GatewayMode.usbSerial;
    final usesHid = mode == GatewayMode.usbCard || mode == GatewayMode.aioc;
    final isVox = !usesSerial && !usesHid;

    return [
      _heading('Gateway-Feineinstellungen'),
      _small(isVox
          ? 'VOX-Betrieb: Das Funkgerät (oder die VOX-Box) schaltet selbst auf Senden. '
              'Die App stellt vor der Sprache einen kurzen Weckton voran.'
          : usesSerial
              ? 'Die App schaltet die Sendetaste über die serielle Leitung (RTS oder DTR).'
              : 'Die App schaltet die Sendetaste über das USB-HID-GPIO (CM108-kompatibel, '
                  'z. B. Soundkarte mit CM108/CM119 oder AIOC-Kabel).'),
      if (usesSerial) ...[
        _DevicePicker(
          key: const ValueKey('gateway-serial-device'),
          title: 'Serieller Port',
          autoLabel: 'Automatisch / erstes Gerät',
          loader: GatewayDevices.listSerial,
          value: r.gwSerialPort,
          onChanged: (k) => r.updateGateway(serialPort: k),
        ),
        _radioRow(
            label: 'PTT über RTS',
            selected: !r.gwUseDtr,
            onTap: () => r.updateGateway(useDtr: false)),
        _radioRow(
            label: 'PTT über DTR',
            selected: r.gwUseDtr,
            onTap: () => r.updateGateway(useDtr: true)),
      ],
      if (usesHid) ...[
        _DevicePicker(
          key: const ValueKey('gateway-hid-device'),
          title: 'USB-HID-Gerät',
          autoLabel: 'Automatisch (CM108 / AIOC)',
          loader: GatewayDevices.listHid,
          value: r.gwHidKey,
          onChanged: (k) => r.updateGateway(hidKey: k),
        ),
        Wrap(spacing: 8, children: [
          for (var g = 1; g <= 4; g++)
            ChoiceChip(
              label: Text('GPIO $g'),
              selected: r.gwHidGpio == g,
              onSelected: (_) => r.updateGateway(hidGpio: g),
            ),
        ]),
        _small('Die meisten Geräte nutzen GPIO 3.'),
      ],
      _DevicePicker(
        key: const ValueKey('gateway-audio-input'),
        title: 'Audio-Eingang (vom Funkgerät)',
        autoLabel: 'Standardgerät',
        loader: GatewayDevices.listInputs,
        value: r.gwInputId,
        onChanged: (k) => r.updateGateway(inputId: k),
      ),
      _small(
          'Audio-Ausgang (zum Funkgerät): das Standard-Wiedergabegerät des Systems. '
          'Unter Windows dort die USB-Soundkarte als Standard einstellen.'),
      _slider(
        'VOX-Schwelle (Funk → Netz)',
        '${(r.gwVoxThreshold * 100).round()} %',
        r.gwVoxThreshold,
        0.05,
        0.9,
        (v) => r.updateGateway(vox: v, save: false),
        r.saveSettings,
      ),
      if (r.gatewayEnabled)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: LinearProgressIndicator(
            value: r.audio.gwInLevel,
            minHeight: 6,
            color: CbColors.meterRed,
            backgroundColor: CbColors.displayDim,
          ),
        ),
      _slider(
        'VOX-Nachlauf',
        '${r.gwHangMs} ms',
        r.gwHangMs.toDouble(),
        200,
        1500,
        (v) => r.updateGateway(hang: v.round(), save: false),
        r.saveSettings,
      ),
      _slider(
        'Eingangspegel (Funkgerät → Netz)',
        '×${r.gwInGain.toStringAsFixed(2)}',
        r.gwInGain,
        0.25,
        4.0,
        (v) => r.updateGateway(inGain: v, save: false),
        r.saveSettings,
      ),
      _slider(
        'Ausgangspegel (Netz → Funkgerät)',
        '×${r.gwOutGain.toStringAsFixed(2)}',
        r.gwOutGain,
        0.25,
        2.0,
        (v) => r.updateGateway(outGain: v, save: false),
        r.saveSettings,
      ),
      _slider(
        isVox ? 'Weckton-Länge (Vorlauf)' : 'PTT-Vorlauf',
        '${r.gwPreMs} ms',
        r.gwPreMs.toDouble(),
        0,
        800,
        (v) => r.updateGateway(pre: v.round(), save: false),
        r.saveSettings,
      ),
      _slider(
        'PTT-Nachlauf',
        '${r.gwPostMs} ms',
        r.gwPostMs.toDouble(),
        100,
        800,
        (v) => r.updateGateway(post: v.round(), save: false),
        r.saveSettings,
      ),
      if (r.gatewayEnabled)
        OutlinedButton(
          onPressed: r.gatewayTest,
          style: OutlinedButton.styleFrom(
            foregroundColor: _lilac,
            side: const BorderSide(color: CbColors.textDim),
            shape: const StadiumBorder(),
          ),
          child: const Text('PTT-Test (1,5 s Ton senden)'),
        ),
    ];
  }

  // ---------- Aufbau ----------
  @override
  Widget build(BuildContext context) {
    final r = context.watch<RadioController>();
    final h = MediaQuery.sizeOf(context).height;
    final dialogMaxHeight = (h - 60).clamp(0.0, h).toDouble();

    final channels = CbChannels.gatewayChannels.join(', ');

    return Dialog(
      backgroundColor: const Color(0xFF26282C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(28)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 30),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: dialogMaxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
          child: Column(children: [
            const Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Text('Einstellungen', style: TextStyle(fontSize: 28)),
              ),
              Text('v${AppConfig.appVersion}',
                  style: TextStyle(color: CbColors.textDim, fontSize: 14)),
            ]),
            const SizedBox(height: 6),
            _hint('▲ Nach oben scrollen ▲', _up, () {
              _scrollTo(0);
            }),
            Expanded(
              child: ListView(
                controller: _sc,
                padding: EdgeInsets.zero,
                children: [
                  // ---- Funkgerät, Kanal und Audio ----
                  _heading('Kanäle & Rufname'),
                  _small('CB-Funk-Kanäle 1–80. Kanal 9 ist der Notrufkanal.',
                      color: CbColors.text),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _callSignController,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    maxLength: 12,
                    onChanged: r.setCallSign,
                    decoration: const InputDecoration(
                      labelText: 'Rufzeichen',
                      hintText: 'z. B. DO5VH / 13CT5',
                      counterText: '',
                    ),
                  ),

                  _heading('Audio & Schieberegler'),
                  _slider(
                    'Sendepegel (Modulation)',
                    '${(r.txLevel * 100).round()} % · +${(r.txLevel * 14).round()} dB',
                    r.txLevel,
                    0,
                    1,
                    r.setTxLevel,
                    r.saveSettings,
                  ),
                  _small('Standard: 50 % / +7 dB.'),
                  _slider(
                    'Mikrofon-Empfindlichkeit',
                    '×${r.micSensitivity.toStringAsFixed(2)}',
                    r.micSensitivity,
                    0.5,
                    2.0,
                    r.setMicSensitivity,
                    r.saveSettings,
                  ),
                  _small(
                      'Bei leiser Stimme oder größerem Mikrofonabstand erhöhen.'),
                  _slider(
                    'Lautstärke',
                    '${(r.volume * 100).round()} %',
                    r.volume,
                    0,
                    1,
                    r.setVolume,
                    r.saveSettings,
                  ),

                  _heading('Roger-Beep'),
                  for (var mode = 0; mode < _rogerBeepModes.length; mode++)
                    _radioRow(
                      label: _rogerBeepModes[mode],
                      selected: r.beepMode == mode,
                      onTap: () => r.setBeepMode(mode),
                    ),

                  _heading('Zusatzfunktionen'),
                  _switchRow(
                    'NB/ANL',
                    'Störimpulse und Rauschen reduzieren.',
                    r.noiseBlanker,
                    (_) => r.toggleNb(),
                  ),
                  _switchRow(
                    'Echo',
                    'Leichtes Echo auf der eigenen Aussendung.',
                    r.echo,
                    (_) => r.toggleEcho(),
                  ),
                  _switchRow(
                    'Papagei-Modus',
                    'Eigene Aussendung lokal wiedergeben; wird nicht über Funk gesendet.',
                    r.parrot,
                    r.setParrot,
                  ),
                  _switchRow(
                    'Realistische Reichweite (~1 km)',
                    'Standort-Umkreis. Die aktuelle MQTT-Schnittstelle überträgt noch keine Standortdaten; Gegenstellen müssen dies ebenfalls unterstützen.',
                    r.realisticRange,
                    r.setRealisticRange,
                  ),

                  // ---- Gateway ----
                  const Text('Gateway – echtes CB-Funkgerät',
                      style:
                          TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  _small(
                      'Verbindet ein echtes CB-Funkgerät mit der App: Was auf dem Funk '
                      'gesprochen wird, hören alle in der App – und umgekehrt.',
                      color: CbColors.text),
                  const SizedBox(height: 6),
                  OutlinedButton(
                    onPressed: _showGuide,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _lilac,
                      minimumSize: const Size.fromHeight(50),
                      side: const BorderSide(color: CbColors.textDim),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text('📖 Anleitungen für Anfänger',
                        style: TextStyle(fontSize: 16)),
                  ),
                  const SizedBox(height: 6),
                  _switchRow(
                    'Gateway einschalten',
                    'Nur Kanal $channels (41/61/71/80 nur FM)',
                    r.gatewayEnabled,
                    (v) {
                      final ok = r.setGatewayEnabled(v);
                      setState(() => _gwHint = ok
                          ? null
                          : 'Auf Kanal ${r.channel} (${r.modulation.label}) ist der '
                              'Gateway nicht erlaubt. Wähle einen der genannten Kanäle, '
                              'bei 41/61/71/80 mit FM.');
                    },
                  ),
                  if (_gwHint != null)
                    _small(_gwHint!, color: CbColors.accentRed),
                  const SizedBox(height: 8),
                  const Text('Anschlussart', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 4),
                  for (final m in GatewayMode.values)
                    _radioRow(
                      label: m.label,
                      selected: r.gatewayMode == m,
                      onTap: () => r.setGatewayMode(m),
                      onHelp: () => _showHelp(m),
                    ),

                  ..._gatewayTuning(r),

                  // ---- Sendetaste & Mikrofon ----
                  _heading('Sendetaste & Mikrofon'),
                  _keyRow(r, KeyAction.ptt, 'Angelernte Taste'),
                  _switchRow(
                    'Umschalten statt Halten',
                    'Einmal drücken = senden, nochmal = hören. Praktisch für Bluetooth-Knöpfe.',
                    r.toggleInsteadOfHold,
                    r.setToggleInsteadOfHold,
                  ),
                  _switchRow(
                    'Headset-/Bluetooth-Taste sendet',
                    'Taste am Kabel-Headset oder Bluetooth-PTT-Knopf.',
                    r.headsetButtonPtt,
                    r.setHeadsetButtonPtt,
                  ),
                  _switchRow(
                    'Leiser-Taste sendet',
                    'Lautstärke-runter als PTT (nicht bei Funkgeräten mit Lautstärkeknopf).',
                    r.volumeDownPtt,
                    r.setVolumeDownPtt,
                  ),
                  _switchRow(
                    'Externes Mikrofon bevorzugen',
                    'Aktuell: ${r.micLabel}',
                    r.preferExternalMic,
                    r.setPreferExternalMic,
                  ),
                  _small(
                      'Zello-/PoC-Funkgeräte (Inrico, Runbo, Sonim, …): die automatische '
                      'Erkennung über das PTT-Signal folgt mit der Android-Anbindung.'),

                  // ---- Tasten ----
                  _heading('Tasten (Funkgeräte ohne Touch)'),
                  _small(
                      'Standard am PC: Pfeil ↑↓ Kanal · Pfeil ←→ Squelch (oder Lautstärke, '
                      'siehe „Regler wechseln“) · Enter Betriebsart · * Suchlauf · # Kanal 9. '
                      'Angelernte Tasten haben Vorrang.',
                      color: CbColors.text),
                  const SizedBox(height: 4),
                  const Text('Eigene Tasten anlernen (P1, P2, Seitentasten …):',
                      style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 4),
                  for (final a in KeyAction.values)
                    if (a != KeyAction.ptt) _keyRow(r, a, a.label),

                  // ---- Antenne ----
                  _heading('Antenne'),
                  _small(
                      'Wirkt sofort auf den Signalpegel, der über den Server gesendet '
                      'und von dir empfangen wird.'),
                  for (final a in Antenna.values)
                    _radioRow(
                      label: a.title,
                      selected: r.antenna == a,
                      onTap: () => r.setAntenna(a),
                    ),

                  if (r.isAndroid) ...[
                    _heading('System'),
                    _small(
                      'Hintergrunddienst: ${!r.systemStatusLoaded ? 'Status wird geprüft' : r.backgroundServiceRunning ? 'Aktiv' : 'Inaktiv'}',
                      color: r.backgroundServiceRunning
                          ? CbColors.online
                          : CbColors.text,
                    ),
                    _small(
                      'Akkuoptimierung: ${!r.systemStatusLoaded ? 'Status wird geprüft' : r.batteryOptimizationIgnored ? 'Für CB-Funk deaktiviert' : 'Aktiv; Android kann Hintergrundaktivität begrenzen'}',
                      color:
                          !r.systemStatusLoaded || r.batteryOptimizationIgnored
                              ? CbColors.textDim
                              : CbColors.accentRed,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: r.openBatteryOptimizationSettings,
                        icon:
                            const Icon(Icons.battery_saver_outlined, size: 18),
                        label: const Text('Akku-Einstellungen öffnen'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
            _hint('▼ Mehr Einstellungen unten ▼', _down, () {
              if (_sc.hasClients) _scrollTo(_sc.position.maxScrollExtent);
            }),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Fertig',
                    style: TextStyle(
                        color: _lilac,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Auswahlliste (Dropdown) mit Neu-Laden-Knopf
class _DevicePicker extends StatefulWidget {
  const _DevicePicker({
    super.key,
    required this.title,
    required this.autoLabel,
    required this.loader,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String autoLabel;
  final Future<List<DeviceInfo>> Function() loader;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<_DevicePicker> {
  List<DeviceInfo>? _devices;
  bool _loading = false;

  Future<void> _loadDevices() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final devices = await widget.loader();
      if (mounted) setState(() => _devices = devices);
    } catch (_) {
      if (mounted) setState(() => _devices = const []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = _devices ?? const <DeviceInfo>[];
    final keys = devices.map((d) => d.key).toSet();
    final current = keys.contains(widget.value) ? widget.value : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(widget.title, style: const TextStyle(fontSize: 15))),
          IconButton(
            tooltip: _loading ? 'Geräte werden geladen' : 'Geräteliste laden',
            visualDensity: VisualDensity.compact,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 20, color: CbColors.textDim),
            onPressed: _loading ? null : _loadDevices,
          ),
        ]),
        DropdownButton<String>(
          isExpanded: true,
          value: current,
          dropdownColor: const Color(0xFF30333A),
          items: [
            DropdownMenuItem(value: '', child: Text(widget.autoLabel)),
            for (final d in devices)
              DropdownMenuItem(
                value: d.key,
                child: Text(d.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => widget.onChanged(v ?? ''),
        ),
        if (_devices == null)
          const Text(
            'Geräteliste bei Bedarf über ↻ laden.',
            style: TextStyle(fontSize: 11, color: CbColors.textDim),
          )
        else if (!_loading && devices.isEmpty)
          const Text(
            'Keine Geräte gefunden.',
            style: TextStyle(fontSize: 11, color: CbColors.textDim),
          ),
      ]),
    );
  }
}
