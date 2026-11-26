import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Drehregler in Silber mit rotem Markierungsstrich.
/// Bedienung per Touch/Maus: Kreisen um die Mitte.
class Knob extends StatelessWidget {
  const Knob({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.size = 74,
    this.warmStyle = false,
    this.chromeStyle = false,
  });

  final String label;
  final double value; // 0..1
  final ValueChanged<double> onChanged;
  final bool enabled;
  final double size;
  final bool warmStyle;
  final bool chromeStyle;

  static const double _minAngle = -135 * math.pi / 180;
  static const double _maxAngle = 135 * math.pi / 180;

  void _update(Offset local) {
    final c = Offset(size / 2, size / 2);
    final d = local - c;
    if (d.distance < 4) return;
    var a = math.atan2(d.dx, -d.dy); // 0 = oben, im Uhrzeigersinn
    a = a.clamp(_minAngle, _maxAngle).toDouble();
    onChanged((a - _minAngle) / (_maxAngle - _minAngle));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: enabled ? 1 : 0.45,
          child: GestureDetector(
            onPanStart: enabled ? (d) => _update(d.localPosition) : null,
            onPanUpdate: enabled ? (d) => _update(d.localPosition) : null,
            onTapDown: enabled ? (d) => _update(d.localPosition) : null,
            child: SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                painter: _KnobPainter(value, warmStyle, chromeStyle),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: enabled
                ? (warmStyle ? const Color(0xFFFFD89B) : CbColors.text)
                : CbColors.textDim,
          ),
        ),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter(this.value, this.warmStyle, this.chromeStyle);
  final double value;
  final bool warmStyle;
  final bool chromeStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    final tick = Paint()
      ..color = warmStyle
          ? const Color(0xFFC89A61)
          : chromeStyle
          ? const Color(0xFFDFE5E9)
          : CbColors.textDim
      ..strokeWidth = 1.2;
    for (var i = 0; i <= 10; i++) {
      final a = Knob._minAngle + (Knob._maxAngle - Knob._minAngle) * i / 10;
      final p1 = c + Offset(math.sin(a), -math.cos(a)) * (r * 0.92);
      final p2 = c + Offset(math.sin(a), -math.cos(a)) * (r * 1.0);
      canvas.drawLine(p1, p2, tick);
    }

    final kr = r * 0.78;
    canvas.drawCircle(
      c + const Offset(0, 2),
      kr,
      Paint()..color = Colors.black54,
    );
    if (chromeStyle && !warmStyle) {
      canvas.drawCircle(c, kr + 2, Paint()..color = const Color(0xFF1B2227));
      canvas.drawCircle(
        c,
        kr + 1,
        Paint()
          ..color = const Color(0xFF465159)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    canvas.drawCircle(
      c,
      kr,
      Paint()
        ..shader = SweepGradient(
          colors: warmStyle
              ? const [
                  Color(0xFFFFE8B0),
                  Color(0xFF9A6B35),
                  Color(0xFFFFD278),
                  Color(0xFF76502B),
                  Color(0xFFFFE8B0),
                ]
              : chromeStyle
              ? const [
                  Color(0xFFFFFFFF),
                  Color(0xFF6B737A),
                  Color(0xFFF8FBFD),
                  Color(0xFF7E878E),
                  Color(0xFFFFFFFF),
                ]
              : const [
                  CbColors.silverLight,
                  CbColors.silverDark,
                  CbColors.silverLight,
                  CbColors.silverDark,
                  CbColors.silverLight,
                ],
        ).createShader(Rect.fromCircle(center: c, radius: kr)),
    );
    canvas.drawCircle(
      c,
      kr * 0.82,
      Paint()
        ..shader = RadialGradient(
          colors: warmStyle
              ? const [Color(0xFFCEA86E), Color(0xFF805A31)]
              : chromeStyle
              ? const [
                  Color(0xFFF0F3F5),
                  Color(0xFFB6C0C6),
                  Color(0xFF59646B),
                ]
              : const [Color(0xFFF4F6F8), Color(0xFFA7AEB5)],
          stops: chromeStyle && !warmStyle ? const [0, 0.58, 1] : null,
        ).createShader(Rect.fromCircle(center: c, radius: kr)),
    );

    if (chromeStyle && !warmStyle) {
      final faceRadius = kr * 0.82;
      final faceRect = Rect.fromCircle(center: c, radius: faceRadius);
      canvas.save();
      canvas.clipPath(Path()..addOval(faceRect));
      final glint = Rect.fromCenter(
        center: c + Offset(-faceRadius * 0.12, -faceRadius * 0.46),
        width: faceRadius * 1.15,
        height: faceRadius * 0.2,
      );
      canvas.drawOval(
        glint,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x66FFFFFF), Color(0x00FFFFFF)],
          ).createShader(glint),
      );
      canvas.restore();
      canvas.drawCircle(
        c,
        kr,
        Paint()
          ..color = const Color(0xFFE8EDF0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      canvas.drawCircle(
        c,
        faceRadius,
        Paint()
          ..color = const Color(0xFF626B72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final a = Knob._minAngle + (Knob._maxAngle - Knob._minAngle) * value;
    final dir = Offset(math.sin(a), -math.cos(a));
    final markStart = c + dir * (kr * 0.25);
    final markEnd = c + dir * (kr * 0.92);
    if (chromeStyle && !warmStyle) {
      canvas.drawCircle(
        c,
        kr * 0.82,
        Paint()
          ..color = const Color(0xFF687178)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
      canvas.drawLine(
        markStart + const Offset(0, 1.2),
        markEnd + const Offset(0, 1.2),
        Paint()
          ..color = const Color(0xAA000000)
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        markStart,
        markEnd,
        Paint()
          ..color = const Color(0xFFD62027)
          ..strokeWidth = 4.8
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        markStart,
        markEnd,
        Paint()
          ..color = const Color(0xFFFFA3A5)
          ..strokeWidth = 1.1
          ..strokeCap = StrokeCap.round,
      );
    } else {
      canvas.drawLine(
        markStart,
        markEnd,
        Paint()
          ..color = warmStyle ? const Color(0xFF452718) : CbColors.knobMark
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_KnobPainter old) =>
      old.value != value ||
      old.warmStyle != warmStyle ||
      old.chromeStyle != chromeStyle;
}
