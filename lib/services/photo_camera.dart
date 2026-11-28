import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/widgets.dart';

/// Wo die Kamera sitzt. Unter Windows meldet das System das nicht zuverlaessig
/// (dort zaehlt der Geraetename); auf dem Handy kommen Vorder- und
/// Rueckkamera ueber diese Einteilung.
enum PhotoCameraFacing { front, back, external }

/// Eine verfuegbare Kamera.
class PhotoCameraInfo {
  const PhotoCameraInfo({
    required this.label,
    required this.facing,
    required this.description,
  });

  final String label;
  final PhotoCameraFacing facing;
  final CameraDescription description;

  String get id => description.name;
}

/// Kamera fuer Einzelfotos (SSTV), plattformunabhaengig ueber
/// `camera_platform_interface`.
///
/// Windows nutzt `camera_windows`. Fuer Android/iOS genuegt spaeter die
/// passende Implementierung (z. B. `camera_android_camerax`,
/// `camera_avfoundation`) in der pubspec; diese Klasse und der Kameradialog
/// bleiben gleich, Vorder-/Rueckkamera erscheinen dann ueber [facing].
class PhotoCamera {
  PhotoCamera({CameraPlatform? platform})
    : _platform = platform ?? CameraPlatform.instance;

  final CameraPlatform _platform;
  int? _cameraId;
  int _openToken = 0;

  /// Groesse des Vorschaubildes in Pixeln (nach dem Oeffnen).
  Size? previewSize;

  bool get isOpen => _cameraId != null;

  /// Verfuegbare Kameras mit lesbarer Bezeichnung.
  Future<List<PhotoCameraInfo>> availableCameras() async {
    final cameras = await _platform.availableCameras();
    var counter = 0;
    return <PhotoCameraInfo>[
      for (final camera in cameras)
        PhotoCameraInfo(
          label: labelFor(camera, ++counter),
          facing: _facing(camera),
          description: camera,
        ),
    ];
  }

  /// Bezeichnung fuer die Auswahl. Windows liefert "Anzeigename <Geraete-ID>".
  static String labelFor(CameraDescription camera, int number) {
    final name = camera.name;
    final idStart = name.lastIndexOf(' <');
    if (idStart > 0 && name.endsWith('>')) {
      return name.substring(0, idStart).trim();
    }
    if (Platform.isWindows && name.trim().isNotEmpty) return name.trim();
    return switch (camera.lensDirection) {
      CameraLensDirection.front => 'Vorderkamera',
      CameraLensDirection.back => 'Rückkamera',
      CameraLensDirection.external => 'Externe Kamera $number',
    };
  }

  static PhotoCameraFacing _facing(CameraDescription camera) {
    // camera_windows meldet immer "front"; dort ist die Lage unbekannt.
    if (Platform.isWindows) return PhotoCameraFacing.external;
    return switch (camera.lensDirection) {
      CameraLensDirection.front => PhotoCameraFacing.front,
      CameraLensDirection.back => PhotoCameraFacing.back,
      CameraLensDirection.external => PhotoCameraFacing.external,
    };
  }

  /// Oeffnet die Kamera (eine zuvor geoeffnete wird geschlossen).
  Future<void> open(PhotoCameraInfo camera) async {
    await close();
    final token = ++_openToken;
    final cameraId = await _platform.createCameraWithSettings(
      camera.description,
      const MediaSettings(
        resolutionPreset: ResolutionPreset.high,
        enableAudio: false,
      ),
    );
    try {
      final initialized = _platform.onCameraInitialized(cameraId).first;
      await _platform.initializeCamera(cameraId);
      final event = await initialized.timeout(const Duration(seconds: 10));
      if (token != _openToken) {
        // Waehrenddessen geschlossen oder andere Kamera gewaehlt
        await _platform.dispose(cameraId);
        return;
      }
      previewSize = Size(event.previewWidth, event.previewHeight);
      _cameraId = cameraId;
    } catch (_) {
      try {
        await _platform.dispose(cameraId);
      } catch (_) {}
      rethrow;
    }
  }

  /// Live-Vorschau der geoeffneten Kamera.
  Widget preview() {
    final cameraId = _cameraId;
    if (cameraId == null) return const SizedBox.shrink();
    return _platform.buildPreview(cameraId);
  }

  /// Nimmt ein Foto auf und liefert die Bilddatei (meist JPEG) als Bytes.
  Future<Uint8List> takePhoto() async {
    final cameraId = _cameraId;
    if (cameraId == null) throw StateError('Keine Kamera geöffnet');
    final file = await _platform.takePicture(cameraId);
    final bytes = await file.readAsBytes();
    // Unter Windows legt das Plugin das Foto im Ordner "Bilder" ab
    // (PhotoCapture_*.jpeg). Die App arbeitet mit einer eigenen Kopie.
    if (Platform.isWindows && file.path.isNotEmpty) {
      final name = file.path.split(RegExp(r'[\\/]')).last;
      if (name.startsWith('PhotoCapture_')) {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
    }
    return bytes;
  }

  Future<void> close() async {
    _openToken++;
    final cameraId = _cameraId;
    _cameraId = null;
    previewSize = null;
    if (cameraId != null) {
      try {
        await _platform.dispose(cameraId);
      } catch (_) {}
    }
  }

  /// Schneidet ein Foto mittig auf das Seitenverhaeltnis des SSTV-Bildes zu
  /// (Breite/Hoehe), damit beim Verkleinern nichts verzerrt wird. Liefert PNG.
  static Future<Uint8List> cropCenterToAspect(
    Uint8List encoded,
    double aspect,
  ) async {
    final codec = await ui.instantiateImageCodec(encoded);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final width = image.width.toDouble();
        final height = image.height.toDouble();
        var cropWidth = width;
        var cropHeight = width / aspect;
        if (cropHeight > height) {
          cropHeight = height;
          cropWidth = height * aspect;
        }
        final outWidth = cropWidth.round();
        final outHeight = cropHeight.round();
        final source = Rect.fromLTWH(
          ((width - outWidth) / 2).roundToDouble(),
          ((height - outHeight) / 2).roundToDouble(),
          outWidth.toDouble(),
          outHeight.toDouble(),
        );
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawImageRect(
          image,
          source,
          Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.none,
        );
        final picture = recorder.endRecording();
        try {
          final cropped = await picture.toImage(outWidth, outHeight);
          try {
            final data = await cropped.toByteData(
              format: ui.ImageByteFormat.png,
            );
            if (data == null) {
              throw StateError('Foto konnte nicht zugeschnitten werden');
            }
            return data.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
          } finally {
            cropped.dispose();
          }
        } finally {
          picture.dispose();
        }
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
