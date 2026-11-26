import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_buffers.dart';

import '../config/app_config.dart';
import 'location_privacy.dart';
import 'app_logger.dart';
import 'map_station_registry.dart';

enum LinkState { offline, connecting, online }

/// MQTT-Anbindung mit fest hinterlegtem Broker (siehe AppConfig).
/// Topics pro Kanal:
///   cbfunk/ch/<n>/audio  -> Audio-Pakete (QoS 0, siehe AudioPacket)
///   cbfunk/ch/<n>/ctl    -> JSON: PTT-Status und Heartbeat (QoS 1)
class MqttService extends ChangeNotifier {
  MqttServerClient? _client;
  LinkState state = LinkState.offline;
  int? _joined;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>?
  _updatesSubscription;
  bool _connectInProgress = false;
  final bool _useNetworkIsolate = Platform.isWindows;
  Isolate? _networkIsolate;
  ReceivePort? _networkReceivePort;
  SendPort? _networkSendPort;
  Completer<void>? _networkReady;
  bool _networkConnected = false;

  bool get transportConnected => _useNetworkIsolate
      ? _networkConnected
      : _client?.connectionStatus?.state == MqttConnectionState.connected;

  /// Zufaellige ID dieser App-Instanz (im Audio-Header und in ctl-Nachrichten)
  final int senderId = math.Random.secure().nextInt(0x7FFFFFFF);
  String get clientId => 'cbfunk_${senderId.toRadixString(16)}';

  final _audioCtl = StreamController<Uint8List>.broadcast();
  final _ctlCtl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Uint8List> get audioStream => _audioCtl.stream;
  Stream<Map<String, dynamic>> get ctlStream => _ctlCtl.stream;

  // Anwesenheit auf dem Kanal: sid -> zuletzt gesehen
  final Map<int, DateTime> _stations = {};
  final Map<int, String> _stationCallSigns = {};
  final Map<int, DateTime> _talkingStations = {};
  final MapStationRegistry _mapStationRegistry = MapStationRegistry();
  final Map<int, Map<int, DateTime>> _spectrumTalkers = {};
  final Map<int, DateTime> _spectrumRecent = {};
  String _localCallSign = '';

  String get localCallSign => _localCallSign;

  /// Windows: Das Netzwerk-Isolate sendet die Heartbeats selbst und braucht
  /// das Rufzeichen, damit andere Stationen es auch ohne PTT sehen. Es wird
  /// mit dem naechsten Heartbeat (spaetestens 8 s) verschickt, nicht bei
  /// jedem Tastendruck im Eingabefeld.
  set localCallSign(String value) {
    if (value == _localCallSign) return;
    _localCallSign = value;
    _sendPresenceToIsolate();
  }

  void _sendPresenceToIsolate() {
    if (!_useNetworkIsolate) return;
    _networkSendPort?.send({
      'cmd': 'presence',
      'callsign': _localCallSign.trim().toUpperCase(),
    });
  }

  double? _locationLatitude;
  double? _locationLongitude;
  bool _locationSharingEnabled = false;
  bool _publishLocationCoordinates = false;
  bool _localPtt = false;
  Timer? _heartbeat;
  Timer? _stationRefresh;

  List<double> get spectrumLevels {
    final now = DateTime.now();
    return List<double>.generate(80, (index) {
      final channel = index + 1;
      final talkers = _spectrumTalkers[channel];
      talkers?.removeWhere(
        (_, seen) => now.difference(seen) > const Duration(seconds: 24),
      );
      if (talkers?.isEmpty ?? false) _spectrumTalkers.remove(channel);
      final active =
          talkers?.values.any(
            (seen) => now.difference(seen) <= const Duration(seconds: 24),
          ) ??
          false;
      if (active) {
        final pulse =
            math.sin(now.millisecondsSinceEpoch / 180 + channel) * 0.07;
        return 0.76 + pulse;
      }
      final recent = _spectrumRecent[channel];
      if (recent == null) return 0;
      final age = now.difference(recent).inMilliseconds;
      if (age >= 1400) return 0;
      return 0.68 * (1 - age / 1400);
    });
  }

