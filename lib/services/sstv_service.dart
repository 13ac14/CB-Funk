import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../audio/audio_engine.dart';
import '../audio/audio_packet.dart';
import '../audio/mulaw.dart';
import '../state/radio_controller.dart';
import 'sstv_image_store.dart';
import 'sstv_modem.dart';

class SstvService extends ChangeNotifier {
  SstvService(this.radio, {SstvImageStore? store})
    : store = store ?? SstvImageStore() {
    _audioSubscription = radio.mqtt.audioStream.listen(_onAudio);
    _controlSubscription = radio.mqtt.ctlStream.listen(_onControl);
    _gatewaySubscription = radio.digitalPcmStream.listen(_onGatewayAudio);
    unawaited(_loadInitialRecent());
  }

  static const int _maximumImageBytes = 32 * 1024 * 1024;

  final RadioController radio;
  final SstvImageStore store;
  final List<int> _receiveSamples = <int>[];
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<Map<String, dynamic>>? _controlSubscription;
  StreamSubscription<DigitalPcmFrame>? _gatewaySubscription;
  Timer? _receiveQuietTimer;
  bool _isDisposed = false;
  bool _decoding = false;
  int _decodeToken = 0;
  Future<void>? _partialDecodeTask;
  Uint8List? _partialRgba;
  int _partialLinesDecoded = 0;
  ui.Image? liveImage;
  SstvMode selectedMode = SstvMode.martin1;
  Uint8List? loadedImage;
  String? loadedImageName;
  List<File> recentImages = const <File>[];
  bool active = false;
  bool loadingImage = false;
  bool sending = false;
  bool receiving = false;
  bool decoding = false;
  double progress = 0;
  String status = 'SSTV · Martin 1 · Kanal 25';
  Object? lastError;

  bool get channelReady => radio.channel == 25;
  bool get modeLocked => loadingImage || sending || receiving || decoding;

  void setActive(bool value) {
    active = value;
    if (!active) {
      _decodeToken++;
      _receiveQuietTimer?.cancel();
      _receiveSamples.clear();
      receiving = false;
    }
    _notify();
  }

  void setMode(SstvMode mode) {
    if (modeLocked) return;
    selectedMode = mode;
    status = 'SSTV · ${mode.label}';
    _notify();
  }

  Future<void> loadImage(Future<File?> Function() imagePicker) async {
    if (loadingImage) return;
    final previousStatus = status;
    loadingImage = true;
    status = 'Bild wird geladen …';
    lastError = null;
    _notify();
    try {
      final file = await imagePicker();
      if (file == null) {
        status = previousStatus;
        return;
      }
      if (_isDisposed) return;
      final length = await file.length();
      if (length <= 0 || length > _maximumImageBytes) {
        throw FileSystemException(
          'Das Bild muss zwischen 1 Byte und 32 MB groß sein',
          file.path,
        );
      }
      final bytes = await file.readAsBytes();
      if (_isDisposed) return;
      if (bytes.isEmpty) throw const FormatException('Die Bilddatei ist leer');
      final mode = selectedMode;
      loadedImage = await SstvModem.normalizeImage(bytes, mode);
      if (_isDisposed) return;
      loadedImageName = file.uri.pathSegments.last;
      status = 'Bild geladen · $loadedImageName · auf SSTV-Größe angepasst';
    } catch (error) {
      if (!_isDisposed) {
        lastError = error;
        status = 'Bild konnte nicht geladen werden';
      }
      rethrow;
    } finally {
      loadingImage = false;
      _notify();
    }
  }

  Future<void> send() async {
    if (!active) throw StateError('SSTV-Fenster ist geschlossen');
    final image = loadedImage;
    if (image == null) throw StateError('Bitte zuerst ein Bild laden');
    if (!channelReady) throw StateError('Nur auf Kanal 25 aktiv');

    sending = true;
    progress = 0;
    status = 'Sende ${selectedMode.label} …';
    lastError = null;
    _notify();
    try {
      await radio.transmitDigitalAudio(
        mode: AudioPacket.sstvLinearPcmModulation,
        requiredChannel: 25,
        frames: SstvModem.encodeImage(
          image,
          selectedMode,
          onProgress: (value) {
            progress = value;
            _notify();
          },
        ),
      );
      await store.saveImage(image, sent: true);
      await refreshRecent();
      status = 'Gesendet · ${selectedMode.label} · Kanal 25';
    } finally {
      sending = false;
      _notify();
    }
  }

  Future<void> refreshRecent() async {
    final files = await store.recent();
    if (_isDisposed) return;
    recentImages = files;
    _notify();
  }

  Future<void> _loadInitialRecent() async {
    try {
      await refreshRecent();
    } catch (error) {
      lastError = error;
      status = 'Lokale SSTV-Bilder nicht verfügbar';
      _notify();
    }
  }

