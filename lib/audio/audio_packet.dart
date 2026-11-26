import 'dart:typed_data';

/// Audio-Paket auf Topic cbfunk/ch/<n>/audio
///
/// Byte 0     Version (1)
/// Byte 1     Modulation (0=FM 1=AM 2=USB 3=LSB 4/6=SSTV 5/7=Packet AFSK)
/// Byte 2     Antennen-Pegel des Senders in dB (int8)
/// Byte 3     Kanal (1..80)
/// Byte 4-7   Sender-ID (uint32)
/// Byte 8-9   Sequenznummer (uint16)
/// Byte 10..  mu-law audio (voice/legacy digital) or PCM16LE (digital v2)
class AudioPacket {
  AudioPacket({
    required this.sender,
    required this.channel,
    required this.modulation,
    required this.antennaDb,
    required this.seq,
    required this.payload,
  });

  static const int version = 1;
  static const int headerLen = 10;
  static const int sstvModulation = 4;
  static const int packetRadioModulation = 5;
  static const int sstvLinearPcmModulation = 6;
  static const int packetRadioLinearPcmModulation = 7;

  static bool isSstvModulation(int modulation) =>
      modulation == sstvModulation || modulation == sstvLinearPcmModulation;

  static bool isPacketRadioModulation(int modulation) =>
      modulation == packetRadioModulation ||
      modulation == packetRadioLinearPcmModulation;

  static bool isDigitalModulation(int modulation) =>
      isSstvModulation(modulation) || isPacketRadioModulation(modulation);

  static bool isDigitalModulationForChannel(int channel, int modulation) =>
      (channel == 24 && isPacketRadioModulation(modulation)) ||
      (channel == 25 && isSstvModulation(modulation));

  static bool isLinearPcmModulation(int modulation) =>
      modulation == sstvLinearPcmModulation ||
      modulation == packetRadioLinearPcmModulation;

  static int? digitalModulationForChannel(int channel) => switch (channel) {
    24 => packetRadioLinearPcmModulation,
    25 => sstvLinearPcmModulation,
    _ => null,
  };

  static Uint8List encodeLinearPcm(Int16List samples) {
    final payload = Uint8List(samples.lengthInBytes);
    final data = ByteData.sublistView(payload);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    return payload;
  }

  static Int16List? decodeLinearPcm(Uint8List payload) {
    if (payload.isEmpty || payload.length.isOdd) return null;
    final samples = Int16List(payload.length ~/ 2);
    final data = ByteData.sublistView(payload);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little);
    }
    return samples;
  }

  final int sender;
  final int channel;
  final int modulation;
  final int antennaDb;
  final int seq;
  final Uint8List payload;

  Uint8List toBytes() {
    final out = Uint8List(headerLen + payload.length);
    final bd = ByteData.sublistView(out);
    out[0] = version;
    out[1] = modulation & 0xFF;
    bd.setInt8(2, antennaDb);
    out[3] = channel & 0xFF;
    bd.setUint32(4, sender);
    bd.setUint16(8, seq & 0xFFFF);
    out.setRange(headerLen, out.length, payload);
    return out;
  }

  static AudioPacket? parse(Uint8List d) {
    if (d.length <= headerLen || d[0] != version) return null;
    final bd = ByteData.sublistView(d);
    return AudioPacket(
      modulation: d[1],
      antennaDb: bd.getInt8(2),
      channel: d[3],
      sender: bd.getUint32(4),
      seq: bd.getUint16(8),
      payload: Uint8List.sublistView(d, headerLen),
    );
  }
}
