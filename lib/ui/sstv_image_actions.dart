import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../platform/win_clipboard_image.dart';
import '../services/app_logger.dart';
import '../services/jpeg_encoder.dart';

const Color _panel = Color(0xFF21150F);
const Color _panelLight = Color(0xFF352116);
const Color _text = Color(0xFFFFE1B4);
const Color _textDim = Color(0xFFBAA084);
const Color _accent = Color(0xFFFFC666);
const Color _border = Color(0xFF9B7048);

/// Liefert das Bild als PNG (Datei, geladenes Bild oder Live-Empfang).
typedef SstvPngLoader = Future<Uint8List> Function();

/// SSTV-Bild mit komfortabler Bedienung (nur Windows):
/// Klick/Doppelklick vergroessert, Rechtsklick oeffnet ein Menue zum
/// Vergroessern, Kopieren und Speichern als PNG/JPG.
class SstvImageActions extends StatelessWidget {
  const SstvImageActions({
    super.key,
    required this.child,
    required this.loadPng,
    required this.title,
    this.suggestedName,
  });

  final Widget child;
  final SstvPngLoader loadPng;
  final String title;
  final String? suggestedName;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.zoomIn,
    child: Tooltip(
      message: 'Klicken: vergrößern · Rechtsklick: kopieren/speichern',
      waitDuration: const Duration(milliseconds: 900),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_enlarge(context)),
        onDoubleTap: () => unawaited(_enlarge(context)),
        onSecondaryTapDown: (details) =>
            unawaited(_contextMenu(context, details.globalPosition)),
        child: child,
      ),
    ),
  );

  Future<void> _enlarge(BuildContext context) async {
    final png = await _load(context);
    if (png == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _SstvEnlargedDialog(
        png: png,
        title: title,
        suggestedName: suggestedName,
      ),
    );
  }

  Future<void> _contextMenu(BuildContext context, Offset globalPosition) async {
    final action = await _showImageMenu(
      context,
      globalPosition,
      withEnlarge: true,
    );
    if (action == null || !context.mounted) return;
    if (action == _ImageAction.enlarge) {
      await _enlarge(context);
      return;
    }
    final png = await _load(context);
    if (png == null || !context.mounted) return;
    final message = await _runAction(context, action, png, suggestedName);
    if (message != null && context.mounted) _snack(context, message);
  }

  Future<Uint8List?> _load(BuildContext context) async {
    try {
      return await loadPng();
    } catch (error, stack) {
      AppLogger.error('SSTV', 'Bild konnte nicht geladen werden', error, stack);
      if (context.mounted) _snack(context, 'Bild nicht verfügbar: $error');
      return null;
    }
  }
}

enum _ImageAction { enlarge, copy, save }

Future<_ImageAction?> _showImageMenu(
  BuildContext context,
  Offset globalPosition, {
  required bool withEnlarge,
}) {
  // Die Oberflaeche ist skaliert (DesktopCanvas): Position in Koordinaten
  // des Overlays umrechnen, damit das Menue am Mauszeiger erscheint.
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(globalPosition);
  PopupMenuItem<_ImageAction> item(
    _ImageAction value,
    IconData icon,
    String label,
  ) => PopupMenuItem<_ImageAction>(
    value: value,
    height: 36,
    child: Row(
      children: [
        Icon(icon, size: 17, color: _accent),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: _text, fontSize: 13)),
      ],
    ),
  );
  return showMenu<_ImageAction>(
    context: context,
    color: _panelLight,
    position: RelativeRect.fromRect(
      local & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      if (withEnlarge) item(_ImageAction.enlarge, Icons.zoom_in, 'Vergrößern'),
      item(_ImageAction.copy, Icons.copy, 'Bild kopieren'),
      item(_ImageAction.save, Icons.save_alt, 'Speichern unter …'),
    ],
  );
}

/// Fuehrt Kopieren/Speichern aus und liefert die Meldung fuer den Nutzer.
Future<String?> _runAction(
  BuildContext context,
  _ImageAction action,
  Uint8List png,
  String? suggestedName,
) async {
  try {
    switch (action) {
      case _ImageAction.enlarge:
        return null;
      case _ImageAction.copy:
        final (width, height, rgba) = await decodeSstvPng(png);
        await copyImageToWindowsClipboard(
          rgba: rgba,
          width: width,
          height: height,
          png: png,
        );
        return 'Bild in die Zwischenablage kopiert';
      case _ImageAction.save:
        final target = await showDialog<_SaveTarget>(
          context: context,
          builder: (_) => _SstvSaveDialog(suggestedName: suggestedName),
        );
        if (target == null) return null;
        await writeSstvImageFile(png, target.file, jpeg: target.jpeg);
        return 'Gespeichert: ${target.file.path}';
    }
  } catch (error, stack) {
    AppLogger.error('SSTV', 'Bildaktion fehlgeschlagen', error, stack);
    return action == _ImageAction.copy
        ? 'Kopieren fehlgeschlagen: $error'
        : 'Speichern fehlgeschlagen: $error';
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        width: 520,
      ),
    );
}

