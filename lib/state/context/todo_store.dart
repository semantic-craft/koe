import 'dart:io';

import 'package:flutter/foundation.dart';

import 'context_file.dart';
import 'todo.dart';

export 'todo.dart';

/// Paid extraction bookkeeping for one recording: written as `pending`
/// before the request and `done` after its result is saved. A `pending`
/// entry found later means the result is unknown.
class TodoExtraction {
  const TodoExtraction({required this.fingerprint, required this.done});

  final String fingerprint;
  final bool done;

  Map<String, Object?> toJson() => {'fingerprint': fingerprint, 'done': done};

  static TodoExtraction? decode(Object? value) {
    if (value is! Map || value['fingerprint'] is! String) return null;
    return TodoExtraction(
      fingerprint: value['fingerprint'] as String,
      done: value['done'] == true,
    );
  }
}

/// Koe's own todos, open clarifications and extraction bookkeeping, in
/// `todos.json`. Every change is saved before it counts; a failed save
/// restores the previous state and rethrows so the UI never shows a
/// completion that was not stored.
class TodoStore extends ChangeNotifier {
  TodoStore({File? file, bool inMemory = false})
    : _file = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'todos.json';

  final ContextFile _file;
  Map<String, Todo> _todos = {};
  List<TodoClarification> _clarifications = [];
  Map<String, TodoExtraction> _extractions = {};
  Future<void>? _loading;
  bool _loaded = false;
  bool _disposed = false;

  String? recoveryNotice;

  bool get loaded => _loaded;
  Future<void> get idle => _file.idle;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final json = await _file.read();
      if (json != null) {
        for (final entry in json['todos'] as List? ?? const []) {
          final todo = Todo.decode(entry);
          if (todo != null) _todos[todo.id] = todo;
        }
        for (final entry in json['clarifications'] as List? ?? const []) {
          final item = TodoClarification.decode(entry);
          if (item != null) _clarifications.add(item);
        }
        final extractions = json['extractions'];
        if (extractions is Map) {
          for (final entry in extractions.entries) {
            final value = TodoExtraction.decode(entry.value);
            if (entry.key is String && value != null) {
              _extractions[entry.key as String] = value;
            }
          }
        }
      }
    } on FormatException {
      recoveryNotice = '待办记录无法读取，已另存旧文件';
    } catch (error) {
      recoveryNotice = '待办记录无法读取';
      debugPrint('[TodoStore] load failed: $error');
    }
    _loaded = true;
    notifyListeners();
  }

  /// Open todos first (earliest due, undated last), then finished ones.
  List<Todo> get todos => _todos.values.toList()..sort(_compare);

  List<Todo> get openMine => [
    for (final todo in todos)
      if (todo.open && todo.kind == TodoKind.mine) todo,
  ];

  List<Todo> todosForProject(String projectId) => [
    for (final todo in todos)
      if (todo.projectIds.contains(projectId)) todo,
  ];

  List<Todo> todosFromRecording(String recordingKey) => [
    for (final todo in todos)
      if (todo.source.recordingKey == recordingKey) todo,
  ];

  Todo? todoById(String id) => _todos[id];

  List<TodoClarification> get clarifications =>
      List.unmodifiable(_clarifications);

  TodoExtraction? extractionFor(String recordingKey) =>
      _extractions[recordingKey];

  static int _compare(Todo a, Todo b) {
    if (a.open != b.open) return a.open ? -1 : 1;
    if (a.due != null && b.due != null) return a.due!.compareTo(b.due!);
    if (a.due != null) return -1;
    if (b.due != null) return 1;
    return a.createdAt.compareTo(b.createdAt);
  }

  Future<void> put(Todo todo) => mutate(() => _todos[todo.id] = todo);

  Future<void> markExtraction(String recordingKey, TodoExtraction? value) =>
      mutate(() {
        if (value == null) {
          _extractions.remove(recordingKey);
        } else {
          _extractions[recordingKey] = value;
        }
      });

  Future<void> resolveClarification(String id) =>
      mutate(() => _clarifications.removeWhere((item) => item.id == id));

  /// Applies an extraction result atomically: new todos, updates to
  /// existing ones, new clarifications and the `done` bookkeeping.
  Future<void> applyExtraction({
    required String recordingKey,
    required String fingerprint,
    required List<Todo> added,
    required List<Todo> updated,
    required List<TodoClarification> clarifications,
  }) => mutate(() {
    for (final todo in [...added, ...updated]) {
      _todos[todo.id] = todo;
    }
    _clarifications.addAll(clarifications);
    _extractions[recordingKey] = TodoExtraction(
      fingerprint: fingerprint,
      done: true,
    );
  });

  /// Runs [change] and saves; on failure everything is put back.
  Future<void> mutate(void Function() change) async {
    final todos = Map<String, Todo>.of(_todos);
    final clarifications = List<TodoClarification>.of(_clarifications);
    final extractions = Map<String, TodoExtraction>.of(_extractions);
    change();
    try {
      await _file.write({
        'version': 1,
        'todos': [for (final todo in _todos.values) todo.toJson()],
        'clarifications': [for (final item in _clarifications) item.toJson()],
        'extractions': {
          for (final entry in _extractions.entries)
            entry.key: entry.value.toJson(),
        },
      });
    } catch (error) {
      _todos = todos;
      _clarifications = clarifications;
      _extractions = extractions;
      debugPrint('[TodoStore] save failed: $error');
      notifyListeners();
      throw StateError('待办保存失败，已恢复原状态，请重试');
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
