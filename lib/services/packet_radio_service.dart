import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/audio_engine.dart';
import '../audio/audio_packet.dart';
import '../audio/mulaw.dart';
import '../state/radio_controller.dart';
import 'packet_radio_modem.dart';

class PacketRadioEntry {
  const PacketRadioEntry({
    required this.time,
    required this.from,
    required this.to,
    required this.text,
    required this.sent,
  });

  final DateTime time;
  final String from;
  final String to;
  final String text;
  final bool sent;
}

class PacketRadioService extends ChangeNotifier {
  PacketRadioService(this.radio) {
    _audioSubscription = radio.mqtt.audioStream.listen(_onAudio);
    _controlSubscription = radio.mqtt.ctlStream.listen(_onControl);
    _gatewaySubscription = radio.digitalPcmStream.listen(_onGatewayAudio);
  }

  final RadioController radio;
  final List<PacketRadioEntry> _entries = <PacketRadioEntry>[];
  final List<int> _receiveSamples = <int>[];
  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<Map<String, dynamic>>? _controlSubscription;
  StreamSubscription<DigitalPcmFrame>? _gatewaySubscription;
  Timer? _receiveQuietTimer;
  bool _decoding = false;
  bool _isDisposed = false;
  bool active = false;
  bool logging = false;
  bool sending = false;
  String status = 'Packet Radio · 1200 Baud AFSK';

  List<PacketRadioEntry> get entries =>
      List<PacketRadioEntry>.unmodifiable(_entries);

  void setLogging(bool value) {
    logging = value;
    if (!_isDisposed) notifyListeners();
  }

  void setActive(bool value) {
    active = value;
    if (!active) {
      _receiveQuietTimer?.cancel();
      _receiveSamples.clear();
    }
    if (!_isDisposed) notifyListeners();
  }

  Future<void> send({required String to, required String text}) async {
    if (!active) throw StateError('Packet-Radio-Fenster ist geschlossen');
    final from = radio.callSign.trim().toUpperCase();
    if (from.isEmpty) throw StateError('Bitte zuerst ein Rufzeichen eintragen');
    final destination = to.trim().toUpperCase();
    if (destination.isEmpty || text.trim().isEmpty) {
      throw ArgumentError('Empfänger und Nachricht dürfen nicht leer sein');
    }

    final pcm = PacketRadioModem.modulate(
      from: from,
      to: destination,
      text: text,
    );
    sending = true;
    status = 'Sende an $destination …';
    if (!_isDisposed) notifyListeners();
    try {
      await radio.transmitDigitalAudio(
        mode: AudioPacket.packetRadioLinearPcmModulation,
        requiredChannel: 24,
        frames: _frames(pcm),
      );
      final entry = PacketRadioEntry(
        time: DateTime.now(),
        from: from,
        to: destination,
        text: text,
        sent: true,
      );
      _addEntry(entry);
      if (logging) await _appendLog(entry);
      status = 'Gesendet · Kanal 24 · 1200 Baud';
    } catch (error) {
      status = 'Senden fehlgeschlagen: $error';
      rethrow;
    } finally {
      sending = false;
      if (!_isDisposed) notifyListeners();
    }
  }

  Stream<Int16List> _frames(Int16List pcm) async* {
    for (var offset = 0; offset < pcm.length; offset += 160) {
      final end = (offset + 160).clamp(0, pcm.length);
      yield Int16List.sublistView(pcm, offset, end);
    }
  }

  void _onAudio(Uint8List data) {
    if (!active || radio.channel != 24) return;
    final packet = AudioPacket.parse(data);
    if (packet == null ||
        packet.channel != 24 ||
        !AudioPacket.isPacketRadioModulation(packet.modulation) ||
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
        radio.channel != 24 ||
        !AudioPacket.isPacketRadioModulation(frame.modulation)) {
      return;
    }
    _appendSamples(frame.samples);
  }

  void _appendSamples(Iterable<int> samples) {
    // Hoechstens 60 s puffern. Der Rahmenanfang bleibt erhalten; Ueberlauf
    // wird verworfen statt den Anfang abzuschneiden.
    const maximumSamples = 60 * PacketRadioModem.sampleRate;
    final free = maximumSamples - _receiveSamples.length;
    if (free > 0) _receiveSamples.addAll(samples.take(free));
    _receiveQuietTimer?.cancel();
    _receiveQuietTimer = Timer(
      const Duration(milliseconds: 900),
      () => unawaited(_finishReceive()),
    );
  }

  void _onControl(Map<String, dynamic> message) {
    if (!active ||
        message['ch'] != 24 ||
        message['ptt'] != false ||
        message['sid'] == radio.mqtt.senderId) {
      return;
    }
    unawaited(_finishReceive());
  }

  Future<void> _finishReceive() async {
    if (!active || _decoding || _receiveSamples.length < 1600) return;
    _receiveQuietTimer?.cancel();
    final pcm = Int16List.fromList(_receiveSamples);
    _receiveSamples.clear();
    _decoding = true;
    try {
      final decoded = await compute(PacketRadioModem.decodePcm, pcm);
      if (_isDisposed || decoded == null) return;
      final entry = PacketRadioEntry(
        time: DateTime.now(),
        from: decoded.from,
        to: decoded.to,
        text: decoded.text,
        sent: false,
      );
      _addEntry(entry);
      if (logging) await _appendLog(entry);
      status = 'Empfangen · ${decoded.from} > ${decoded.to}';
      if (!_isDisposed) notifyListeners();
    } catch (error) {
      status = 'Packet-Radio-Empfang/Log fehlgeschlagen: $error';
      if (!_isDisposed) notifyListeners();
    } finally {
      _decoding = false;
      if (active && _receiveSamples.length >= 1600) {
        _receiveQuietTimer = Timer(
          const Duration(milliseconds: 900),
          () => unawaited(_finishReceive()),
        );
      }
    }
  }

  void _addEntry(PacketRadioEntry entry) {
    _entries.add(entry);
    if (_entries.length > 200) _entries.removeAt(0);
    if (!_isDisposed) notifyListeners();
  }

  Future<void> _appendLog(PacketRadioEntry entry) async {
    final support = await getApplicationSupportDirectory();
    final path = '${support.path}${Platform.pathSeparator}packet-radio.log';
    final time = entry.time.toLocal().toIso8601String();
    final line = '$time ${entry.from} > ${entry.to}: ${entry.text}\r\n';
    await File(path).writeAsString(line, mode: FileMode.append, flush: true);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _receiveQuietTimer?.cancel();
    _audioSubscription?.cancel();
    _controlSubscription?.cancel();
    _gatewaySubscription?.cancel();
    super.dispose();
  }
}
