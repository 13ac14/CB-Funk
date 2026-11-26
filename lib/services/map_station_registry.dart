class MapStation {
  const MapStation({
    required this.senderId,
    required this.channel,
    required this.callSign,
    required this.latitude,
    required this.longitude,
    required this.lastSeen,
    required this.transmitting,
  });

  final int senderId;
  final int channel;
  final String callSign;
  final double latitude;
  final double longitude;
  final DateTime lastSeen;
  final bool transmitting;
}

class MapStationRegistry {
  static const offlineTimeout = Duration(minutes: 2);

  final Map<String, MapStation> _stations = {};
  final Map<int, String> _keyBySender = {};
  final Map<String, DateTime> _lastTransmitAt = {};

  List<MapStation> stations({DateTime? now}) {
    _prune(now ?? DateTime.now());
    return List<MapStation>.unmodifiable(_stations.values);
  }

  bool update(Map<String, dynamic> message, {DateTime? now}) {
    final senderId = (message['sid'] as num?)?.toInt();
    final channel = (message['ch'] as num?)?.toInt();
    if (senderId == null || channel == null || channel < 1 || channel > 80) {
      return false;
    }
    final receivedAt = now ?? DateTime.now();
    _prune(receivedAt);

    final previousKey = _keyBySender[senderId];
    final advertisedCallSign = message['callsign'];
    final previous =
        _stations[previousKey ?? _key(advertisedCallSign, senderId)];
    final callSign =
        advertisedCallSign is String && advertisedCallSign.trim().isNotEmpty
        ? advertisedCallSign.trim().toUpperCase()
        : previous?.callSign ??
              'Station ${senderId.toRadixString(16).toUpperCase()}';
    final key = _key(callSign, senderId);

    if (message['loc'] == false) {
      _stations.remove(key);
      _lastTransmitAt.remove(key);
      if (previousKey != null) _stations.remove(previousKey);
      if (previousKey != null) _lastTransmitAt.remove(previousKey);
      _keyBySender.remove(senderId);
      return previous != null;
    }

    final lat = message['lat'];
    final lon = message['lon'];
    final hasCoordinates =
        lat is num &&
        lon is num &&
        lat.toDouble().isFinite &&
        lon.toDouble().isFinite &&
        lat.toDouble() >= -90 &&
        lat.toDouble() <= 90 &&
        lon.toDouble() >= -180 &&
        lon.toDouble() <= 180;
    if (!hasCoordinates && previous == null) return false;

    final oldAtKey = _stations[key];
    if (previousKey != null &&
        previousKey != key &&
        _stations[previousKey]?.senderId == senderId) {
      _stations.remove(previousKey);
      final previousTransmitAt = _lastTransmitAt.remove(previousKey);
      if (previousTransmitAt != null) {
        _lastTransmitAt[key] = previousTransmitAt;
      }
    }
    final ptt = message['ptt'];
    final tx = message['tx'];
    final transmitting = tx is bool
        ? tx
        : ptt is bool
        ? ptt
        : previous?.transmitting ?? false;
    if (transmitting) {
      if (tx == true ||
          ptt == true ||
          (message['hb'] == true && previous?.transmitting == true)) {
        _lastTransmitAt[key] = receivedAt;
      }
    } else {
      _lastTransmitAt.remove(key);
    }
    final station = MapStation(
      senderId: senderId,
      channel: channel,
      callSign: callSign,
      latitude: hasCoordinates ? lat.toDouble() : previous!.latitude,
      longitude: hasCoordinates ? lon.toDouble() : previous!.longitude,
      lastSeen: receivedAt,
      transmitting: transmitting,
    );
    _stations[key] = station;
    _keyBySender[senderId] = key;
    return oldAtKey?.channel != station.channel ||
        oldAtKey?.callSign != station.callSign ||
        oldAtKey?.latitude != station.latitude ||
        oldAtKey?.longitude != station.longitude ||
        oldAtKey?.transmitting != station.transmitting;
  }

  void removeSender(int senderId, {String? callSign}) {
    final key = _keyBySender.remove(senderId);
    if (key != null) {
      _stations.remove(key);
      _lastTransmitAt.remove(key);
    }
    if (callSign != null && callSign.trim().isNotEmpty) {
      final callSignKey = _key(callSign, senderId);
      _stations.remove(callSignKey);
      _lastTransmitAt.remove(callSignKey);
    }
  }

  void clear() {
    _stations.clear();
    _keyBySender.clear();
    _lastTransmitAt.clear();
  }

  void _prune(DateTime now) {
    _stations.removeWhere(
      (_, station) => now.difference(station.lastSeen) > offlineTimeout,
    );
    _lastTransmitAt.removeWhere((key, _) => !_stations.containsKey(key));
    for (final entry in _stations.entries.toList()) {
      final station = entry.value;
      final lastTransmit = _lastTransmitAt[entry.key];
      if (station.transmitting &&
          lastTransmit != null &&
          now.difference(lastTransmit) > const Duration(seconds: 24)) {
        _stations[entry.key] = MapStation(
          senderId: station.senderId,
          channel: station.channel,
          callSign: station.callSign,
          latitude: station.latitude,
          longitude: station.longitude,
          lastSeen: station.lastSeen,
          transmitting: false,
        );
        _lastTransmitAt.remove(entry.key);
      }
    }
    _keyBySender.removeWhere((senderId, key) {
      final station = _stations[key];
      return station == null || station.senderId != senderId;
    });
  }

  String _key(Object? callSign, int senderId) {
    if (callSign is String && callSign.trim().isNotEmpty) {
      return 'CALL:${callSign.trim().toUpperCase()}';
    }
    return 'SID:$senderId';
  }
}
