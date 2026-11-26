import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import 'sstv_modem.dart';

abstract interface class SstvRemoteArchive {
  Future<void> upload(File image);
}

class SstvImageStore {
  SstvImageStore({this.remoteArchive, Directory? localDirectory})
    : _localDirectory = localDirectory;

  static const int retainedImages = 2;
  final SstvRemoteArchive? remoteArchive;
  final Directory? _localDirectory;
  Future<void> _writeQueue = Future<void>.value();

  Future<Directory> _folder() async {
    final folder =
        _localDirectory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}digital-radio'
          '${Platform.pathSeparator}sstv',
        );
    await folder.create(recursive: true);
    return folder;
  }

  Future<File> savePng(Uint8List png, {required bool sent}) {
    final operation = _writeQueue.then((_) => _savePng(png, sent: sent));
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<File> saveImage(Uint8List imageBytes, {required bool sent}) async {
    final codec = await ui.instantiateImageCodec(imageBytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) {
          throw StateError('Bild konnte nicht als PNG kodiert werden');
        }
        return await savePng(png.buffer.asUint8List(), sent: sent);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<File> saveFrame(SstvDecodedFrame frame, {required bool sent}) async {
    final image = await frameToImage(frame);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('SSTV-Bild konnte nicht als PNG kodiert werden');
      }
      return await savePng(data.buffer.asUint8List(), sent: sent);
    } finally {
      image.dispose();
    }
  }

  Future<List<File>> recent() async {
    final folder = await _folder();
    final files = await folder
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .where((file) => file.uri.pathSegments.last.startsWith('sstv_'))
        .toList();
    await _prune(files);
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.take(retainedImages).toList(growable: false);
  }

  Future<File> _savePng(Uint8List png, {required bool sent}) async {
    final folder = await _folder();
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    final file = File(
      '${folder.path}${Platform.pathSeparator}'
      'sstv_${timestamp}_${sent ? 'tx' : 'rx'}.png',
    );
    await file.writeAsBytes(png, flush: true);
    final files = await folder
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .where((item) => item.uri.pathSegments.last.startsWith('sstv_'))
        .toList();
    await _prune(files);
    final archive = remoteArchive;
    if (archive != null) await archive.upload(file);
    return file;
  }

  Future<void> _prune(List<File> files) async {
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final old in files.skip(retainedImages)) {
      await old.delete();
    }
  }

  Future<ui.Image> frameToImage(SstvDecodedFrame frame) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      frame.rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}
