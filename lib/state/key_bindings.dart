import 'dart:async';
import 'package:flutter/services.dart';
import '../models/key_action.dart';

/// Angelernte Tasten (Aktion -> LogicalKeyboardKey.keyId) und der Anlern-Modus.
class KeyBindings {
  final Map<KeyAction, int> _map = {};
  Completer<int?>? _learning;

  bool get isLearning => _learning != null;

  int? idFor(KeyAction a) => _map[a];

  KeyAction? actionFor(int keyId) {
    for (final e in _map.entries) {
      if (e.value == keyId) return e.key;
    }
    return null;
  }

  String labelFor(KeyAction a) {
    final id = _map[a];
    if (id == null) return 'keine Taste';
    final k = LogicalKeyboardKey.findKeyByKeyId(id);
    final l = k?.keyLabel ?? '';
    return l.trim().isNotEmpty ? l : (k?.debugName ?? 'Taste $id');
  }

  void set(KeyAction a, int keyId) {
    // jede Taste nur einer Aktion zuordnen
    _map.removeWhere((_, v) => v == keyId);
    _map[a] = keyId;
  }

  void clear(KeyAction a) => _map.remove(a);

  Future<int?> beginLearn() {
    cancelLearn();
    final c = Completer<int?>();
    _learning = c;
    return c.future;
  }

  void completeLearn(int keyId) {
    final c = _learning;
    _learning = null;
    c?.complete(keyId);
  }

  void cancelLearn() {
    final c = _learning;
    _learning = null;
    if (c != null && !c.isCompleted) c.complete(null);
  }
}
