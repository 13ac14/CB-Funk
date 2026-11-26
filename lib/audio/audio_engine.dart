import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:record/record.dart';

import '../config/app_config.dart';
import '../models/enums.dart';
import '../gateway/ptt_driver.dart';
import '../services/app_logger.dart';
import '../services/mqtt_service.dart';
import 'audio_packet.dart';
import 'freq_shifter.dart';
import 'mulaw.dart';

/// Was die Audio-Engine vom Funkgeraet wissen muss (RadioController implementiert das).
abstract class RadioAudioState {
  bool get power;
  int get channel;
  Modulation get modulation;
  double get volume;
  double get micSensitivity;
  double get squelch;
  double get rfGain;
  bool get realisticRange;
  int get antennaDb;
  bool get transmitting;
  bool get scanning;
  bool get parrot;
  bool get echo;
  int get beepMode; // 0 = aus, 1..5 = Varianten
  bool get noiseBlanker;
  double get clarifier; // 0..1, 0.5 = Mitte
  bool get clarifierActive;
  // Gateway
  bool get gatewayEnabled;
  GatewayMode get gatewayMode;
  String get gwOutputId;
  double get gwVoxThreshold; // 0..1 (Eingangspegel-Schwelle)
  int get gwHangMs; // VOX-Nachlauf Funk -> Netz
  double get gwInGain;
  double get gwOutGain;
  int get gwPreMs; // Vorlauf (Weckton/PTT) Netz -> Funk
  int get gwPostMs; // PTT-Nachlauf
}

class DigitalPcmFrame {
  const DigitalPcmFrame({required this.modulation, required this.samples});

  final int modulation;
  final Int16List samples;
}

/// Empfang: MQTT -> Jitter-Puffer -> Clarifier -> Squelch/Rauschen/NB -> Lautsprecher
/// Senden:  Mikrofon -> 8 kHz -> Echo -> mu-law -> MQTT (+ Roger-Beep, Echo-Schwanz)
/// Papagei: Mikrofon -> lokal aufnehmen -> nach PTT-Ende abspielen (nichts wird gesendet)
///
/// WICHTIG: Alle flutter_soloud-Aufrufe stehen NUR in dieser Datei
/// (init / _feed / watchdog / dispose).
class AudioEngine {
  AudioEngine(this.mqtt, this.state);

  final MqttService mqtt;
  final RadioAudioState state;

  /// S-Meter-Pegel 0..1, ca. alle 20 ms (RX-Signal, beim Senden/Papagei: Mikrofonpegel)
  void Function(double level)? onLevel;

  /// Fehler-/Statusmeldung geaendert
  void Function()? onStatus;

  /// Suchlauf: auf einem anderen Kanal wurde ein hoerbares Signal erkannt
  void Function(int channel)? onScanHit;
  void Function(DigitalPcmFrame frame)? onDigitalSamples;
  String? error;

  /// Sendepegel (Faktor)
  double txGain = 1.0;

  /// true, solange gerade jemand empfangen wird
  bool get rxActive => _talker != null;

  /// PTT-Treiber des Gateways (null = VOX-Betrieb), wird vom Controller gesetzt
  PttDriver? ptt;
  void setError(String? e) => _setError(e);

  static const int _rate = AppConfig.audioRate;
  static const int _frame = AppConfig.frameSamples;
  static const int _ratio = AppConfig.micRate ~/ AppConfig.audioRate;
  static const int _echoLen = 2000; // 250 ms @ 8 kHz
  static final math.Random _noiseRandom = math.Random();

  // ---------- Wiedergabe ----------
  AudioSource? _out;
  SoundHandle? _outHandle;
  Timer? _tick;
  DateTime _lastTickAt = DateTime.now();
  DateTime _lastRxPacketAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _bufferingSince;
  bool _recoveringOutput = false;
  bool _initializingOutput = false;
  bool _outputReady = false;
  bool _windowsOutputUnavailable = false;
  bool _windowHealthCheckRequested = false;
  int _consecutiveFeedErrors = 0;
  Duration? _lastConsumedAudioTime;
  DateTime _lastOutputProgressAt = DateTime.now();
  static const String _windowsOutputPausedMessage =
      'Audioausgabe stockt – Wiedergabegerät prüfen';
  StreamSubscription<AudioDeviceStartFailure>? _deviceStartFailureSub;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<Map<String, dynamic>>? _ctlSub;
  final FreqShifter _shifter = FreqShifter(_rate);

  final ListQueue<int> _fifo = ListQueue<int>();
  int? _talker;
  double _amLowpass = 0;
  double _amHighpassInput = 0;
  double _amHighpassOutput = 0;
  DateTime _lastRx = DateTime.fromMillisecondsSinceEpoch(0);
  int _rxAntDb = 0;
  int _rxMod = 0;
  bool _primed = false;
  int _underruns = 0;
  int _tailTicks = 0;
  bool _lastOpen = false;
  double _level = 0;
  double _micLevel = 0;

  // Papagei
  final ListQueue<int> _parrotPlay = ListQueue<int>();
  final List<int> _parrotRec = <int>[];
  bool _txParrot = false;

