import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/packet_radio_service.dart';
import '../services/sstv_modem.dart';
import '../services/sstv_service.dart';
import '../state/radio_controller.dart';
import 'sstv_camera_dialog.dart';
import 'sstv_image_actions.dart';
import 'sstv_image_picker_dialog.dart';

enum DigitalOverlayMode { sstv, packet }

class DigitalRadioOverlay extends StatefulWidget {
  const DigitalRadioOverlay({
    super.key,
    required this.mode,
    required this.radio,
    required this.sstv,
    required this.packet,
    required this.onClose,
  });

  final DigitalOverlayMode mode;
  final RadioController radio;
  final SstvService sstv;
  final PacketRadioService packet;
  final VoidCallback onClose;

  @override
  State<DigitalRadioOverlay> createState() => _DigitalRadioOverlayState();
}

class _DigitalRadioOverlayState extends State<DigitalRadioOverlay> {
  Offset _position = const Offset(10, 225);

  @override
  Widget build(BuildContext context) {
    final isSstv = widget.mode == DigitalOverlayMode.sstv;
    final width = isSstv ? 570.0 : 510.0;
    final height = isSstv ? 485.0 : 470.0;
    return Positioned(
      left: _position.dx,
      top: _position.dy,
      width: width,
      height: height,
      child: Material(
        elevation: 22,
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF21150F),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFC18A53), width: 2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                blurRadius: 18,
                offset: Offset(0, 7),
              ),
            ],
          ),
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (details) {
                  setState(() {
                    _position = Offset(
                      (_position.dx + details.delta.dx)
                          .clamp(0.0, 1280.0 - width)
                          .toDouble(),
                      (_position.dy + details.delta.dy)
                          .clamp(0.0, 720.0 - height)
                          .toDouble(),
                    );
                  });
                },
                child: _titleBar(isSstv),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: isSstv ? _sstvContent() : _packetContent(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<File?> _showSstvImagePicker(BuildContext context) => showDialog<File>(
    context: context,
    builder: (_) => const SstvImagePickerDialog(),
  );

  /// Foto ueber eine Kamera; zugeschnitten auf das Seitenverhaeltnis des
  /// gewaehlten SSTV-Modus (320 x 256 bzw. 320 x 240).
  Future<File?> _showSstvCamera(BuildContext context, SstvMode mode) =>
      showDialog<File>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            SstvCameraDialog(aspect: 320 / SstvModem.imageHeight(mode)),
      );

  Widget _titleBar(bool isSstv) => Container(
    height: 38,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: const BoxDecoration(
      color: Color(0xFF51301D),
      borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
    ),
    child: Row(
      children: [
        Icon(
          isSstv ? Icons.image_outlined : Icons.forum_outlined,
          color: const Color(0xFFFFD89B),
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            isSstv
                ? 'SSTV · KANAL 25 · 27,245 MHz'
                : 'PACKET RADIO · KANAL 24 · 27,235 MHz · 1200 BAUD',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFFFE4B7),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
        const Text(
          'VERSCHIEBEN',
          style: TextStyle(color: Color(0xFFCFB18A), fontSize: 8),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Schließen',
          onPressed: widget.onClose,
          icon: const Icon(Icons.close, size: 17),
          color: const Color(0xFFFFD89B),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
        ),
      ],
    ),
  );

  Widget _sstvContent() => AnimatedBuilder(
    animation: widget.sstv,
    builder: (context, _) {
      final service = widget.sstv;
      final valid = service.channelReady;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!valid)
            _notice('Nur auf Kanal 25 aktiv')
          else
            _notice('Martin 1 · Scottie 1 · Robot 36 · Auto-Slant-Empfang'),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 3, child: _imagePreview(service)),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: _recentImages(service.recentImages)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'MODUS',
                style: TextStyle(
                  color: Color(0xFFE9C99C),
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<SstvMode>(
                value: service.selectedMode,
                dropdownColor: const Color(0xFF352116),
                style: const TextStyle(color: Color(0xFFFFE1B4), fontSize: 12),
                underline: const SizedBox.shrink(),
                items: SstvMode.values
                    .map(
                      (mode) => DropdownMenuItem(
                        value: mode,
                        child: Text(mode.label),
                      ),
                    )
                    .toList(),
                onChanged: service.modeLocked
                    ? null
                    : (mode) {
                        if (mode != null) service.setMode(mode);
                      },
              ),
              const Spacer(),
              _smallButton(
                service.loadingImage ? 'LÄDT …' : 'BILD LADEN',
                onPressed: service.sending || service.loadingImage
                    ? null
                    : () => _runSstv(
                        () => service.loadImage(
                          () => _showSstvImagePicker(context),
                        ),
                      ),
              ),
              const SizedBox(width: 7),
              _smallButton(
                'KAMERA',
                onPressed: service.sending || service.loadingImage
                    ? null
                    : () => _runSstv(
                        () => service.loadImage(
                          () => _showSstvCamera(context, service.selectedMode),
                        ),
                      ),
              ),
              const SizedBox(width: 7),
              _smallButton(
                service.sending ? 'ABBRECHEN' : 'SENDEN',
                active: service.sending,
                onPressed: service.sending
                    ? widget.radio.cancelDigitalTransmission
                    : !valid
                    ? null
                    : () => _runSstv(service.send),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (service.sending || service.receiving || service.decoding)
            LinearProgressIndicator(
              value: service.progress,
              minHeight: 3,
              backgroundColor: const Color(0xFF47301E),
              color: const Color(0xFFFFC666),
            )
          else
            const SizedBox(height: 3),
          Text(
            service.lastError == null
                ? service.status
                : '${service.status}: ${service.lastError}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: service.lastError == null
                  ? const Color(0xFFE4CCAA)
                  : const Color(0xFFFF8C78),
              fontSize: 10,
            ),
          ),
        ],
      );
    },
  );

  Widget _imagePreview(SstvService service) {
    final loaded = service.loadedImage;
    final recent = service.recentImages;
    Widget image;
    if (service.receiving && service.liveImage != null) {
      image = SstvImageActions(
        title: 'SSTV-Empfang (Live-Stand)',
        loadPng: () => _liveImagePng(service),
        child: RawImage(
          image: service.liveImage,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
      );
    } else if (loaded != null) {
      final name = service.loadedImageName;
      image = SstvImageActions(
        title: name == null ? 'Geladenes Bild' : 'Geladenes Bild · $name',
        suggestedName: name,
        loadPng: () async => loaded,
        child: Image.memory(loaded, fit: BoxFit.contain, gaplessPlayback: true),
      );
    } else if (recent.isNotEmpty) {
      final file = recent.first;
      image = SstvImageActions(
        title: _recentTitle(file),
        suggestedName: _fileBaseName(file),
        loadPng: file.readAsBytes,
        child: Image.file(file, fit: BoxFit.contain),
      );
    } else {
      image = const Center(
        child: Text(
          'Bild laden\noder SSTV empfangen',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFFBAA084), fontSize: 12),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF100C09),
        border: Border.all(color: const Color(0xFF6D482C)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (service.receiving)
              const Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  color: Color(0xFFFFC666),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _recentImages(List<File> files) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'LETZTE 2 · LOKAL',
        style: TextStyle(
          color: Color(0xFFE9C99C),
          fontSize: 9,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: files.isEmpty
            ? const Center(
                child: Text(
                  'Noch keine Bilder',
                  style: TextStyle(color: Color(0xFFBAA084), fontSize: 10),
                ),
              )
            : ListView.separated(
                itemCount: files.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final file = files[index];
                  return SizedBox(
                    height: 100,
                    child: SstvImageActions(
                      title: _recentTitle(file),
                      suggestedName: _fileBaseName(file),
                      loadPng: file.readAsBytes,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF100C09),
                          border: Border.all(color: const Color(0xFF6D482C)),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: Image.file(file, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );

  /// Momentaufnahme des Live-Empfangs als PNG.
  static Future<Uint8List> _liveImagePng(SstvService service) async {
    final live = service.liveImage?.clone();
    if (live == null) throw StateError('Kein Live-Bild vorhanden');
    try {
      final data = await live.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Live-Bild nicht lesbar');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      live.dispose();
    }
  }

  static String _fileBaseName(File file) {
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// "Empfangen · 27.11.2026 14:05:12" aus sstv_<UTC-Zeit>_rx.png
  static String _recentTitle(File file) {
    final match = RegExp(
      r'^sstv_(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})(\.\d+)?Z_(tx|rx)',
    ).firstMatch(file.uri.pathSegments.last);
    if (match == null) return file.uri.pathSegments.last;
    final time = DateTime.tryParse(
      '${match[1]}T${match[2]}:${match[3]}:${match[4]}${match[5] ?? ''}Z',
    )?.toLocal();
    final kind = match[6] == 'tx' ? 'Gesendet' : 'Empfangen';
    if (time == null) return kind;
    String two(int value) => value.toString().padLeft(2, '0');
    return '$kind · ${two(time.day)}.${two(time.month)}.${time.year} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  Widget _packetContent() => AnimatedBuilder(
    animation: widget.packet,
    builder: (context, _) {
      final service = widget.packet;
      final valid = widget.radio.channel == 24;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _notice('Nur auf Kanal 24 aktiv · 1200 Baud'),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF100C09),
                border: Border.all(color: const Color(0xFF6D482C)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: service.entries.isEmpty
                  ? const Center(
                      child: Text(
                        'Packet-Radio-Terminal · 1200 Baud AFSK',
                        style: TextStyle(
                          color: Color(0xFFBAA084),
                          fontSize: 11,
                        ),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(8),
                      itemCount: service.entries.length,
                      itemBuilder: (context, index) {
                        final entry =
                            service.entries[service.entries.length - index - 1];
                        final time = entry.time.toLocal();
                        final stamp =
                            '${time.hour.toString().padLeft(2, '0')}:'
                            '${time.minute.toString().padLeft(2, '0')}:'
                            '${time.second.toString().padLeft(2, '0')}';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text.rich(
                            TextSpan(
                              style: const TextStyle(
                                color: Color(0xFFE6D2B9),
                                fontSize: 11,
                              ),
                              children: [
                                TextSpan(
                                  text:
                                      '$stamp ${entry.from} > ${entry.to}'
                                      '${entry.sent ? ' · TX' : ' · RX'}\n',
                                  style: const TextStyle(
                                    color: Color(0xFFFFCA7B),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                TextSpan(text: entry.text),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _destination,
                  enabled: !service.sending,
                  maxLength: 6,
                  textCapitalization: TextCapitalization.characters,
                  decoration: _fieldDecoration('TO', counterText: ''),
                  style: const TextStyle(color: Color(0xFFFFE1B4)),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _message,
                  enabled: !service.sending,
                  maxLength: 240,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: _fieldDecoration('Nachricht'),
                  style: const TextStyle(color: Color(0xFFFFE1B4)),
                  onSubmitted: (_) => _sendPacket(service, valid),
                ),
              ),
              const SizedBox(width: 6),
              _smallButton(
                service.sending ? 'SENDET…' : 'SENDEN',
                active: service.sending,
                onPressed: !valid || service.sending
                    ? null
                    : () => _sendPacket(service, valid),
              ),
            ],
          ),
          Row(
            children: [
              Switch(
                value: service.logging,
                onChanged: (value) {
                  service.setLogging(value);
                },
                activeThumbColor: const Color(0xFFFFC666),
              ),
              const Text(
                'Lokales Text-Log',
                style: TextStyle(color: Color(0xFFE4CCAA), fontSize: 10),
              ),
              const Spacer(),
              Text(
                service.status,
                style: const TextStyle(color: Color(0xFFE4CCAA), fontSize: 9),
              ),
            ],
          ),
        ],
      );
    },
  );

  final TextEditingController _destination = TextEditingController(text: 'CQ');
  final TextEditingController _message = TextEditingController();

  Future<void> _sendPacket(
    PacketRadioService service,
    bool channelReady,
  ) async {
    if (!channelReady) return;
    final text = _message.text.trim();
    if (text.isEmpty) return;
    try {
      await service.send(to: _destination.text, text: text);
      _message.clear();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _runSstv(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.toString()),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _notice(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xFF332116),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0xFF7E5734)),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xFFFFD99F),
        fontWeight: FontWeight.w700,
        fontSize: 10,
      ),
    ),
  );

  Widget _smallButton(
    String label, {
    required VoidCallback? onPressed,
    bool active = false,
  }) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: const Color(0xFFFFE1B4),
      backgroundColor: active
          ? const Color(0xFF6A321E)
          : const Color(0xFF3B2618),
      side: BorderSide(
        color: active ? const Color(0xFFFFC666) : const Color(0xFF9B7048),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      minimumSize: const Size(0, 32),
      textStyle: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800),
    ),
    child: Text(label),
  );

  InputDecoration _fieldDecoration(String label, {String? counterText}) =>
      InputDecoration(
        labelText: label,
        counterText: counterText,
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF100C09),
        labelStyle: const TextStyle(color: Color(0xFFBFA47F), fontSize: 10),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Color(0xFF6D482C)),
          borderRadius: BorderRadius.circular(6),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Color(0xFFFFC666)),
          borderRadius: BorderRadius.circular(6),
        ),
      );
}
