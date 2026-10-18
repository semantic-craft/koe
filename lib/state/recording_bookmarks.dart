import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'recording.dart';

/// A personal bookmark (optionally with a note) on one material.
///
/// Identity follows the #124 source anchor: material key + transcript
/// revision + segment text/time range. The position is on the original audio;
/// the segment anchor lets a later transcript change be detected instead of
/// silently jumping to whatever sentence now sits at the same index.
class RecordingBookmark {
  const RecordingBookmark({
    required this.id,
    required this.recordingKey,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
    this.note = '',
    this.segmentText,
    this.segmentStart,
    this.segmentEnd,
    this.transcriptRevision,
  });

  final String id;
  final String recordingKey;
  final Duration position;
  final String note;
  final String? segmentText;
  final Duration? segmentStart;
  final Duration? segmentEnd;
  final int? transcriptRevision;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get anchoredToSegment => segmentText != null && segmentStart != null;

  RecordingBookmark copyWith({String? note, DateTime? updatedAt}) =>
      RecordingBookmark(
        id: id,
        recordingKey: recordingKey,
        position: position,
        note: note ?? this.note,
        segmentText: segmentText,
        segmentStart: segmentStart,
        segmentEnd: segmentEnd,
        transcriptRevision: transcriptRevision,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'recordingKey': recordingKey,
    'positionMs': position.inMilliseconds,
    if (note.isNotEmpty) 'note': note,
    if (segmentText != null) 'segmentText': segmentText,
    if (segmentStart != null) 'segmentStartMs': segmentStart!.inMilliseconds,
    if (segmentEnd != null) 'segmentEndMs': segmentEnd!.inMilliseconds,
    if (transcriptRevision != null) 'transcriptRevision': transcriptRevision,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static RecordingBookmark? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final key = value['recordingKey'];
    final position = value['positionMs'];
    final createdAt = DateTime.tryParse('${value['createdAt']}');
    final updatedAt = DateTime.tryParse('${value['updatedAt']}');
    if (id is! String || id.isEmpty || key is! String || key.isEmpty) {
      return null;
    }
    if (position is! int || position < 0) return null;
    if (createdAt == null || updatedAt == null) return null;
    Duration? ms(Object? raw) =>
        raw is int && raw >= 0 ? Duration(milliseconds: raw) : null;
    final text = value['segmentText'];
    return RecordingBookmark(
      id: id,
      recordingKey: key,
      position: Duration(milliseconds: position),
      note: value['note'] is String ? value['note'] as String : '',
      segmentText: text is String && text.isNotEmpty ? text : null,
      segmentStart: ms(value['segmentStartMs']),
      segmentEnd: ms(value['segmentEndMs']),
      transcriptRevision: value['transcriptRevision'] is int
          ? value['transcriptRevision'] as int
          : null,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// Where a bookmark can be replayed now, or why it cannot.
class BookmarkTarget {
  const BookmarkTarget._(
    this.bookmark, {
    this.seekTo,
    this.segmentIndex,
    this.unavailableReason,
  });

  final RecordingBookmark bookmark;
  final Duration? seekTo;
  final int? segmentIndex;
  final String? unavailableReason;
  bool get available => seekTo != null;
}

/// Tolerance for a re-transcribed sentence whose start moved slightly.
const _anchorTolerance = Duration(seconds: 1);

/// Resolves [bookmark] against the material as it is now.
///
/// [segments] must be the timed segments the reader can actually locate
/// (empty when timing is unreliable). A segment-anchored bookmark only replays
/// when the same sentence is still present near its saved time; otherwise it
/// is reported as changed rather than jumping to a different sentence.
BookmarkTarget resolveBookmark(
  RecordingBookmark bookmark, {
  required bool audioAvailable,
  required bool audioChanged,
  required List<TranscriptSegment> segments,
  Duration? duration,
}) {
  if (!audioAvailable) {
    return BookmarkTarget._(
      bookmark,
      unavailableReason: '原录音不在本机，暂时无法回听；书签与批注仍保留。',
    );
  }
  if (audioChanged) {
    return BookmarkTarget._(
      bookmark,
      unavailableReason: '原音频已变化，书签位置可能不再对应；为避免跳错，暂不定位。',
    );
  }
  if (bookmark.anchoredToSegment) {
    final savedText = bookmark.segmentText!.trim();
    final savedStart = bookmark.segmentStart!;
    if (segments.isEmpty) {
      return BookmarkTarget._(
        bookmark,
        unavailableReason: '当前转写没有可用的句段时间，无法确认原片段；为避免跳错，暂不定位。',
      );
    }
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      if (segment.text.trim() != savedText) continue;
      if ((segment.start - savedStart).abs() > _anchorTolerance) continue;
      final end = segment.end ?? bookmark.segmentEnd;
      final length = end != null && end > segment.start
          ? end - segment.start
          : Duration.zero;
      var offset = bookmark.position - savedStart;
      if (offset < Duration.zero) offset = Duration.zero;
      if (offset > length) offset = length;
      return BookmarkTarget._(
        bookmark,
        seekTo: segment.start + offset,
        segmentIndex: index,
      );
    }
    return BookmarkTarget._(
      bookmark,
      unavailableReason: '转写已更新，原片段已不存在；为避免跳错，不再定位。',
    );
  }
  if (duration != null &&
      duration > Duration.zero &&
      bookmark.position > duration) {
    return BookmarkTarget._(
      bookmark,
      unavailableReason: '书签位置超出当前录音长度，来源可能已更改。',
    );
  }
  return BookmarkTarget._(bookmark, seekTo: bookmark.position);
}

/// Persists bookmarks and the marker display preference.
///
/// Every mutation writes first and only then changes memory, so a failed save
/// never shows unsaved personal content as saved.
class RecordingBookmarkStore {
  RecordingBookmarkStore({this.file, this.inMemory = false});

  static const fileName = 'recording_bookmarks.json';
  final File? file;
  final bool inMemory;
  List<RecordingBookmark> _items = const [];
  bool _showMarkers = true;
  int _sequence = 0;
  Future<void> _pendingSave = Future<void>.value();
  String? recoveryNotice;

  bool get showMarkers => _showMarkers;

  List<RecordingBookmark> forRecording(String recordingKey) =>
      _items.where((item) => item.recordingKey == recordingKey).toList()
        ..sort((a, b) {
          final byPosition = a.position.compareTo(b.position);
          return byPosition != 0
              ? byPosition
              : a.createdAt.compareTo(b.createdAt);
        });

  String newId(DateTime now) =>
      '${now.microsecondsSinceEpoch.toRadixString(36)}-${(_sequence++).toRadixString(36)}';

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
    File? target;
    try {
      target = await _file();
      if (!await target.exists()) return;
      final raw = await target.readAsString();
      final value = jsonDecode(raw);
      if (value is! Map || value['bookmarks'] is! List) {
        throw const FormatException('bookmarks');
      }
      _items = [
        for (final entry in value['bookmarks'] as List)
          ?RecordingBookmark.decode(entry),
      ];
      _showMarkers = value['showMarkers'] != false;
    } catch (error) {
      debugPrint('[Bookmarks] load failed: $error');
      // Keep the unreadable file aside so the next save cannot erase it.
      try {
        if (target != null && await target.exists()) {
          await target.rename(
            '${target.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}',
          );
        }
      } catch (_) {}
      recoveryNotice = '书签记录无法读取，已另存原文件；录音与转写不受影响';
    }
  }

  Future<void> add(RecordingBookmark bookmark) =>
      _commit((items) => [...items, bookmark]);

  Future<void> updateNote(String id, String note, {required DateTime now}) =>
      _commit(
        (items) => [
          for (final item in items)
            item.id == id ? item.copyWith(note: note, updatedAt: now) : item,
        ],
      );

  Future<void> remove(String id) =>
      _commit((items) => items.where((item) => item.id != id).toList());

  Future<void> forgetRecording(String recordingKey) async {
    if (!_items.any((item) => item.recordingKey == recordingKey)) return;
    await _commit(
      (items) =>
          items.where((item) => item.recordingKey != recordingKey).toList(),
    );
  }

  Future<void> setShowMarkers(bool value) =>
      _commit((items) => items, showMarkers: value);

  /// Serialises mutations; each one sees the previous committed list.
  Future<void> _commit(
    List<RecordingBookmark> Function(List<RecordingBookmark> items) change, {
    bool? showMarkers,
  }) {
    final operation = _pendingSave.then((_) async {
      final next = change(_items);
      final markers = showMarkers ?? _showMarkers;
      if (!inMemory) await _write(next, markers);
      _items = List.unmodifiable(next);
      _showMarkers = markers;
    });
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(List<RecordingBookmark> items, bool showMarkers) async {
    final target = await _file();
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'showMarkers': showMarkers,
        'bookmarks': [for (final item in items) item.toJson()],
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }
}
