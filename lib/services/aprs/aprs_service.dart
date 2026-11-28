import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app_logger.dart';
import '../location_privacy.dart';
import 'aprs_codec.dart';

enum AprsLinkState { off, connecting, connected, failed }

/// Eine APRS-Station (oder ein APRS-Objekt) fuer die Live-Karte.
class AprsStation {
  const AprsStation({
    required this.name,
    required this.source,
    required this.latitude,
    required this.longitude,
    required this.symbolTable,
    required this.symbolCode,
    required this.comment,
    required this.lastHeard,
  });

  final String name;
  final String source;
  final double latitude;
  final double longitude;
  final String symbolTable;
  final String symbolCode;
  final String comment;
  final DateTime lastHeard;
}

/// CB-APRS-Anbindung (APRS-IS ueber TCP, nur IPv4).
///
/// Nur aktiv, wenn der Nutzer APRS in den Einstellungen freigibt. Empfaengt
/// die Stationsdaten des Servers fuer die Live-Karte und meldet die eigene
/// Position (bereits gemaess der gewaehlten Standortgenauigkeit gerundet).
/// Der Passcode wird aus dem Basis-Rufzeichen berechnet.
class AprsService extends ChangeNotifier {
  AprsService({
    this.host = defaultHost,
    this.port = defaultPort,
    this.softwareVersion = '',
    this.beaconInterval = const Duration(minutes: 10),
    this.minimumBeaconSpacing = const Duration(minutes: 2),
    this.stationTimeout = const Duration(minutes: 60),
    this.silenceTimeout = const Duration(seconds: 120),
    this.notifyDelay = const Duration(seconds: 1),
  });

  static const String defaultHost = 'cbaprs.dyndns.org';
  static const int defaultPort = 27235;
  static const int _maximumStations = 2000;

  final String host;
  final int port;
  final String softwareVersion;
  final Duration beaconInterval;
  final Duration minimumBeaconSpacing;
  final Duration stationTimeout;
  final Duration silenceTimeout;
  final Duration notifyDelay;

  /// Kommentar der Positionsmeldung (z. B. Programm und Kanal)
  String Function()? commentBuilder;

  AprsLinkState state = AprsLinkState.off;
  String status = 'APRS aus';
  bool verified = false;

  bool _active = false;
  bool _disposed = false;
  String _callInput = '';
  String? _loginCall;
  bool _readOnly = true;
  ({double latitude, double longitude})? _position;
  ({double latitude, double longitude})? _lastBeaconPosition;
  DateTime? _lastBeaconAt;
  DateTime _lastLineAt = DateTime.now();
  Duration _reconnectDelay = const Duration(seconds: 10);
  int _generation = 0;

  Socket? _socket;
  StreamSubscription<String>? _lines;
  Timer? _reconnectTimer;
  Timer? _watchdog;
  Timer? _beaconTimer;
  Timer? _pendingBeacon;
  Timer? _notifyTimer;
  Timer? _callSignTimer;

  final Map<String, AprsStation> _stations = <String, AprsStation>{};

  bool get active => _active;

  /// Rufzeichen, mit dem sich die App beim APRS-Server anmeldet
  String? get aprsCallSign => AprsCodec.callSign(_callInput);

  /// APRS-Stationen fuer die Karte (abgelaufene werden entfernt)
  List<AprsStation> get stations {
    _prune(DateTime.now());
    return List<AprsStation>.unmodifiable(_stations.values);
  }

  /// APRS ein-/ausschalten. Aus: Verbindung sofort trennen, nichts mehr
  /// senden, alle APRS-Stationen entfernen.
  void setActive(bool value) {
    if (_disposed || value == _active) return;
    _active = value;
    if (value) {
      AppLogger.info('APRS', 'APRS aktiviert ($host:$port, IPv4)');
      _reconnectDelay = const Duration(seconds: 10);
      unawaited(_connect());
    } else {
      AppLogger.info('APRS', 'APRS deaktiviert');
      _shutdown();
      _stations.clear();
      state = AprsLinkState.off;
      status = 'APRS aus';
      _notifyNow();
    }
  }

  /// Rufzeichen geaendert: erst nach kurzer Ruhe neu anmelden (das Feld
  /// meldet jeden Tastendruck).
  void setCallSign(String value) {
    _callInput = value;
    if (!_active) return;
    _callSignTimer?.cancel();
    _callSignTimer = Timer(const Duration(seconds: 3), () {
      if (_active && aprsCallSign != _loginCall) {
        AppLogger.info('APRS', 'Rufzeichen geändert, melde neu an');
        _restart();
      }
    });
  }

