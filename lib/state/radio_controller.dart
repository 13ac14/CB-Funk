import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/audio_engine.dart';
import '../audio/audio_packet.dart';
import '../config/app_config.dart';
import '../data/cb_channels.dart';
import '../gateway/ptt_driver.dart';
import '../models/enums.dart';
import '../models/key_action.dart';
import '../services/app_logger.dart';
import '../services/aprs/aprs_service.dart';
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
      ..onScanHit = _onScanHit
      ..onDigitalSamples = (frame) {
        if (!_digitalSamples.isClosed) _digitalSamples.add(frame);
      };
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
  final StreamController<DigitalPcmFrame> _digitalSamples =
      StreamController<DigitalPcmFrame>.broadcast();
  Stream<DigitalPcmFrame> get digitalPcmStream => _digitalSamples.stream;
  bool _digitalTransmitActive = false;
  int _digitalTransmitToken = 0;
  Completer<void>? _digitalTransmitCancelled;
  double _smoothedSMeter = 0;
  double _lastPublishedSMeter = 0;
  bool _rxIndicator = false;
  bool _lastPublishedRxIndicator = false;
  DateTime _lastSMeterPublish = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  int get antennaDb => antenna.db;
  String? get audioError => audio.error;
  int get stationsOnChannel => mqtt.stationCount;
  bool get rxIndicator => _rxIndicator;

  void _onLevel(double v) {
    final level = v.clamp(0.0, 1.0).toDouble();
    final smoothing = level > _smoothedSMeter ? 0.45 : 0.14;
    _smoothedSMeter += (level - _smoothedSMeter) * smoothing;
    if (_smoothedSMeter < 0.005) _smoothedSMeter = 0;
    sMeter = _smoothedSMeter;

    if (!_rxIndicator && sMeter >= 0.08) {
      _rxIndicator = true;
    } else if (_rxIndicator && sMeter <= 0.035) {
      _rxIndicator = false;
    }

    final oldStep = (_lastPublishedSMeter * 13).round();
    final newStep = (sMeter * 13).round();
    final rxChanged = _rxIndicator != _lastPublishedRxIndicator;
    if (oldStep == newStep && !rxChanged) return;

    final now = DateTime.now();
    final isSilent = sMeter <= 0.001;
    if (!isSilent &&
        now.difference(_lastSMeterPublish) < const Duration(milliseconds: 80)) {
      return;
    }
    _lastPublishedSMeter = sMeter;
    _lastPublishedRxIndicator = _rxIndicator;
    _lastSMeterPublish = now;
    sMeterListenable.value = sMeter;
  }

  void _resetSMeter() {
    _smoothedSMeter = 0;
    sMeter = 0;
    _rxIndicator = false;
    _lastPublishedSMeter = 0;
    _lastPublishedRxIndicator = false;
    _lastSMeterPublish = DateTime.now();
    sMeterListenable.value = 0;
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
  int beepMode = 0;
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
  bool shareLocation = false;
  bool preciseLocation = false;

  /// CB-APRS (Windows): Opt-in in den Standort-Einstellungen
  bool aprsEnabled = false;
  late final AprsService aprs = AprsService(
    softwareVersion: AppConfig.appVersion,
  )..commentBuilder = _aprsComment;
  String locationStatus = 'Standortfreigabe aus';
  double? _latitude;
  double? _longitude;
  bool _locationRequestInProgress = false;
  Timer? _locationTimer;
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
  @override
  String gwOutputId = '';

  bool get externalMicActive => false;
  bool get digitalTransmitActive => _digitalTransmitActive;
  String get micLabel =>
      externalMicActive ? 'Externes Mikrofon' : 'Eingebautes Mikrofon';

  /// Zweite Statuszeile unter dem Display
  String get statusDetail {
    // TX/PTT feedback must remain visible even if a previous RX warning is
    // still being cleared by the audio output watchdog.
    if (transmitting) {
      return digitalTransmitActive
          ? 'Digitalsignal wird über Kanal $channel gesendet'
          : 'Senden · Mikrofon: $micLabel';
    }
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
    return '${rxIndicator ? 'Signal empfangen' : 'Band ruhig'} · Funknetz';
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

  /// Windows: Schliessen-Knopf, Alt+F4, Taskleiste. Sendung beenden und
  /// Einstellungen sichern, bevor der Prozess endet.
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    cancelDigitalTransmission();
    try {
      await prepareForExit().timeout(const Duration(seconds: 2));
    } catch (_) {}
    return AppExitResponse.exit;
  }

  Future<void> prepareForExit() async {
    AppLogger.info(
      'APP',
      'Beenden angefordert: Sendung stoppen, Einstellungen sichern',
    );
    if (transmitting) pttUp();
    if (gatewayEnabled) {
      try {
        await audio.stopGateway().timeout(const Duration(seconds: 1));
      } catch (_) {}
      try {
        await _ptt?.close();
      } catch (_) {}
    }
    _saveTimer?.cancel();
    await _save();
    AppLogger.close();
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
        await mqtt.reconnectIfDisconnected().timeout(
          const Duration(seconds: 12),
        );
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
  /// Laedt die Einstellungen. Ist die Einstellungsdatei defekt (z. B. nach
  /// Stromausfall waehrend des Speicherns), wird sie beiseitegelegt; sonst
  /// koennte die App nie wieder etwas speichern.
  static Future<SharedPreferences?> _openPreferences() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (e, st) {
      AppLogger.error('SETTINGS', 'Einstellungen nicht lesbar: $e', e, st);
    }
    if (!Platform.isWindows) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File(
        '${dir.path}${Platform.pathSeparator}shared_preferences.json',
      );
      if (await f.exists()) {
        final backup = '${f.path}.defekt';
        await f.rename(backup);
        AppLogger.warn(
          'SETTINGS',
          'Defekte Einstellungsdatei gesichert als $backup, starte mit Standardwerten',
        );
      }
      return await SharedPreferences.getInstance();
    } catch (e, st) {
      AppLogger.error(
        'SETTINGS',
        'Einstellungen konnten nicht repariert werden: $e',
        e,
        st,
      );
      return null;
    }
  }

  Future<void> loadSettings() async {
    final p = await _openPreferences();
    if (p == null) {
      _finishLoadingSettings();
      return;
    }

    antenna =
        Antenna.values[(_readPreference<int>(
          p,
          'antenna',
          antenna.index,
        )).clamp(0, Antenna.values.length - 1)];
    gatewayMode =
        GatewayMode.values[(_readPreference<int>(
          p,
          'gatewayMode',
          gatewayMode.index,
        )).clamp(0, GatewayMode.values.length - 1)];
    gatewayEnabled = _readPreference<bool>(p, 'gatewayEnabled', false);
    toggleInsteadOfHold = _readPreference<bool>(
      p,
      'toggleInsteadOfHold',
      false,
    );
    headsetButtonPtt = _readPreference<bool>(p, 'headsetButtonPtt', true);
    volumeDownPtt = _readPreference<bool>(p, 'volumeDownPtt', false);
    preferExternalMic = _readPreference<bool>(p, 'preferExternalMic', true);
    beepMode = _readPreference<int>(p, 'beepMode', 0).clamp(0, 5);
    parrot = _readPreference<bool>(p, 'parrot', false);
    callSign = _readPreference<String>(p, 'callSign', '').trim().toUpperCase();
    mqtt.localCallSign = callSign;
    aprs.setCallSign(callSign);
    realisticRange = _readPreference<bool>(p, 'realisticRange', false);
    shareLocation =
        Platform.isWindows && _readPreference<bool>(p, 'shareLocation', false);
    preciseLocation = _readPreference<bool>(p, 'preciseLocation', false);
    aprsEnabled =
        Platform.isWindows && _readPreference<bool>(p, 'aprsEnabled', false);
    gwVoxThreshold = _readPreference<double>(
      p,
      'gwVox',
      0.35,
    ).clamp(0.05, 0.9).toDouble();
    gwHangMs = _readPreference<int>(p, 'gwHang', 700).clamp(200, 1500);
    gwInGain = _readPreference<double>(
      p,
      'gwIn',
      1.0,
    ).clamp(0.25, 4.0).toDouble();
    gwOutGain = _readPreference<double>(
      p,
      'gwOut',
      1.0,
    ).clamp(0.25, 2.0).toDouble();
    gwPreMs = _readPreference<int>(p, 'gwPre', 200).clamp(0, 800);
    gwPostMs = _readPreference<int>(p, 'gwPost', 300).clamp(100, 800);
    gwSerialPort = _readPreference<String>(p, 'gwSerial', '');
    gwUseDtr = _readPreference<bool>(p, 'gwDtr', false);
    gwHidKey = _readPreference<String>(p, 'gwHid', '');
    gwHidGpio = _readPreference<int>(p, 'gwGpio', 3).clamp(1, 4);
    gwInputId = _readPreference<String>(p, 'gwInput', '');
    if (Platform.isWindows) {
      gwOutputId = _readPreference<String>(p, 'gwOutput', '');
    }
    for (final a in KeyAction.values) {
      final id = _readPreference<int?>(p, 'key_${a.name}', null);
      if (id != null) keys.set(a, id);
    }
    channel = _readPreference<int>(
      p,
      'channel',
      channel,
    ).clamp(1, CbChannels.count);
    modulation =
        Modulation.values[(_readPreference<int>(
          p,
          'mod',
          0,
        )).clamp(0, Modulation.values.length - 1)];
    volume = _readPreference<double>(
      p,
      'volume',
      volume,
    ).clamp(0.0, 1.0).toDouble();
    squelch = _readPreference<double>(
      p,
      'squelch',
      squelch,
    ).clamp(0.0, 1.0).toDouble();
    rfGain = _readPreference<double>(
      p,
      'rfGain',
      rfGain,
    ).clamp(0.0, 1.0).toDouble();
    clarifier = _readPreference<double>(
      p,
      'clarifier',
      clarifier,
    ).clamp(0.0, 1.0).toDouble();
    txLevel = _readPreference<double>(
      p,
      'txLevel',
      txLevel,
    ).clamp(0.0, 1.0).toDouble();
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
      if (Platform.isWindows) unawaited(_applyGatewayOutputDevice());
      if (shareLocation) _startLocationUpdates();
      _applyAprs();
      if (gatewayEnabled) _queueGateway();
    } catch (e, st) {
      AppLogger.error(
        'SETTINGS',
        'Fehler in _finishLoadingSettings: $e',
        e,
        st,
      );
    }
  }

  Future<void> _saveChain = Future<void>.value();
  bool _saveQueued = false;

  /// Speichert alle Einstellungen. Aufrufe werden zusammengefasst und laufen
  /// nacheinander. Geschrieben werden nur geaenderte Werte: Unter Windows
  /// schreibt jeder einzelne set-Aufruf die komplette Datei neu (synchron im
  /// UI-Thread, der auch den Audio-Takt erzeugt).
  Future<void> _save() {
    if (_saveQueued) return _saveChain;
    _saveQueued = true;
    _saveChain = _saveChain.then((_) {
      _saveQueued = false;
      return _writeSettings();
    });
    return _saveChain;
  }

  Map<String, Object?> _settingsSnapshot() => <String, Object?>{
    'antenna': antenna.index,
    'gatewayMode': gatewayMode.index,
    'gatewayEnabled': gatewayEnabled,
    'toggleInsteadOfHold': toggleInsteadOfHold,
    'headsetButtonPtt': headsetButtonPtt,
    'volumeDownPtt': volumeDownPtt,
    'preferExternalMic': preferExternalMic,
    'beepMode': beepMode,
    'parrot': parrot,
    'callSign': callSign,
    'realisticRange': realisticRange,
    if (Platform.isWindows) 'shareLocation': shareLocation,
    if (Platform.isWindows) 'preciseLocation': preciseLocation,
    if (Platform.isWindows) 'aprsEnabled': aprsEnabled,
    'channel': channel,
    'mod': modulation.index,
    'volume': volume,
    'squelch': squelch,
    'rfGain': rfGain,
    'clarifier': clarifier,
    'txLevel': txLevel,
    'micSensitivity': micSensitivity,
    'echo': echo,
    'nb': noiseBlanker,
    'gwVox': gwVoxThreshold,
    'gwHang': gwHangMs,
    'gwIn': gwInGain,
    'gwOut': gwOutGain,
    'gwPre': gwPreMs,
    'gwPost': gwPostMs,
    'gwSerial': gwSerialPort,
    'gwDtr': gwUseDtr,
    'gwHid': gwHidKey,
    'gwGpio': gwHidGpio,
    'gwInput': gwInputId,
    if (Platform.isWindows) 'gwOutput': gwOutputId,
    for (final a in KeyAction.values) 'key_${a.name}': keys.idFor(a),
  };

  Future<void> _writeSettings() async {
    try {
      final p = await SharedPreferences.getInstance();
      var written = 0;
      for (final e in _settingsSnapshot().entries) {
        final v = e.value;
        if (p.get(e.key) == v) continue;
        written++;
        if (v == null) {
          await p.remove(e.key);
        } else if (v is bool) {
          await p.setBool(e.key, v);
        } else if (v is int) {
          await p.setInt(e.key, v);
        } else if (v is double) {
          await p.setDouble(e.key, v);
        } else if (v is String) {
          await p.setString(e.key, v);
        }
      }
      if (written > 0 && kDebugMode) {
        AppLogger.info('SETTINGS', '$written Einstellung(en) gespeichert');
      }
    } catch (e) {
      // Keep transient storage failures from escaping a UI timer/input callback.
      AppLogger.warn('SETTINGS', 'Speichern fehlgeschlagen: $e');
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
    mqtt.localCallSign = callSign;
    aprs.setCallSign(callSign);
    _saveSoon();
    _changed();
  }

  void setRealisticRange(bool value) {
    realisticRange = value;
    _save();
    _changed();
  }

  void setShareLocation(bool value) {
    if (!Platform.isWindows || shareLocation == value) return;
    shareLocation = value;
    _save();
    if (shareLocation) {
      locationStatus = 'Standort wird ermittelt …';
      _startLocationUpdates();
    } else {
      _locationTimer?.cancel();
      _locationTimer = null;
      _latitude = null;
      _longitude = null;
      locationStatus = 'Standortfreigabe aus';
      _shareLocationCoordinates(
        latitude: null,
        longitude: null,
        precise: preciseLocation,
        enabled: false,
      );
    }
    _changed();
  }

  void setPreciseLocation(bool value) {
    if (!Platform.isWindows || preciseLocation == value) return;
    preciseLocation = value;
    _save();
    if (shareLocation) {
      _publishLocation();
      locationStatus = value
          ? 'Genauer Standort wird freigegeben'
          : 'Ungefährer Standort (auf etwa 1 km gerundet)';
    }
    _changed();
  }

  void _startLocationUpdates() {
    _locationTimer?.cancel();
    _shareLocationCoordinates(
      latitude: _latitude,
      longitude: _longitude,
      precise: preciseLocation,
      enabled: true,
    );
    unawaited(_refreshLocation());
    _locationTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_refreshLocation()),
    );
  }

  Future<void> _refreshLocation() async {
    if (!shareLocation || _locationRequestInProgress) return;
    _locationRequestInProgress = true;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!shareLocation) return;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _latitude = null;
        _longitude = null;
        locationStatus = permission == LocationPermission.deniedForever
            ? 'Standortzugriff in den Windows-Einstellungen dauerhaft verweigert'
            : 'Windows-Standortzugriff nicht erteilt';
        _shareLocationCoordinates(
          latitude: null,
          longitude: null,
          precise: preciseLocation,
          enabled: shareLocation,
        );
        _changed();
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: preciseLocation
              ? LocationAccuracy.best
              : LocationAccuracy.low,
          timeLimit: const Duration(seconds: 15),
        ),
      );
      if (!shareLocation) return;
      _latitude = position.latitude;
      _longitude = position.longitude;
      _publishLocation();
      locationStatus = preciseLocation
          ? 'Genauer Standort wird freigegeben'
          : 'Ungefährer Standort (auf etwa 1 km gerundet)';
      _changed();
    } on LocationServiceDisabledException catch (e) {
      AppLogger.warn(
        'LOCATION',
        'Windows-Standortdienste sind deaktiviert: $e',
      );
      locationStatus = 'Windows-Standortdienste sind deaktiviert';
      _shareLocationCoordinates(
        latitude: null,
        longitude: null,
        precise: preciseLocation,
        enabled: shareLocation,
      );
      _changed();
    } catch (e, st) {
      AppLogger.error(
        'LOCATION',
        'Standort konnte nicht ermittelt werden: $e',
        e,
        st,
      );
      locationStatus = 'Standort konnte nicht ermittelt werden';
      _shareLocationCoordinates(
        latitude: null,
        longitude: null,
        precise: preciseLocation,
        enabled: shareLocation,
      );
      _changed();
    } finally {
      _locationRequestInProgress = false;
    }
  }

  /// Standort an MQTT (Live-Karte) und, falls freigegeben, an APRS geben.
  /// Fuer MQTT unveraendert; APRS rundet selbst gemaess [precise].
  void _shareLocationCoordinates({
    required double? latitude,
    required double? longitude,
    required bool precise,
    required bool enabled,
  }) {
    mqtt.setLocationCoordinates(
      latitude: latitude,
      longitude: longitude,
      precise: precise,
      enabled: enabled,
    );
    aprs.setPosition(
      enabled ? latitude : null,
      enabled ? longitude : null,
      precise: precise,
    );
  }

  /// APRS-Haken in den Standort-Einstellungen (nur Windows)
  void setAprsEnabled(bool value) {
    if (!Platform.isWindows || aprsEnabled == value) return;
    aprsEnabled = value;
    _save();
    _applyAprs();
    _changed();
  }

  void _applyAprs() {
    aprs.setCallSign(callSign);
    aprs.setPosition(
      shareLocation ? _latitude : null,
      shareLocation ? _longitude : null,
      precise: preciseLocation,
    );
    aprs.setActive(Platform.isWindows && aprsEnabled && power);
  }

  String _aprsComment() =>
      'CB-Funk ${AppConfig.appVersion} Kanal $channel '
      '${modulation.name.toUpperCase()}';

  void _publishLocation() {
    _shareLocationCoordinates(
      latitude: _latitude,
      longitude: _longitude,
      precise: preciseLocation,
      enabled: shareLocation,
    );
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
    AppLogger.info(
      'GATEWAY',
      'Gateway aktiviert: $v (Modus: ${gatewayMode.name})',
    );
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
    if (power) cancelDigitalTransmission();
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
      _resetSMeter();
      mqtt.disconnect();
    } else {
      _watchdogTimer ??= Timer.periodic(
        Duration(
          seconds: defaultTargetPlatform == TargetPlatform.windows ? 3 : 15,
        ),
        (_) => unawaited(_runWatchdog()),
      );
      mqtt.connect();
      mqtt.joinChannel(channel);
      unawaited(_setBackgroundAudio(true));
    }
    _applyAprs();
    _queueGateway();
    _changed();
  }

  void setChannel(int ch) {
    if (!power) return;
    cancelDigitalTransmission();
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
          AppLogger.info(
            'GATEWAY',
            'PTT-Treiber geöffnet (${gatewayMode.name})',
          );
          _ptt = d;
          audio.ptt = d;
          audio.setError(null);
        } catch (e, st) {
          AppLogger.error(
            'GATEWAY',
            'Fehler beim Öffnen des PTT-Treibers: $e',
            e,
            st,
          );
          audio.setError('Gateway: $e');
        }
      }
    } catch (e, st) {
      AppLogger.error('GATEWAY', 'Fehler bei PttDriverFactory: $e', e, st);
    }

    try {
      await audio
          .startGateway(inputId: gwInputId)
          .timeout(const Duration(seconds: 6));
    } catch (e, st) {
      AppLogger.error(
        'GATEWAY',
        'Fehler beim Starten von audio.startGateway: $e',
        e,
        st,
      );
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
    final restart =
        serialPort != null ||
        useDtr != null ||
        hidKey != null ||
        hidGpio != null ||
        inputId != null;
    if (restart && gatewayEnabled) _queueGateway();
    _changed();
  }

  Future<void> saveSettings() => _save();

  Future<void> setGatewayOutputDevice(String deviceId) async {
    if (gwOutputId == deviceId) return;
    gwOutputId = deviceId;
    _changed();
    final applying = _applyGatewayOutputDevice();
    await _save();
    await applying;
  }

  Future<void> _applyGatewayOutputDevice() async {
    try {
      await audio.changeOutputDevice(gwOutputId);
    } catch (e, st) {
      AppLogger.error(
        'AUDIO',
        'Ausgewähltes Windows-Ausgabegerät konnte nicht aktiviert werden',
        e,
        st,
      );
      audio.setError('Audio-Ausgang: $e');
    }
  }

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
    if (!power || transmitting || gatewayEnabled || _digitalTransmitActive) {
      return;
    }
    if (scanning) _stopScan();
    transmitting = true;
    _resetSMeter();
    audio.flush();
    if (!parrot) mqtt.publishPtt(channel, true, antenna.db);
    _changed();
    unawaited(audio.startTx());
  }

  void pttUp() {
    if (!transmitting || _digitalTransmitActive) return;
    transmitting = false;
    audio.stopTx();
    if (!parrot) mqtt.publishPtt(channel, false, antenna.db);
    _changed();
  }

  Future<void> transmitDigitalAudio({
    required int mode,
    required int requiredChannel,
    required Stream<Int16List> frames,
  }) async {
    final expectedMode = AudioPacket.digitalModulationForChannel(
      requiredChannel,
    );
    if (expectedMode == null || mode != expectedMode) {
      throw ArgumentError('Unbekannter Digitalmodus oder Kanal');
    }
    if (!power || channel != requiredChannel) {
      throw StateError('Digitalfunk ist nur auf Kanal $requiredChannel aktiv');
    }
    if (transmitting || _digitalTransmitActive) {
      throw StateError('Es läuft bereits eine Sendung');
    }
    if (mqtt.state != LinkState.online) {
      throw StateError('Keine MQTT-Verbindung – Senden nicht möglich');
    }

    final token = ++_digitalTransmitToken;
    final cancelled = Completer<void>();
    _digitalTransmitCancelled = cancelled;
    _digitalTransmitActive = true;
    transmitting = true;
    audio.flush();
    mqtt.publishPtt(channel, true, antenna.db);
    _changed();
    var sequence = 0;
    final iterator = StreamIterator<Int16List>(frames);
    try {
      while (token == _digitalTransmitToken) {
        final hasFrame = await Future.any<bool>([
          iterator.moveNext(),
          cancelled.future.then((_) => false),
        ]);
        if (!hasFrame || token != _digitalTransmitToken) break;
        final samples = iterator.current;
        if (samples.isEmpty || samples.length > AppConfig.frameSamples) {
          throw StateError('Ungültige Audio-Framegröße: ${samples.length}');
        }
        final packet = AudioPacket(
          sender: mqtt.senderId,
          channel: requiredChannel,
          modulation: mode,
          antennaDb: antenna.db,
          seq: sequence++ & 0xffff,
          payload: AudioPacket.encodeLinearPcm(samples),
        );
        audio.queueDigitalTxSamples(
          channel: requiredChannel,
          modulation: mode,
          samples: samples,
        );
        mqtt.publishAudio(packet.toBytes());
        await Future<void>.delayed(
          Duration(
            milliseconds: (samples.length * 1000 / AppConfig.audioRate).round(),
          ),
        );
      }
      if (token != _digitalTransmitToken) {
        throw StateError('Digitalsendung abgebrochen');
      }
    } finally {
      await iterator.cancel();
      if (token == _digitalTransmitToken) {
        _digitalTransmitActive = false;
        _digitalTransmitCancelled = null;
        transmitting = false;
        mqtt.publishPtt(requiredChannel, false, antenna.db);
        _changed();
      }
    }
  }

  void cancelDigitalTransmission() {
    if (!_digitalTransmitActive) return;
    final channelBeingSent = channel;
    _digitalTransmitToken++;
    _digitalTransmitActive = false;
    transmitting = false;
    mqtt.publishPtt(channelBeingSent, false, antenna.db);
    final cancelled = _digitalTransmitCancelled;
    _digitalTransmitCancelled = null;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
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

    final isHeadset =
        k == LogicalKeyboardKey.headsetHook ||
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
    cancelDigitalTransmission();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_setBackgroundAudio(false));
    _watchdogTimer?.cancel();
    _scanTimer?.cancel();
    _saveTimer?.cancel();
    _locationTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleKey);
    audio.dispose();
    _digitalSamples.close();
    mqtt.removeListener(notifyListeners);
    aprs.dispose();
    sMeterListenable.dispose();
    AppLogger.close();
    super.dispose();
  }
}
