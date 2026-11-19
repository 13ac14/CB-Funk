import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/audio_engine.dart';
import '../data/cb_channels.dart';
import '../gateway/ptt_driver.dart';
import '../models/enums.dart';
import '../models/key_action.dart';
import '../services/app_logger.dart';
import '../services/mqtt_service.dart';
import 'key_bindings.dart';

/// Zentraler Zustand des Funkgeraets (Display, Regler, Tasten, Einstellungen).
class RadioController extends ChangeNotifier
    with WidgetsBindingObserver
    implements RadioAudioState {
  RadioController(this.mqtt) {
    WidgetsBinding.instance.addObserver(this);
    mqtt.addListener(notifyListeners);
    audio = AudioEngine(mqtt, this)
      ..onLevel = _onLevel
      ..onStatus = _changed
      ..onScanHit = _onScanHit;
    HardwareKeyboard.instance.addHandler(_handleKey);
    _watchdogTimer = Timer.periodic(
      Duration(
        seconds: defaultTargetPlatform == TargetPlatform.windows ? 3 : 15,
      ),
      (_) => unawaited(_runWatchdog()),
    );
  }

  final MqttService mqtt;
  static const MethodChannel _backgroundAudioChannel = MethodChannel(
    'de.cbfunk/background_audio',
  );
  bool systemStatusLoaded = false;
  bool backgroundServiceRunning = false;
  bool batteryOptimizationIgnored = false;
  bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;
  late final AudioEngine audio;
  final KeyBindings keys = KeyBindings();

  /// Wird von main.dart gesetzt (oeffnet den Einstellungsdialog)
  VoidCallback? onOpenMenu;

  /// true solange der Einstellungsdialog offen ist (Standardtasten pausieren)
  bool dialogOpen = false;
  Timer? _watchdogTimer;
  bool _watchdogRunning = false;
  final ValueNotifier<double> sMeterListenable = ValueNotifier<double>(0);
  double _lastPublishedSMeter = 0;
  DateTime _lastSMeterPublish = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  int get antennaDb => antenna.db;
  String? get audioError => audio.error;
  int get stationsOnChannel => mqtt.stationCount;

  void _onLevel(double v) {
    sMeter = v;
    final oldStep = (_lastPublishedSMeter * 13).round();
    final newStep = (v * 13).round();
    final rxChanged = (v > 0.05) != (_lastPublishedSMeter > 0.05);
    if (oldStep == newStep && !rxChanged) return;

    final now = DateTime.now();
    final isSilent = v <= 0.001;
    if (!isSilent &&
        now.difference(_lastSMeterPublish) < const Duration(milliseconds: 80)) {
      return;
    }
    _lastPublishedSMeter = v;
    _lastSMeterPublish = now;
    sMeterListenable.value = v;
  }

  @override
  bool power = true;
  @override
  int channel = 11;
  @override
  Modulation modulation = Modulation.fm;

  // Regler 0.0 .. 1.0
  @override
  double volume = 0.6;
  @override
  double squelch = 0.3;
  @override
  double rfGain = 0.8;
  @override
  double clarifier = 0.5; // 0.5 = Mitte
  @override
  double micSensitivity = 1.0;
  double txLevel = 0.5;

  // Tasten / Funktionen
  @override
  bool scanning = false;
  @override
  bool parrot = false; // PAPAGEI
  @override
  bool noiseBlanker = false; // NB/ANL
  @override
  bool echo = false;

  /// Roger-Beep: 0 = aus, 1..5 = Signalvarianten
  @override
  int beepMode = 1;
  bool get beep => beepMode != 0;

  /// Pfeiltasten links/rechts regeln Lautstaerke (true) oder Squelch (false)
  bool leftRightIsVolume = false;

  // Status
  @override
  bool transmitting = false;
  double sMeter = 0.0; // 0..1 (S1..S9+40dB; beim Senden/Papagei: Mikrofonpegel)

  // ---- Einstellungen (werden gespeichert) ----
  Antenna antenna = Antenna.mobil;
  String callSign = '';
  @override
  bool realisticRange = false;
  @override
  bool gatewayEnabled = false;
  @override
  GatewayMode gatewayMode = GatewayMode.voxRadio;
  bool toggleInsteadOfHold = false;
  bool headsetButtonPtt = true;
  bool volumeDownPtt = false;
  bool preferExternalMic = true;

  // ---- Gateway-Feineinstellungen (werden gespeichert) ----
  @override
  double gwVoxThreshold = 0.35;
  @override
  int gwHangMs = 700;
  @override
  double gwInGain = 1.0;
  @override
  double gwOutGain = 1.0;
  @override
  int gwPreMs = 200;
  @override
  int gwPostMs = 300;
  String gwSerialPort = '';
  bool gwUseDtr = false; // false = RTS
  String gwHidKey = '';
  int gwHidGpio = 3;
  String gwInputId = '';

  bool get externalMicActive => false;
  String get micLabel =>
      externalMicActive ? 'Externes Mikrofon' : 'Eingebautes Mikrofon';

  /// Zweite Statuszeile unter dem Display
  String get statusDetail {
    final e = audio.error;
    if (e != null) return e;
    if (gatewayEnabled) {
      return '${audio.gwInfo} · Eingang ${(audio.gwInLevel * 100).round()} % '
          '(Schwelle ${(gwVoxThreshold * 100).round()} %)';
    }
    if (parrot) {
      return 'Papagei: PTT halten, sprechen, loslassen – du hörst dich selbst · '
          'Sendepegel ${(audio.txGain * 100).round()} % (◄► regelt)';
    }
    return '${sMeter > 0.05 ? 'Signal' : 'Band ruhig'} · $micLabel';
  }

  /// Clarifier nur bei SSB aktiv (bei FM/AM ausgegraut).
  @override
  bool get clarifierActive =>
      modulation == Modulation.usb || modulation == Modulation.lsb;

  double get frequencyMHz => CbChannels.frequency(channel);

  bool get gatewayAllowed =>
      CbChannels.gatewayChannels.contains(channel) &&
      (!CbChannels.gatewayFmOnly.contains(channel) ||
          modulation == Modulation.fm);

  void _changed() => notifyListeners();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.resumed) {
      unawaited(_setBackgroundAudio(power));
    }
    if (state == AppLifecycleState.resumed && power) {
      unawaited(_recoverAfterResume());
    }
  }

  Future<void> _recoverAfterResume() async {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      audio.requestOutputHealthCheck();
    }
    await _runWatchdog();
    await refreshSystemStatus();
  }

  Future<void> _runWatchdog() async {
    if (!power || _watchdogRunning) return;
    _watchdogRunning = true;
    try {
      if (!mqtt.transportConnected || mqtt.state != LinkState.online) {
        AppLogger.warn(
          'WATCHDOG',
          'MQTT nicht online (transportConnected: ${mqtt.transportConnected}, state: ${mqtt.state}), veranlasse Reconnect...',
        );
        await mqtt.reconnectIfDisconnected().timeout(const Duration(seconds: 12));
      }
      if (power && audio.needsOutputRecovery) {
        AppLogger.warn('WATCHDOG', 'Audio-Ausgabe erfordert Wiederherstellung');
        await audio.recoverOutput().timeout(const Duration(seconds: 10));
      }
    } catch (e, st) {
      AppLogger.error('WATCHDOG', 'Ausnahme im Watchdog-Zyklus: $e', e, st);
    } finally {
      _watchdogRunning = false;
    }
  }

  Future<void> _setBackgroundAudio(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _backgroundAudioChannel.invokeMethod<void>(
        enabled ? 'start' : 'stop',
      );
    } catch (_) {}
    await refreshSystemStatus();
  }

  Future<void> refreshSystemStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      systemStatusLoaded = true;
      _changed();
      return;
    }
    try {
      final status = await _backgroundAudioChannel
          .invokeMapMethod<String, dynamic>('status');
      backgroundServiceRunning = status?['serviceRunning'] == true;
      batteryOptimizationIgnored =
          status?['batteryOptimizationIgnored'] == true;
      systemStatusLoaded = true;
      _changed();
    } catch (_) {
      systemStatusLoaded = false;
      _changed();
    }
  }

  Future<void> openBatteryOptimizationSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _backgroundAudioChannel.invokeMethod<void>('openBatterySettings');
    } catch (_) {}
  }

  Timer? _saveTimer;

  /// Regler/Kanal nach kurzer Ruhe speichern (nicht bei jedem Ziehen)
  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _save);
  }

  T _readPreference<T>(SharedPreferences preferences, String key, T fallback) {
    try {
      final value = preferences.get(key);
      if (value == null) return fallback;
      if (value is T) return value as T;
    } catch (_) {}

    try {
      if (preferences.containsKey(key)) {
        unawaited(preferences.remove(key).catchError((Object _) => false));
      }
    } catch (_) {}
    return fallback;
  }

  // ---------- Speichern / Laden ----------
  Future<void> loadSettings() async {
    SharedPreferences p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      _finishLoadingSettings();
      return;
    }

    antenna = Antenna
        .values[(_readPreference<int>(p, 'antenna', antenna.index)).clamp(
      0,
      Antenna.values.length - 1,
    )];
    gatewayMode = GatewayMode.values[(_readPreference<int>(
      p,
      'gatewayMode',
      gatewayMode.index,
    )).clamp(
      0,
      GatewayMode.values.length - 1,
    )];
    gatewayEnabled = _readPreference<bool>(p, 'gatewayEnabled', false);
    toggleInsteadOfHold =
        _readPreference<bool>(p, 'toggleInsteadOfHold', false);
    headsetButtonPtt = _readPreference<bool>(p, 'headsetButtonPtt', true);
    volumeDownPtt = _readPreference<bool>(p, 'volumeDownPtt', false);
    preferExternalMic = _readPreference<bool>(p, 'preferExternalMic', true);
    beepMode = _readPreference<int>(p, 'beepMode', 1).clamp(0, 5);
    parrot = _readPreference<bool>(p, 'parrot', false);
    callSign = _readPreference<String>(p, 'callSign', '');
    realisticRange = _readPreference<bool>(p, 'realisticRange', false);
    gwVoxThreshold =
        _readPreference<double>(p, 'gwVox', 0.35).clamp(0.05, 0.9).toDouble();
    gwHangMs = _readPreference<int>(p, 'gwHang', 700).clamp(200, 1500);
    gwInGain =
        _readPreference<double>(p, 'gwIn', 1.0).clamp(0.25, 4.0).toDouble();
    gwOutGain =
        _readPreference<double>(p, 'gwOut', 1.0).clamp(0.25, 2.0).toDouble();
    gwPreMs = _readPreference<int>(p, 'gwPre', 200).clamp(0, 800);
    gwPostMs = _readPreference<int>(p, 'gwPost', 300).clamp(100, 800);
    gwSerialPort = _readPreference<String>(p, 'gwSerial', '');
    gwUseDtr = _readPreference<bool>(p, 'gwDtr', false);
    gwHidKey = _readPreference<String>(p, 'gwHid', '');
    gwHidGpio = _readPreference<int>(p, 'gwGpio', 3).clamp(1, 4);
    gwInputId = _readPreference<String>(p, 'gwInput', '');
    for (final a in KeyAction.values) {
      final id = _readPreference<int?>(p, 'key_${a.name}', null);
      if (id != null) keys.set(a, id);
    }
    channel =
        _readPreference<int>(p, 'channel', channel).clamp(1, CbChannels.count);
    modulation = Modulation.values[(_readPreference<int>(p, 'mod', 0)).clamp(
      0,
      Modulation.values.length - 1,
    )];
    volume =
        _readPreference<double>(p, 'volume', volume).clamp(0.0, 1.0).toDouble();
    squelch = _readPreference<double>(p, 'squelch', squelch)
        .clamp(0.0, 1.0)
        .toDouble();
    rfGain =
        _readPreference<double>(p, 'rfGain', rfGain).clamp(0.0, 1.0).toDouble();
    clarifier = _readPreference<double>(p, 'clarifier', clarifier)
        .clamp(0.0, 1.0)
        .toDouble();
    txLevel = _readPreference<double>(p, 'txLevel', txLevel)
        .clamp(0.0, 1.0)
        .toDouble();
    audio.txGain = 0.5 + txLevel;
    micSensitivity = _readPreference<double>(
      p,
      'micSensitivity',
      micSensitivity,
    ).clamp(0.5, 2.0).toDouble();
    echo = _readPreference<bool>(p, 'echo', false);
    noiseBlanker = _readPreference<bool>(p, 'nb', false);
    _finishLoadingSettings();
  }

  void _finishLoadingSettings() {
    try {
      audio.txGain = 0.5 + txLevel;
      mqtt.joinChannel(channel);
      _enforceGateway();
      _changed();
      unawaited(_setBackgroundAudio(power));
      if (gatewayEnabled) _queueGateway();
    } catch (e, st) {
      AppLogger.error('SETTINGS', 'Fehler in _finishLoadingSettings: $e', e, st);
    }
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt('antenna', antenna.index);
      await p.setInt('gatewayMode', gatewayMode.index);
      await p.setBool('gatewayEnabled', gatewayEnabled);
      await p.setBool('toggleInsteadOfHold', toggleInsteadOfHold);
      await p.setBool('headsetButtonPtt', headsetButtonPtt);
      await p.setBool('volumeDownPtt', volumeDownPtt);
      await p.setBool('preferExternalMic', preferExternalMic);
      await p.setInt('beepMode', beepMode);
      await p.setBool('parrot', parrot);
      await p.setString('callSign', callSign);
      await p.setBool('realisticRange', realisticRange);
      await p.setInt('channel', channel);
      await p.setInt('mod', modulation.index);
      await p.setDouble('volume', volume);
      await p.setDouble('squelch', squelch);
      await p.setDouble('rfGain', rfGain);
      await p.setDouble('clarifier', clarifier);
      await p.setDouble('txLevel', txLevel);
      await p.setDouble('micSensitivity', micSensitivity);
      await p.setBool('echo', echo);
      await p.setBool('nb', noiseBlanker);
      await p.setDouble('gwVox', gwVoxThreshold);
      await p.setInt('gwHang', gwHangMs);
      await p.setDouble('gwIn', gwInGain);
      await p.setDouble('gwOut', gwOutGain);
      await p.setInt('gwPre', gwPreMs);
      await p.setInt('gwPost', gwPostMs);
      await p.setString('gwSerial', gwSerialPort);
      await p.setBool('gwDtr', gwUseDtr);
      await p.setString('gwHid', gwHidKey);
      await p.setInt('gwGpio', gwHidGpio);
      await p.setString('gwInput', gwInputId);
      for (final a in KeyAction.values) {
        final id = keys.idFor(a);
        if (id == null) {
          await p.remove('key_${a.name}');
        } else {
          await p.setInt('key_${a.name}', id);
        }
      }
    } catch (_) {
      // Keep transient storage failures from escaping a UI timer/input callback.
    }
  }

  // ---------- Einstellungs-Setter ----------
  void setAntenna(Antenna a) {
    antenna = a;
    _save();
    _changed();
  }

  void setCallSign(String value) {
    callSign = value.trim().toUpperCase();
    _saveSoon();
  }

  void setRealisticRange(bool value) {
    realisticRange = value;
    _save();
    _changed();
  }

  void setTxLevel(double value) {
    txLevel = value.clamp(0.0, 1.0).toDouble();
    audio.txGain = 0.5 + txLevel;
    _saveSoon();
    _changed();
  }

  void setMicSensitivity(double value) {
    micSensitivity = value.clamp(0.5, 2.0).toDouble();
    _saveSoon();
    _changed();
  }

  void setParrot(bool value) {
    if (!power || gatewayEnabled) return;
    if (transmitting) pttUp();
    parrot = value;
    if (parrot) _stopScan();
    audio.flush();
    _save();
    _changed();
  }

  void setGatewayMode(GatewayMode m) {
    gatewayMode = m;
    AppLogger.info('GATEWAY', 'Gateway-Modus gesetzt: ${m.name}');
    _save();
    _changed();
    if (gatewayEnabled) _queueGateway();
  }

  bool setGatewayEnabled(bool v) {
    if (v && !gatewayAllowed) return false;
    gatewayEnabled = v;
    AppLogger.info('GATEWAY', 'Gateway aktiviert: $v (Modus: ${gatewayMode.name})');
    _save();
    _changed();
    _queueGateway();
    return true;
  }

  void _enforceGateway() {
    if (gatewayEnabled && !gatewayAllowed) {
      gatewayEnabled = false;
      _save();
      _queueGateway();
    }
  }

  void setToggleInsteadOfHold(bool v) {
    toggleInsteadOfHold = v;
    if (transmitting) pttUp();
    _save();
    _changed();
  }

  void setHeadsetButtonPtt(bool v) {
    headsetButtonPtt = v;
    _save();
    _changed();
  }

  void setVolumeDownPtt(bool v) {
    volumeDownPtt = v;
    _save();
    _changed();
  }

  void setPreferExternalMic(bool v) {
    preferExternalMic = v;
    _save();
    _changed();
  }

  void setBeepMode(int value) {
    beepMode = value.clamp(0, 5).toInt();
    _save();
    _changed();
  }

  void bindKey(KeyAction a, int keyId) {
    keys.set(a, keyId);
    _save();
    _changed();
  }

  void unbindKey(KeyAction a) {
    keys.clear(a);
    _save();
    _changed();
  }

  // ---------- Bedienung ----------
  void togglePower() {
    power = !power;
    AppLogger.info('RADIO', 'Power umgeschaltet: ${power ? "EIN" : "AUS"}');
    if (!power) {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      unawaited(_setBackgroundAudio(false));
      if (transmitting) pttUp();
      _stopScan();
      parrot = false;
      audio.flush();
      sMeter = 0;
      _onLevel(0);
      mqtt.disconnect();
    } else {
      _watchdogTimer ??= Timer.periodic(
        Duration(seconds: defaultTargetPlatform == TargetPlatform.windows ? 3 : 15),
        (_) => unawaited(_runWatchdog()),
      );
      mqtt.connect();
      mqtt.joinChannel(channel);
      unawaited(_setBackgroundAudio(true));
    }
    _queueGateway();
    _changed();
  }

  void setChannel(int ch) {
    if (!power) return;
    if (scanning) _stopScan(); // Kanaltaste beendet den Suchlauf
    final old = channel;
    channel =
        ((ch - 1) % CbChannels.count + CbChannels.count) % CbChannels.count + 1;
    if (old != channel) {
      AppLogger.info('RADIO', 'Kanal gewechselt: $old -> $channel');
      if (transmitting) pttUp();
      audio.flush();
      mqtt.joinChannel(channel);
    }
    _saveSoon();
    _enforceGateway();
    _changed();
  }

  void channelUp() => setChannel(channel + 1);
  void channelDown() => setChannel(channel - 1);
  void channel9() => setChannel(9);
  void channel19() => setChannel(19);

  void cycleModulation() {
    if (!power) return;
    modulation = modulation.next;
    AppLogger.info('RADIO', 'Modulation umgeschaltet: ${modulation.name}');
    audio.flush();
    _saveSoon();
    _enforceGateway();
    _changed();
  }

  void setModulation(Modulation m) {
    if (modulation == m) return;
    modulation = m;
    AppLogger.info('RADIO', 'Modulation gesetzt: ${modulation.name}');
    audio.flush();
    _saveSoon();
    _enforceGateway();
    _changed();
  }

  void setVolume(double v) {
    volume = v.clamp(0.0, 1.0).toDouble();
    _saveSoon();
    _changed();
  }

  void setSquelch(double v) {
    squelch = v.clamp(0.0, 1.0).toDouble();
    _saveSoon();
    _changed();
  }

  void setRfGain(double v) {
    rfGain = v.clamp(0.0, 1.0).toDouble();
    _saveSoon();
    _changed();
  }

  void setClarifier(double v) {
    clarifier = v.clamp(0.0, 1.0).toDouble();
    _saveSoon();
    _changed();
  }

  void toggleNb() {
    noiseBlanker = !noiseBlanker;
    _saveSoon();
    _changed();
  }

  void toggleEcho() {
    echo = !echo;
    _saveSoon();
    _changed();
  }

  /// BEEP-Taste: aus -> Pip -> Doppelton -> Quindar -> aus
  void cycleBeep() {
    beepMode = (beepMode + 1) % 6;
    _save();
    _changed();
  }

  // ---------- Gateway ----------
  PttDriver? _ptt;
  Future<void> _gwOp = Future<void>.value();

  void _queueGateway() {
    _gwOp = _gwOp.then((_) => _applyGateway()).catchError((Object _) {});
  }

  void _updateWakelock() {
    try {
      WakelockPlus.toggle(enable: gatewayEnabled && power);
    } catch (_) {}
  }

  Future<void> _applyGateway() async {
    _updateWakelock();
    AppLogger.info(
      'GATEWAY',
      '_applyGateway: aktiv=$gatewayEnabled, power=$power, modus=${gatewayMode.name}',
    );
    try {
      await audio.stopGateway().timeout(const Duration(seconds: 2));
    } catch (e) {
      AppLogger.warn('GATEWAY', 'Fehler beim Stoppen des alten Gateways: $e');
    }
    final old = _ptt;
    _ptt = null;
    audio.ptt = null;
    try {
      await old?.close();
    } catch (_) {}
    if (!gatewayEnabled || !power) {
      _changed();
      return;
    }
    if (transmitting) pttUp();
    parrot = false;
    _stopScan();
    try {
      final d = PttDriverFactory.create(
        mode: gatewayMode,
        serialPort: gwSerialPort,
        useDtr: gwUseDtr,
        hidKey: gwHidKey,
        hidGpio: gwHidGpio,
      );
      if (d != null) {
        try {
          await d.open().timeout(const Duration(seconds: 3));
          AppLogger.info('GATEWAY', 'PTT-Treiber geöffnet (${gatewayMode.name})');
          _ptt = d;
          audio.ptt = d;
          audio.setError(null);
        } catch (e, st) {
          AppLogger.error('GATEWAY', 'Fehler beim Öffnen des PTT-Treibers: $e', e, st);
          audio.setError('Gateway: $e');
        }
      }
    } catch (e, st) {
      AppLogger.error('GATEWAY', 'Fehler bei PttDriverFactory: $e', e, st);
    }

    try {
      await audio.startGateway(inputId: gwInputId).timeout(const Duration(seconds: 6));
    } catch (e, st) {
      AppLogger.error('GATEWAY', 'Fehler beim Starten von audio.startGateway: $e', e, st);
      audio.setError('Gateway-Audio: $e');
    }
    _changed();
  }

  void updateGateway({
    double? vox,
    int? hang,
    double? inGain,
    double? outGain,
    int? pre,
    int? post,
    String? serialPort,
    bool? useDtr,
    String? hidKey,
    int? hidGpio,
    String? inputId,
    bool save = true,
  }) {
    if (vox != null) gwVoxThreshold = vox;
    if (hang != null) gwHangMs = hang;
    if (inGain != null) gwInGain = inGain;
    if (outGain != null) gwOutGain = outGain;
    if (pre != null) gwPreMs = pre;
    if (post != null) gwPostMs = post;
    if (serialPort != null) gwSerialPort = serialPort;
    if (useDtr != null) gwUseDtr = useDtr;
    if (hidKey != null) gwHidKey = hidKey;
    if (hidGpio != null) gwHidGpio = hidGpio;
    if (inputId != null) gwInputId = inputId;
    if (save) _save();
    final restart = serialPort != null ||
        useDtr != null ||
        hidKey != null ||
        hidGpio != null ||
        inputId != null;
    if (restart && gatewayEnabled) _queueGateway();
    _changed();
  }

  void saveSettings() => _save();
  void gatewayTest() => audio.gatewayTest();

  // ---------- Papagei ----------
  void toggleParrot() {
    setParrot(!parrot);
  }

  // ---------- Suchlauf ----------
  Timer? _scanTimer;
  DateTime _scanHold = DateTime.fromMillisecondsSinceEpoch(0);

  void toggleScan() {
    if (!power || gatewayEnabled) return;
    if (scanning) {
      _stopScan();
    } else {
      if (parrot) parrot = false;
      if (transmitting) pttUp();
      scanning = true;
      _scanHold = DateTime.now();
      mqtt.setScan(true);
      _scanTimer = Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => _scanTick(),
      );
    }
    _changed();
  }

  void _stopScan() {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (scanning) {
      scanning = false;
      mqtt.setScan(false);
    }
  }

  void _scanTick() {
    if (!power || transmitting || parrot) return;
    final now = DateTime.now();
    if (audio.rxActive) _scanHold = now.add(const Duration(seconds: 3));
    if (now.isBefore(_scanHold)) return; // Signal gefunden: kurz verweilen
    channel = channel % CbChannels.count + 1;
    mqtt.joinChannel(channel);
    _changed();
  }

  void _onScanHit(int ch) {
    if (!scanning || transmitting) return;
    channel = ch;
    mqtt.joinChannel(ch);
    audio.flush();
    _scanHold = DateTime.now().add(const Duration(seconds: 3));
    _enforceGateway();
    _changed();
  }

  // ---------- PTT ----------
  void pttPress() {
    if (toggleInsteadOfHold) {
      transmitting ? pttUp() : pttDown();
    } else {
      pttDown();
    }
  }

  void pttRelease() {
    if (!toggleInsteadOfHold) pttUp();
  }

  void pttDown() {
    if (!power || transmitting || gatewayEnabled) return;
    if (scanning) _stopScan();
    transmitting = true;
    sMeter = 0;
    _onLevel(0);
    audio.flush();
    if (!parrot) mqtt.publishPtt(channel, true, antenna.db);
    _changed();
    unawaited(audio.startTx());
  }

  void pttUp() {
    if (!transmitting) return;
    transmitting = false;
    audio.stopTx();
    if (!parrot) mqtt.publishPtt(channel, false, antenna.db);
    _changed();
  }

  // ---------- Tasten ----------
  void _leftRight(int dir) {
    if (parrot) {
      setTxLevel(txLevel + 0.1 * dir);
    } else if (leftRightIsVolume) {
      setVolume(volume + 0.05 * dir);
    } else {
      setSquelch(squelch + 0.05 * dir);
    }
  }

  void runAction(KeyAction a) {
    if (!power && a != KeyAction.powerToggle && a != KeyAction.menu) return;
    switch (a) {
      case KeyAction.ptt:
        break;
      case KeyAction.parrot:
        toggleParrot();
      case KeyAction.switchKnob:
        leftRightIsVolume = !leftRightIsVolume;
        _changed();
      case KeyAction.scan:
        toggleScan();
      case KeyAction.channel9:
        channel9();
      case KeyAction.channel19:
        channel19();
      case KeyAction.mode:
        cycleModulation();
      case KeyAction.channelUp:
        channelUp();
      case KeyAction.channelDown:
        channelDown();
      case KeyAction.volumeUp:
        setVolume(volume + 0.05);
      case KeyAction.volumeDown:
        setVolume(volume - 0.05);
      case KeyAction.squelchUp:
        setSquelch(squelch + 0.05);
      case KeyAction.squelchDown:
        setSquelch(squelch - 0.05);
      case KeyAction.txLevelUp:
        setTxLevel(txLevel + 0.05);
      case KeyAction.txLevelDown:
        setTxLevel(txLevel - 0.05);
      case KeyAction.echo:
        toggleEcho();
      case KeyAction.rogerBeep:
        cycleBeep();
      case KeyAction.powerToggle:
        togglePower();
      case KeyAction.menu:
        onOpenMenu?.call();
    }
  }

  bool _handleKey(KeyEvent e) {
    final k = e.logicalKey;

    if (keys.isLearning) {
      if (e is KeyDownEvent) keys.completeLearn(k.keyId);
      return true;
    }

    final down = e is KeyDownEvent;
    final repeat = e is KeyRepeatEvent;

    final a = keys.actionFor(k.keyId);
    if (a != null) {
      if (a == KeyAction.ptt) {
        if (down) pttPress();
        if (e is KeyUpEvent) pttRelease();
      } else if (down ||
          (repeat &&
              (a == KeyAction.volumeUp ||
                  a == KeyAction.volumeDown ||
                  a == KeyAction.squelchUp ||
                  a == KeyAction.squelchDown ||
                  a == KeyAction.txLevelUp ||
                  a == KeyAction.txLevelDown))) {
        runAction(a);
      }
      return true;
    }

    final isHeadset = k == LogicalKeyboardKey.headsetHook ||
        k == LogicalKeyboardKey.mediaPlayPause;
    if ((headsetButtonPtt && isHeadset) ||
        (volumeDownPtt && k == LogicalKeyboardKey.audioVolumeDown)) {
      if (down) pttPress();
      if (e is KeyUpEvent) pttRelease();
      return true;
    }

    if (dialogOpen || !power) return false;
    if (down || repeat) {
      if (k == LogicalKeyboardKey.arrowUp) {
        channelUp();
        return true;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        channelDown();
        return true;
      }
      if (k == LogicalKeyboardKey.arrowLeft) {
        _leftRight(-1);
        return true;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _leftRight(1);
        return true;
      }
    }
    if (down) {
      if (k == LogicalKeyboardKey.enter) {
        cycleModulation();
        return true;
      }
      if (k == LogicalKeyboardKey.asterisk) {
        toggleScan();
        return true;
      }
      if (k == LogicalKeyboardKey.numberSign) {
        channel9();
        return true;
      }
    }
    return false;
  }

  void updateSettings(void Function() change) {
    change();
    _changed();
  }

  @override
  void dispose() {
    AppLogger.info('RADIO', 'RadioController dispose() aufgerufen');
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_setBackgroundAudio(false));
    _watchdogTimer?.cancel();
    _scanTimer?.cancel();
    _saveTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    audio.dispose();
    mqtt.removeListener(notifyListeners);
    sMeterListenable.dispose();
    AppLogger.close();
    super.dispose();
  }
}
