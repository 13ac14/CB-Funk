import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
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
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }

    if (defaultTargetPlatform == TargetPlatform.windows) {
      AppLogger.info('SYSTEM', 'Initialisiere Windows WindowManager');
      await windowManager.ensureInitialized();
      const windowOptions = WindowOptions(
        size: Size(1280, 720),
        minimumSize: Size(1280, 720),
        maximumSize: Size(1280, 720),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        try {
          await windowManager.setResizable(false);
          await windowManager.setMinimizable(false);
          await windowManager.setMaximizable(false);
          await windowManager.show();
          await windowManager.focus();
          AppLogger.info('SYSTEM', 'Windows-Fenster erfolgreich initialisiert und angezeigt');
        } catch (e, st) {
          AppLogger.error('SYSTEM', 'Fehler beim Konfigurieren des Windows-Fensters', e, st);
        }
      });
      // Sicherheits-Timer: Nach 800ms sicherstellen, dass das Fenster angezeigt wird
      Future.delayed(const Duration(milliseconds: 800), () async {
        try {
          if (!await windowManager.isVisible()) {
            await windowManager.show();
            await windowManager.focus();
            AppLogger.info('SYSTEM', 'Windows-Fenster über Sicherheits-Timer forciert angezeigt');
          }
        } catch (e) {
          AppLogger.warn('SYSTEM', 'Sicherheits-Timer windowManager.show fehlgeschlagen: $e');
        }
      });
    }

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
        home: const RadioScreen(),
      ),
    );
  }
}
