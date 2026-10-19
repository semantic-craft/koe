import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'context/context_file.dart';

/// One material in the continuous listening queue.
///
/// The per-material resume point itself lives in [PlaybackHistoryStore]; this
/// record only keeps queue order and the identity needed to find the same
/// material after a rename or restart.
class ListeningQueueEntry {
  const ListeningQueueEntry({
    required this.path,
    required this.title,
    required this.addedAt,
    this.fileId,
  });

  final String path;
  final int? fileId;

  /// Snapshot shown when the material itself can no longer be resolved.
  final String title;
  final DateTime addedAt;

  String get key => keyFor(fileId: fileId, path: path);

  static String keyFor({int? fileId, String? path}) =>
      fileId != null ? 'id:$fileId' : 'path:${path ?? ''}';

  bool matches({int? fileId, String? path}) =>
      (fileId != null && this.fileId == fileId) ||
      (path != null && this.path == path);

  Map<String, Object?> toJson() => {
    'path': path,
    if (fileId != null) 'fileId': fileId,
    'title': title,
    'addedAt': addedAt.toIso8601String(),
  };

  static ListeningQueueEntry? decode(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final title = value['title'];
    final addedAt = DateTime.tryParse('${value['addedAt']}');
    if (path is! String || path.isEmpty || title is! String) return null;
    if (addedAt == null) return null;
    final fileId = value['fileId'];
    if (fileId != null && (fileId is! int || fileId < 0)) return null;
    return ListeningQueueEntry(
      path: path,
      fileId: fileId is int ? fileId : null,
      title: title,
      addedAt: addedAt,
    );
  }
}

/// Whether a queue item can be played now, with the real reason when it cannot.
class ListeningQueueAvailability {
  const ListeningQueueAvailability({
    required this.playable,
    required this.reason,
    this.path,
    this.fileId,
  });

  final bool playable;
  final String reason;
  final String? path;
  final int? fileId;
}

typedef _QueueChange<T> =
    ({
      List<ListeningQueueEntry> entries,
      String? currentKey,
      bool changed,
      T result,
    })
    Function(List<ListeningQueueEntry> entries, String? currentKey);

/// Persists the ordered listening queue and its current material.
///
/// Every mutation writes first and only then changes memory, so a failed save
/// never shows a queue order that is not on disk.
class ListeningQueueStore {
  ListeningQueueStore({this.file, this.inMemory = false})
    : _doc = ContextFile(fileName, file: file, inMemory: inMemory);

  static const fileName = 'listening_queue.json';

  final File? file;
  final bool inMemory;
  final ContextFile _doc;

  List<ListeningQueueEntry> _entries = const [];
  String? _currentKey;
  bool _writeBlocked = false;

  String? recoveryNotice;

  List<ListeningQueueEntry> get entries => _entries;
  String? get currentKey => _currentKey;

