import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../services/photo_camera.dart';

const Color _panel = Color(0xFF21150F);
const Color _panelLight = Color(0xFF352116);
const Color _text = Color(0xFFFFE1B4);
const Color _textDim = Color(0xFFBAA084);
const Color _accent = Color(0xFFFFC666);
const Color _error = Color(0xFFFF8C78);

/// Foto fuer SSTV ueber eine Kamera aufnehmen.
///
/// Liefert eine PNG-Datei, die mittig auf das Seitenverhaeltnis des SSTV-
/// Bildes ([aspect] = Breite/Hoehe) zugeschnitten ist. Sie wird wie ein
/// geladenes Bild weiterverarbeitet (Rufzeichen/Uhrzeit beim Senden).
class SstvCameraDialog extends StatefulWidget {
  const SstvCameraDialog({super.key, required this.aspect, this.camera});

  final double aspect;

  /// Fuer Tests austauschbar
  final PhotoCamera? camera;

  @override
  State<SstvCameraDialog> createState() => _SstvCameraDialogState();
}

enum _Phase { loading, live, capturing, captured, failed }

class _SstvCameraDialogState extends State<SstvCameraDialog> {
  /// Zuletzt gewaehlte Kamera (fuer die laufende Sitzung)
  static String? _lastCameraId;