  void _onAudio(Uint8List data) {
    if (!active || !channelReady) return;
    final packet = AudioPacket.parse(data);
    if (packet == null ||
        packet.channel != 25 ||
        !AudioPacket.isSstvModulation(packet.modulation) ||
        (packet.sender & 0x7fffffff) == radio.mqtt.senderId) {
      return;
    }
    final samples = AudioPacket.isLinearPcmModulation(packet.modulation)
        ? AudioPacket.decodeLinearPcm(packet.payload)
        : Int16List.fromList(packet.payload.map(MuLaw.decode).toList());
    if (samples != null) _appendSamples(samples);
  }

  void _onGatewayAudio(DigitalPcmFrame frame) {
    if (!active ||
        !channelReady ||
        !AudioPacket.isSstvModulation(frame.modulation)) {
      return;
    }
    _appendSamples(frame.samples);
  }

  void _appendSamples(Iterable<int> samples) {
    if (!receiving) {
      _partialRgba = null;
      _partialLinesDecoded = 0;
      progress = 0;
    }
    receiving = true;
    lastError = null;
    _receiveSamples.addAll(samples);
    const maximumSamples = 8 * 180 * SstvModem.sampleRate;
    if (_receiveSamples.length > maximumSamples) {
      _receiveSamples.removeRange(0, _receiveSamples.length - maximumSamples);
    }
    _receiveQuietTimer?.cancel();
    _receiveQuietTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_finishReceive()),
    );
    _schedulePartialDecode();
    _notify();
  }

  void _schedulePartialDecode() {
    if (_isDisposed || _partialDecodeTask != null) return;
    final task = _decodeAvailableLines();
    _partialDecodeTask = task;
    unawaited(
      task.whenComplete(() {
        _partialDecodeTask = null;
        if (!_isDisposed &&
            active &&
            SstvModem.completeLineCount(_receiveSamples.length, selectedMode) >
                _partialLinesDecoded) {
          _schedulePartialDecode();
        }
      }),
    );
  }

  Future<void> _decodeAvailableLines() async {
    try {
      final mode = selectedMode;
      final height = SstvModem.imageHeight(mode);
      _partialRgba ??= Uint8List(320 * height * 4);
      final available = SstvModem.completeLineCount(
        _receiveSamples.length,
        mode,
      );
      while (_partialLinesDecoded < available) {
        if (!SstvModem.decodeLine(
          _receiveSamples,
          mode,
          _partialLinesDecoded,
          _partialRgba!,
        )) {
          break;
        }
        _partialLinesDecoded++;
        progress = _partialLinesDecoded / height;
        final preview = await store.frameToImage(
          SstvDecodedFrame(
            width: 320,
            height: height,
            rgba: Uint8List.fromList(_partialRgba!),
            linesDecoded: _partialLinesDecoded,
          ),
        );
        if (_isDisposed) {
          preview.dispose();
          return;
        }
        final previous = liveImage;
        liveImage = preview;
        if (previous != null) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            previous.dispose();
          });
        }
        _notify();
      }
    } catch (error) {
      lastError = error;
      status = 'SSTV-Zeilenempfang fehlgeschlagen';
      _notify();
    }
  }

  void _onControl(Map<String, dynamic> message) {
    if (!active ||
        message['ch'] != 25 ||
        message['ptt'] != false ||
        message['sid'] == radio.mqtt.senderId) {
      return;
    }
    unawaited(_finishReceive());
  }

  Future<void> _finishReceive() async {
    if (_isDisposed ||
        !active ||
        _decoding ||
        _receiveSamples.length < SstvModem.sampleRate) {
      return;
    }
    _receiveQuietTimer?.cancel();
    await _partialDecodeTask;
    if (_isDisposed) return;
    _decoding = true;
    final pcm = Int16List.fromList(_receiveSamples);
    _receiveSamples.clear();
    receiving = false;
    decoding = true;
    status = 'Synchronisiere ${selectedMode.label} …';
    _notify();
    try {
      final mode = selectedMode;
      final token = _decodeToken;
      final (resultToken, frame) = await SstvModem.decodeInIsolate(
        pcm,
        mode,
        token: token,
      );
      if (resultToken != token) return;
      if (_isDisposed || token != _decodeToken) return;
      if (frame == null) {
        status = 'Kein gültiger SSTV-Sync erkannt';
        _notify();
        return;
      }
      await store.saveFrame(frame, sent: false);
      await refreshRecent();
      progress = 1;
      status = 'Bild empfangen · Auto-Slant korrigiert';
    } catch (error) {
      lastError = error;
      status = 'SSTV-Empfang fehlgeschlagen';
    } finally {
      decoding = false;
      _decoding = false;
      if (!_isDisposed &&
          active &&
          _receiveSamples.length >= SstvModem.sampleRate) {
        _receiveQuietTimer = Timer(
          const Duration(seconds: 2),
          () => unawaited(_finishReceive()),
        );
      }
      _notify();
    }
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _decodeToken++;
    _receiveQuietTimer?.cancel();
    _audioSubscription?.cancel();
    _controlSubscription?.cancel();
    _gatewaySubscription?.cancel();
    liveImage?.dispose();
    liveImage = null;
    super.dispose();
  }
}
