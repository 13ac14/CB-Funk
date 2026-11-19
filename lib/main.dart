import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'services/app_logger.dart';
import 'services/mqtt_service.dart';
import 'state/radio_controller.dart';
import 'ui/nav.dart';
import 'ui/radio_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    AppLogger.init();

    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      AppLogger.error(
        'FLUTTER',
        'Ungefangener Flutter-UI-Fehler: ${details.exceptionAsString()}',
        details.exception,
        details.stack,
      );
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      AppLogger.error('PLATFORM', 'Ungefangener Plattform-Fehler: $error', error, stack);
      return true; // Verhindert unkontrollierten Absturz
    };

    if (defaultTargetPlatform == TargetPlatform.android) {
      AppLogger.info('SYSTEM', 'Konfiguriere Android Orientierung (Portrait)');
      try {
        await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      } catch (e) {
        AppLogger.warn('SYSTEM', 'Orientierung konnte nicht gesetzt werden: $e');
      }
    }

    // Windows: Das Fenster legt der native Runner an (windows/runner) und
    // zeigt es, sobald das erste Bild gezeichnet ist. Hier ist nichts zu tun.
    AppLogger.info('APP', 'Starte CbFunkApp UI');
    runApp(const CbFunkApp());
  }, (Object error, StackTrace stack) {
    AppLogger.error('GLOBAL', 'Ungefangene Zone-Ausnahme abgefangen: $error', error, stack);
  });
}

class CbFunkApp extends StatelessWidget {
  const CbFunkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => MqttService()),
        ChangeNotifierProvider<RadioController>(
          create: (c) {
            final r = RadioController(c.read<MqttService>());
            r.onOpenMenu = () {
              final c = appNavigatorKey.currentState?.overlay?.context;
              if (c != null && !r.dialogOpen) showSettings(c);
            };
            try {
              r.mqtt.connect();
              r.mqtt.joinChannel(r.channel);
            } catch (e, st) {
              AppLogger.error('APP', 'Fehler beim Starten der MQTT-Verbindung: $e', e, st);
            }
            try {
              r.audio.init(); // Lautsprecher-Stream + Empfangs-Loop starten
            } catch (e, st) {
              AppLogger.error('APP', 'Fehler beim Starten der Audio-Engine: $e', e, st);
            }
            try {
              r.loadSettings(); // gespeicherte Einstellungen laden
            } catch (e, st) {
              AppLogger.error('APP', 'Fehler beim Laden der Einstellungen: $e', e, st);
            }
            return r;
          },
        ),
      ],
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        title: 'CB-Funk',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        builder: (context, child) => Platform.isWindows
            ? DesktopCanvas(child: child ?? const SizedBox.shrink())
            : (child ?? const SizedBox.shrink()),
        home: const RadioScreen(),
      ),
    );
  }
}

/// Windows: Die Oberflaeche wird immer auf einer festen 1280x720-Leinwand
/// gezeichnet und gleichmaessig auf die Fenstergroesse skaliert. So passt sie
/// auch auf kleine Bildschirme bzw. bei 125-175 % Windows-Skalierung, ohne
/// dass Teile abgeschnitten werden oder das Layout ueberlaeuft.
class DesktopCanvas extends StatelessWidget {
  const DesktopCanvas({super.key, required this.child});

  /// Normal 1280x720. Nur zum Testen am PC laesst sich per
  /// --dart-define=PREVIEW_SIZE=393x852 eine Handy-Groesse simulieren.
  static final Size designSize = _previewSize() ?? const Size(1280, 720);

  /// Nur zum Testen: --dart-define=PREVIEW_TEXT_SCALE=1.3 (grosse Handy-Schrift)
  static final double? _previewTextScale =
      double.tryParse(const String.fromEnvironment('PREVIEW_TEXT_SCALE'));

  static Size? _previewSize() {
    const raw = String.fromEnvironment('PREVIEW_SIZE');
    final parts = raw.split('x');
    if (parts.length != 2) return null;
    final w = double.tryParse(parts[0]);
    final h = double.tryParse(parts[1]);
    return (w == null || h == null) ? null : Size(w, h);
  }
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ColoredBox(
      color: CbColors.bgBottom,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox.fromSize(
          size: designSize,
          child: MediaQuery(
            data: media.copyWith(
              size: designSize,
              textScaler: _previewTextScale == null
                  ? media.textScaler
                  : TextScaler.linear(_previewTextScale!),
              padding: EdgeInsets.zero,
              viewPadding: EdgeInsets.zero,
              viewInsets: EdgeInsets.zero,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
