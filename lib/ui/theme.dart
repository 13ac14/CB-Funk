import 'package:flutter/material.dart';

class CbColors {
  static const bgTop = Color(0xFF2A2C30);
  static const bgBottom = Color(0xFF16171A);
  static const metal = Color(0xFF3A3D43);
  static const metalDark = Color(0xFF26282C);
  static const displayBg = Color(0xFF07131C);
  static const displayBlue = Color(0xFF7CC8FF); // helles Blau
  static const displayDim = Color(0xFF16303F);
  static const meterRed = Color(0xFFFF6B6B);    // helles Rot
  static const knobMark = Color(0xFFE53935);    // roter Markierungsstrich
  static const silverLight = Color(0xFFE9ECEF);
  static const silverDark = Color(0xFF8E959C);
  static const text = Color(0xFFD7DADF);
  static const textDim = Color(0xFF8A8F98);
  static const accentRed = Color(0xFFFF5252);
  static const online = Color(0xFF4CD964);
}

ThemeData buildTheme() => ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: CbColors.bgBottom,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFB9A8FF),
        surface: Color(0xFF26282C),
      ),
    );