  void _recordSpectrumActivity(Map<String, dynamic> message) {
    if (!_useNetworkIsolate) return;
    final channel = (message['ch'] as num?)?.toInt();
    final sender = (message['sid'] as num?)?.toInt();
    if (channel == null || channel < 1 || channel > 80 || sender == null) {
      return;
    }

    final now = DateTime.now();
    if (message['ptt'] == true) {
      (_spectrumTalkers[channel] ??= <int, DateTime>{})[sender] = now;
      _spectrumRecent[channel] = now;
    } else if (message['ptt'] == false) {
      _spectrumTalkers[channel]?.remove(sender);
      if (_spectrumTalkers[channel]?.isEmpty ?? false) {
        _spectrumTalkers.remove(channel);
      }
      _spectrumRecent[channel] = now;
    } else if (message['hb'] == true && message['tx'] == false) {
      final wasActive = _spectrumTalkers[channel]?.remove(sender) != null;
      if (_spectrumTalkers[channel]?.isEmpty ?? false) {
        _spectrumTalkers.remove(channel);
      }
      if (wasActive) _spectrumRecent[channel] = now;
    } else if (message['hb'] == true &&
        _spectrumTalkers[channel]?.containsKey(sender) == true) {
      _spectrumTalkers[channel]![sender] = now;
    }
  }

  int get stationCount {
    _pruneStationData();
    return state == LinkState.online ? math.max(1, _stations.length) : 0;
  }

  List<MapStation> get mapStations {
    final stations = _mapStationRegistry.stations().toList();
    if (state == LinkState.online &&
        _locationSharingEnabled &&
        _locationLatitude != null &&
        _locationLongitude != null &&
        _joined != null) {
      final ownKey = localCallSign.trim().toUpperCase();
      stations.removeWhere(
        (station) =>
            station.senderId == senderId ||
            (ownKey.isNotEmpty && station.callSign == ownKey),
      );
      stations.add(
        MapStation(
          senderId: senderId,
          channel: _joined!,
          callSign: ownKey.isEmpty ? 'Eigene Station' : ownKey,
          latitude: _locationLatitude!,
          longitude: _locationLongitude!,
          lastSeen: DateTime.now(),
          transmitting: _localPtt,
        ),
      );
    }
    return List<MapStation>.unmodifiable(stations);
  }

  List<String> stationCallSigns(String ownCallSign) {
    _pruneStationData();
    if (state != LinkState.online) return const [];
    final own = ownCallSign.trim().isEmpty
        ? 'Eigene Station'
        : ownCallSign.trim();
    final stations = _stations.keys.map((sid) {
      if (sid == senderId) return own;
      final callSign = _stationCallSigns[sid];
      return callSign?.isNotEmpty == true
          ? callSign!
          : 'Station ${sid.toRadixString(16).toUpperCase()}';
    }).toList();
    return stations.isEmpty ? [own] : stations;
  }

  String? get activeTalkerCallSign {
    _pruneStationData();
    final remoteTalkers = _talkingStations.keys
        .where((sid) => sid != senderId)
        .toList();
    if (remoteTalkers.isEmpty) return null;
    remoteTalkers.sort(
      (a, b) => _talkingStations[b]!.compareTo(_talkingStations[a]!),
    );
    final sid = remoteTalkers.first;
    return _stationCallSigns[sid] ??
        'Station ${sid.toRadixString(16).toUpperCase()}';
  }

  void _pruneStationData() {
    final now = DateTime.now();
    final expired = _stations.entries
        .where((entry) => now.difference(entry.value).inSeconds > 25)
        .map((entry) => entry.key)
        .toSet();
    _stations.removeWhere((sid, _) => expired.contains(sid));
    for (final sid in expired) {
      _stationCallSigns.remove(sid);
      _talkingStations.remove(sid);
    }
    _talkingStations.removeWhere(
      (sid, seen) =>
          !_stations.containsKey(sid) || now.difference(seen).inSeconds > 25,
    );
  }

  void _clearStationData({bool clearMap = true}) {
    _stations.clear();
    _stationCallSigns.clear();
    _talkingStations.clear();
    if (clearMap) _mapStationRegistry.clear();
  }

  String topic(int ch, String sub) => '${AppConfig.topicPrefix}/ch/$ch/$sub';

