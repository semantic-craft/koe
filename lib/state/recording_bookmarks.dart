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
    this.audioVersion,
  });

  final String id;
  final String recordingKey;
  final Duration position;
  final String note;
  final String? segmentText;
  final Duration? segmentStart;
  final Duration? segmentEnd;
  final int? transcriptRevision;

  /// Content digest of the original audio when saved (`audioVersion`), or
  /// null when it could not be read.
  final String? audioVersion;
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
        audioVersion: audioVersion,
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
    if (audioVersion != null) 'audioVersion': audioVersion,
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
      audioVersion: value['audioVersion'] is String
          ? value['audioVersion'] as String
          : null,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

/// A bookmark could not be saved; [message] is shown with the kept draft.
class BookmarkSaveException implements Exception {
  const BookmarkSaveException(this.message);
  final String message;
  @override
  String toString() => message;
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

/// The segment whose own time range contains [position], if any.
///
/// A position in a silent gap, or past a known segment end, belongs to no
/// sentence; a segment without an end extends to the next segment's start.
int? segmentContaining(List<TranscriptSegment> segments, Duration position) {
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    if (position < segment.start) return null;
    final next = index + 1 < segments.length ? segments[index + 1].start : null;
    if (next != null && position >= next) continue;
    if (position == segment.start) return index;
    final end = segment.end ?? next;
    return end == null || position < end ? index : null;
  }
  return null;
}

