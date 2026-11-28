import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cb_funk/services/aprs/aprs_codec.dart';
import 'package:cb_funk/services/aprs/aprs_service.dart';
import 'package:cb_funk/services/mqtt_service.dart';
import 'package:cb_funk/state/radio_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('APRS-Codec', () {
    test('Passcode nach APRS-IS-Verfahren aus dem Basis-Rufzeichen', () {
      expect(AprsCodec.passcode('N0CALL'), 13023);
      expect(AprsCodec.passcode('n0call-9'), 13023);
      expect(AprsCodec.passcode('13CB123'), AprsCodec.passcode('13cb123-5'));
    });

    test('Rufzeichen wird APRS-tauglich', () {
      expect(AprsCodec.callSign('13cb123'), '13CB123');
      expect(AprsCodec.callSign('13cb123-5'), '13CB123-5');
      expect(AprsCodec.callSign('DK-ALPHA'), 'DKALPHA');
      expect(AprsCodec.callSign('Lima 12'), 'LIMA12');
      expect(AprsCodec.callSign('ABCDEFGHIJKL'), 'ABCDEFGHI');
      expect(AprsCodec.callSign('ABCDEFGHIJ-12'), 'ABCDEF-12');
      expect(AprsCodec.callSign('  '), isNull);
      expect(AprsCodec.callSign('---'), isNull);
    });

    test('Koordinaten im APRS-Format', () {
      expect(AprsCodec.latitude(51.1657), '5109.94N');
      expect(AprsCodec.longitude(10.4515), '01027.09E');
      expect(AprsCodec.latitude(-33.5), '3330.00S');
      expect(AprsCodec.longitude(-72.0292), '07201.75W');
      expect(AprsCodec.latitude(50.999999), '5100.00N');
      expect(
        AprsCodec.positionPacket(
          callSign: '13CB123',
          latitude: 51.17,
          longitude: 10.45,
          comment: 'CB-Funk · Kanal 11',
        ),
        '13CB123>APZCBF,TCPIP*:!5110.20N/01027.00E-CB-Funk  Kanal 11',
      );
    });

    test('Feste Position vom CB-APRS-Server', () {
      final r = AprsCodec.parse(
        'CB4APRS>FUNFUNK,TCPIP*,qAC,FUNFUNK:!5057.82N/00729.37E#Wiehl BPQ32+BPQBBS',
      )!;
      expect(r.name, 'CB4APRS');
      expect(r.latitude, closeTo(50.96367, 1e-5));
      expect(r.longitude, closeTo(7.48950, 1e-5));
      expect(r.symbolTable, '/');
      expect(r.symbolCode, '#');
      expect(r.comment, 'Wiehl BPQ32+BPQBBS');
    });

    test('Position mit Zeitstempel', () {
      final r = AprsCodec.parse(
        '13TH514>APTGB4,TCPIP*,qAS,FUPOGATE:@281537z5111.22N/01200.61E> Andi on Tour.',
      )!;
      expect(r.name, '13TH514');
      expect(r.latitude, closeTo(51.18700, 1e-5));
      expect(r.longitude, closeTo(12.01017, 1e-5));
      expect(r.symbolCode, '>');
    });

    test('Objekt, Item und gelöschtes Objekt', () {
      final object = AprsCodec.parse(
        'FR62CD>APRS,TCPIP*,qAC,FRANCE:;ER-FR62CD*111111z5045.23NE00215.20E0446.000MHz',
      )!;
      expect(object.name, 'ER-FR62CD');
      expect(object.source, 'FR62CD');
      expect(object.latitude, closeTo(50.75383, 1e-5));
      expect(object.symbolTable, 'E');

      final item = AprsCodec.parse('X>APRS:)AID #2!4903.50N/07201.75WA')!;
      expect(item.name, 'AID #2');
      expect(item.longitude, closeTo(-72.02917, 1e-5));

      final killed = AprsCodec.parse(
        'X>APRS:;LEADER   _092345z4903.50N/07201.75W>',
      )!;
      expect(killed.removed, isTrue);
      expect(killed.name, 'LEADER');
    });

    test('Mic-E (Mobilstation)', () {
      final r = AprsCodec.parse(
        'LW6ENA-9>ST408V-2,LU7AA-10*,WIDE1-1*,WIDE2-2*,qAR,LU7ERZ-10:`V60m4y>/qap 433.650+',
      )!;
      expect(r.name, 'LW6ENA-9');
      expect(r.latitude, closeTo(-(34 + 40.86 / 60), 1e-5));
      expect(r.longitude, closeTo(-(58 + 26.20 / 60), 1e-5));
      expect(r.symbolTable, '/');
      expect(r.symbolCode, '>');
    });

    test('Komprimierte Position (Beispiel der APRS-Spezifikation)', () {
      final r = AprsCodec.parse('X>APRS:!/5L!!<*e7>7P[')!;
      expect(r.latitude, closeTo(49.5, 1e-4));
      expect(r.longitude, closeTo(-72.75, 1e-4));
      expect(r.symbolCode, '>');
    });

    test('Serverzeilen, Status und Unbekanntes werden ignoriert', () {
      for (final line in [
        '# logresp N0CALL unverified, server EIFEL-CB',
        'AP3NOD-13>APBPQ1,TCPIP*,qAC,EIFEL-CB:<IGATE,MSG_CNT=0,LOC_CNT=6',
        'ON3STE>WIDE1-1,TCPIP*,qAC,EIFEL-CB:!51°00\'53"N/3°28\'30"EI jCLNT',
        'kaputt',
        'A>B:',
      ]) {
        expect(AprsCodec.parse(line), isNull, reason: line);
      }
    });
  });

  group('APRS-Verbindung (lokaler Test-Server)', () {
    late ServerSocket server;
    late StreamIterator<Socket> clients;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      clients = StreamIterator(server);
    });

    tearDown(() async {
      await server.close();
    });

    AprsService service() => AprsService(
      host: '127.0.0.1',
      port: server.port,
      softwareVersion: '9.9.9',
      minimumBeaconSpacing: Duration.zero,
      notifyDelay: const Duration(milliseconds: 5),
    );

    Future<(Socket, StreamIterator<String>)> accept() async {
      expect(await clients.moveNext(), isTrue);
      final socket = clients.current;
      final lines = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      return (socket, lines);
    }

    Future<String> nextLine(StreamIterator<String> lines) async {
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 5)),
        isTrue,
      );
      return lines.current;
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('Anmeldung mit Passcode, Position (ca. 1 km), Empfang, Aus', () async {
      final aprs = service()
        ..commentBuilder = (() => 'CB-Funk Kanal 11')
          ..setCallSign('13cb123')
          ..setPosition(51.16574, 10.45151, precise: false)
          ..setActive(true);
      final (socket, lines) = await accept();
      socket.write('# CBAPRS-Server Test\r\n');

      final login = await nextLine(lines);
      expect(
        login,
        'user 13CB123 pass ${AprsCodec.passcode('13CB123')} vers CB-Funk 9.9.9',
      );

      socket.write('# logresp 13CB123 verified, server TEST\r\n');
      // Ungefaehr: auf 0,01 Grad gerundet (51,17 / 10,45)
      expect(
        await nextLine(lines),
        '13CB123>APZCBF,TCPIP*:!5110.20N/01027.00E-CB-Funk Kanal 11',
      );
      await until(() => aprs.verified);
      expect(aprs.status, contains('13CB123'));

      socket.write(
        'CB4APRS>FUNFUNK,TCPIP*,qAC,FUNFUNK:!5057.82N/00729.37E#Wiehl\r\n'
        '13CB123>APZCBF,TCPIP*,qAC,TEST:!5110.20N/01027.00E-eigenes Echo\r\n',
      );
      await until(() => aprs.stations.isNotEmpty);
      expect(aprs.stations.map((s) => s.name), ['CB4APRS']);

      // Genauer Standort: ungerundet
      aprs.setPosition(51.16574, 10.45151, precise: true);
      expect(
        await nextLine(lines),
        '13CB123>APZCBF,TCPIP*:!5109.94N/01027.09E-CB-Funk Kanal 11',
      );

      // Haken aus: Verbindung zu, Stationen weg, nichts mehr gesendet
      aprs.setActive(false);
      expect(aprs.stations, isEmpty);
      expect(aprs.state, AprsLinkState.off);
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 5)),
        isFalse,
      );
      aprs.setPosition(52.0, 11.0, precise: true);
      aprs.dispose();
      socket.destroy();
    });

    test('Ohne Rufzeichen nur Empfang, keine Position', () async {
      final aprs = service()
        ..setPosition(51.0, 10.0, precise: true)
        ..setActive(true);
      final (socket, lines) = await accept();
      final login = await nextLine(lines);
      expect(login, matches(RegExp(r'^user CBF\d{4} pass -1 vers ')));
      socket.write('# logresp CBF1234 unverified, server TEST\r\n');
      await until(() => aprs.status.contains('nur Empfang'));
      expect(aprs.verified, isFalse);
      // Keine Positionsmeldung
      await expectLater(
        lines.moveNext().timeout(const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      aprs.dispose();
      socket.destroy();
    });

    test('Nicht bestätigte Anmeldung sendet keine Position', () async {
      final aprs = service()
        ..setCallSign('13CB123')
        ..setPosition(51.0, 10.0, precise: true)
        ..setActive(true);
      final (socket, lines) = await accept();
      await nextLine(lines);
      socket.write('# logresp 13CB123 unverified, server TEST\r\n');
      await until(() => aprs.status.contains('nicht bestätigt'));
      await expectLater(
        lines.moveNext().timeout(const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      aprs.dispose();
      socket.destroy();
    });

    test('Nach Verbindungsabbruch wird neu verbunden', () async {
      final aprs = AprsService(
        host: '127.0.0.1',
        port: server.port,
        notifyDelay: const Duration(milliseconds: 5),
      )..setActive(true);
      final (first, _) = await accept();
      first.destroy();
      // Erster Neuversuch nach 10 s
      expect(
        await clients.moveNext().timeout(const Duration(seconds: 15)),
        isTrue,
      );
      clients.current.destroy();
      aprs.dispose();
    });
  });

  group('Einstellungen', () {
    setUpAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (call) async => call.method == 'isRecording' ? false : null,
          );
    });

    test(
      'APRS ist bei frischer Installation aus, Rufzeichen wird übernommen',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'callSign': 'dk-alpha',
        });
        // Kein dispose(): siehe sstv_camera_test.dart
        final radio = RadioController(MqttService());
        await radio.loadSettings();
        expect(radio.aprsEnabled, isFalse);
        expect(radio.aprs.active, isFalse);
        expect(radio.aprs.aprsCallSign, 'DKALPHA');
      },
    );
  });
}