  Future<void> connect() async {
    if (_connectInProgress || transportConnected) return;
    AppLogger.info(
      'MQTT',
      'Verbindungsaufbau gestartet (Host: ${AppConfig.mqttHost}:${AppConfig.mqttPort}, Isolate-Modus: $_useNetworkIsolate)',
    );
    if (_useNetworkIsolate) {
      _connectInProgress = true;
      state = LinkState.connecting;
      notifyListeners();
      try {
        await _ensureNetworkIsolate();
        _sendPresenceToIsolate();
        _networkSendPort?.send({
          'cmd': 'connect',
          'channel': _joined,
          'scan': _wild,
        });
      } catch (e, st) {
        AppLogger.error(
          'MQTT',
          'Fehler beim Starten des Netzwerk-Isolates',
          e,
          st,
        );
        state = LinkState.offline;
        notifyListeners();
      } finally {
        _connectInProgress = false;
      }
      return;
    }
    _connectInProgress = true;
    state = LinkState.connecting;
    notifyListeners();

    final c =
        MqttServerClient.withPort(
            AppConfig.mqttHost,
            clientId,
            AppConfig.mqttPort,
          )
          ..keepAlivePeriod = 20
          ..disconnectOnNoResponsePeriod = 30
          ..autoReconnect = true
          ..logging(on: false)
          ..onConnected = _onConnected
          ..onDisconnected = _onDisconnected
          ..onAutoReconnect = _onAutoReconnect
          ..onAutoReconnected = _onConnected;
    _client = c;

    try {
      if (AppConfig.mqttUser.isEmpty) {
        await c.connect().timeout(const Duration(seconds: 10));
      } else {
        await c
            .connect(AppConfig.mqttUser, AppConfig.mqttPassword)
            .timeout(const Duration(seconds: 10));
      }
      await _updatesSubscription?.cancel();
      _updatesSubscription = c.updates?.listen(
        _onMessages,
        onError: (Object e) {
          AppLogger.error('MQTT', 'Fehler im Hauptprozess-Updates-Stream', e);
        },
      );
    } catch (e, st) {
      AppLogger.error(
        'MQTT',
        'Verbindungsfehler im Hauptprozess (Timeout/Socket)',
        e,
        st,
      );
      try {
        c.disconnect();
      } catch (_) {}
      state = LinkState.offline;
      notifyListeners();
    } finally {
      _connectInProgress = false;
    }
  }

  Future<void> reconnectIfDisconnected({bool force = false}) async {
    if (_connectInProgress) return;
    if (!force && transportConnected && state == LinkState.online) return;

    AppLogger.info(
      'MQTT',
      'Wiederverbindung angefordert (force: $force, aktuell: $state, transportConnected: $transportConnected)',
    );

    if (_useNetworkIsolate) {
      await _ensureNetworkIsolate();
      _sendPresenceToIsolate();
      _networkSendPort?.send({'cmd': 'reconnect'});
      return;
    }

    _heartbeat?.cancel();
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    final oldClient = _client;
    _client = null;
    oldClient?.onDisconnected = null;
    oldClient?.onAutoReconnected = null;
    try {
      oldClient?.disconnect();
    } catch (_) {}
    _localPtt = false;
    _clearStationData(clearMap: false);
    state = LinkState.offline;
    notifyListeners();
    await connect();
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> msgs) {
    for (final m in msgs) {
      final pm = m.payload;
      if (pm is! MqttPublishMessage) continue;
      final bytes = Uint8List.fromList(pm.payload.message);
      if (m.topic.endsWith('/audio')) {
        _audioCtl.add(bytes);
      } else if (m.topic.endsWith('/ctl')) {
        try {
          final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
          _handleCtl(j);
          _ctlCtl.add(j);
        } catch (e) {
          AppLogger.warn(
            'MQTT',
            'Fehler beim Parsen der Steuerungsnachricht: $e',
          );
        }
      }
    }
  }

  Future<void> _ensureNetworkIsolate() async {
    if (_networkSendPort != null) return;
    final pending = _networkReady;
    if (pending != null) return pending.future;

    final ready = Completer<void>();
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    _networkReady = ready;
    _networkReceivePort = receivePort;
    receivePort.listen(_handleNetworkMessage);
    errorPort.listen((dynamic errorData) {
      if (errorData is List && errorData.length >= 2) {
        AppLogger.error(
          'MQTT',
          'Unbehandelter Fehler im Netzwerk-Isolate: ${errorData[0]}',
          errorData[0],
          StackTrace.fromString(errorData[1].toString()),
        );
      } else {
        AppLogger.error(
          'MQTT',
          'Fehler-Signal aus Netzwerk-Isolate: $errorData',
        );
      }
    });

    try {
      AppLogger.info('MQTT', 'Starte cbfunk-mqtt Isolate...');
      _networkIsolate = await Isolate.spawn<Map<String, Object>>(
        _mqttNetworkWorker,
        <String, Object>{
          'mainPort': receivePort.sendPort,
          'host': AppConfig.mqttHost,
          'port': AppConfig.mqttPort,
          'username': AppConfig.mqttUser,
          'password': AppConfig.mqttPassword,
          'topicPrefix': AppConfig.topicPrefix,
          'clientId': clientId,
          'senderId': senderId,
          'logPath': AppLogger.logFilePath,
        },
        debugName: 'cbfunk-mqtt',
        onExit: receivePort.sendPort,
        onError: errorPort.sendPort,
      );
      await ready.future.timeout(const Duration(seconds: 6));
      AppLogger.info('MQTT', 'Netzwerk-Isolate erfolgreich bereit');
    } catch (e, st) {
      AppLogger.error(
        'MQTT',
        'Netzwerk-Isolate konnte nicht initialisiert werden',
        e,
        st,
      );
      receivePort.close();
      errorPort.close();
      _networkReceivePort = null;
      _networkReady = null;
      _networkSendPort = null;
      _networkIsolate = null;
      rethrow;
    }
  }