/// Resolves [bookmark] against the material as it is now.
///
/// [segments] must be the timed segments the reader can actually locate
/// (empty when timing is unreliable). A segment-anchored bookmark replays
/// only when exactly the same sentence can be identified: an exact start match
/// wins; otherwise a single nearby match is accepted and several are treated
/// as ambiguous rather than guessed. [currentAudioVersion] is the digest of
/// the audio on disk now (null with [audioVersionKnown] false while it is
/// still being read).
BookmarkTarget resolveBookmark(
  RecordingBookmark bookmark, {
  required bool audioAvailable,
  required bool audioChanged,
  required List<TranscriptSegment> segments,
  Duration? duration,
  bool audioVersionKnown = true,
  String? currentAudioVersion,
}) {
  if (!audioAvailable) {
    return BookmarkTarget._(
      bookmark,
      unavailableReason: '原录音不在本机，暂时无法回听；书签与批注仍保留。',
    );
  }
  final saved = bookmark.audioVersion;
  if (saved == null) {
    return BookmarkTarget._(
      bookmark,
      unavailableReason: '这条书签没有记录原音频版本，无法确认来源；为避免跳错，暂不定位。',
    );
  }
  if (!audioVersionKnown) {
    return BookmarkTarget._(bookmark, unavailableReason: '正在核对原音频，稍后即可回听。');
  }
  if (!audioChanged && currentAudioVersion == null) {
    return BookmarkTarget._(
      bookmark,
      unavailableReason: '无法读取原音频以核对版本；为避免跳错，暂不定位。',
    );
  }
  if (audioChanged || currentAudioVersion != saved) {
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
    int? exact;
    final near = <int>[];
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      if (segment.text.trim() != savedText) continue;
      if (segment.start == savedStart) {
        exact = index;
        break;
      }
      if ((segment.start - savedStart).abs() <= _anchorTolerance) {
        near.add(index);
      }
    }
    final match = exact ?? (near.length == 1 ? near.single : null);
    if (match == null) {
      return BookmarkTarget._(
        bookmark,
        unavailableReason: near.length > 1
            ? '转写已更新，附近有多处相同文字，无法确认原片段；为避免跳错，不再定位。'
            : '转写已更新，原片段已不存在；为避免跳错，不再定位。',
      );
    }
    var offset = bookmark.position - savedStart;
    if (offset < Duration.zero) offset = Duration.zero;
    final segment = segments[match];
    final seekTo = segment.start + offset;
    final next = match + 1 < segments.length ? segments[match + 1].start : null;
    final end = segment.end ?? next;
    final outside =
        offset > Duration.zero &&
        ((end != null && seekTo >= end) ||
            (next != null && seekTo >= next) ||
            (duration != null &&
                duration > Duration.zero &&
                seekTo > duration));
    if (outside) {
      return BookmarkTarget._(
        bookmark,
        unavailableReason: '转写已更新，书签位置超出原片段的新范围；为避免跳到别的句子，不再定位。',
      );
    }
    return BookmarkTarget._(bookmark, seekTo: seekTo, segmentIndex: match);
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

  /// True when an unreadable file could not be set aside; saving would then
  /// overwrite the only copy, so every mutation is refused.
  bool get writeBlocked => _writeBlocked;
  bool _writeBlocked = false;

  Future<void> load() async {
    if (inMemory) return;
    File? target;
    var broken = 0;
    try {
      target = await _file();
      if (!await target.exists()) return;
      final raw = await target.readAsString();
      final value = jsonDecode(raw);
      if (value is! Map || value['bookmarks'] is! List) {
        throw const FormatException('bookmarks');
      }
      final entries = value['bookmarks'] as List;
      final valid = <RecordingBookmark>[
        for (final entry in entries) ?RecordingBookmark.decode(entry),
      ];
      _items = List.unmodifiable(valid);
      _showMarkers = value['showMarkers'] != false;
      broken = entries.length - valid.length;
    } catch (error) {
      debugPrint('[Bookmarks] load failed: $error');
      _items = const [];
      // Keep the unreadable file aside so the next save cannot erase it.
      try {
        if (target == null) throw StateError('no bookmark file');
        if (await target.exists()) await backupUnreadable(target);
        recoveryNotice = '书签记录无法读取，已另存原文件；录音与转写不受影响。';
      } catch (backupError) {
        debugPrint('[Bookmarks] backup failed: $backupError');
        _writeBlocked = true;
        recoveryNotice = '书签记录无法读取，也未能另存原文件；为避免覆盖，暂不保存新的书签。';
      }
      return;
    }
    if (broken > 0) await _preservePartlyBroken(target, broken);
  }

  /// Some entries failed to decode: copy the original aside before any save
  /// can drop them, then keep the readable ones usable.
  Future<void> _preservePartlyBroken(File target, int broken) async {
    try {
      await backupUnreadable(target, keepOriginal: true);
    } catch (error) {
      debugPrint('[Bookmarks] partial backup failed: $error');
      _writeBlocked = true;
      recoveryNotice = '有 $broken 条书签记录无法读取，也未能另存原文件；为避免覆盖，暂不保存书签修改。';
      return;
    }
    recoveryNotice = '有 $broken 条书签记录无法读取，已另存原文件；其余书签照常可用。';
    try {
      // Rewrite with the readable entries so the copy is not repeated on
      // every launch; on failure the original file is still intact.
      await _write(_items, _showMarkers);
    } catch (error) {
      debugPrint('[Bookmarks] rewrite after partial backup failed: $error');
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

  /// Decided inside the save queue so a bookmark still being written is
  /// removed too.
  Future<void> forgetRecording(String recordingKey) => _commit((items) {
    if (!items.any((item) => item.recordingKey == recordingKey)) return null;
    return items.where((item) => item.recordingKey != recordingKey).toList();
  });

  Future<void> setShowMarkers(bool value) =>
      _commit((items) => items, showMarkers: value);

  /// Serialises mutations; each one sees the previous committed list.
  Future<void> _commit(
    List<RecordingBookmark>? Function(List<RecordingBookmark> items) change, {
    bool? showMarkers,
  }) {
    final operation = _pendingSave.then((_) async {
      if (_writeBlocked) {
        throw StateError('bookmark file unreadable and not backed up');
      }
      final next = change(_items);
      if (next == null) return;
      final markers = showMarkers ?? _showMarkers;
      if (!inMemory) await _write(next, markers);
      _items = List.unmodifiable(next);
      _showMarkers = markers;
    });
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(List<RecordingBookmark> items, bool showMarkers) =>
      writeSnapshot(
        const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'showMarkers': showMarkers,
          'bookmarks': [for (final item in items) item.toJson()],
        }),
      );

  /// Moves an unreadable bookmark file aside before anything can overwrite it.
  @visibleForOverriding
  Future<void> backupUnreadable(File target, {bool keepOriginal = false}) {
    final aside =
        '${target.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}';
    return keepOriginal ? target.copy(aside) : target.rename(aside);
  }

  /// Atomically replaces the bookmark file. Overridable so tests can hold a
  /// write open and exercise the real save queue.
  @visibleForOverriding
  Future<void> writeSnapshot(String json) async {
    final target = await _file();
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(json, flush: true);
    await temporary.rename(target.path);
  }
}