/// PNG -> (Breite, Hoehe, RGBA).
Future<(int, int, Uint8List)> decodeSstvPng(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw StateError('Bild konnte nicht gelesen werden');
      return (
        image.width,
        image.height,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// Schreibt das Bild als PNG (unveraendert) oder JPG (Qualitaet 92).
Future<void> writeSstvImageFile(
  Uint8List png,
  File file, {
  required bool jpeg,
}) async {
  Uint8List bytes = png;
  if (jpeg) {
    final (width, height, rgba) = await decodeSstvPng(png);
    // Kodieren ausserhalb des UI-Isolates (Audio-Takt laeuft dort)
    bytes = await Isolate.run(() => JpegEncoder.encode(rgba, width, height));
  }
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
}

/// Vergroesserte Ansicht mit Zoom (Mausrad) und Kopieren/Speichern.
class _SstvEnlargedDialog extends StatefulWidget {
  const _SstvEnlargedDialog({
    required this.png,
    required this.title,
    this.suggestedName,
  });

  final Uint8List png;
  final String title;
  final String? suggestedName;

  @override
  State<_SstvEnlargedDialog> createState() => _SstvEnlargedDialogState();
}

class _SstvEnlargedDialogState extends State<_SstvEnlargedDialog> {
  String? _message;

  Future<void> _run(_ImageAction action) async {
    final message = await _runAction(
      context,
      action,
      widget.png,
      widget.suggestedName,
    );
    if (mounted && message != null) setState(() => _message = message);
  }

  Future<void> _menu(Offset globalPosition) async {
    final action = await _showImageMenu(
      context,
      globalPosition,
      withEnlarge: false,
    );
    if (action != null) await _run(action);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: _panel,
    insetPadding: const EdgeInsets.all(24),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: Color(0xFFC18A53), width: 2),
    ),
    child: SizedBox(
      width: 900,
      height: 680,
      child: Column(
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF51301D),
              borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                const Icon(Icons.image_outlined, color: _accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => unawaited(_run(_ImageAction.copy)),
                  icon: const Icon(Icons.copy, size: 16, color: _accent),
                  label: const Text('Kopieren', style: TextStyle(color: _text)),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: () => unawaited(_run(_ImageAction.save)),
                  icon: const Icon(Icons.save_alt, size: 16, color: _accent),
                  label: const Text(
                    'Speichern unter …',
                    style: TextStyle(color: _text),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Schließen (Esc)',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: _accent),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              color: const Color(0xFF100C09),
              child: GestureDetector(
                onSecondaryTapDown: (details) =>
                    unawaited(_menu(details.globalPosition)),
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 6,
                  child: Center(
                    child: Image.memory(
                      widget.png,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(
              _message ??
                  'Mausrad/Ziehen: zoomen und verschieben · Rechtsklick: '
                      'kopieren oder speichern',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _message == null ? _textDim : _accent,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SaveTarget {
  const _SaveTarget(this.file, {required this.jpeg});
  final File file;
  final bool jpeg;
}

/// "Speichern unter" innerhalb der App (wie die Bildauswahl beim Laden):
/// ein nativer Windows-Dialog wuerde den UI-Thread und damit den
/// Audio-Takt blockieren.
class _SstvSaveDialog extends StatefulWidget {
  const _SstvSaveDialog({this.suggestedName});

  final String? suggestedName;

  @override
  State<_SstvSaveDialog> createState() => _SstvSaveDialogState();
}

class _SstvSaveDialogState extends State<_SstvSaveDialog> {
  /// Zuletzt gewaehlter Ordner (fuer die laufende Sitzung)
  static String? _lastDirectory;

  late Directory _directory;
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  List<Directory> _folders = const <Directory>[];
  bool _jpeg = false;
  bool _loading = true;
  bool _confirmOverwrite = false;
  String? _error;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['USERPROFILE'];
    final start =
        _lastDirectory ??
        (home == null ? Directory.current.path : '$home\\Pictures');
    _directory = Directory(start);
    _pathController.text = start;
    _nameController.text = sstvSuggestedBaseName(widget.suggestedName);
    unawaited(_load(start, fallback: home ?? Directory.current.path));
  }

  @override
  void dispose() {
    _pathController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _load(String path, {String? fallback}) async {
    final request = ++_loadRequest;
    final target = Directory(path.trim().replaceAll('"', ''));
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await target
          .list(followLinks: false)
          .where((entry) => entry is Directory)
          .cast<Directory>()
          .toList();
      entries.sort(
        (a, b) =>
            _name(a.path).toLowerCase().compareTo(_name(b.path).toLowerCase()),
      );
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _directory = target;
        _pathController.text = target.path;
        _folders = entries;
        _confirmOverwrite = false;
      });
    } catch (error) {
      if (!mounted || request != _loadRequest) return;
      if (fallback != null) {
        unawaited(_load(fallback));
        return;
      }
      setState(() {
        _folders = const <Directory>[];
        _error = 'Ordner konnte nicht gelesen werden: $error';
      });
    } finally {
      if (mounted && request == _loadRequest) {
        setState(() => _loading = false);
      }
    }
  }

  static String _name(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  File _targetFile() {
    final base = sstvSafeFileName(_nameController.text);
    final extension = _jpeg ? '.jpg' : '.png';
    return File('${_directory.path}${Platform.pathSeparator}$base$extension');
  }

  Future<void> _save() async {
    final base = sstvSafeFileName(_nameController.text);
    if (base.isEmpty) {
      setState(() => _error = 'Bitte einen Dateinamen eingeben');
      return;
    }
    final file = _targetFile();
    if (!_confirmOverwrite && await file.exists()) {
      if (!mounted) return;
      setState(() {
        _confirmOverwrite = true;
        _error = 'Die Datei gibt es schon. Nochmal klicken zum Überschreiben.';
      });
      return;
    }
    _lastDirectory = _directory.path;
    if (mounted) Navigator.of(context).pop(_SaveTarget(file, jpeg: _jpeg));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: _panel,
    title: const Text(
      'SSTV-Bild speichern',
      style: TextStyle(color: _text, fontSize: 17),
    ),
    content: SizedBox(
      width: 540,
      height: 380,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Übergeordneten Ordner öffnen',
                onPressed: _directory.parent.path == _directory.path
                    ? null
                    : () => unawaited(_load(_directory.parent.path)),
                icon: const Icon(Icons.arrow_upward),
                color: _accent,
              ),
              Expanded(
                child: TextField(
                  controller: _pathController,
                  onSubmitted: (path) => unawaited(_load(path)),
                  style: const TextStyle(color: _text, fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Ordnerpfad',
                    hintStyle: TextStyle(color: _textDim),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: _border),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: _accent),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Ordner öffnen',
                onPressed: _loading
                    ? null
                    : () => unawaited(_load(_pathController.text)),
                icon: const Icon(Icons.folder_open),
                color: _accent,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _accent))
                : _folders.isEmpty
                ? const Center(
                    child: Text(
                      'Keine Unterordner – hier wird gespeichert',
                      style: TextStyle(color: _textDim, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: _folders.length,
                    itemBuilder: (context, index) {
                      final folder = _folders[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.folder_outlined,
                          color: _accent,
                        ),
                        title: Text(
                          _name(folder.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: _text, fontSize: 12),
                        ),
                        onTap: () => unawaited(_load(folder.path)),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameController,
                  autofocus: true,
                  onChanged: (_) => setState(() {
                    _confirmOverwrite = false;
                    _error = null;
                  }),
                  onSubmitted: (_) => unawaited(_save()),
                  style: const TextStyle(color: _text, fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Dateiname',
                    labelStyle: TextStyle(color: _textDim),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: _border),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: _accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<bool>(
                value: _jpeg,
                dropdownColor: _panelLight,
                style: const TextStyle(color: _text, fontSize: 13),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(
                    value: false,
                    child: Text('PNG (verlustfrei)'),
                  ),
                  DropdownMenuItem(value: true, child: Text('JPG')),
                ],
                onChanged: (value) => setState(() {
                  _jpeg = value ?? false;
                  _confirmOverwrite = false;
                  _error = null;
                }),
              ),
            ],
          ),
          SizedBox(
            height: 18,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFFF8C78), fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen', style: TextStyle(color: _textDim)),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF8A5A2E),
          foregroundColor: _text,
        ),
        onPressed: _loading ? null : () => unawaited(_save()),
        child: Text(_confirmOverwrite ? 'Überschreiben' : 'Speichern'),
      ),
    ],
  );
}

/// Dateiname ohne unter Windows unzulaessige Zeichen und ohne Endung.
String sstvSafeFileName(String input) {
  var name = input.trim();
  final lower = name.toLowerCase();
  for (final extension in const ['.png', '.jpg', '.jpeg']) {
    if (lower.endsWith(extension)) {
      name = name.substring(0, name.length - extension.length);
      break;
    }
  }
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  return name.replaceAll(RegExp(r'[. ]+$'), '');
}

/// Vorschlag fuer den Dateinamen: Name der gespeicherten Datei oder
/// "sstv_JJJJ-MM-TT_HH-MM-SS".
String sstvSuggestedBaseName(String? suggestion, {DateTime? now}) {
  if (suggestion != null && suggestion.trim().isNotEmpty) {
    final safe = sstvSafeFileName(suggestion);
    if (safe.isNotEmpty) return safe;
  }
  final t = now ?? DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'sstv_${t.year}-${two(t.month)}-${two(t.day)}_'
      '${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
}
