import 'package:flutter/material.dart';
import '../theme.dart';

class RadioKey extends StatelessWidget {
  const RadioKey({
    super.key,
    required this.label,
    required this.onTap,
    this.active = false,
    this.textColor,
    this.height = 46,
    this.fontSize = 14,
    this.warmStyle = false,
    this.raisedStyle = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? textColor;
  final double height;
  final double fontSize;
  final bool warmStyle;
  final bool raisedStyle;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Ink(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: raisedStyle
                  ? const [
                      Color(0xFF806747),
                      Color(0xFF58432D),
                      Color(0xFF302319),
                    ]
                  : warmStyle
                  ? const [Color(0xFF8A4B2C), Color(0xFF492315)]
                  : const [CbColors.metal, CbColors.metalDark],
            ),
            border: Border.all(
              color: active
                  ? (warmStyle
                        ? const Color(0xFFFFD17F)
                        : raisedStyle
                        ? const Color(0xFFFFD17F)
                        : CbColors.displayBlue)
                  : (warmStyle
                        ? const Color(0xFFB87945)
                        : raisedStyle
                        ? const Color(0xFFB28A5F)
                        : Colors.black54),
              width: 1.4,
            ),
            boxShadow: raisedStyle
                ? const [
                    BoxShadow(
                      color: Color(0x99000000),
                      offset: Offset(0, 2),
                      blurRadius: 2,
                    ),
                    BoxShadow(
                      color: Color(0x558E6741),
                      offset: Offset(0, -1),
                      blurRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            // Einzeilig; bei grosser Handyschrift lieber etwas kleiner als umbrechen
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: fontSize,
                  letterSpacing: 0.5,
                  color:
                      textColor ??
                      (active
                          ? (warmStyle
                                ? const Color(0xFFFFDC9A)
                                : raisedStyle
                                ? const Color(0xFFFFE3AE)
                                : CbColors.displayBlue)
                          : (warmStyle
                                ? const Color(0xFFFFE1B4)
                                : raisedStyle
                                ? const Color(0xFFF0DFC6)
                                : CbColors.text)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