  void _handleNetworkMessage(dynamic message) {
    if (message == null) {
      AppLogger.warn(
        'MQTT',
        'Netzwerk-Isolate wurde beendet/geschlossen (onExit empfangen)',
      );
      _networkSendPort = null;
      _networkIsolate = null;
      _networkReady = null;
      _networkReceivePort?.close();
      _networkReceivePort = null;
      _networkConnected = false;
      state = LinkState.offline;
      notifyListeners();
      return;
    }
    if (message is! Map) return;
    switch (message['kind']) {
      case 'ready':
        _networkSendPort = message['port'] as SendPort?;
        if (!(_networkReady?.isCompleted ?? true)) {
          _networkReady!.complete();
        }
        break;
      case 'state':
        _stationRefresh ??= Timer.periodic(
          const Duration(seconds: 8),
          (_) => notifyListeners(),
        );
        final wasConnected = _networkConnected;
        _networkConnected = message['connected'] == true;
        state = _networkConnected
            ? LinkState.online
            : (message['connecting'] == true
                  ? LinkState.connecting
                  : LinkState.offline);
        if (wasConnected != _networkConnected) {
          AppLogger.info(
            'MQTT',
            'Statusänderung: state=$state (connected=$_networkConnected)',
          );
        }
        notifyListeners();
        break;
      case 'audio':
        final packet = message['packet'];
        if (packet is TransferableTypedData) {
          _audioCtl.add(packet.materialize().asUint8List());
        }
        break;
      case 'ctl':
        final data = message['data'];
        if (data is Map<String, dynamic>) {
          _recordSpectrumActivity(data);
          _handleCtl(data);
          _ctlCtl.add(data);
        }
        break;
      case 'log':
        final level = message['level'] as String? ?? 'INFO';
        final msg = message['msg'] as String? ?? '';
        final err = message['err'];
        AppLogger.log(level, 'MQTT-ISOLATE', msg, err);
        break;
    }
  }

  void _handleCtl(Map<String, dynamic> j) {
    final sid = (j['sid'] as num?)?.toInt();
    final ch = (j['ch'] as num?)?.toInt();
    if (sid == null || ch == null || ch < 1 || ch > 80) return;

    final callSign = j['callsign'];
    final mapChanged = _mapStationRegistry.update(j);

    if (ch != _joined) {
      if (mapChanged) notifyListeners();
      return;
    }
    _pruneStationData();
    final before = _stations.length;
    _stations[sid] = DateTime.now();
    if (callSign is String && callSign.trim().isNotEmpty) {
      _stationCallSigns[sid] = callSign.trim().toUpperCase();
    }
    final ptt = j['ptt'] ?? (j['hb'] == true ? j['tx'] : null);
    if (ptt == true) {
      _talkingStations[sid] = DateTime.now();
    } else if (ptt == false) {
      _talkingStations.remove(sid);
    } else if (j['hb'] == true && _talkingStations.containsKey(sid)) {
      _talkingStations[sid] = DateTime.now();
    }
    final stationChanged = _stations.length != before;
    if (stationChanged) {
      AppLogger.info(
        'MQTT',
        'Stationen auf Kanal $_joined geändert: ${_stations.length} Station(en)',
      );
    }
    if (mapChanged || stationChanged || ptt is bool || callSign is String) {
      notifyListeners();
    }
  }

