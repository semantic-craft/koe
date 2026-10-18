import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One real listening position. Positions are keyed by device file id when
/// available so renaming a material does not move another recording's point.
class PlaybackPoint {
  const PlaybackPoint({
    required this.path,
    required this.position,
    required this.duration,
    required this.completed,
    required this.updatedAt,
    this.fileId,
  });

  final String path;
  final int? fileId;
  final Duration position;
  final Duration duration;
  final bool completed;
  final DateTime updatedAt;

  String get key => PlaybackHistoryStore.keyFor(fileId: fileId, path: path);

  PlaybackPoint copyWith({
    String? path,
    Duration? position,
    Duration? duration,
    bool? completed,
    DateTime? updatedAt,
  }) => PlaybackPoint(
    path: path ?? this.path,
    fileId: fileId,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    completed: completed ?? this.completed,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'path': path,
    if (fileId != null) 'fileId': fileId,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'completed': completed,
    'updatedAt': updatedAt.toIso8601String(),
  };

  static PlaybackPoint? decode(Object? value) {
    if (value is! Map) return null;
    final path = value['path'];
    final position = value['positionMs'];
    final duration = value['durationMs'];
    final updatedAt = DateTime.tryParse('${value['updatedAt']}');
    if (path is! String ||
        path.isEmpty ||
        position is! int ||
        duration is! int) {
      return null;
    }
    if (updatedAt == null || position < 0 || duration < 0) return null;
    return PlaybackPoint(
      path: path,
      fileId: value['fileId'] is int ? value['fileId'] as int : null,
      position: Duration(milliseconds: position),
      duration: Duration(milliseconds: duration),
      completed: value['completed'] == true,
      updatedAt: updatedAt,
    );
  }
}

/// Persists the last position per material and the user's playback speed.
///
/// A corrupt file only loses resume points; audio originals are never touched.
class PlaybackHistoryStore {
  PlaybackHistoryStore({this.file, this.inMemory = false});

  static const fileName = 'playback_history.json';

  final File? file;
  final bool inMemory;
  final Map<String, PlaybackPoint> _points = {};
  String? _lastKey;
  double speed = 1;
  Future<void> _pendingSave = Future<void>.value();

  String? recoveryNotice;
  String? saveError;

  static String keyFor({int? fileId, String? path}) =>
      fileId != null ? 'id:$fileId' : 'path:${path ?? ''}';

  PlaybackPoint? get latest {
    final key = _lastKey;
    return key == null ? null : _points[key];
  }

  PlaybackPoint? forRecording({int? fileId, String? path}) {
    final exact = _points[keyFor(fileId: fileId, path: path)];
    if (exact != null) return exact;
    if (fileId == null && path != null) {
      for (final point in _points.values) {
        if (point.path == path) return point;
      }
    }
    return null;
  }

  Future<File> _file() async {
    if (file != null) return file!;
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, fileName));
  }

  Future<void> load() async {
    if (inMemory) return;
    try {
      final target = await _file();
      if (!await target.exists()) return;
      final decoded = decode(await target.readAsString());
      if (decoded == null) {
        recoveryNotice = '回听进度无法读取，原音频仍保留';
        return;
      }
      _points.addAll(decoded.points);
      _lastKey = decoded.lastKey;
      speed = decoded.speed;
    } catch (error) {
      recoveryNotice = '回听进度无法读取，原音频仍保留';
      debugPrint('[PlaybackHistory] load failed: $error');
    }
  }

  @visibleForTesting
  static ({Map<String, PlaybackPoint> points, String? lastKey, double speed})?
  decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final entries = value['points'];
      if (entries is! List) return null;
      final points = <String, PlaybackPoint>{};
      for (final entry in entries) {
        final point = PlaybackPoint.decode(entry);
        if (point != null) points[point.key] = point;
      }
      final speed = value['speed'];
      return (
        points: points,
        lastKey: value['lastKey'] is String ? value['lastKey'] as String : null,
        speed: speed is num && speed >= 0.5 && speed <= 2
            ? speed.toDouble()
            : 1,
      );
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Map<String, Object?> encode(
    Iterable<PlaybackPoint> points, {
    String? lastKey,
    required double speed,
  }) => {
    'version': 1,
    'lastKey': lastKey,
    'speed': speed,
    'points': points.map((point) => point.toJson()).toList(),
  };

  Future<void> record(PlaybackPoint point, {bool makeLatest = true}) async {
    _points[point.key] = point;
    if (makeLatest) _lastKey = point.key;
    if (_points.length > 200) {
      final ordered = _points.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _points
        ..clear()
        ..addEntries(ordered.take(200).map((item) => MapEntry(item.key, item)));
    }
    await save();
  }

  Future<void> setSpeed(double value) async {
    speed = value;
    await save();
  }

  Future<void> forget({int? fileId, String? path}) async {
    final key = keyFor(fileId: fileId, path: path);
    final removed = _points.remove(key);
    if (removed == null && path != null) {
      _points.removeWhere((_, point) => point.path == path);
    }
    if (_lastKey == key || (_points[_lastKey] == null && _points.isNotEmpty)) {
      final ordered = _points.values.toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _lastKey = ordered.isEmpty ? null : ordered.first.key;
    }
    await save();
  }

  Future<void> save() {
    if (inMemory) return Future<void>.value();
    final snapshot = List<PlaybackPoint>.of(_points.values);
    final lastKey = _lastKey;
    final speedSnapshot = speed;
    final operation = _pendingSave.then(
      (_) => _write(snapshot, lastKey: lastKey, speed: speedSnapshot),
    );
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(
    List<PlaybackPoint> snapshot, {
    required String? lastKey,
    required double speed,
  }) async {
    try {
      final target = await _file();
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(encode(snapshot, lastKey: lastKey, speed: speed)),
        flush: true,
      );
      await temporary.rename(target.path);
      saveError = null;
    } catch (error) {
      saveError = '回听进度保存失败';
      debugPrint('[PlaybackHistory] save failed: $error');
    }
  }
}
