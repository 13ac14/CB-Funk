import 'dart:io';
import 'package:flutter/foundation.dart';
import '../config/app_config.dart';

/// Robustes Datei-Logging in `cb_funk_debug.log`.
/// Liegt direkt im Installationsverzeichnis der App und schreibt
/// jede Zeile sofort synchron per flush() auf Festplatte.
class AppLogger {
  AppLogger._();

  static RandomAccessFile? _raf;
  static String? _logPath;
  static bool _initialized = false;

  static String get logFilePath => _logPath ?? '';

  static void init() {
    if (_initialized) return;
    try {
      String dir;
      if (Platform.isWindows) {
        dir = File(Platform.resolvedExecutable).parent.path;
      } else {
        dir = Directory.current.path;
      }

      final candidatePath = '$dir${Platform.pathSeparator}cb_funk_debug.log';
      final file = File(candidatePath);

      try {
        _raf = file.openSync(mode: FileMode.append);
        _logPath = candidatePath;
        _initialized = true;
      } catch (e) {
        // Fallback falls Installationsverzeichnis keine Schreibrechte hat
        final fallbackDir = Directory.systemTemp.path;
        final fallbackPath =
            '$fallbackDir${Platform.pathSeparator}cb_funk_debug.log';
        final fallbackFile = File(fallbackPath);
        _raf = fallbackFile.openSync(mode: FileMode.append);
        _logPath = fallbackPath;
        _initialized = true;
      }

      info('APP', '==================================================');
      info('APP', 'CB-Funk Logging initialisiert');
      info('APP', 'Log-Datei: $_logPath');
      info('APP', 'App-Version: ${AppConfig.appName} v${AppConfig.appVersion}');
      info('APP', 'Plattform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} (PID: $pid)');
      info('APP', 'Programm-Pfad: ${Platform.resolvedExecutable}');
      info('APP', 'Arbeitsverzeichnis: ${Directory.current.path}');
      info('APP', '==================================================');
    } catch (e, st) {
      debugPrint('AppLogger init Fehler: $e\n$st');
    }
  }

  static void log(
    String level,
    String category,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final now = DateTime.now();
    final timeStr = formatTimestamp(now);
    final sb = StringBuffer('$timeStr [$level] [$category] $message');
    if (error != null) {
      sb.write(' | FEHLER: $error');
    }
    if (stackTrace != null) {
      sb.write('\n$stackTrace');
    }
    sb.writeln();
    final line = sb.toString();

    // In Debug-Konsole ausgeben
    if (kDebugMode) {
      stdout.write(line);
    }

    // Synchron und sofort per flushSync auf die Festplatte schreiben
    try {
      if (_raf != null) {
        _raf!.writeStringSync(line);
        _raf!.flushSync();
      } else if (_logPath != null) {
        appendRaw(_logPath!, line);
      }
    } catch (_) {
      // Protokollierungsfehler duerfen unter keinen Umstaenden die App zum Absturz bringen
    }
  }

  static void info(String category, String message) =>
      log('INFO', category, message);

  static void warn(String category, String message, [Object? error]) =>
      log('WARN', category, message, error);

  static void error(
    String category,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) =>
      log('ERROR', category, message, error, stackTrace);

  /// Synchrones Schreiben aus separaten Isolates direkt in die Log-Datei
  static void appendRaw(String path, String line) {
    try {
      final f = File(path);
      final raf = f.openSync(mode: FileMode.append);
      try {
        raf.writeStringSync(line);
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
    } catch (_) {}
  }

  static String formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$y-$m-$d $h:$min:$s.$ms';
  }

  static void close() {
    try {
      info('APP', 'CB-Funk wird ordnungsgemäß beendet');
      _raf?.flushSync();
      _raf?.closeSync();
      _raf = null;
      _initialized = false;
    } catch (_) {}
  }
}