  void _onConnected() {
    AppLogger.info('MQTT', 'Erfolgreich mit Broker verbunden (online)');
    state = LinkState.online;
    notifyListeners();
    if (_wild) {
      _subscribeWild();
    } else if (_joined != null) {
      joinChannel(_joined!);
    }
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 8), (_) {
      _sendCtl({'hb': true});
      notifyListeners(); // Stationszahl aktualisieren (Timeout)
    });
  }

  void _onAutoReconnect() {
    AppLogger.warn(
      'MQTT',
      'Verbindung verloren, automatische Neuverbindung läuft',
    );
    _heartbeat?.cancel();
    _localPtt = false;
    state = LinkState.connecting;
    notifyListeners();
  }

  void _onDisconnected() {
    AppLogger.warn('MQTT', 'Vom Broker getrennt (offline)');
    _heartbeat?.cancel();
    _localPtt = false;
    _clearStationData(clearMap: false);
    state = LinkState.offline;
    notifyListeners();
  }

  void disconnect() {
    AppLogger.info('MQTT', 'Verbindung wird getrennt');
    if (_useNetworkIsolate) {
      _networkSendPort?.send({'cmd': 'disconnect'});
      _networkConnected = false;
      _localPtt = false;
      _clearStationData(clearMap: false);
      state = LinkState.offline;
      notifyListeners();
      return;
    }
    _heartbeat?.cancel();
    _updatesSubscription?.cancel();
    _updatesSubscription = null;
    try {
      _client?.disconnect();
    } catch (_) {}
    _client = null;
    _localPtt = false;
    _clearStationData(clearMap: false);
    state = LinkState.offline;
    notifyListeners();
  }

  // ---- Suchlauf: Wildcard-Abo auf alle Kanaele ----
  bool _wild = false;
  String get _wildAudio => '${AppConfig.topicPrefix}/ch/+/audio';
  String get _wildCtl => '${AppConfig.topicPrefix}/ch/+/ctl';

  void _subscribeWild() {
    final c = _client;
    if (c == null || state != LinkState.online) return;
    c.subscribe(_wildAudio, MqttQos.atMostOnce);
    c.subscribe(_wildCtl, MqttQos.atLeastOnce);
  }

  /// Suchlauf an/aus. Waehrend des Suchlaufs wird alles auf allen Kanaelen
  /// empfangen (Wildcard), das ersetzt das Abo des Einzelkanals.
  void setScan(bool on) {
    if (_wild == on) return;
    _wild = on;
    AppLogger.info('MQTT', 'Suchlauf ${on ? "aktiviert" : "deaktiviert"}');
    if (_useNetworkIsolate) {
      _networkSendPort?.send({'cmd': 'scan', 'on': on});
      notifyListeners();
      return;
    }
    final c = _client;
    if (c == null || state != LinkState.online) return;
    final ch = _joined;
    if (on) {
      if (ch != null) {
        c.unsubscribe(topic(ch, 'audio'));
        c.unsubscribe(topic(ch, 'ctl'));
      }
      _subscribeWild();
    } else {
      c.unsubscribe(_wildAudio);
      c.unsubscribe(_wildCtl);
      if (ch != null) {
        c.subscribe(topic(ch, 'audio'), MqttQos.atMostOnce);
        c.subscribe(topic(ch, 'ctl'), MqttQos.atLeastOnce);
        _sendCtl({'hb': true});
      }
    }
    notifyListeners();
  }

  void joinChannel(int ch) {
    AppLogger.info('MQTT', 'Kanal $ch beitreten (bisher: $_joined)');
    if (_useNetworkIsolate) {
      if (_joined != ch) _clearStationData(clearMap: false);
      _joined = ch;
      _networkSendPort?.send({'cmd': 'join', 'channel': ch});
      notifyListeners();
      return;
    }
    if (_wild) {
      // im Suchlauf nur merken, welcher Kanal gerade angezeigt wird
      if (_joined != ch) _clearStationData(clearMap: false);
      _joined = ch;
      notifyListeners();
      return;
    }
    final c = _client;
    if (c == null || state != LinkState.online) {
      _joined = ch;
      return;
    }
    if (_joined != null && _joined != ch) {
      c.unsubscribe(topic(_joined!, 'audio'));
      c.unsubscribe(topic(_joined!, 'ctl'));
      _clearStationData(clearMap: false);
    }
    _joined = ch;
    c.subscribe(topic(ch, 'audio'), MqttQos.atMostOnce);
    c.subscribe(topic(ch, 'ctl'), MqttQos.atLeastOnce);
    _sendCtl({'hb': true});
    notifyListeners();
  }

  void _sendCtl(Map<String, dynamic> extra) {
    final data = <String, Object?>{
      ...extra,
      if (localCallSign.trim().isNotEmpty)
        'callsign': localCallSign.trim().toUpperCase(),
      'loc': _locationSharingEnabled,
      'tx': _localPtt,
      if (_locationSharingEnabled &&
          _publishLocationCoordinates &&
          _locationLatitude != null &&
          _locationLongitude != null) ...{
        'lat': _locationLatitude,
        'lon': _locationLongitude,
      },
    };
    if (_useNetworkIsolate) {
      _networkSendPort?.send({'cmd': 'publishCtl', 'data': data});
      return;
    }
    final c = _client;
    final ch = _joined;
    if (c == null || state != LinkState.online || ch == null) return;
    final buf = Uint8Buffer()
      ..addAll(utf8.encode(jsonEncode({'sid': senderId, 'ch': ch, ...data})));
    c.publishMessage(topic(ch, 'ctl'), MqttQos.atLeastOnce, buf);
  }

  void setLocationCoordinates({
    required double? latitude,
    required double? longitude,
    required bool precise,
    required bool enabled,
  }) {
    _locationSharingEnabled = enabled;
    _publishLocationCoordinates = false;
    if (!enabled) {
      _locationLatitude = null;
      _locationLongitude = null;
      _mapStationRegistry.removeSender(senderId, callSign: localCallSign);
    } else if (latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180) {
      _locationLatitude = LocationPrivacy.shareCoordinate(
        latitude,
        precise: precise,
      );
      _locationLongitude = LocationPrivacy.shareCoordinate(
        longitude,
        precise: precise,
      );
      _publishLocationCoordinates = true;
    }
    _sendCtl({'hb': true});
  }

  void publishPtt(int ch, bool on, int antennaDb) {
    if (ch != _joined) return;
    _localPtt = on;
    _recordSpectrumActivity(<String, dynamic>{
      'sid': senderId,
      'ch': ch,
      'ptt': on,
    });
    AppLogger.info(
      'MQTT',
      'PTT $ch gesendet: ${on ? "AN" : "AUS"} (Antenne: ${antennaDb}dB)',
    );
    _sendCtl({'ptt': on, 'ant_db': antennaDb});
  }

  void publishAudio(Uint8List packet) {
    if (_useNetworkIsolate) {
      _networkSendPort?.send({
        'cmd': 'publishAudio',
        'packet': TransferableTypedData.fromList([packet]),
      });
      return;
    }
    final c = _client;
    final ch = _joined;
    if (c == null || state != LinkState.online || ch == null) return;
    final buf = Uint8Buffer()..addAll(packet);
    c.publishMessage(topic(ch, 'audio'), MqttQos.atMostOnce, buf);
  }

  @override
  void dispose() {
    AppLogger.info('MQTT', 'MqttService wird disposed');
    if (_useNetworkIsolate) {
      _networkSendPort?.send({'cmd': 'shutdown'});
      _networkReceivePort?.close();
      _networkIsolate?.kill(priority: Isolate.immediate);
      _networkReceivePort = null;
      _networkIsolate = null;
      _networkSendPort = null;
      _networkReady = null;
    }
    _heartbeat?.cancel();
    _stationRefresh?.cancel();
    _updatesSubscription?.cancel();
    try {
      _client?.disconnect();
    } catch (_) {}
    _audioCtl.close();
    _ctlCtl.close();
    super.dispose();
  }
}

