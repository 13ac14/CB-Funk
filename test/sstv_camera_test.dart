import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cb_funk/services/mqtt_service.dart';
import 'package:cb_funk/services/photo_camera.dart';
import 'package:cb_funk/state/radio_controller.dart';
import 'package:cb_funk/ui/sstv_camera_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Roger-Piep', () {
    setUpAll(() {
      // Mikrofon-Plugin gibt es in der Testumgebung nicht
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (call) async => call.method == 'isRecording' ? false : null,
          );
    });

    // Kein dispose(): RadioController.dispose() benachrichtigt unter Windows
    // nachlaufend (bestehendes Verhalten, in der App nur beim Beenden).
    Future<RadioController> radioWith(Map<String, Object> stored) async {
      SharedPreferences.setMockInitialValues(stored);
      final radio = RadioController(MqttService());
      await radio.loadSettings();
      return radio;
    }

    test('ist bei frischer Installation aus', () async {
      final radio = await radioWith(<String, Object>{});
      expect(radio.beepMode, 0);
      expect(radio.beep, isFalse);
    });

    test(
      'gespeicherte Wahl bleibt erhalten und alle Varianten wählbar',
      () async {
        final radio = await radioWith(<String, Object>{'beepMode': 3});
        expect(radio.beepMode, 3);
        for (var mode = 0; mode <= 5; mode++) {
          radio.setBeepMode(mode);
          expect(radio.beepMode, mode);
        }
      },
    );
  });

  group('Kamera', () {
    test('Windows-Gerätenamen werden lesbar, Handy-Kameras nach Lage', () {
      CameraDescription camera(String name, CameraLensDirection direction) =>
          CameraDescription(
            name: name,
            lensDirection: direction,
            sensorOrientation: 0,
          );
      expect(
        PhotoCamera.labelFor(
          camera(
            r'Integrated Webcam <\\?\usb#vid_0c45&pid_6a10#{65e8773d}>',
            CameraLensDirection.front,
          ),
          1,
        ),
        'Integrated Webcam',
      );
      expect(
        PhotoCamera.labelFor(camera('', CameraLensDirection.back), 2),
        'Rückkamera',
      );
      expect(
        PhotoCamera.labelFor(camera('', CameraLensDirection.front), 1),
        'Vorderkamera',
      );
    });

    test('Öffnen, Foto, Schließen; Zwischendatei wird entfernt', () async {
      final fake = await _FakeCameraPlatform.create();
      final camera = PhotoCamera(platform: fake);
      final cameras = await camera.availableCameras();
      expect(cameras.map((c) => c.label), ['Integrated Webcam', 'USB Kamera']);

      await camera.open(cameras[1]);
      expect(camera.isOpen, isTrue);
      expect(camera.previewSize, const Size(640, 360));
      expect(fake.created, [cameras[1].id]);

      final photo = await camera.takePhoto();
      expect(photo, fake.jpeg);
      expect(await File(fake.lastPicturePath!).exists(), isFalse);

      // Kamerawechsel schliesst die vorige
      await camera.open(cameras[0]);
      expect(fake.disposed, [1]);
      await camera.close();
      expect(fake.disposed, [1, 2]);
      expect(camera.isOpen, isFalse);
      await fake.cleanUp();
    });

    test(
      'Foto wird mittig auf das SSTV-Seitenverhältnis zugeschnitten',
      () async {
        // 640 x 360: links rot, Mitte gruen, rechts blau
        final png = await _png(_bands(640, 360), 640, 360);
        final cropped = await PhotoCamera.cropCenterToAspect(png, 320 / 256);
        final (w, h, rgba) = await _decode(cropped);
        expect((w, h), (450, 360));
        // Mitte bleibt gruen, Raender stammen aus dem mittleren Bereich
        int green(int x, int y) => rgba[(y * w + x) * 4 + 1];
        expect(green(w ~/ 2, h ~/ 2), 255);
        // 450 von 640: links fehlen 95 px -> Spalte 0 = Quellspalte 95 (rot)
        expect(rgba[(180 * w) * 4], 255);
      },
    );

    test('Kamerafoto wird als PNG abgelegt, ältere entfernt', () async {
      final folder = await Directory.systemTemp.createTemp('cbfunk_cam_');
      try {
        final first = await saveCameraPhoto(
          Uint8List.fromList([1, 2, 3]),
          folder: folder,
        );
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final second = await saveCameraPhoto(
          Uint8List.fromList([4, 5]),
          folder: folder,
        );
        expect(await first.exists(), isFalse);
        expect(await second.readAsBytes(), [4, 5]);
        expect(second.path, endsWith('.png'));
      } finally {
        await folder.delete(recursive: true);
      }
    });

    testWidgets('Dialog: Kamera wählen, Foto aufnehmen, übernehmen', (
      tester,
    ) async {
      final fake = (await tester.runAsync(_FakeCameraPlatform.create))!;
      File? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<File>(
                  context: context,
                  builder: (_) => SstvCameraDialog(
                    aspect: 320 / 256,
                    camera: PhotoCamera(platform: fake),
                  ),
                );
              },
              child: const Text('öffnen'),
            ),
          ),
        ),
      );
      Future<void> pumpUntil(bool Function() done) async {
        for (var i = 0; i < 60 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      await tester.tap(find.text('öffnen'));
      final preview = find.byKey(const ValueKey('fake-preview'));
      await pumpUntil(() => preview.evaluate().isNotEmpty);
      expect(find.text('SSTV-Foto aufnehmen'), findsOneWidget);
      expect(find.text('Foto aufnehmen'), findsOneWidget);
      expect(preview, findsOneWidget);

      await tester.tap(find.text('Foto aufnehmen'));
      await pumpUntil(() => find.text('Übernehmen').evaluate().isNotEmpty);
      expect(find.text('Übernehmen'), findsOneWidget);
      expect(find.text('Neu aufnehmen'), findsOneWidget);

      await tester.tap(find.text('Übernehmen'));
      await pumpUntil(() => result != null);
      expect(result, isNotNull);
      final (w, h, _) = (await tester.runAsync(
        () async => _decode(await result!.readAsBytes()),
      ))!;
      expect((w, h), (450, 360));
      await tester.runAsync(() async {
        await result!.delete();
        await fake.cleanUp();
      });
    });
  });
}

