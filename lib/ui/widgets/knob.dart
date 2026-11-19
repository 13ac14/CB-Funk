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
  });

  final String label;
  final double value; // 0..1
  final ValueChanged<double> onChanged;
  final bool enabled;
  final double size;

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
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Opacity(
        opacity: enabled ? 1 : 0.45,
        child: GestureDetector(
          onPanStart: enabled ? (d) => _update(d.localPosition) : null,
          onPanUpdate: enabled ? (d) => _update(d.localPosition) : null,
          onTapDown: enabled ? (d) => _update(d.localPosition) : null,
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(painter: _KnobPainter(value)),
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: enabled ? CbColors.text : CbColors.textDim)),
    ]);
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter(this.value);
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    final tick = Paint()
      ..color = CbColors.textDim
      ..strokeWidth = 1.2;
    for (var i = 0; i <= 10; i++) {
      final a = Knob._minAngle + (Knob._maxAngle - Knob._minAngle) * i / 10;
      final p1 = c + Offset(math.sin(a), -math.cos(a)) * (r * 0.92);
      final p2 = c + Offset(math.sin(a), -math.cos(a)) * (r * 1.0);
      canvas.drawLine(p1, p2, tick);
    }

    final kr = r * 0.78;
    canvas.drawCircle(c + const Offset(0, 2), kr, Paint()..color = Colors.black54);
    canvas.drawCircle(
      c,
      kr,
      Paint()
        ..shader = const SweepGradient(colors: [
          CbColors.silverLight,
          CbColors.silverDark,
          CbColors.silverLight,
          CbColors.silverDark,
          CbColors.silverLight,
        ]).createShader(Rect.fromCircle(center: c, radius: kr)),
    );
    canvas.drawCircle(
      c,
      kr * 0.82,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFF4F6F8), Color(0xFFA7AEB5)],
        ).createShader(Rect.fromCircle(center: c, radius: kr)),
    );

    final a = Knob._minAngle + (Knob._maxAngle - Knob._minAngle) * value;
    final dir = Offset(math.sin(a), -math.cos(a));
    canvas.drawLine(
      c + dir * (kr * 0.25),
      c + dir * (kr * 0.92),
      Paint()
        ..color = CbColors.knobMark
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.value != value;
}
