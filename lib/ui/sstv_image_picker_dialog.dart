import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

class SstvImagePickerDialog extends StatefulWidget {
  const SstvImagePickerDialog({super.key, this.initialDirectory});

  final String? initialDirectory;

  @override
  State<SstvImagePickerDialog> createState() => _SstvImagePickerDialogState();
}

class _SstvImagePickerDialogState extends State<SstvImagePickerDialog> {
  static const Set<String> _extensions = <String>{
    'png',
    'jpg',
    'jpeg',
    'bmp',
    'webp',
  };

  late Directory _directory;
  final TextEditingController _pathController = TextEditingController();
  List<FileSystemEntity> _entries = const <FileSystemEntity>[];
  String? _error;
  bool _loading = true;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['USERPROFILE'];
    final pictures = widget.initialDirectory == null
        ? home == null
              ? Directory.current
              : Directory('$home${Platform.pathSeparator}Pictures')
        : Directory(widget.initialDirectory!);
    _directory = pictures;
    _pathController.text = pictures.path;
    if (widget.initialDirectory == null) {
      unawaited(_loadInitialDirectory(home, pictures));
    } else {
      unawaited(_loadDirectory(pictures.path));
    }
  }

  Future<void> _loadInitialDirectory(String? home, Directory pictures) async {
    if (await pictures.exists()) {
      await _loadDirectory(pictures.path);
    } else {
      await _loadDirectory(home ?? Directory.current.path);
    }
  }

  Future<void> _loadDirectory(String path) async {
    if (!mounted) return;
    final request = ++_loadRequest;
    final target = Directory(path.trim().replaceAll('"', ''));
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await target.list(followLinks: false).toList();
      entries.removeWhere((entry) {
        if (entry is Directory) return false;
        final dot = entry.path.lastIndexOf('.');
        return dot < 0 ||
            !_extensions.contains(entry.path.substring(dot + 1).toLowerCase());
      });
      entries.sort((a, b) {
        final aDirectory = a is Directory;
        final bDirectory = b is Directory;
        if (aDirectory != bDirectory) return aDirectory ? -1 : 1;
        return _name(
          a.path,
        ).toLowerCase().compareTo(_name(b.path).toLowerCase());
      });
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _directory = target;
        _pathController.text = target.path;
        _entries = entries;
      });
    } catch (error) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _entries = const <FileSystemEntity>[];
        _error = 'Ordner konnte nicht gelesen werden: $error';
      });
    } finally {
      if (mounted && request == _loadRequest) {
        setState(() => _loading = false);
      }
    }
  }

  void _goUp() {
    final parent = _directory.parent;
    if (parent.path != _directory.path) {
      unawaited(_loadDirectory(parent.path));
    }
  }

  static String _name(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF21150F),
    title: const Text(
      'SSTV-Bild auswählen',
      style: TextStyle(color: Color(0xFFFFE1B4), fontSize: 17),
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
                    : _goUp,
                icon: const Icon(Icons.arrow_upward),
                color: const Color(0xFFFFD89B),
              ),
              Expanded(
                child: TextField(
                  controller: _pathController,
                  onSubmitted: (path) => unawaited(_loadDirectory(path)),
                  style: const TextStyle(
                    color: Color(0xFFFFE1B4),
                    fontSize: 12,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Ordnerpfad',
                    hintStyle: TextStyle(color: Color(0xFFBFA47F)),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF9B7048)),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFFFFC666)),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Ordner öffnen',
                onPressed: _loading
                    ? null
                    : () => unawaited(_loadDirectory(_pathController.text)),
                icon: const Icon(Icons.folder_open),
                color: const Color(0xFFFFD89B),
              ),
            ],
          ),
          if (_error != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFFF8C78), fontSize: 11),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFFC666)),
                  )
                : _entries.isEmpty
                ? const Center(
                    child: Text(
                      'Keine unterstützten Bilder oder Ordner',
                      style: TextStyle(color: Color(0xFFBAA084), fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      final isDirectory = entry is Directory;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isDirectory
                              ? Icons.folder_outlined
                              : Icons.image_outlined,
                          color: const Color(0xFFFFC666),
                        ),
                        title: Text(
                          _name(entry.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFFFE1B4),
                            fontSize: 12,
                          ),
                        ),
                        onTap: () {
                          if (isDirectory) {
                            unawaited(_loadDirectory(entry.path));
                          } else {
                            Navigator.of(context).pop(File(entry.path));
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text(
          'Abbrechen',
          style: TextStyle(color: Color(0xFFE4CCAA)),
        ),
      ),
    ],
  );
}