  late final PhotoCamera _camera = widget.camera ?? PhotoCamera();
  List<PhotoCameraInfo> _cameras = const <PhotoCameraInfo>[];
  PhotoCameraInfo? _selected;
  _Phase _phase = _Phase.loading;
  String? _message;
  Uint8List? _photo;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_camera.close());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final cameras = await _camera.availableCameras();
      if (_closed) return;
      if (cameras.isEmpty) {
        setState(() {
          _phase = _Phase.failed;
          _message = 'Keine Kamera gefunden';
        });
        return;
      }
      final remembered = cameras.where((c) => c.id == _lastCameraId);
      setState(() {
        _cameras = cameras;
        _selected = remembered.isEmpty ? cameras.first : remembered.first;
      });
      await _open(_selected!);
    } catch (error, stack) {
      AppLogger.error('KAMERA', 'Kameras nicht abrufbar', error, stack);
      if (!_closed) {
        setState(() {
          _phase = _Phase.failed;
          _message = 'Kameras konnten nicht abgefragt werden: $error';
        });
      }
    }
  }

  Future<void> _open(PhotoCameraInfo camera) async {
    setState(() {
      _phase = _Phase.loading;
      _message = null;
      _photo = null;
    });
    try {
      await _camera.open(camera);
      if (_closed) return;
      _lastCameraId = camera.id;
      setState(() => _phase = _Phase.live);
    } catch (error, stack) {
      AppLogger.error(
        'KAMERA',
        'Kamera "${camera.label}" startet nicht',
        error,
        stack,
      );
      if (!_closed) {
        setState(() {
          _phase = _Phase.failed;
          _message =
              'Kamera konnte nicht gestartet werden ($error). Ist sie von '
              'einem anderen Programm belegt oder unter Windows-Einstellungen '
              '› Datenschutz › Kamera gesperrt?';
        });
      }
    }
  }

  Future<void> _capture() async {
    setState(() => _phase = _Phase.capturing);
    try {
      final raw = await _camera.takePhoto();
      final cropped = await PhotoCamera.cropCenterToAspect(raw, widget.aspect);
      if (_closed) return;
      setState(() {
        _photo = cropped;
        _phase = _Phase.captured;
      });
    } catch (error, stack) {
      AppLogger.error('KAMERA', 'Foto fehlgeschlagen', error, stack);
      if (!_closed) {
        setState(() {
          _phase = _Phase.live;
          _message = 'Foto fehlgeschlagen: $error';
        });
      }
    }
  }

  Future<void> _accept() async {
    final photo = _photo;
    if (photo == null) return;
    try {
      final file = await saveCameraPhoto(photo);
      if (mounted) Navigator.of(context).pop(file);
    } catch (error) {
      if (mounted) setState(() => _message = 'Foto nicht speicherbar: $error');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: _panel,
    title: Row(
      children: [
        const Icon(Icons.photo_camera_outlined, color: _accent, size: 20),
        const SizedBox(width: 8),
        const Text(
          'SSTV-Foto aufnehmen',
          style: TextStyle(color: _text, fontSize: 17),
        ),
        const Spacer(),
        if (_cameras.length > 1)
          DropdownButton<String>(
            value: _selected?.id,
            dropdownColor: _panelLight,
            style: const TextStyle(color: _text, fontSize: 12),
            underline: const SizedBox.shrink(),
            items: [
              for (final camera in _cameras)
                DropdownMenuItem(value: camera.id, child: Text(camera.label)),
            ],
            onChanged: _phase == _Phase.loading || _phase == _Phase.capturing
                ? null
                : (id) {
                    final camera = _cameras.firstWhere((c) => c.id == id);
                    setState(() => _selected = camera);
                    unawaited(_open(camera));
                  },
          )
        else if (_selected != null)
          Text(
            _selected!.label,
            style: const TextStyle(color: _textDim, fontSize: 12),
          ),
      ],
    ),
    content: SizedBox(
      width: 600,
      height: 400,
      child: Column(
        children: [
          Expanded(
            child: Container(
              color: const Color(0xFF100C09),
              alignment: Alignment.center,
              child: _body(),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _message ??
                    (_phase == _Phase.captured
                        ? 'Übernehmen: Rufzeichen und Uhrzeit kommen beim Senden dazu'
                        : 'Der helle Rahmen zeigt den Bildausschnitt für SSTV'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _message == null ? _textDim : _error,
                  fontSize: 11,
                ),
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
      if (_phase == _Phase.captured) ...[
        TextButton(
          onPressed: () => setState(() {
            _photo = null;
            _message = null;
            _phase = _Phase.live;
          }),
          child: const Text('Neu aufnehmen', style: TextStyle(color: _text)),
        ),
        FilledButton(
          style: _filled,
          onPressed: () => unawaited(_accept()),
          child: const Text('Übernehmen'),
        ),
      ] else
        FilledButton.icon(
          style: _filled,
          onPressed: _phase == _Phase.live ? () => unawaited(_capture()) : null,
          icon: const Icon(Icons.camera, size: 18),
          label: const Text('Foto aufnehmen'),
        ),
    ],
  );

  static final ButtonStyle _filled = FilledButton.styleFrom(
    backgroundColor: const Color(0xFF8A5A2E),
    foregroundColor: _text,
  );

  Widget _body() {
    switch (_phase) {
      case _Phase.loading:
        return const CircularProgressIndicator(color: _accent);
      case _Phase.failed:
        return const Icon(
          Icons.no_photography_outlined,
          color: _textDim,
          size: 48,
        );
      case _Phase.captured:
        return AspectRatio(
          aspectRatio: widget.aspect,
          child: Image.memory(_photo!, fit: BoxFit.contain),
        );
      case _Phase.live:
      case _Phase.capturing:
        final size = _camera.previewSize;
        final aspect = size == null || size.height == 0
            ? 4 / 3
            : size.width / size.height;
        return AspectRatio(
          aspectRatio: aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _camera.preview(),
              CustomPaint(
                painter: _CropFramePainter(
                  previewAspect: aspect,
                  targetAspect: widget.aspect,
                ),
              ),
              if (_phase == _Phase.capturing)
                const Center(child: CircularProgressIndicator(color: _accent)),
            ],
          ),
        );
    }
  }
}

/// Dunkelt den Bereich ausserhalb des SSTV-Ausschnitts ab.
class _CropFramePainter extends CustomPainter {
  const _CropFramePainter({
    required this.previewAspect,
    required this.targetAspect,
  });

  final double previewAspect;
  final double targetAspect;

  @override
  void paint(Canvas canvas, Size size) {
    var width = size.width;
    var height = width / targetAspect;
    if (height > size.height) {
      height = size.height;
      width = height * targetAspect;
    }
    final frame = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
    final shade = Paint()..color = const Color(0x99000000);
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(outside, shade);
    canvas.drawRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xCCFFE1B4),
    );
  }

  @override
  bool shouldRepaint(_CropFramePainter oldDelegate) =>
      oldDelegate.previewAspect != previewAspect ||
      oldDelegate.targetAspect != targetAspect;
}

/// Legt das Foto als PNG im temporaeren Ordner der App ab (aeltere
/// Kamerafotos dort werden entfernt) und liefert die Datei.
Future<File> saveCameraPhoto(Uint8List png, {Directory? folder}) async {
  final directory =
      folder ??
      Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}cbfunk_camera',
      );
  await directory.create(recursive: true);
  await for (final entity in directory.list()) {
    if (entity is File && entity.path.toLowerCase().endsWith('.png')) {
      try {
        await entity.delete();
      } catch (_) {}
    }
  }
  final t = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  final name =
      'kamera_${t.year}-${two(t.month)}-${two(t.day)}_'
      '${two(t.hour)}-${two(t.minute)}-${two(t.second)}.png';
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(png, flush: true);
  return file;
}
