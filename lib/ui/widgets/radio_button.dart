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
  });

  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? textColor;
  final double height;
  final double fontSize;

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
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [CbColors.metal, CbColors.metalDark],
            ),
            border: Border.all(
                color: active ? CbColors.displayBlue : Colors.black54,
                width: 1.4),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            // Einzeilig; bei grosser Handyschrift lieber etwas kleiner als umbrechen
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: fontSize,
                      letterSpacing: 0.5,
                      color: textColor ??
                          (active ? CbColors.displayBlue : CbColors.text))),
            ),
          ),
        ),
      ),
    );
  }
}
