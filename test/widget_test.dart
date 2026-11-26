import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cb_funk/audio/audio_packet.dart';
import 'package:cb_funk/audio/mulaw.dart';
import 'package:cb_funk/data/cb_channels.dart';
import 'package:cb_funk/services/location_privacy.dart';
import 'package:cb_funk/services/map_station_registry.dart';

void main() {
  test('Kanaltabelle: 80 Kanaele, Kanal 11 = 27.085 MHz', () {
    expect(CbChannels.count, 80);
    expect(CbChannels.frequency(11), closeTo(27.085, 0.0001));
    expect(CbChannels.frequency(1), closeTo(26.965, 0.0001));
    expect(CbChannels.frequency(41), closeTo(26.565, 0.0001));
  });

  test('Standortfreigabe rundet ungefaehre Koordinaten, genaue nicht', () {
    expect(LocationPrivacy.shareCoordinate(52.5234, precise: false), 52.52);
    expect(LocationPrivacy.shareCoordinate(13.4122, precise: false), 13.41);
    expect(LocationPrivacy.shareCoordinate(52.5234, precise: true), 52.5234);
  });

  test(
    'Kartenstation behaelt Koordinaten bei Kontrollpaketen ohne Standort',
    () {
      final registry = MapStationRegistry();
      final now = DateTime(2026, 11, 23);
      registry.update({
        'sid': 42,
        'ch': 11,
        'callsign': 'DO5VH',
        'lat': 52.52,
        'lon': 13.41,
        'loc': true,
      }, now: now);
      registry.update({
        'sid': 42,
        'ch': 19,
        'callsign': 'DO5VH',
        'ptt': true,
        'loc': true,
      }, now: now.add(const Duration(seconds: 30)));

      final station = registry.stations(
        now: now.add(const Duration(seconds: 30)),
      );
      expect(station, hasLength(1));
      expect(station.single.callSign, 'DO5VH');
      expect(station.single.channel, 19);
      expect(station.single.latitude, 52.52);
      expect(station.single.longitude, 13.41);
    },
  );

  test('Kartenstation wird nach explizitem Standort-Ausschalten entfernt', () {
    final registry = MapStationRegistry();
    registry.update({
      'sid': 42,
      'ch': 11,
      'callsign': 'DO5VH',
      'lat': 52.52,
      'lon': 13.41,
    });
    registry.update({'sid': 42, 'ch': 11, 'callsign': 'DO5VH', 'loc': false});

    expect(registry.stations(), isEmpty);
  });

  test('TX-Status folgt MQTT-PTT und Heartbeat', () {
    final registry = MapStationRegistry();
    final now = DateTime(2026, 11, 23);
    registry.update({
      'sid': 42,
      'ch': 11,
      'callsign': 'DO5VH',
      'lat': 52.52,
      'lon': 13.41,
      'tx': true,
    }, now: now);
    expect(registry.stations(now: now).single.transmitting, isTrue);

    registry.update({
      'sid': 42,
      'ch': 11,
      'callsign': 'DO5VH',
      'hb': true,
      'tx': false,
    }, now: now.add(const Duration(seconds: 8)));
    expect(
      registry
          .stations(now: now.add(const Duration(seconds: 8)))
          .single
          .transmitting,
      isFalse,
    );
  });

  test(
    'Kartenstation bleibt waehrend Aktivitaet online und laeuft spaeter ab',
    () {
      final registry = MapStationRegistry();
      final now = DateTime(2026, 11, 23);
      registry.update({
        'sid': 42,
        'ch': 11,
        'callsign': 'DO5VH',
        'lat': 52.52,
        'lon': 13.41,
      }, now: now);
      registry.update({
        'sid': 42,
        'ch': 11,
        'callsign': 'DO5VH',
        'hb': true,
      }, now: now.add(const Duration(seconds: 90)));

      expect(
        registry.stations(now: now.add(const Duration(seconds: 180))),
        hasLength(1),
      );
      expect(
        registry.stations(now: now.add(const Duration(seconds: 211))),
        isEmpty,
      );
      expect(
        registry.update({
          'sid': 42,
          'ch': 11,
          'callsign': 'DO5VH',
          'hb': true,
        }, now: now.add(const Duration(seconds: 211))),
        isFalse,
      );
    },
  );

  test('mu-law Rundlauf bleibt nahe am Original', () {
    for (final v in [-20000, -3000, -500, 0, 500, 3000, 20000]) {
      final back = MuLaw.decode(MuLaw.encode(v));
      expect(
        (back - v).abs() <= (v.abs() * 0.07 + 40),
        isTrue,
        reason: 'v=$v back=$back',
      );
    }
  });

  test('Audio-Paket Rundlauf inkl. Gateway-Bit', () {
    final p = AudioPacket(
      sender: 0x80000000 | 1234,
      channel: 19,
      modulation: 2,
      antennaDb: -9,
      seq: 65535,
      payload: Uint8List.fromList(List.generate(160, (i) => i)),
    );
    final q = AudioPacket.parse(p.toBytes())!;
    expect(q.sender, 0x80000000 | 1234);
    expect(q.channel, 19);
    expect(q.modulation, 2);
    expect(q.antennaDb, -9);
    expect(q.seq, 65535);
    expect(q.payload.length, 160);
  });
}