/// Owns the Windows MQTT socket and packet callbacks outside Flutter's UI
/// isolate. Only compact state/audio messages cross back to the UI isolate.
void _mqttNetworkWorker(Map<String, Object> args) {
  final mainPort = args['mainPort']! as SendPort;
  final logPath = args['logPath'] as String? ?? '';

  void writeIsolateLog(String level, String msg, [Object? err]) {
    final now = DateTime.now();
    final timeStr = AppLogger.formatTimestamp(now);
    final sb = StringBuffer('$timeStr [$level] [MQTT-ISOLATE] $msg');
    if (err != null) sb.write(' | FEHLER: $err');
    sb.writeln();
    try {
      // Der Haupt-Isolate schreibt die Zeile ins Log.
      mainPort.send({
        'kind': 'log',
        'level': level,
        'msg': msg,
        'err': err?.toString(),
      });
    } catch (_) {
      if (logPath.isNotEmpty) AppLogger.appendRaw(logPath, sb.toString());
    }
  }

  runZonedGuarded(
    () {
      final commands = ReceivePort();
      mainPort.send({'kind': 'ready', 'port': commands.sendPort});

      final host = args['host']! as String;
      final port = args['port']! as int;
      final username = args['username']! as String;
      final password = args['password']! as String;
      final prefix = args['topicPrefix']! as String;
      final clientId = args['clientId']! as String;
      final senderId = args['senderId']! as int;
      MqttServerClient? client;
      StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? updates;
      Timer? heartbeat;
      bool connecting = false;
      bool connected = false;
      bool scanning = false;
      bool stopping = false;
      bool localTx = false;
      int? channel;
      // Rufzeichen fuer die Heartbeats dieses Isolates (vom Haupt-Isolate)
      String callSign = '';
      String topic(int ch, String sub) => '$prefix/ch/$ch/$sub';

      /// Heartbeats tragen das Rufzeichen mit, damit andere Stationen es
      /// auch ohne PTT sehen (wie unter Android).
      Map<String, dynamic> withCallSign(Map<String, dynamic> extra) => {
        if (callSign.isNotEmpty) 'callsign': callSign,
        ...extra,
      };

      void sendState() => mainPort.send({
        'kind': 'state',
        'connected': connected,
        'connecting': connecting,
      });

      void sendCtl(Map<String, dynamic> extra) {
        final c = client;
        final ch = channel;
        if (c == null || !connected || ch == null) return;
        try {
          final payload = Uint8Buffer()
            ..addAll(
              utf8.encode(jsonEncode({'sid': senderId, 'ch': ch, ...extra})),
            );
          c.publishMessage(topic(ch, 'ctl'), MqttQos.atLeastOnce, payload);
        } catch (e) {
          writeIsolateLog('WARN', 'Fehler beim Senden von ctl-Nachricht', e);
        }
      }

      void subscribeCurrentChannel() {
        final c = client;
        if (c == null || !connected) return;
        try {
          if (scanning) {
            writeIsolateLog(
              'INFO',
              'Abonniere Wildcard-Suchlauf ($prefix/ch/+/audio)',
            );
            c.subscribe('$prefix/ch/+/audio', MqttQos.atMostOnce);
          } else if (channel != null) {
            writeIsolateLog(
              'INFO',
              'Abonniere Kanal $channel Audio und Spectrum-Status',
            );
            c.subscribe(topic(channel!, 'audio'), MqttQos.atMostOnce);
          }
          // Windows-Spektrumanzeige: nur kompakte PTT-Steuerdaten aller Kanaele.
          // Audio bleibt weiterhin ausschliesslich am Kanal-/Suchlauf-Abo.
          c.subscribe('$prefix/ch/+/ctl', MqttQos.atLeastOnce);
        } catch (e) {
          writeIsolateLog('ERROR', 'Abonnieren fehlgeschlagen', e);
        }
      }

      void onConnected() {
        writeIsolateLog('INFO', 'Broker-Verbindung erfolgreich hergestellt');
        connected = true;
        connecting = false;
        sendState();
        subscribeCurrentChannel();
        sendCtl(withCallSign({'hb': true, 'tx': localTx}));
        heartbeat?.cancel();
        heartbeat = Timer.periodic(const Duration(seconds: 8), (_) {
          sendCtl(withCallSign({'hb': true, 'tx': localTx}));
        });
      }

      // Verbindung abgerissen, mqtt_client verbindet selbst neu: Anzeige auf
      // "Verbinde ..." statt weiter "Online" (Pakete gehen sonst ins Leere).
      void onAutoReconnect() {
        writeIsolateLog(
          'WARN',
          'Verbindung verloren, automatische Neuverbindung läuft',
        );
        connected = false;
        connecting = true;
        localTx = false;
        heartbeat?.cancel();
        sendState();
      }

      void onDisconnected() {
        writeIsolateLog('WARN', 'Broker-Verbindung getrennt (onDisconnected)');
        connected = false;
        connecting = false;
        localTx = false;
        heartbeat?.cancel();
        sendState();
      }

      Future<void> doConnect() async {
        if (connecting || connected || stopping) return;
        connecting = true;
        sendState();
        heartbeat?.cancel();
        await updates?.cancel();
        updates = null;
        final previousClient = client;
        client = null;
        previousClient?.onDisconnected = null;
        previousClient?.onAutoReconnect = null;
        previousClient?.onAutoReconnected = null;
        try {
          previousClient?.disconnect();
        } catch (_) {}

        writeIsolateLog(
          'INFO',
          'Verbinde mit $host:$port (ClientId: $clientId)...',
        );
        final c = MqttServerClient.withPort(host, clientId, port)
          ..keepAlivePeriod = 20
          ..disconnectOnNoResponsePeriod = 30
          ..autoReconnect = true
          ..logging(on: false)
          ..onConnected = onConnected
          ..onDisconnected = onDisconnected
          ..onAutoReconnect = onAutoReconnect
          ..onAutoReconnected = onConnected;
        client = c;
        try {
          if (username.isEmpty) {
            await c.connect().timeout(const Duration(seconds: 10));
          } else {
            await c
                .connect(username, password)
                .timeout(const Duration(seconds: 10));
          }
          await updates?.cancel();
          updates = c.updates?.listen(
            (messages) {
              for (final message in messages) {
                final mqttMessage = message.payload;
                if (mqttMessage is! MqttPublishMessage) continue;
                final bytes = Uint8List.fromList(mqttMessage.payload.message);
                if (message.topic.endsWith('/audio')) {
                  mainPort.send({
                    'kind': 'audio',
                    'packet': TransferableTypedData.fromList([bytes]),
                  });
                } else if (message.topic.endsWith('/ctl')) {
                  try {
                    final json = jsonDecode(utf8.decode(bytes));
                    if (json is Map<String, dynamic>) {
                      mainPort.send({'kind': 'ctl', 'data': json});
                    }
                  } catch (_) {}
                }
              }
            },
            onError: (Object e) {
              writeIsolateLog('ERROR', 'Fehler im updates-Stream', e);
            },
          );
          if (c.connectionStatus?.state != MqttConnectionState.connected) {
            writeIsolateLog(
              'WARN',
              'Verbindungsstatus nach connect: ${c.connectionStatus?.state}',
            );
            connected = false;
            connecting = false;
            sendState();
          }
        } catch (e) {
          writeIsolateLog(
            'ERROR',
            'Verbindungsfehler oder Timeout bei $host:$port',
            e,
          );
          try {
            c.disconnect();
          } catch (_) {}
          if (identical(client, c)) client = null;
          connected = false;
          connecting = false;
          sendState();
        }
      }

      Future<void> doDisconnect() async {
        writeIsolateLog('INFO', 'doDisconnect aufgerufen');
        heartbeat?.cancel();
        await updates?.cancel();
        updates = null;
        final oldClient = client;
        client = null;
        connected = false;
        connecting = false;
        oldClient?.onDisconnected = null;
        oldClient?.onAutoReconnect = null;
        oldClient?.onAutoReconnected = null;
        try {
          oldClient?.disconnect();
        } catch (_) {}
        sendState();
      }

      commands.listen(
        (dynamic raw) {
          if (raw is! Map) return;
          final command = raw['cmd'];
          switch (command) {
            case 'connect':
              channel = (raw['channel'] as num?)?.toInt() ?? channel;
              scanning = raw['scan'] == true;
              unawaited(doConnect());
              break;
            case 'reconnect':
              if (!connected && !connecting) {
                unawaited(doConnect());
              }
              break;
            case 'join':
              final next = (raw['channel'] as num?)?.toInt();
              if (next == null) break;
              final previous = channel;
              channel = next;
              if (connected && !scanning) {
                if (previous != null && previous != next) {
                  try {
                    client?.unsubscribe(topic(previous, 'audio'));
                  } catch (_) {}
                }
                subscribeCurrentChannel();
                sendCtl(withCallSign({'hb': true}));
              }
              break;
            case 'scan':
              final next = raw['on'] == true;
              if (scanning == next) break;
              scanning = next;
              if (connected) {
                if (scanning) {
                  final ch = channel;
                  if (ch != null) {
                    try {
                      client?.unsubscribe(topic(ch, 'audio'));
                    } catch (_) {}
                  }
                  subscribeCurrentChannel();
                } else {
                  try {
                    client?.unsubscribe('$prefix/ch/+/audio');
                  } catch (_) {}
                  subscribeCurrentChannel();
                  sendCtl(withCallSign({'hb': true}));
                }
              }
              break;
            case 'presence':
              final next = raw['callsign'];
              if (next is String) callSign = next.trim().toUpperCase();
              break;
            case 'publishCtl':
              final data = raw['data'];
              if (data is Map<String, dynamic>) {
                final tx = data['tx'];
                if (tx is bool) localTx = tx;
                sendCtl(data);
              }
              break;
            case 'publishAudio':
              final packet = raw['packet'];
              final ch = channel;
              final c = client;
              if (packet is TransferableTypedData &&
                  connected &&
                  ch != null &&
                  c != null) {
                try {
                  final payload = Uint8Buffer()
                    ..addAll(packet.materialize().asUint8List());
                  c.publishMessage(
                    topic(ch, 'audio'),
                    MqttQos.atMostOnce,
                    payload,
                  );
                } catch (e) {
                  writeIsolateLog('WARN', 'publishAudio fehlgeschlagen', e);
                }
              }
              break;
            case 'disconnect':
              unawaited(doDisconnect());
              break;
            case 'shutdown':
              stopping = true;
              unawaited(doDisconnect().whenComplete(commands.close));
              break;
          }
        },
        onError: (Object e) {
          writeIsolateLog('ERROR', 'Fehler im commands ReceivePort', e);
        },
      );
    },
    (Object error, StackTrace stack) {
      writeIsolateLog(
        'ERROR',
        'Ungefangene Zone-Ausnahme im Isolate: $error',
        error,
      );
    },
  );
}