/// Nachgebaute Kamera: zwei Geraete, Vorschau 640 x 360, Foto als PNG.
class _FakeCameraPlatform extends CameraPlatform {
  _FakeCameraPlatform(this.jpeg, this._folder);

  static Future<_FakeCameraPlatform> create() async {
    final folder = await Directory.systemTemp.createTemp('cbfunk_fakecam_');
    return _FakeCameraPlatform(await _png(_bands(640, 360), 640, 360), folder);
  }

  final Uint8List jpeg;
  final Directory _folder;
  final List<String> created = <String>[];
  final List<int> disposed = <int>[];
  final _events = StreamController<CameraInitializedEvent>.broadcast();
  String? lastPicturePath;
  int _nextId = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
    CameraDescription(
      name: 'Integrated Webcam <usb#1>',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 0,
    ),
    CameraDescription(
      name: 'USB Kamera <usb#2>',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 0,
    ),
  ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async {
    created.add(cameraDescription.name);
    return ++_nextId;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _events.stream.where((event) => event.cameraId == cameraId);

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    scheduleMicrotask(
      () => _events.add(
        CameraInitializedEvent(
          cameraId,
          640,
          360,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      ),
    );
  }

  @override
  Widget buildPreview(int cameraId) =>
      const ColoredBox(key: ValueKey('fake-preview'), color: Colors.green);

  @override
  Future<XFile> takePicture(int cameraId) async {
    final file = File(
      '${_folder.path}${Platform.pathSeparator}PhotoCapture_$cameraId.jpeg',
    );
    await file.writeAsBytes(jpeg);
    lastPicturePath = file.path;
    return XFile(file.path);
  }

  @override
  Future<void> dispose(int cameraId) async => disposed.add(cameraId);

  Future<void> cleanUp() async {
    await _events.close();
    if (await _folder.exists()) await _folder.delete(recursive: true);
  }
}

Uint8List _bands(int width, int height) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final o = (y * width + x) * 4;
      final band = x * 3 ~/ width;
      pixels[o] = band == 0 ? 255 : 0;
      pixels[o + 1] = band == 1 ? 255 : 0;
      pixels[o + 2] = band == 2 ? 255 : 0;
      pixels[o + 3] = 255;
    }
  }
  return pixels;
}

Future<Uint8List> _png(Uint8List rgba, int width, int height) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<(int, int, Uint8List)> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = (image.width, image.height, data!.buffer.asUint8List());
  image.dispose();
  codec.dispose();
  return result;
}