  Future<void> init() async {
    AppLogger.info('AUDIO', 'AudioEngine init() aufgerufen');
    if (Platform.isWindows) {
      _deviceStartFailureSub ??= SoLoud.instance.audioDeviceStartFailures.listen(
        (failure) {
          AppLogger.error(
            'AUDIO',
            'SoLoud meldet fehlgeschlagenen Windows-Audiogerätestart: $failure',
          );
          _setError('Windows-Audioausgabe wird neu gestartet …');
          if (_outputReady && state.power) unawaited(recoverOutput());
        },
      );
    }
    try {
      await _initializeOutput();
    } catch (e, st) {
      AppLogger.warn('AUDIO', 'Fehler in _initializeOutput(): $e');
    }
    try {
      _audioSub ??= mqtt.audioStream.listen(
        _onAudio,
        onError: (Object e) {
          AppLogger.error('AUDIO', 'Fehler im mqtt.audioStream', e);
        },
      );
    } catch (e) {
      AppLogger.warn('AUDIO', 'Fehler beim Starten von _audioSub: $e');
    }
    try {
      _ctlSub ??= mqtt.ctlStream.listen(
        _onCtl,
        onError: (Object e) {
          AppLogger.error('AUDIO', 'Fehler im mqtt.ctlStream', e);
        },
      );
    } catch (e) {
      AppLogger.warn('AUDIO', 'Fehler beim Starten von _ctlSub: $e');
    }
    try {
      _tick ??= Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => _onTick(),
      );
    } catch (e) {
      AppLogger.warn('AUDIO', 'Fehler beim Starten von _tick: $e');
    }
  }

  Future<void> _initializeOutput() async {
    if (_initializingOutput) return;
    _initializingOutput = true;
    _outputReady = false;
    AppLogger.info(
      'AUDIO',
      'Initialisiere Audio-Ausgabe (SoLoud, Rate: $_rate Hz)',
    );
    try {
      if (!SoLoud.instance.isInitialized) {
        try {
          PlaybackDevice? outputDevice;
          if (Platform.isWindows) {
            final devices = SoLoud.instance.listPlaybackDevices();
            for (final device in devices) {
              AppLogger.info(
                'AUDIO',
                'Windows-Ausgabegerät: id=${device.id}, default=${device.isDefault}, name="${device.name}"',
              );
            }
            if (devices.isEmpty) {
              throw StateError(
                'Windows meldet kein verfügbares Audioausgabegerät',
              );
            }
            outputDevice = _resolvePlaybackDevice(devices, state.gwOutputId);
            AppLogger.info(
              'AUDIO',
              'SoLoud wird explizit mit dem Windows-Ausgabegerät "${outputDevice.name}" (id=${outputDevice.id}) gestartet',
            );
          }
          await SoLoud.instance
              .init(
                device: outputDevice,
                sampleRate: 44100,
                // Keep the device mixer ahead of the 8 kHz, 20 ms RX feed.
                // This is about 93 ms at 44.1 kHz and tolerates UI scheduling
                // jitter without changing the RF packet/frame timing.
                bufferSize: 4096,
                channels: Channels.stereo,
              )
              .timeout(const Duration(seconds: 5));
        } catch (e, st) {
          AppLogger.warn(
            'AUDIO',
            'SoLoud.instance.init() fehlgeschlagen (keine Soundkarte?): $e',
          );
          _setError('Audio-Ausgabe nicht verfügbar ($e)');
          return;
        }
      }
      if (!SoLoud.instance.isInitialized) {
        AppLogger.warn('AUDIO', 'SoLoud ist nicht initialisiert');
        _setError('Audio-System nicht bereit');
        return;
      }
      if (Platform.isWindows) {
        // A permanently fed radio stream must not have its output device
        // auto-stopped during a short BufferStream underrun. SoLoud 5.x keeps
        // the device lifecycle serialized off the UI isolate.
        SoLoud.instance.setAudioDeviceIdleTimeout(null);
        AppLogger.info(
          'AUDIO',
          'Windows-Audioausgabegerät bleibt während Funkbetrieb aktiv',
        );
      }
      AudioSource? streamOut;
      try {
        streamOut = SoLoud.instance.setBufferStream(
          // A short packet gap can pause a released stream while it waits for
          // bufferingTimeNeeds. Give it enough headroom to survive longer
          // Windows endpoint stalls: SoLoud permanently ends the stream if
          // this limit is reached, after which no later RX audio is playable.
          // Released buffers discard already played frames, so this is a cap,
          // not a pre-allocation.
          maxBufferSizeDuration: const Duration(minutes: 30),
          sampleRate: _rate,
          channels: Channels.mono,
          format: BufferType.s16le,
          bufferingType: BufferingType.released,
          // This is a real-time PCM stream that is continuously fed (including
          // silence between calls). Do not make SoLoud wait for a large refill
          // window after an underrun; the next 20 ms frame should resume it.
          bufferingTimeNeeds: 0.001,
          onBuffering: (buffering, _, __) {
            _bufferingSince = buffering
                ? (_bufferingSince ?? DateTime.now())
                : null;
            if (!buffering &&
                Platform.isWindows &&
                error == _windowsOutputPausedMessage) {
              _setError(null);
            }
          },
        );
      } catch (e, st) {
        AppLogger.warn('AUDIO', 'setBufferStream fehlgeschlagen: $e');
        _setError('Audio-Stream-Fehler: $e');
        return;
      }
      _consecutiveFeedErrors = 0;
      _out = streamOut;
      if (streamOut != null) {
        // SoLoud may leave a released BufferStream voice idle if play() is
        // called before it contains any PCM. Prime it with 100 ms of silence
        // so the device mixer has real frames to start; live RX/parrot frames
        // replace this startup padding immediately afterward.
        try {
          final primingSilence = Int16List(_rate ~/ 10);
          SoLoud.instance.addAudioDataStream(
            streamOut,
            primingSilence.buffer.asUint8List(),
          );
        } catch (e, st) {
          AppLogger.error(
            'AUDIO',
            'SoLoud-Stream konnte nicht vorgefüllt werden',
            e,
            st,
          );
          _setError('Audio-Stream konnte nicht gestartet werden: $e');
          _out = null;
          return;
        }
        _outHandle = SoLoud.instance.play(streamOut);
        _lastConsumedAudioTime = null;
        _lastOutputProgressAt = DateTime.now();
        _outputReady = true;
        AppLogger.info(
          'AUDIO',
          'Audio-Ausgabe erfolgreich initialisiert (Gerätestatus: ${Platform.isWindows ? SoLoud.instance.getAudioDeviceState() : 'n/a'})',
        );
      }
    } catch (e, st) {
      AppLogger.error(
        'AUDIO',
        'Initialisierung der Audio-Ausgabe fehlgeschlagen',
        e,
        st,
      );
      _setError('Audio-Ausgabe: $e');
    } finally {
      _initializingOutput = false;
    }
  }

  PlaybackDevice _resolvePlaybackDevice(
    List<PlaybackDevice> devices,
    String deviceId,
  ) {
    if (deviceId.isNotEmpty) {
      for (final device in devices) {
        if (device.id.toString() == deviceId) return device;
      }
      AppLogger.warn(
        'AUDIO',
        'Gespeichertes Ausgabegerät "$deviceId" ist nicht verfügbar; verwende Windows-Standard',
      );
    }
    return devices.firstWhere(
      (device) => device.isDefault,
      orElse: () => devices.first,
    );
  }

  Future<void> changeOutputDevice(String deviceId) async {
    if (!Platform.isWindows) return;
    while (_initializingOutput) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (!SoLoud.instance.isInitialized) return;

    final devices = SoLoud.instance.listPlaybackDevices();
    if (devices.isEmpty) {
      throw StateError('Windows meldet kein verfügbares Audioausgabegerät');
    }
    final device = deviceId.isEmpty
        ? _resolvePlaybackDevice(devices, '')
        : devices.where((d) => d.id.toString() == deviceId).firstOrNull;
    if (device == null) {
      throw StateError(
        'Das ausgewählte Windows-Ausgabegerät "$deviceId" ist nicht mehr verfügbar',
      );
    }

    await SoLoud.instance.changeDevice(newDevice: device);
    AppLogger.info(
      'AUDIO',
      'Windows-Ausgabegerät gewechselt: "${device.name}" (id=${device.id})',
    );
  }

  DateTime _lastRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get needsOutputRecovery {
    if (!state.power ||
        _recoveringOutput ||
        _initializingOutput ||
        _windowsOutputUnavailable) {
      return false;
    }
    final now = DateTime.now();

    // Verhindere Erholungs-Schleifen (Cooldown 15 Sekunden) - auch wenn die
    // Ausgabe nie bereit war (z. B. PC ohne Soundkarte/Lautsprecher): sonst
    // wuerde SoLoud alle 3 Sekunden neu gestartet.
    if (now.difference(_lastRecoveryAt) < const Duration(seconds: 15)) {
      return false;
    }
    if (!_outputReady) return true;

    final windowHealthCheck = _windowHealthCheckRequested;
    _windowHealthCheckRequested = false;
    // A stalled Dart tick during a native window move is not by itself an
    // audio-device failure. Skip one poll after such a pause, then inspect the
    // native stream's own consumption progress below.
    if (Platform.isWindows &&
        now.difference(_lastTickAt) > const Duration(seconds: 2) &&
        !windowHealthCheck) {
      return false;
    }
    if (!Platform.isWindows &&
        now.difference(_lastTickAt) > const Duration(seconds: 2)) {
      return true;
    }
    if (_consecutiveFeedErrors >= 3 &&
        now.difference(_lastRxPacketAt) < const Duration(seconds: 3)) {
      AppLogger.warn(
        'AUDIO',
        'needsOutputRecovery: Zu viele Feed-Fehler während RX ($_consecutiveFeedErrors)',
      );
      return true;
    }
    // A native voice can end after a Windows endpoint/device change while
    // Dart and MQTT keep running. Recreate its one-shot buffer stream then.
    final handle = _outHandle;
    if (handle == null) return true;
    try {
      if (!SoLoud.instance.getIsValidVoiceHandle(handle)) {
        AppLogger.warn(
          'AUDIO',
          'needsOutputRecovery: Voice-Handle nicht mehr gültig',
        );
        return true;
      }
      final output = _out;
      if (output == null) return true;

      // Nur prüfen, ob Stream konsumiert wird, wenn auch tatsächlich Audio empfangen/abgespielt wird!
      // Bei Inaktivität (kein Signal, Band ruhig) ist das Ausbleiben von Fortschritten völlig normal.
      final hasRecentRx =
          now.difference(_lastRxPacketAt) < const Duration(seconds: 4);
      final isActivelyPlaying =
          _talker != null ||
          hasRecentRx ||
          _parrotPlay.isNotEmpty ||
          (_gwRunning && _gwState == 2);

      if (Platform.isWindows && isActivelyPlaying) {
        final deviceState = SoLoud.instance.getAudioDeviceState();
        if (deviceState != AudioDeviceState.started) {
          AppLogger.warn(
            'AUDIO',
            'Windows-Ausgabegerät ist während aktivem Audio nicht gestartet (state: $deviceState)',
          );
          if (error != _windowsOutputPausedMessage) {
            _setError(_windowsOutputPausedMessage);
          }
          return true;
        }
      }

      final consumed = SoLoud.instance.getStreamTimeConsumed(output);
      final previous = _lastConsumedAudioTime;
      if (previous == null || consumed > previous) {
        _lastConsumedAudioTime = consumed;
        _lastOutputProgressAt = now;
        if (Platform.isWindows && error == _windowsOutputPausedMessage) {
          _setError(null);
        }
      } else if (isActivelyPlaying &&
          now.difference(_lastOutputProgressAt) > const Duration(seconds: 4)) {
        // Der Stream konsumiert trotz aktiver Wiedergabe keine Frames
        if (Platform.isWindows) {
          if (error != _windowsOutputPausedMessage) {
            AppLogger.warn(
              'AUDIO',
              'SoLoud-Stream konsumiert trotz RX keine Frames; starte Windows-Audiogerät neu',
            );
            _setError(_windowsOutputPausedMessage);
          }
          return true;
        } else {
          AppLogger.warn(
            'AUDIO',
            'needsOutputRecovery: Stream konsumiert keine Frames bei aktiver Wiedergabe',
          );
          return true;
        }
      }
    } catch (e) {
      AppLogger.warn(
        'AUDIO',
        'needsOutputRecovery: Ausnahme bei Handle-Prüfung: $e',
      );
      return true;
    }
    final bufferingSince = _bufferingSince;
    if (bufferingSince != null &&
        now.difference(bufferingSince) > const Duration(seconds: 2) &&
        now.difference(_lastRxPacketAt) < const Duration(seconds: 2)) {
      if (Platform.isWindows) {
        if (error != _windowsOutputPausedMessage) {
          AppLogger.warn(
            'AUDIO',
            'SoLoud-Stream bleibt im Buffering; starte Windows-Audiogerät neu',
          );
          _setError(_windowsOutputPausedMessage);
        }
        return true;
      }
      AppLogger.warn(
        'AUDIO',
        'needsOutputRecovery: Buffering hängt während Empfang',
      );
      return true;
    }
    return false;
  }

  Future<void> recoverOutput() async {
    if (_recoveringOutput || !state.power) return;
    if (Platform.isWindows) {
      if (_consecutiveFeedErrors >= 3) {
        // A full/ended PCM source cannot be revived by restarting its device.
        // Quarantine it without calling native stop/dispose on the UI isolate.
        _windowsOutputUnavailable = true;
        _outputReady = false;
        _out = null;
        _outHandle = null;
        AppLogger.error(
          'AUDIO',
          'Windows-PCM-Stream nimmt wiederholt keine Frames an; Stream quarantänisiert',
        );
        _setError('Audio-Stream ist beendet – bitte CB-Funk neu starten');
        return;
      }

      // flutter_soloud 5 serializes device lifecycle operations away from the
      // UI isolate and preserves active voices. Restart only the native output
      // device; never rebuild or dispose the BufferStream/voice here.
      _recoveringOutput = true;
      _lastRecoveryAt = DateTime.now();
      try {
        final before = SoLoud.instance.getAudioDeviceState();
        AppLogger.warn(
          'AUDIO',
          'Wiederherstellung des Windows-Audiogeräts gestartet (state: $before)',
        );
        if (before == AudioDeviceState.started) {
          await SoLoud.instance
              .stopAudioDevice(force: true)
              .timeout(const Duration(seconds: 8));
        }
        await SoLoud.instance.startAudioDevice().timeout(
          const Duration(seconds: 10),
        );
        final after = SoLoud.instance.getAudioDeviceState();
        AppLogger.info('AUDIO', 'Windows-Audiogerät nach Neustart: $after');
        if (after != AudioDeviceState.started) {
          throw StateError(
            'Windows meldet Audiogerätestatus $after statt started',
          );
        }
        _lastConsumedAudioTime = null;
        _lastOutputProgressAt = DateTime.now();
        _bufferingSince = null;
        if (error == _windowsOutputPausedMessage) _setError(null);
      } catch (e, st) {
        AppLogger.error(
          'AUDIO',
          'Windows-Audiogerät konnte nicht neu gestartet werden',
          e,
          st,
        );
        _setError('Windows-Audioausgabe: $e');
      } finally {
        _recoveringOutput = false;
      }
      return;
    }
    _recoveringOutput = true;
    _lastRecoveryAt = DateTime.now();
    AppLogger.info(
      'AUDIO',
      'Audio-Wiederherstellung (recoverOutput) wird ausgeführt',
    );
    final oldOutput = _out;
    final oldHandle = _outHandle;
    _out = null;
    _outHandle = null;
    _bufferingSince = null;
    flush();
    try {
      if (SoLoud.instance.isInitialized) {
        if (oldHandle != null) {
          try {
            await SoLoud.instance
                .stop(oldHandle)
                .timeout(
                  const Duration(milliseconds: 500),
                  onTimeout: () {
                    AppLogger.warn(
                      'AUDIO',
                      'Timeout beim Stoppen des alten Audio-Handles',
                    );
                  },
                );
          } catch (_) {}
        }
        if (oldOutput != null) {
          try {
            await SoLoud.instance
                .disposeSource(oldOutput)
                .timeout(
                  const Duration(milliseconds: 500),
                  onTimeout: () {
                    AppLogger.warn(
                      'AUDIO',
                      'Timeout beim Freigeben der alten Audio-Quelle',
                    );
                  },
                );
          } catch (_) {}
        }
      }
      await _initializeOutput();
      _lastTickAt = DateTime.now();
      AppLogger.info(
        'AUDIO',
        'Audio-Wiederherstellung erfolgreich abgeschlossen',
      );
    } catch (e, st) {
      _outputReady = false;
      AppLogger.error('AUDIO', 'Audio-Wiederherstellung fehlgeschlagen', e, st);
      _setError('Audio-Wiederherstellung: $e');
    } finally {
      _recoveringOutput = false;
    }
  }

  /// Called after a Windows window move/focus transition or app resume. The
  /// watchdog checks stream health outside WndProc; it never tears down or
  /// recreates the native SoLoud device on the UI isolate.
  void requestOutputHealthCheck() {
    if (state.power && _outputReady) _windowHealthCheckRequested = true;
  }

  void _feed(Int16List samples) {
    final o = _out;
    if (o == null) return;
    try {
      SoLoud.instance.addAudioDataStream(o, samples.buffer.asUint8List());
      _consecutiveFeedErrors = 0;
    } catch (e, st) {
      if (_consecutiveFeedErrors == 0) {
        AppLogger.error(
          'AUDIO',
          'SoLoud-Audio-Stream nimmt keine Daten an: $e',
          e,
          st,
        );
      }
      _consecutiveFeedErrors++;
      /* Fehlerhaften Frame verwerfen; der Watchdog behandelt den Ausfall. */
    }
  }

  void _setError(String? e) {
    error = e;
    onStatus?.call();
  }

  /// Bei Kanalwechsel / Power aus / neuem PTT
  void flush() {
    _fifo.clear();
    _talker = null;
    _primed = false;
    _underruns = 0;
    _tailTicks = 0;
    _resetAmFilter();
    _clearReceiveMeter();
    _tailTimer?.cancel();
    _tailTimer = null;
  }

  void _clearReceiveMeter() {
    if (_level <= 0) return;
    _level = 0;
    onLevel?.call(0);
  }

  static const bool _mqttHasLocationData = false;

  double _strengthDb(int senderAntDb) {
    final baseDb = !state.realisticRange || !_mqttHasLocationData
        ? 60.0
        : 30.0 + senderAntDb + state.antennaDb;
    return baseDb * state.rfGain.clamp(0.0, 1.0);
  }

  void _onCtl(Map<String, dynamic> m) {
    if (m['ptt'] == false && _talker != null) {
      final id = (m['sid'] as num?)?.toInt();
      if (id != null && (_talker! & 0x7FFFFFFF) == id) {
        _lastRx = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
  }

  void _onAudio(Uint8List data) {
    final p = AudioPacket.parse(data);
    if (p == null || !state.power || state.transmitting) return;
    if (AudioPacket.isDigitalModulation(p.modulation)) {
      if (!AudioPacket.isDigitalModulationForChannel(p.channel, p.modulation) ||
          p.channel != state.channel ||
          (p.sender & 0x7FFFFFFF) == mqtt.senderId ||
          (state.gatewayEnabled && (p.sender & 0x80000000) != 0)) {
        return;
      }
      _receiveDigitalAudio(p);
      return;
    }
    // Modulation is already part of the packet header. Treat each mode as an
    // independent channel before scan detection, signal strength, or audio.
    if (p.modulation < 0 ||
        p.modulation >= Modulation.values.length ||
        p.modulation != state.modulation.index) {
      if (_talker != null && _rxMod != state.modulation.index) {
        _clearReceiveMeter();
      }
      return;
    }
    final gw = state.gatewayEnabled;
    if (!gw && state.parrot) return;
    final fromGateway = (p.sender & 0x80000000) != 0;
    final realSender = p.sender & 0x7FFFFFFF;
    if (gw && fromGateway) return; // Gateways koppeln sich nicht gegenseitig

    if (p.channel != state.channel) {
      // Suchlauf: Signal auf anderem Kanal, das den Squelch oeffnen wuerde?
      if (!gw &&
          state.scanning &&
          !state.transmitting &&
          realSender != mqtt.senderId &&
          _strengthDb(p.antennaDb) >= state.squelch * 50.0) {
        onScanHit?.call(p.channel);
      }
      if (p.channel != state.channel) return;
    }

    if (!AppConfig.loopbackTest) {
      if (realSender == mqtt.senderId) return; // eigene Sendung
    }
    _lastRxPacketAt = DateTime.now();
    // Gateway: Funkgeraet empfaengt gerade selbst -> nichts aufs Funkgeraet geben
    if (gw && _voxOpen) return;
    final now = DateTime.now();
    if (_talker != null &&
        _talker != p.sender &&
        now.difference(_lastRx).inMilliseconds < 300) {
      return; // nur ein Sprecher gleichzeitig
    }
    if (_talker != p.sender || _rxMod != p.modulation) {
      _fifo.clear();
      _primed = false;
      _underruns = 0;
      _resetAmFilter();
      _talker = p.sender;
      AppLogger.info(
        'AUDIO',
        'Empfang gestartet: Sprecher 0x${p.sender.toRadixString(16)}, Kanal ${p.channel}, Mod ${Modulation.values[p.modulation].name}, Ant ${p.antennaDb} dB',
      );
    }
    _lastRx = now;
    _rxAntDb = p.antennaDb;
    _rxMod = p.modulation;
    for (final b in p.payload) {
      _fifo.add(MuLaw.decode(b));
    }
    final cap = gw ? (_rate * 1.5).round() : _rate ~/ 2.5;
    while (_fifo.length > cap) {
      _fifo.removeFirst();
    }
  }

  void _receiveDigitalAudio(AudioPacket packet) {
    final samples = AudioPacket.isLinearPcmModulation(packet.modulation)
        ? AudioPacket.decodeLinearPcm(packet.payload)
        : Int16List.fromList(packet.payload.map(MuLaw.decode).toList());
    if (samples == null) return;
    if (_talker != packet.sender || _rxMod != packet.modulation) {
      _fifo.clear();
      _talker = packet.sender;
    }
    _rxMod = packet.modulation;
    _rxAntDb = packet.antennaDb;
    _lastRx = DateTime.now();
    _fifo.addAll(samples);
    final cap = (_rate * 1.5).round();
    while (_fifo.length > cap) {
      _fifo.removeFirst();
    }
  }

  void _endTalker() {
    if (_talker != null) {
      AppLogger.info(
        'AUDIO',
        'Empfang beendet: Sprecher 0x${_talker!.toRadixString(16)}',
      );
    }
    _talker = null;
    _primed = false;
    _fifo.clear();
    _underruns = 0;
    if (_lastOpen) _tailTicks = 6;
  }

  void _onTick() {
    _lastTickAt = DateTime.now();
    final out = Int16List(_frame);
    _micLevel *= 0.85;

    if (!state.power) {
      if (_talker != null) flush();
      _level = 0;
      onLevel?.call(0);
      _feed(out);
      return;
    }

    if (state.gatewayEnabled) {
      _tickGateway(out);
      return;
    }

    if (_talker != null &&
        (_talker! & 0x7FFFFFFF) != mqtt.senderId &&
        AudioPacket.isDigitalModulation(_rxMod)) {
      _tickLocalDigitalRx(out);
      return;
    }

    if (state.parrot) {
      _tickParrot(out);
      return;
    }

    if (state.transmitting) {
      if (_talker != null) flush();
      onLevel?.call(_micLevel); // Modulationsanzeige beim Senden
      _feed(out);
      return;
    }

    // Sprecher-Timeout (kein Paket mehr)
    if (_talker != null &&
        DateTime.now().difference(_lastRx).inMilliseconds > 300 &&
        _fifo.isEmpty) {
      _endTalker();
    }

    final hasTalker = _talker != null;
    final modMatch = _rxMod == state.modulation.index;

    var strengthDb = 0.0;
    var level = 0.0;
    if (hasTalker) {
      strengthDb = _strengthDb(_rxAntDb);
      level = (strengthDb / 60.0).clamp(0.0, 1.0).toDouble();
    }

    final thresholdDb = state.squelch * 50.0;
    final squelchOpen = hasTalker
        ? strengthDb >= thresholdDb
        : state.squelch < 0.12;
    if (hasTalker || _tailTicks == 0) _lastOpen = squelchOpen;

    final voice = Float64List(_frame);
    var voiceValid = false;
    if (hasTalker) {
      if (!_primed && _fifo.length >= _frame * 3) _primed = true;
      if (_primed) {
        if (_fifo.length >= _frame) {
          for (var i = 0; i < _frame; i++) {
            voice[i] = _fifo.removeFirst() / 32768.0;
          }
          voiceValid = true;
          _underruns = 0;
        } else {
          for (var i = 0; i < _frame && _fifo.isNotEmpty; i++) {
            voice[i] = _fifo.removeFirst() / 32768.0;
          }
          voiceValid = true;
          if (++_underruns > 10) _endTalker();
        }
      }
    }

    if (voiceValid && _rxMod == Modulation.am.index) {
      _shapeAm(voice);
    }

    // SSB frequency offset follows sideband polarity; the center position is neutral.
    if (voiceValid &&
        state.clarifierActive &&
        (_rxMod == Modulation.usb.index || _rxMod == Modulation.lsb.index)) {
      final sidebandDirection = _rxMod == Modulation.lsb.index ? -1.0 : 1.0;
      final hz = (state.clarifier - 0.5) * 1200.0 * sidebandDirection;
      if (hz.abs() >= 15) {
        _shifter.hz = hz;
        for (var i = 0; i < _frame; i++) {
          voice[i] = _shifter.process(voice[i]);
        }
      }
    }

    final playVoice = voiceValid && squelchOpen && modMatch;

    final tail = !hasTalker && _tailTicks > 0;
    if (tail) _tailTicks--;

    final voiceGain = (0.25 + 0.75 * level) * state.rfGain;
    final vol = state.volume * state.volume * 1.6;
    final staticOpen =
        !hasTalker &&
        state.squelch <= 0.01 &&
        (state.modulation == Modulation.fm ||
            state.modulation == Modulation.am);

    for (var i = 0; i < _frame; i++) {
      final v = playVoice ? voice[i] * voiceGain : 0.0;
      final hiss = staticOpen
          ? (_noiseRandom.nextDouble() * 2.0 - 1.0) * 0.07
          : 0.0;
      final mixed = v + hiss;
      final mix = state.noiseBlanker
          ? mixed.clamp(-0.7, 0.7).toDouble()
          : mixed;
      final s = (mix * vol).clamp(-1.0, 1.0).toDouble();
      out[i] = (s * 32767.0).round();
    }

    final meterLevel = hasTalker && modMatch ? level : 0.0;
    if (hasTalker && !modMatch) {
      _level = 0;
    } else {
      _level = meterLevel > _level
          ? meterLevel
          : _level * 0.85 + meterLevel * 0.15;
    }
    if (_level < 0.01) _level = 0;
    onLevel?.call(_level);

    _feed(out);
  }

  void _resetAmFilter() {
    _amLowpass = 0;
    _amHighpassInput = 0;
    _amHighpassOutput = 0;
  }

  void _shapeAm(Float64List samples) {
    final lowpassAlpha = 1 - math.exp(-2 * math.pi * 3000 / _rate);
    final highpassAlpha = math.exp(-2 * math.pi * 250 / _rate);
    for (var i = 0; i < samples.length; i++) {
      final input = samples[i];
      _amHighpassOutput =
          highpassAlpha * (_amHighpassOutput + input - _amHighpassInput);
      _amHighpassInput = input;
      _amLowpass += lowpassAlpha * (_amHighpassOutput - _amLowpass);
      samples[i] = input * 0.3 + _amLowpass * 0.7;
    }
  }

  // ---------- Gateway (echtes Funkgeraet) ----------
  String gwInfo = 'Gateway bereit';
  double get gwInLevel => _gwInLevel;

  final AudioRecorder _gwRec = AudioRecorder();
  StreamSubscription<Uint8List>? _gwSub;
  bool _gwRunning = false;
  final List<int> _gwPcm = <int>[];
  int? _gwOdd;
  final ListQueue<Float64List> _gwPre = ListQueue<Float64List>();
  bool _voxOpen = false;
  int _voxAbove = 0;
  int _voxHangLeft = 0;
  double _gwInLevel = 0;
  DateTime _gwIgnoreUntil = DateTime.fromMillisecondsSinceEpoch(0);
  // Netz -> Funk: 0 = Leerlauf, 1 = Vorlauf, 2 = Senden, 3 = Nachlauf
  int _gwState = 0;
  int _gwTicks = 0;
  int _gwTxTicks = 0;
  int _gwTestTicks = 0;
  double _gwPhase = 0;

  void _setGwInfo(String s) {
    if (s != gwInfo) {
      AppLogger.info('GATEWAY', 'Gateway-Status: $s');
      gwInfo = s;
      onStatus?.call();
    }
  }

  void _gwKey(bool on) {
    final d = ptt;
    if (d == null) return;
    AppLogger.info('GATEWAY', 'PTT-Steuerung: ${on ? "AN" : "AUS"}');
    d.setPtt(on).catchError((Object e) {
      AppLogger.error('GATEWAY', 'PTT-Schaltfehler: $e', e);
      _setError('PTT: $e');
    });
  }

  /// 1,5 s Testton mit PTT (zum Einrichten)
  void gatewayTest() {
    if (_gwRunning && _gwState == 0) _gwTestTicks = 75;
  }

  void _gwTone(Int16List out, double hz, double amp) {
    for (var i = 0; i < _frame; i++) {
      _gwPhase += 2 * math.pi * hz / _rate;
      out[i] = (math.sin(_gwPhase) * amp * 32767.0).round();
    }
    _gwPhase %= 2 * math.pi;
  }

  Future<void> startGateway({String inputId = ''}) async {
    if (_gwRunning) return;
    AppLogger.info(
      'GATEWAY',
      'Starte Gateway Audio-Eingang (inputId: "$inputId")',
    );
    try {
      // 1. Mikrofon-Berechtigung abfragen
      bool hasPerm = false;
      try {
        hasPerm = await _gwRec.hasPermission().timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
      } catch (e) {
        AppLogger.warn('GATEWAY', 'hasPermission Ausnahme: $e');
        hasPerm = false;
      }
      if (!hasPerm) {
        AppLogger.warn(
          'GATEWAY',
          'Mikrofon-Berechtigung fehlt oder nicht erreichbar',
        );
        _setError('Mikrofon-Berechtigung fehlt');
        _setGwInfo('Keine Berechtigung');
        return;
      }

      // 2. Verfügbare Eingabegeräte abrufen
      List<InputDevice> devices = [];
      try {
        devices = await _gwRec.listInputDevices().timeout(
          const Duration(seconds: 2),
          onTimeout: () => <InputDevice>[],
        );
      } catch (e) {
        AppLogger.warn('GATEWAY', 'Fehler beim Abrufen der Eingabegeräte: $e');
        devices = [];
      }

      if (devices.isEmpty) {
        AppLogger.warn(
          'GATEWAY',
          'Keine Audio-Eingabegeräte auf dem System gefunden. Gateway wartet auf manuelle Auswahl.',
        );
        _setError(
          'Kein Audio-Eingang gefunden (Soundkarte in Einstellungen wählen)',
        );
        _setGwInfo('Kein Audiogerät');
        return;
      }

      // 3. Wenn inputId leer ist: Auf manuelle Konfiguration im Menü hinweisen und nicht blind auf Standardgerät zugreifen
      if (inputId.isEmpty) {
        AppLogger.warn(
          'GATEWAY',
          'Kein spezifisches Audio-Eingabegerät konfiguriert. Bitte in Einstellungen wählen.',
        );
        _setError('Bitte Audio-Eingang in Einstellungen wählen');
        _setGwInfo('Eingang nicht gewählt');
        return;
      }

      // 4. Prüfen, ob inputId in den vorhandenen Geräten existiert
      InputDevice? dev;
      for (final d in devices) {
        if (d.id == inputId) {
          dev = d;
          break;
        }
      }

      if (dev == null) {
        AppLogger.warn(
          'GATEWAY',
          'Gespeichertes Audiogerät "$inputId" ist auf diesem PC nicht vorhanden oder offline.',
        );
        _setError(
          'Gespeichertes Audiogerät nicht gefunden (bitte in Einstellungen wählen)',
        );
        _setGwInfo('Gerät offline');
        return;
      }

      AppLogger.info(
        'GATEWAY',
        'Öffne Audiogerät: "${dev.label}" (ID: ${dev.id})',
      );

      Stream<Uint8List>? stream;
      try {
        stream = await _gwRec
            .startStream(
              RecordConfig(
                encoder: AudioEncoder.pcm16bits,
                sampleRate: AppConfig.micRate,
                numChannels: 1,
                device: dev,
                echoCancel: false,
                noiseSuppress: false,
                autoGain: false,
              ),
            )
            .timeout(const Duration(seconds: 5));
      } catch (e, st) {
        AppLogger.error(
          'GATEWAY',
          'startStream fehlgeschlagen für Gerät "${dev.label}": $e',
          e,
          st,
        );
        _setError('Gerät konnte nicht geöffnet werden: $e');
        _setGwInfo('Fehler beim Öffnen');
        return;
      }

      _gwPcm.clear();
      _gwOdd = null;
      _gwPre.clear();
      _voxAbove = 0;
      _gwRunning = true;
      _setGwInfo('Gateway bereit');
      _gwSub = stream.listen(
        _onGwMic,
        onError: (Object e) {
          AppLogger.error('GATEWAY', 'Fehler im Gateway Mikrofon-Stream', e);
          _setError('Gateway-Eingang: $e');
        },
      );
      AppLogger.info('GATEWAY', 'Gateway Audio-Eingang erfolgreich gestartet');
    } catch (e, st) {
      AppLogger.error('GATEWAY', 'Allgemeiner Fehler bei startGateway', e, st);
      _setError('Gateway-Eingang: $e');
      _setGwInfo('Gateway gestoppt');
    }
  }

  Future<void> stopGateway() async {
    AppLogger.info('GATEWAY', 'Stoppe Gateway Audio-Eingang');
    try {
      await _gwSub?.cancel();
    } catch (_) {}
    _gwSub = null;
    try {
      final recording = await _gwRec.isRecording().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      if (recording) {
        await _gwRec.stop().timeout(const Duration(seconds: 2));
      }
    } catch (e) {
      AppLogger.warn('GATEWAY', 'Fehler beim Stoppen von _gwRec: $e');
    }
    _gwRunning = false;
    _gwPcm.clear();
    _gwOdd = null;
    _gwPre.clear();
    _voxAbove = 0;
    _resetDigitalGate();
    if (_voxOpen) _voxClose();
    if (_gwState != 0) {
      _gwKey(false);
      _gwState = 0;
    }
    _gwTestTicks = 0;
    _gwInLevel = 0;
    gwInfo = 'Gateway bereit';
    AppLogger.info('GATEWAY', 'Gateway Audio-Eingang gestoppt');
  }

  void _onGwMic(Uint8List chunk) {
    var data = chunk;
    if (_gwOdd != null) {
      final b = BytesBuilder()
        ..addByte(_gwOdd!)
        ..add(chunk);
      data = b.takeBytes();
      _gwOdd = null;
    }
    if (data.length.isOdd) {
      _gwOdd = data.last;
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    final bd = ByteData.sublistView(data);
    for (var i = 0; i < data.length ~/ 2; i++) {
      _gwPcm.add(bd.getInt16(i * 2, Endian.little));
    }
    const need = _frame * _ratio;
    while (_gwPcm.length >= need) {
      final f = Float64List(_frame);
      var sumSq = 0.0;
      for (var j = 0; j < _frame; j++) {
        var sum = 0;
        for (var k = 0; k < _ratio; k++) {
          sum += _gwPcm[j * _ratio + k];
        }
        var x = sum / _ratio * state.gwInGain;
        if (x > 32767) x = 32767;
        if (x < -32768) x = -32768;
        f[j] = x;
        sumSq += x * x;
      }
      _gwPcm.removeRange(0, need);
      final rms = math.sqrt(sumSq / _frame) / 32768.0;
      _gwProcessFrame(f, (rms / 0.2).clamp(0.0, 1.0).toDouble());
    }
  }

  /// VOX-Erkennung Funk -> Netz
  void _gwProcessFrame(Float64List f, double lvl) {
    _gwInLevel = lvl;
    final digitalMode = state.channel == 25
        ? AudioPacket.sstvModulation
        : state.channel == 24
        ? AudioPacket.packetRadioModulation
        : null;
    if (digitalMode != null) {
      _gwDigitalFrame(f, lvl, digitalMode);
      return;
    }
    if (_digitalGateMode != null) _resetDigitalGate();
    final busy =
        _gwState != 0 ||
        _talker != null ||
        DateTime.now().isBefore(_gwIgnoreUntil);
    if (busy) {
      if (_voxOpen) _voxClose();
      _gwPre.clear();
      _voxAbove = 0;
      return;
    }
    final thr = state.gwVoxThreshold;
    if (!_voxOpen) {
      _gwPre.addLast(f);
      while (_gwPre.length > 5) {
        _gwPre.removeFirst();
      }
      _voxAbove = lvl >= thr ? _voxAbove + 1 : 0;
      if (_voxAbove >= 2) {
        _voxOpen = true;
        _voxHangLeft = (state.gwHangMs / 20).round();
        _seq = 0;
        _txChannel = state.channel;
        _txMod = state.modulation.index;
        _txAnt = state.antennaDb;
        mqtt.publishPtt(_txChannel, true, _txAnt);
        _setGwInfo('Funk → Netz');
        AppLogger.info(
          'GATEWAY',
          'VOX geöffnet: Funk → Netz (Kanal $_txChannel, Mod $_txMod, Pegel ${(lvl * 100).round()}%)',
        );
        for (final pf in _gwPre) {
          _publish(_encode(pf), gw: true);
        }
        _gwPre.clear();
      }
    } else {
      _publish(_encode(f), gw: true);
      if (lvl >= thr * 0.7) {
        _voxHangLeft = (state.gwHangMs / 20).round();
      } else if (--_voxHangLeft <= 0) {
        _voxClose();
      }
    }
  }

  // ---- Digitaler Gateway-Eingang (Kanal 24/25) ----
  final DigitalInputGate _digitalGate = DigitalInputGate();
  int? _digitalGateMode;

  void _resetDigitalGate() {
    _digitalGate.reset();
    _digitalGateMode = null;
  }

  void _gwDigitalFrame(Float64List f, double lvl, int mode) {
    // Gateway sendet gerade (oder gleich) aufs Funkgeraet: Eingang ignorieren
    final busy =
        _gwState != 0 ||
        _talker != null ||
        DateTime.now().isBefore(_gwIgnoreUntil);
    if (busy || _digitalGateMode != mode) _resetDigitalGate();
    if (busy) return;
    _digitalGateMode = mode;
    final frames = _digitalGate.process(
      f,
      lvl,
      threshold: state.gwVoxThreshold,
      hangFrames: (state.gwHangMs / 20).round(),
    );
    for (final frame in frames) {
      if (frame.isEmpty) continue;
      final samples = Int16List(frame.length);
      for (var i = 0; i < frame.length; i++) {
        samples[i] = frame[i].round().clamp(-32768, 32767).toInt();
      }
      onDigitalSamples?.call(
        DigitalPcmFrame(modulation: mode, samples: samples),
      );
    }
  }

  void _voxClose() {
    _voxOpen = false;
    _voxAbove = 0;
    mqtt.publishPtt(_txChannel, false, _txAnt);
    _setGwInfo('Gateway bereit');
    AppLogger.info('GATEWAY', 'VOX geschlossen: Funk → Netz beendet');
  }

  /// Netz -> Funk: Sprache aus dem Puffer, PTT/Weckton steuern
  void _tickGateway(Int16List out) {
    final now = DateTime.now();
    if (_talker != null &&
        now.difference(_lastRx).inMilliseconds > 300 &&
        _fifo.isEmpty) {
      _talker = null;
      _primed = false;
    }
    final hasTalker = _talker != null;
    final testing = _gwTestTicks > 0;
    final primed = hasTalker && _fifo.length >= _frame * 3;
    final preFrames = (state.gwPreMs / 20).round();
    final postFrames = (state.gwPostMs / 20).round();
    final voxMode = ptt == null;
    final voxBox = state.gatewayMode == GatewayMode.voxBox;

    // Sicherheits-Sendezeitbegrenzung
    if (_gwState != 0) {
      if (++_gwTxTicks > AppConfig.gwMaxTxSeconds * 50) {
        AppLogger.warn(
          'GATEWAY',
          'Sicherheits-Sendezeitbegrenzung (${AppConfig.gwMaxTxSeconds} s) erreicht!',
        );
        _gwKey(false);
        _gwState = 0;
        _gwTxTicks = 0;
        _fifo.clear();
        _talker = null;
        _gwTestTicks = 0;
        _gwIgnoreUntil = now.add(const Duration(seconds: 5));
        _setGwInfo('Sendezeit-Limit erreicht');
        onLevel?.call(0);
        _feed(out);
        return;
      }
    } else {
      _gwTxTicks = 0;
    }

    if (_gwState == 0) {
      if (primed || testing) {
        _gwState = 1;
        _gwTicks = preFrames;
        _gwKey(true);
        _setGwInfo('Netz → Funk (Senden)');
      }
    } else if (_gwState == 1) {
      if (voxMode && preFrames > 0) {
        _gwTone(
          out,
          voxBox ? AppConfig.gwKeyToneHz : AppConfig.gwVoxToneHz,
          voxBox ? 0.6 : 0.25,
        );
      }
      if (--_gwTicks <= 0) _gwState = 2;
    } else if (_gwState == 2) {
      if (testing) {
        _gwTone(out, 1000, 0.5);
        if (--_gwTestTicks <= 0) {
          _gwState = 3;
          _gwTicks = postFrames;
        }
      } else {
        final gain = state.gwOutGain;
        for (var i = 0; i < _frame && _fifo.isNotEmpty; i++) {
          final v = (_fifo.removeFirst() / 32768.0 * gain)
              .clamp(-1.0, 1.0)
              .toDouble();
          out[i] = (v * 32767.0).round();
        }
        if (!hasTalker && _fifo.isEmpty) {
          _gwState = 3;
          _gwTicks = postFrames;
        }
      }
    } else {
      if (primed) {
        _gwState = 2;
      } else if (--_gwTicks <= 0) {
        _gwKey(false);
        _gwState = 0;
        _gwIgnoreUntil = now.add(const Duration(milliseconds: 600));
        _setGwInfo('Gateway bereit');
      }
    }

    var peak = 0.0;
    for (var i = 0; i < _frame; i++) {
      final a = out[i].abs() / 32768.0;
      if (a > peak) peak = a;
    }
    onLevel?.call(
      _gwState == 0 ? _gwInLevel : (peak * 2.0).clamp(0.0, 1.0).toDouble(),
    );
    _feed(out);
  }

  void _tickLocalDigitalRx(Int16List out) {
    final gain = state.volume;
    var peak = 0.0;
    for (var i = 0; i < _frame && _fifo.isNotEmpty; i++) {
      final sample = (_fifo.removeFirst() * gain)
          .round()
          .clamp(-32768, 32767)
          .toInt();
      out[i] = sample;
      peak = math.max(peak, sample.abs() / 32768.0);
    }
    onLevel?.call((peak * 2.0).clamp(0.0, 1.0).toDouble());
    _feed(out);
    if (_fifo.isEmpty &&
        DateTime.now().difference(_lastRx) >
            const Duration(milliseconds: 300)) {
      _endTalker();
    }
  }

  // ---------- Papagei: eigene Aufnahme abspielen ----------
  void _tickParrot(Int16List out) {
    if (_talker != null) flush();
    double lvl;
    if (_parrotPlay.isNotEmpty) {
      final vol = state.volume * state.volume * 1.6;
      var peak = 0.0;
      for (var i = 0; i < _frame && _parrotPlay.isNotEmpty; i++) {
        final v = _parrotPlay.removeFirst() / 32768.0;
        final s = (v * vol).clamp(-1.0, 1.0).toDouble();
        out[i] = (s * 32767.0).round();
        if (s.abs() > peak) peak = s.abs();
      }
      lvl = (peak * 2.0).clamp(0.0, 1.0).toDouble();
    } else {
      lvl = state.transmitting ? _micLevel : 0.0;
    }
    onLevel?.call(lvl);
    _feed(out);
  }

  // ---------- Echo ----------
  final Float64List _echoBuf = Float64List(_echoLen);
  int _echoIdx = 0;

  double _echoDo(double x) {
    if (!state.echo) return x;
    final d = _echoBuf[_echoIdx];
    _echoBuf[_echoIdx] = x + d * 0.40; // Rueckkopplung
    _echoIdx = (_echoIdx + 1) % _echoLen;
    return x + d * 0.55; // Echo-Anteil
  }

  // ---------- Roger-Beep + Echo-Schwanz ----------
  Timer? _tailTimer;
  int _rogerIdx = 0;
  int _rogerTotal = 0;
  int _echoLeft = 0;
  double _tonePhase = 0;

  static int _rogerFrames(int mode) {
    switch (mode) {
      case 1:
        return 8; // 160 ms
      case 2:
        return 8; // Doppelton
      case 3:
        return 6; // 120 ms
      case 4:
        return 9; // Morse K: Strich, Punkt, Strich
      case 5:
        return 8; // Modulationstest
      default:
        return 0;
    }
  }

  static double _rogerFreq(int mode, int idx) {
    switch (mode) {
      case 1:
        return 1000;
      case 2:
        return idx < 4 ? 1500 : 1000;
      case 3:
        return 2500;
      case 4:
        return (idx <= 2 || idx == 4 || idx >= 6) ? 1000 : 0;
      case 5:
        return idx.isEven ? 700 : 1700;
      default:
        return 0;
    }
  }

  void _beginTail() {
    _rogerIdx = 0;
    _rogerTotal = _rogerFrames(state.beepMode);
    _echoLeft = state.echo ? 60 : 0; // 1,2 s Echo-Ausklang
    _tonePhase = 0;
  }

  /// naechstes 20-ms-Frame (int16-Einheiten) oder null, wenn nichts mehr kommt
  Float64List? _nextTailFrame() {
    final f = Float64List(_frame);
    if (_rogerIdx < _rogerTotal) {
      final mode = state.beepMode;
      if (mode == 3) {
        for (var i = 0; i < _frame; i++) {
          final elapsed = _rogerIdx * _frame + i;
          final freq =
              850 +
              650 *
                  (0.5 +
                      0.5 * math.sin(2 * math.pi * elapsed / (_rate * 0.12)));
          _tonePhase += 2 * math.pi * freq / _rate;
          f[i] = math.sin(_tonePhase) * 13000.0;
        }
      } else {
        final freq = _rogerFreq(mode, _rogerIdx);
        if (freq > 0) {
          for (var i = 0; i < _frame; i++) {
            _tonePhase += 2 * math.pi * freq / _rate;
            f[i] = math.sin(_tonePhase) * 13000.0;
          }
        }
      }
      _rogerIdx++;
    } else if (_echoLeft > 0) {
      _echoLeft--;
    } else {
      return null;
    }
    for (var i = 0; i < _frame; i++) {
      f[i] = _echoDo(f[i]);
    }
    return f;
  }

  Uint8List _encode(Float64List f) {
    final enc = Uint8List(_frame);
    for (var j = 0; j < _frame; j++) {
      var v = f[j].round();
      if (v > 32767) v = 32767;
      if (v < -32768) v = -32768;
      enc[j] = MuLaw.encode(v);
    }
    return enc;
  }

  void queueDigitalTxSamples({
    required int channel,
    required int modulation,
    required Int16List samples,
  }) {
    if (!state.power ||
        !state.gatewayEnabled ||
        channel != state.channel ||
        !AudioPacket.isDigitalModulation(modulation)) {
      return;
    }
    final sender = mqtt.senderId;
    if (_talker != null && _talker != sender) return;
    if (_talker != sender) {
      _fifo.clear();
      _talker = sender;
      _primed = false;
    }
    _rxMod = modulation;
    _rxAntDb = state.antennaDb;
    _lastRx = DateTime.now();
    _fifo.addAll(samples);
    final cap = (_rate * 1.5).round();
    while (_fifo.length > cap) {
      _fifo.removeFirst();
    }
  }

  void _publish(Uint8List enc, {bool gw = false}) {
    mqtt.publishAudio(
      AudioPacket(
        // Bit 31 = Paket stammt von einem Gateway (verhindert Gateway-Schleifen)
        sender: gw ? (mqtt.senderId | 0x80000000) : mqtt.senderId,
        channel: _txChannel,
        modulation: _txMod,
        antennaDb: _txAnt,
        seq: _seq++,
        payload: enc,
      ).toBytes(),
    );
  }

  void _startTail() {
    _tailTimer?.cancel();
    _tailTimer = Timer.periodic(const Duration(milliseconds: 20), (t) {
      final f = _nextTailFrame();
      if (f == null) {
        t.cancel();
        _tailTimer = null;
        return;
      }
      _publish(_encode(f));
    });
  }

  void _finishParrot() {
    for (;;) {
      final f = _nextTailFrame();
      if (f == null) break;
      final enc = _encode(f);
      for (final b in enc) {
        if (_parrotRec.length < _rate * 20) _parrotRec.add(MuLaw.decode(b));
      }
    }
    _parrotPlay
      ..clear()
      ..addAll(_parrotRec);
    AppLogger.info(
      'AUDIO',
      'Papagei-Aufnahme abgeschlossen: ${_parrotRec.length} Samples, Wiedergabe vorbereitet: ${_parrotPlay.length} Samples',
    );
    _parrotRec.clear();
  }

  // ---------- Senden ----------
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  int _txToken = 0;
  int _seq = 0;
  bool _txActive = false;
  int _txChannel = 1;
  int _txMod = 0;
  int _txAnt = 0;
  final List<int> _txPcm = <int>[];
  int? _oddByte;

  /// Alle Mikrofon-Aufrufe (start/stop) laufen nacheinander, nie
  /// gleichzeitig: schnelles Druecken/Loslassen der Sendetaste hat sonst
  /// start() und stop() des nativen Recorders ueberlappen lassen.
  Future<void> _micQueue = Future<void>.value();

  Future<void> _enqueueMic(Future<void> Function() op) {
    final next = _micQueue.then((_) => op()).catchError((
      Object e,
      StackTrace st,
    ) {
      AppLogger.error('AUDIO', 'Mikrofon-Operation fehlgeschlagen: $e', e, st);
    });
    _micQueue = next;
    return next;
  }

  Future<void> startTx() {
    final token = ++_txToken;
    _tailTimer?.cancel();
    _tailTimer = null;
    AppLogger.info(
      'AUDIO',
      'startTx: PTT gedrückt (Kanal ${state.channel}, Mod ${state.modulation.name}, Papagei: ${state.parrot})',
    );
    return _enqueueMic(() => _startTxImpl(token));
  }

  Future<void> _startTxImpl(int token) async {
    if (token != _txToken) return; // PTT schon wieder losgelassen

    // Defensiv: laufende Aufnahme zuerst stoppen (verhindert doppelte MF-Session)
    try {
      if (await _rec.isRecording().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      )) {
        await _rec.stop().timeout(const Duration(seconds: 2));
      }
    } catch (_) {}

    try {
      // hasPermission() kann auf bestimmten Windows-10-Treibern hängen → Timeout
      bool hasPerm = false;
      try {
        hasPerm = await _rec.hasPermission().timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
      } catch (_) {
        hasPerm = false;
      }
      if (!hasPerm) {
        AppLogger.error('AUDIO', 'startTx: Mikrofon-Berechtigung fehlt');
        _setError(
          Platform.isWindows
              ? 'Mikrofon gesperrt (Windows-Einstellungen › Datenschutz › Mikrofon)'
              : 'Mikrofon-Berechtigung fehlt',
        );
        return;
      }
      if (token != _txToken) return;

      // Direkt starten; die Geräteliste wird nur im Fehlerfall abgefragt
      // (spart bei jedem Drücken der Sendetaste Zeit = kein abgeschnittener
      // Wortanfang).
      Stream<Uint8List>? stream;
      try {
        stream = await _rec
            .startStream(
              const RecordConfig(
                encoder: AudioEncoder.pcm16bits,
                sampleRate: AppConfig.micRate,
                numChannels: 1,
                echoCancel: false,
                noiseSuppress: false,
                autoGain: false,
              ),
            )
            .timeout(const Duration(seconds: 5));
      } catch (e, st) {
        AppLogger.error(
          'AUDIO',
          'startTx: Mikrofon konnte nicht gestartet werden: $e',
          e,
          st,
        );
        var devices = <InputDevice>[];
        try {
          devices = await _rec.listInputDevices().timeout(
            const Duration(seconds: 2),
            onTimeout: () => <InputDevice>[],
          );
        } catch (_) {}
        _setError(
          devices.isEmpty
              ? 'Kein Mikrofon gefunden'
              : 'Mikrofon konnte nicht gestartet werden: $e',
        );
        return;
      }

      if (token != _txToken) {
        // PTT wurde inzwischen losgelassen – Aufnahme sofort wieder stoppen
        try {
          await _rec.stop().timeout(const Duration(seconds: 2));
        } catch (_) {}
        return;
      }

      _txPcm.clear();
      _oddByte = null;
      _seq = 0;
      _txChannel = state.channel;
      _txMod = state.modulation.index;
      _txAnt = state.antennaDb;
      _txParrot = state.parrot;
      _echoBuf.fillRange(0, _echoLen, 0);
      _echoIdx = 0;
      _parrotRec.clear();
      if (_txParrot) _parrotPlay.clear();
      _txActive = true;
      if (error != null) _setError(null);
      _micSub = stream.listen(
        _onMic,
        onError: (Object e) {
          AppLogger.error('AUDIO', 'startTx: Mikrofon-Stream-Fehler: $e', e);
          _setError('Mikrofon-Fehler: $e');
          _txActive = false;
        },
        cancelOnError: false,
      );
      AppLogger.info('AUDIO', 'startTx: Mikrofon-Aufnahme läuft aktiv');
    } catch (e, st) {
      AppLogger.error('AUDIO', 'startTx: Unerwarteter Fehler: $e', e, st);
      _setError('Mikrofon: $e');
      _txActive = false;
    }
  }

  Future<void> stopTx() {
    final token = ++_txToken;
    final had = _txActive;
    final wasParrot = _txParrot;
    _txActive = false; // ab sofort keine Mikrofon-Daten mehr senden
    AppLogger.info(
      'AUDIO',
      'stopTx: PTT losgelassen (hatte gesendet: $had, Papagei: $wasParrot)',
    );
    return _enqueueMic(() => _stopTxImpl(token, had, wasParrot));
  }

  Future<void> _stopTxImpl(int token, bool had, bool wasParrot) async {
    // micSub cancel darf nie werfen
    try {
      await _micSub?.cancel();
    } catch (_) {}
    _micSub = null;

    // isRecording() / stop() können auf fehlerhaften Windows-Treibern werfen → Timeouts
    try {
      final recording = await _rec.isRecording().timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
      if (recording) {
        await _rec.stop().timeout(const Duration(seconds: 3));
      }
    } catch (e) {
      AppLogger.warn('AUDIO', 'stopTx: Fehler beim Stoppen von _rec: $e');
    }

    _txPcm.clear();
    _oddByte = null;
    if (!had || token != _txToken) return; // inzwischen neues PTT

    // Roger-Beep und Echo-Ausklang
    _beginTail();
    if (wasParrot) {
      _finishParrot();
    } else if (_rogerTotal > 0 || _echoLeft > 0) {
      _startTail();
    }
  }

  void _onMic(Uint8List chunk) {
    if (!_txActive) return; // PTT schon losgelassen, Stream laeuft noch aus
    var data = chunk;
    if (_oddByte != null) {
      final b = BytesBuilder()
        ..addByte(_oddByte!)
        ..add(chunk);
      data = b.takeBytes();
      _oddByte = null;
    }
    if (data.length.isOdd) {
      _oddByte = data.last;
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    final bd = ByteData.sublistView(data);
    for (var i = 0; i < data.length ~/ 2; i++) {
      _txPcm.add(bd.getInt16(i * 2, Endian.little));
    }

    const need = _frame * _ratio;
    while (_txPcm.length >= need) {
      final f = Float64List(_frame);
      var peak = 0.0;
      for (var j = 0; j < _frame; j++) {
        var sum = 0;
        for (var k = 0; k < _ratio; k++) {
          sum += _txPcm[j * _ratio + k];
        }
        var x = sum / _ratio * txGain * state.micSensitivity;
        x = _echoDo(x);
        if (x > 32767) x = 32767;
        if (x < -32768) x = -32768;
        f[j] = x;
        if (x.abs() > peak) peak = x.abs();
      }
      _txPcm.removeRange(0, need);
      final lv = (peak / 32768.0 * 3.0).clamp(0.0, 1.0).toDouble();
      if (lv > _micLevel) _micLevel = lv;

      final enc = _encode(f);
      if (_txParrot) {
        for (final b in enc) {
          if (_parrotRec.length < _rate * 20) _parrotRec.add(MuLaw.decode(b));
        }
      } else {
        _publish(enc);
      }
    }
  }

  Future<void> dispose() async {
    AppLogger.info('AUDIO', 'AudioEngine wird freigegeben (dispose)');
    _tick?.cancel();
    _tailTimer?.cancel();
    try {
      await _audioSub?.cancel();
    } catch (_) {}
    try {
      await _ctlSub?.cancel();
    } catch (_) {}
    try {
      await _deviceStartFailureSub?.cancel();
    } catch (_) {}
    _deviceStartFailureSub = null;
    try {
      await stopTx().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await stopGateway().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await _rec.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
    try {
      await _gwRec.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {}
    final handle = _outHandle;
    final output = _out;
    _outHandle = null;
    _out = null;
    if (SoLoud.instance.isInitialized) {
      if (handle != null) {
        try {
          await SoLoud.instance
              .stop(handle)
              .timeout(const Duration(milliseconds: 500));
        } catch (_) {}
      }
      if (output != null) {
        try {
          await SoLoud.instance
              .disposeSource(output)
              .timeout(const Duration(milliseconds: 500));
        } catch (_) {}
      }
    }
    AppLogger.info('AUDIO', 'AudioEngine erfolgreich beendet');
  }
}

/// Pegelschwelle fuer den digitalen Gateway-Eingang (SSTV/Packet, Kanal 24/25).
///
/// Wie beim VOX gibt erst ein Signal ueber der Schwelle (zwei Frames in Folge)
/// den Eingang frei; nach dem Nachlauf schliesst er wieder. Ohne Schwelle
/// landen Stille und Rauschen dauerhaft im SSTV-/Packet-Puffer: der Empfang
/// endet nie, und der Bildanfang liegt nicht am Pufferanfang. Das erste Frame
/// wird ab dem Signalbeginn weitergegeben, weil SSTV den Bildanfang am
/// Pufferanfang erwartet.
class DigitalInputGate {
  bool _open = false;
  int _above = 0;
  int _hangLeft = 0;
  Float64List? _pending;

  bool get isOpen => _open;

  void reset() {
    _open = false;
    _above = 0;
    _hangLeft = 0;
    _pending = null;
  }

  /// [level] wie beim VOX: RMS / 32768 / 0,2 (0..1). Liefert die Frames, die
  /// an SSTV/Packet weitergegeben werden.
  List<Float64List> process(
    Float64List frame,
    double level, {
    required double threshold,
    required int hangFrames,
  }) {
    if (!_open) {
      if (level < threshold) {
        _above = 0;
        _pending = null;
        return const <Float64List>[];
      }
      if (++_above < 2) {
        _pending = _trimOnset(frame, threshold);
        return const <Float64List>[];
      }
      _open = true;
      _hangLeft = hangFrames;
      final pending = _pending;
      _pending = null;
      return <Float64List>[if (pending != null) pending, frame];
    }
    if (level >= threshold * 0.7) {
      _hangLeft = hangFrames;
    } else if (--_hangLeft <= 0) {
      // Nachlauf vorbei: dieses Frame gehoert noch dazu, dann zu
      _open = false;
      _above = 0;
    }
    return <Float64List>[frame];
  }

  static Float64List _trimOnset(Float64List frame, double threshold) {
    // Schwelle als Amplitude (RMS-Wert), halbiert als Einsatzpunkt
    final onset = threshold * 0.2 * 32768.0 * 0.5;
    for (var i = 0; i < frame.length; i++) {
      if (frame[i].abs() >= onset) return Float64List.sublistView(frame, i);
    }
    return frame;
  }
}
