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
import 'app_logger.dart';

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
  Timer? _heartbeat;

  int get stationCount {
    final now = DateTime.now();
    _stations.removeWhere((_, t) => now.difference(t).inSeconds > 25);
    return state == LinkState.online ? math.max(1, _stations.length) : 0;
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
        _networkSendPort?.send({
          'cmd': 'connect',
          'channel': _joined,
          'scan': _wild,
        });
      } catch (e, st) {
        AppLogger.error('MQTT', 'Fehler beim Starten des Netzwerk-Isolates', e, st);
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

    final c = MqttServerClient.withPort(
        AppConfig.mqttHost, clientId, AppConfig.mqttPort)
      ..keepAlivePeriod = 20
      ..disconnectOnNoResponsePeriod = 30
      ..autoReconnect = true
      ..logging(on: false)
      ..onConnected = _onConnected
      ..onDisconnected = _onDisconnected
      ..onAutoReconnected = _onConnected;
    _client = c;

    try {
      if (AppConfig.mqttUser.isEmpty) {
        await c.connect().timeout(const Duration(seconds: 10));
      } else {
        await c.connect(AppConfig.mqttUser, AppConfig.mqttPassword)
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
      AppLogger.error('MQTT', 'Verbindungsfehler im Hauptprozess (Timeout/Socket)', e, st);
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
    _stations.clear();
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
          AppLogger.warn('MQTT', 'Fehler beim Parsen der Steuerungsnachricht: $e');
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
        AppLogger.error('MQTT', 'Fehler-Signal aus Netzwerk-Isolate: $errorData');
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
      AppLogger.error('MQTT', 'Netzwerk-Isolate konnte nicht initialisiert werden', e, st);
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
      AppLogger.warn('MQTT', 'Netzwerk-Isolate wurde beendet/geschlossen (onExit empfangen)');
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
        final wasConnected = _networkConnected;
        _networkConnected = message['connected'] == true;
        state = _networkConnected
            ? LinkState.online
            : (message['connecting'] == true
                ? LinkState.connecting
                : LinkState.offline);
        if (wasConnected != _networkConnected) {
          AppLogger.info('MQTT', 'Statusänderung: state=$state (connected=$_networkConnected)');
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
    if (sid == null || ch != _joined) return;
    final before = _stations.length;
    _stations[sid] = DateTime.now();
    if (_stations.length != before) {
      AppLogger.info('MQTT', 'Stationen auf Kanal $_joined geändert: ${_stations.length} Station(en)');
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

  void _onDisconnected() {
    AppLogger.warn('MQTT', 'Vom Broker getrennt (offline)');
    _heartbeat?.cancel();
    _stations.clear();
    state = LinkState.offline;
    notifyListeners();
  }

  void disconnect() {
    AppLogger.info('MQTT', 'Verbindung wird getrennt');
    if (_useNetworkIsolate) {
      _networkSendPort?.send({'cmd': 'disconnect'});
      _networkConnected = false;
      _stations.clear();
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
    _stations.clear();
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
      if (_joined != ch) _stations.clear();
      _joined = ch;
      _networkSendPort?.send({'cmd': 'join', 'channel': ch});
      notifyListeners();
      return;
    }
    if (_wild) {
      // im Suchlauf nur merken, welcher Kanal gerade angezeigt wird
      if (_joined != ch) _stations.clear();
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
      _stations.clear();
    }
    _joined = ch;
    c.subscribe(topic(ch, 'audio'), MqttQos.atMostOnce);
    c.subscribe(topic(ch, 'ctl'), MqttQos.atLeastOnce);
    _sendCtl({'hb': true});
    notifyListeners();
  }

  void _sendCtl(Map<String, dynamic> extra) {
    if (_useNetworkIsolate) {
      _networkSendPort?.send({'cmd': 'publishCtl', 'data': extra});
      return;
    }
    final c = _client;
    final ch = _joined;
    if (c == null || state != LinkState.online || ch == null) return;
    final buf = Uint8Buffer()
      ..addAll(utf8.encode(jsonEncode({'sid': senderId, 'ch': ch, ...extra})));
    c.publishMessage(topic(ch, 'ctl'), MqttQos.atLeastOnce, buf);
  }

  void publishPtt(int ch, bool on, int antennaDb) {
    if (ch != _joined) return;
    AppLogger.info('MQTT', 'PTT $ch gesendet: ${on ? "AN" : "AUS"} (Antenne: ${antennaDb}dB)');
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
    if (logPath.isNotEmpty) {
      AppLogger.appendRaw(logPath, sb.toString());
    }
    try {
      mainPort.send({'kind': 'log', 'level': level, 'msg': msg, 'err': err?.toString()});
    } catch (_) {}
  }

  runZonedGuarded(() {
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
    int? channel;
    String topic(int ch, String sub) => '$prefix/ch/$ch/$sub';

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
          ..addAll(utf8.encode(jsonEncode({'sid': senderId, 'ch': ch, ...extra})));
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
          writeIsolateLog('INFO', 'Abonniere Wildcard-Suchlauf ($prefix/ch/+/...)');
          c.subscribe('$prefix/ch/+/audio', MqttQos.atMostOnce);
          c.subscribe('$prefix/ch/+/ctl', MqttQos.atLeastOnce);
        } else if (channel != null) {
          writeIsolateLog('INFO', 'Abonniere Kanal $channel ($prefix/ch/$channel/...)');
          c.subscribe(topic(channel!, 'audio'), MqttQos.atMostOnce);
          c.subscribe(topic(channel!, 'ctl'), MqttQos.atLeastOnce);
        }
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
      heartbeat?.cancel();
      heartbeat = Timer.periodic(const Duration(seconds: 8), (_) {
        sendCtl({'hb': true});
      });
    }

    void onDisconnected() {
      writeIsolateLog('WARN', 'Broker-Verbindung getrennt (onDisconnected)');
      connected = false;
      connecting = false;
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
      previousClient?.onAutoReconnected = null;
      try {
        previousClient?.disconnect();
      } catch (_) {}

      writeIsolateLog('INFO', 'Verbinde mit $host:$port (ClientId: $clientId)...');
      final c = MqttServerClient.withPort(host, clientId, port)
        ..keepAlivePeriod = 20
        ..disconnectOnNoResponsePeriod = 30
        ..autoReconnect = true
        ..logging(on: false)
        ..onConnected = onConnected
        ..onDisconnected = onDisconnected
        ..onAutoReconnected = onConnected;
      client = c;
      try {
        if (username.isEmpty) {
          await c.connect().timeout(const Duration(seconds: 10));
        } else {
          await c.connect(username, password).timeout(const Duration(seconds: 10));
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
          writeIsolateLog('WARN', 'Verbindungsstatus nach connect: ${c.connectionStatus?.state}');
          connected = false;
          connecting = false;
          sendState();
        }
      } catch (e) {
        writeIsolateLog('ERROR', 'Verbindungsfehler oder Timeout bei $host:$port', e);
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
                  client?.unsubscribe(topic(previous, 'ctl'));
                } catch (_) {}
              }
              subscribeCurrentChannel();
              sendCtl({'hb': true});
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
                    client?.unsubscribe(topic(ch, 'ctl'));
                  } catch (_) {}
                }
                subscribeCurrentChannel();
              } else {
                try {
                  client?.unsubscribe('$prefix/ch/+/audio');
                  client?.unsubscribe('$prefix/ch/+/ctl');
                } catch (_) {}
                subscribeCurrentChannel();
                sendCtl({'hb': true});
              }
            }
            break;
          case 'publishCtl':
            final data = raw['data'];
            if (data is Map<String, dynamic>) sendCtl(data);
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
                c.publishMessage(topic(ch, 'audio'), MqttQos.atMostOnce, payload);
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
  }, (Object error, StackTrace stack) {
    writeIsolateLog('ERROR', 'Ungefangene Zone-Ausnahme im Isolate: $error', error);
  });
}
