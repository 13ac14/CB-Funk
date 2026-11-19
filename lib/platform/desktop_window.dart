import 'dart:io';

import 'package:flutter/services.dart';

import '../services/app_logger.dart';

/// Steuerung des randlosen Windows-Fensters.
///
/// Gegenstueck ist der Kanal "de.cbfunk/window" in
/// windows/runner/flutter_window.cpp. Verschieben uebernimmt Windows selbst
/// (wie beim Ziehen an einer normalen Titelleiste).
class DesktopWindow {
  DesktopWindow._();

  static const MethodChannel _channel = MethodChannel('de.cbfunk/window');

  static bool get supported => Platform.isWindows;

  static Future<void> _call(String method) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      AppLogger.warn('WINDOW', 'Fensterbefehl "$method" fehlgeschlagen: $e');
    }
  }

  /// Beim Druecken in der Ziehleiste aufrufen.
  static Future<void> startDrag() => _call('startDrag');

  static Future<void> minimize() => _call('minimize');

  static Future<void> close() => _call('close');
}