  ListeningQueueEntry? get current {
    final key = _currentKey;
    if (key == null) return null;
    for (final entry in _entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// An unreadable file could not be set aside, so saving would overwrite the
  /// only copy. Every mutation is refused until the app restarts.
  bool get writeBlocked => _writeBlocked;

  ListeningQueueEntry? entryFor({int? fileId, String? path}) {
    for (final entry in _entries) {
      if (entry.matches(fileId: fileId, path: path)) return entry;
    }
    return null;
  }

  int indexOf(String key) => _entries.indexWhere((entry) => entry.key == key);

  Future<void> load() async {
    if (inMemory) return;
    File? target;
    try {
      target = await _doc.target();
      if (!await target.exists()) return;
      final value = jsonDecode(await target.readAsString());
      if (value is! Map || value['entries'] is! List) {
        throw const FormatException('listening queue');
      }
      final raw = value['entries'] as List;
      final entries = <ListeningQueueEntry>[];
      var broken = 0;
      for (final item in raw) {
        final entry = ListeningQueueEntry.decode(item);
        if (entry == null ||
            entries.any(
              (saved) => saved.matches(fileId: entry.fileId, path: entry.path),
            )) {
          broken++;
          continue;
        }
        entries.add(entry);
      }
      _entries = List.unmodifiable(entries);
      final savedCurrent = value['currentKey'];
      _currentKey =
          savedCurrent is String &&
              entries.any((entry) => entry.key == savedCurrent)
          ? savedCurrent
          : null;
      if (broken > 0) {
        recoveryNotice = '有 $broken 条收听队列记录无法读取，其余条目照常可用。';
      }
    } catch (error) {
      debugPrint('[ListeningQueue] load failed: $error');
      _entries = const [];
      _currentKey = null;
      try {
        if (target == null) throw StateError('no queue file');
        if (await target.exists()) await backupUnreadable(target);
        recoveryNotice = '收听队列无法读取，已另存原文件；资料与回听进度不受影响。';
      } catch (backupError) {
        debugPrint('[ListeningQueue] backup failed: $backupError');
        _writeBlocked = true;
        recoveryNotice = '收听队列无法读取，也未能另存原文件；为避免覆盖，暂不保存队列修改。';
      }
    }
  }

  Future<bool> add(ListeningQueueEntry entry) => _commit((entries, current) {
    if (entries.any(
      (saved) => saved.matches(fileId: entry.fileId, path: entry.path),
    )) {
      return (
        entries: entries,
        currentKey: current,
        changed: false,
        result: false,
      );
    }
    return (
      entries: [...entries, entry],
      currentKey: current,
      changed: true,
      result: true,
    );
  });

  /// Removes [key]. When it is the current item, [nextCurrentKey] becomes the
  /// new current (null when the user chose to stop).
  Future<bool> remove(String key, {String? nextCurrentKey}) => _commit((
    entries,
    current,
  ) {
    final index = entries.indexWhere((entry) => entry.key == key);
    if (index < 0) {
      return (
        entries: entries,
        currentKey: current,
        changed: false,
        result: false,
      );
    }
    final next = [...entries]..removeAt(index);
    final remainingKeys = next.map((entry) => entry.key).toSet();
    final currentKey = current == key
        ? (remainingKeys.contains(nextCurrentKey) ? nextCurrentKey : null)
        : current;
    return (entries: next, currentKey: currentKey, changed: true, result: true);
  });

  Future<bool> move(int from, int to) => _commit((entries, current) {
    if (from < 0 ||
        from >= entries.length ||
        to < 0 ||
        to >= entries.length ||
        from == to) {
      return (
        entries: entries,
        currentKey: current,
        changed: false,
        result: false,
      );
    }
    final next = [...entries];
    final moved = next.removeAt(from);
    next.insert(to, moved);
    return (entries: next, currentKey: current, changed: true, result: true);
  });

  Future<void> setCurrent(String? key) async {
    await _commit<bool>((entries, current) {
      final next = key != null && entries.any((entry) => entry.key == key)
          ? key
          : null;
      if (next == current) {
        return (
          entries: entries,
          currentKey: current,
          changed: false,
          result: false,
        );
      }
      return (entries: entries, currentKey: next, changed: true, result: true);
    });
  }

  Future<T> _commit<T>(_QueueChange<T> change) {
    return _doc.serialize(() async {
      if (_writeBlocked) {
        throw StateError('listening queue file unreadable and not backed up');
      }
      final next = change(_entries, _currentKey);
      if (next.changed && !inMemory) {
        await _write(next.entries, next.currentKey);
      }
      _entries = List.unmodifiable(next.entries);
      _currentKey = next.currentKey;
      return next.result;
    });
  }

  /// Moves an unreadable queue file aside before anything can overwrite it.
  /// Overridable so tests can exercise a backup failure without touching
  /// production paths.
  @visibleForOverriding
  Future<void> backupUnreadable(File target) => _doc.setAside();

  Future<void> _write(List<ListeningQueueEntry> entries, String? currentKey) =>
      writeSnapshot(
        const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'currentKey': currentKey,
          'entries': [for (final entry in entries) entry.toJson()],
        }),
      );

  /// Atomically replaces the queue file. Overridable so tests can fail a real
  /// save without touching production paths.
  @visibleForOverriding
  Future<void> writeSnapshot(String json) => _doc.replace(json);
}
