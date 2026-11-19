import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cb_funk/audio/audio_packet.dart';
import 'package:cb_funk/audio/mulaw.dart';
import 'package:cb_funk/data/cb_channels.dart';

void main() {
  test('Kanaltabelle: 80 Kanaele, Kanal 11 = 27.085 MHz', () {
    expect(CbChannels.count, 80);
    expect(CbChannels.frequency(11), closeTo(27.085, 0.0001));
    expect(CbChannels.frequency(1), closeTo(26.965, 0.0001));
    expect(CbChannels.frequency(41), closeTo(26.565, 0.0001));
  });

  test('mu-law Rundlauf bleibt nahe am Original', () {
    for (final v in [-20000, -3000, -500, 0, 500, 3000, 20000]) {
      final back = MuLaw.decode(MuLaw.encode(v));
      expect((back - v).abs() <= (v.abs() * 0.07 + 40), isTrue,
          reason: 'v=$v back=$back');
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