  /// Eigene Position (Rohwert). null = keine Position senden. Bei
  /// [precise] == false wird wie bei der Live-Karte auf ca. 1 km gerundet.
  void setPosition(
    double? latitude,
    double? longitude, {
    required bool precise,
  }) {
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      _position = null;
      _pendingBeacon?.cancel();
      return;
    }
    final next = (
      latitude: LocationPrivacy.shareCoordinate(latitude, precise: precise),
      longitude: LocationPrivacy.shareCoordinate(longitude, precise: precise),
    );
    final previous = _position;
    _position = next;
    if (previous == next) return;
    // Nur bei spuerbarer Bewegung sofort melden (GPS-Zittern ignorieren)
    final reference = _lastBeaconPosition;
    if (reference != null && _distanceMeters(reference, next) < 100) return;
    _scheduleBeacon();
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    _shutdownSocket();
    state = AprsLinkState.connecting;
    verified = false;
    status = 'Verbinde mit $host …';
    _notifyNow();
    try {
      final addresses = await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 10));
      if (addresses.isEmpty) {
        throw SocketException('Keine IPv4-Adresse für $host');
      }
      final socket = await Socket.connect(
        addresses.first,
        port,
        timeout: const Duration(seconds: 15),
      );
      if (generation != _generation || !_active) {
        socket.destroy();
        return;
      }
      _socket = socket;
      _lastLineAt = DateTime.now();
      _lines = socket
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
            (line) => _onLine(line, generation),
            onError: (Object error) => _connectionLost(generation, '$error'),
            onDone: () => _connectionLost(generation, 'vom Server getrennt'),
            cancelOnError: true,
          );

      final call = aprsCallSign;
      _readOnly = call == null;
      _loginCall =
          call ?? 'CBF${math.Random().nextInt(9000) + 1000}'; // nur Empfang
      final pass = _readOnly ? -1 : AprsCodec.passcode(_loginCall!);
      final version = softwareVersion.isEmpty ? '' : ' $softwareVersion';
      socket.write('user $_loginCall pass $pass vers CB-Funk$version\r\n');
      AppLogger.info(
        'APRS',
        'Verbunden mit ${addresses.first.address}:$port, Anmeldung als $_loginCall'
            '${_readOnly ? ' (nur Empfang)' : ''}',
      );
      state = AprsLinkState.connected;
      status = 'Verbunden, Anmeldung läuft …';
      _watchdog?.cancel();
      _watchdog = Timer.periodic(const Duration(seconds: 20), (_) {
        if (DateTime.now().difference(_lastLineAt) > silenceTimeout) {
          _connectionLost(generation, 'Server antwortet nicht');
        }
      });
      _notifyNow();
    } catch (error) {
      if (generation != _generation || !_active) return;
      AppLogger.warn('APRS', 'Verbindung zu $host:$port fehlgeschlagen', error);
      state = AprsLinkState.failed;
      status = 'Keine Verbindung zu $host – neuer Versuch folgt';
      _scheduleReconnect();
      _notifyNow();
    }
  }

  void _onLine(String line, int generation) {
    if (generation != _generation || !_active) return;
    _lastLineAt = DateTime.now();
    if (line.startsWith('#')) {
      if (line.startsWith('# logresp')) _onLogin(line);
      return;
    }
    final report = AprsCodec.parse(line);
    if (report == null) return;
    final own = _loginCall;
    if (own != null && (report.source == own || report.name == own)) return;
    if (report.removed) {
      if (_stations.remove(report.name) != null) _notifySoon();
      return;
    }
    _stations[report.name] = AprsStation(
      name: report.name,
      source: report.source,
      latitude: report.latitude,
      longitude: report.longitude,
      symbolTable: report.symbolTable,
      symbolCode: report.symbolCode,
      comment: report.comment.trim(),
      lastHeard: _lastLineAt,
    );
    if (_stations.length > _maximumStations) _prune(_lastLineAt);
    _notifySoon();
  }

  void _onLogin(String line) {
    verified = line.contains(' verified') && !_readOnly;
    _reconnectDelay = const Duration(seconds: 10);
    if (_readOnly) {
      status = 'Verbunden · nur Empfang (kein Rufzeichen eingetragen)';
    } else if (verified) {
      status = 'Verbunden als $_loginCall';
    } else {
      status =
          'Verbunden · Anmeldung als $_loginCall nicht bestätigt, nur Empfang';
    }
    AppLogger.info('APRS', 'Server-Antwort: ${line.substring(2)}');
    _beaconTimer?.cancel();
    if (verified) {
      _beaconTimer = Timer.periodic(beaconInterval, (_) => _sendBeacon());
      _sendBeacon();
    }
    _notifyNow();
  }

  void _scheduleBeacon() {
    if (!_active || !verified) return;
    final last = _lastBeaconAt;
    if (last == null) {
      _sendBeacon();
      return;
    }
    final wait = minimumBeaconSpacing - DateTime.now().difference(last);
    if (wait <= Duration.zero) {
      _sendBeacon();
    } else if (_pendingBeacon?.isActive != true) {
      _pendingBeacon = Timer(wait, _sendBeacon);
    }
  }

  void _sendBeacon() {
    final socket = _socket;
    final position = _position;
    final call = _loginCall;
    if (!_active ||
        !verified ||
        _readOnly ||
        socket == null ||
        position == null ||
        call == null) {
      return;
    }
    final packet = AprsCodec.positionPacket(
      callSign: call,
      latitude: position.latitude,
      longitude: position.longitude,
      comment: commentBuilder?.call() ?? 'CB-Funk',
    );
    try {
      socket.write('$packet\r\n');
      _lastBeaconAt = DateTime.now();
      _lastBeaconPosition = position;
      final t = _lastBeaconAt!;
      status =
          'Verbunden als $call · Position gesendet '
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
      _notifyNow();
    } catch (error) {
      AppLogger.warn('APRS', 'Position konnte nicht gesendet werden', error);
    }
  }

  void _connectionLost(int generation, String reason) {
    if (generation != _generation || !_active) return;
    AppLogger.warn('APRS', 'Verbindung verloren: $reason');
    _shutdownSocket();
    state = AprsLinkState.failed;
    verified = false;
    status = 'Verbindung verloren ($reason) – neuer Versuch folgt';
    _scheduleReconnect();
    _notifyNow();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = _reconnectDelay;
    _reconnectDelay = Duration(
      seconds: math.min(_reconnectDelay.inSeconds * 2, 120),
    );
    _reconnectTimer = Timer(delay, () {
      if (_active) unawaited(_connect());
    });
  }

  void _restart() {
    _shutdownSocket();
    _reconnectDelay = const Duration(seconds: 10);
    unawaited(_connect());
  }

  void _shutdownSocket() {
    _watchdog?.cancel();
    _watchdog = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _pendingBeacon?.cancel();
    _pendingBeacon = null;
    final lines = _lines;
    _lines = null;
    if (lines != null) unawaited(lines.cancel());
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    verified = false;
  }

  void _shutdown() {
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _callSignTimer?.cancel();
    _callSignTimer = null;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _shutdownSocket();
    _lastBeaconAt = null;
    _lastBeaconPosition = null;
  }

  void _prune(DateTime now) {
    _stations.removeWhere(
      (_, station) => now.difference(station.lastHeard) > stationTimeout,
    );
    if (_stations.length > _maximumStations) {
      final oldest = _stations.values.toList()
        ..sort((a, b) => a.lastHeard.compareTo(b.lastHeard));
      for (final station in oldest.take(_stations.length - _maximumStations)) {
        _stations.remove(station.name);
      }
    }
  }

  static double _distanceMeters(
    ({double latitude, double longitude}) a,
    ({double latitude, double longitude}) b,
  ) {
    const metersPerDegree = 111320.0;
    final dLat = (a.latitude - b.latitude) * metersPerDegree;
    final dLon =
        (a.longitude - b.longitude) *
        metersPerDegree *
        math.cos(a.latitude * math.pi / 180);
    return math.sqrt(dLat * dLat + dLon * dLon);
  }

  /// Kartenupdates gebuendelt (der Server liefert mehrere Pakete pro Sekunde)
  void _notifySoon() {
    if (_disposed || _notifyTimer != null) return;
    _notifyTimer = Timer(notifyDelay, () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  void _notifyNow() {
    if (_disposed) return;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _active = false;
    _shutdown();
    _stations.clear();
    _disposed = true;
    super.dispose();
  }
}
