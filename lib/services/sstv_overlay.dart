import 'dart:typed_data';
import 'dart:ui' as ui;

/// Blendet beim SSTV-Senden Rufzeichen und Uhrzeit oben links ins Bild ein
/// (aehnlich MMSSTV). Das Motiv wird 1:1 uebernommen, nicht skaliert oder
/// verzerrt; nur der kleine Bereich unter dem Hintergrundbalken aendert sich.
class SstvOverlay {
  SstvOverlay._();

  static const double _fontSize = 17;
  static const double _margin = 4;
  static const double _paddingX = 6;
  static const double _paddingY = 3;

  /// Text der Einblendung, z. B. "DK-ALPHA · 14:05". Ohne Rufzeichen nur
  /// die Uhrzeit.
  static String label({required String callSign, required DateTime time}) {
    final hours = time.hour.toString().padLeft(2, '0');
    final minutes = time.minute.toString().padLeft(2, '0');
    final clock = '$hours:$minutes';
    final call = callSign.trim().toUpperCase();
    return call.isEmpty ? clock : '$call · $clock';
  }

  /// Zeichnet die Einblendung auf ein PNG und liefert wieder ein PNG gleicher
  /// Groesse.
  static Future<Uint8List> stamp(
    Uint8List png, {
    required String callSign,
    required DateTime time,
  }) async {
    final codec = await ui.instantiateImageCodec(png);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final width = image.width;
        final height = image.height;
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        // Motiv pixelgenau uebernehmen (ganzzahliger Versatz, kein Filter)
        canvas.drawImage(
          image,
          ui.Offset.zero,
          ui.Paint()..filterQuality = ui.FilterQuality.none,
        );

        final builder =
            ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  maxLines: 1,
                  ellipsis: '…',
                  fontFamily: 'Segoe UI',
                ),
              )
              ..pushStyle(
                ui.TextStyle(
                  color: const ui.Color(0xFFFFFFFF),
                  fontSize: _fontSize,
                  fontWeight: ui.FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              )
              ..addText(label(callSign: callSign, time: time));
        final paragraph = builder.build()
          ..layout(
            ui.ParagraphConstraints(width: width - 2 * (_margin + _paddingX)),
          );
        final textWidth = paragraph.longestLine.ceilToDouble();
        final textHeight = paragraph.height.ceilToDouble();

        // Dunkler, leicht transparenter Balken fuer gute Lesbarkeit auch
        // nach der SSTV-Uebertragung (helle Schrift auf dunklem Grund).
        canvas.drawRRect(
          ui.RRect.fromRectAndRadius(
            ui.Rect.fromLTWH(
              _margin,
              _margin,
              textWidth + 2 * _paddingX,
              textHeight + 2 * _paddingY,
            ),
            const ui.Radius.circular(3),
          ),
          ui.Paint()..color = const ui.Color(0xC0000000),
        );
        canvas.drawParagraph(
          paragraph,
          const ui.Offset(_margin + _paddingX, _margin + _paddingY),
        );

        final picture = recorder.endRecording();
        try {
          final stamped = await picture.toImage(width, height);
          try {
            final data = await stamped.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null) {
              throw StateError('SSTV-Einblendung konnte nicht kodiert werden');
            }
            return data.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
          } finally {
            stamped.dispose();
          }
        } finally {
          picture.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
