import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One imported transcript segment. Timings are optional because a text-only
/// import must stay readable without pretending that it can be replayed.
class MinutesSegment {
  const MinutesSegment({
    required this.text,
    required this.start,
    this.end,
    this.speaker,
  });

  final String text;
  final Duration start;
  final Duration? end;
  final String? speaker;

  Map<String, Object?> toJson() => {
    'text': text,
    'startMs': start.inMilliseconds,
    if (end != null) 'endMs': end!.inMilliseconds,
    if (speaker != null) 'speaker': speaker,
  };

  static MinutesSegment? decode(Object? value) {
    if (value is! Map) return null;
    final text = value['text'];
    final startMs = value['startMs'];
    final endMs = value['endMs'];
    final speaker = value['speaker'];
    if (text is! String ||
        text.trim().isEmpty ||
        startMs is! int ||
        startMs < 0) {
      return null;
    }
    if (endMs != null && (endMs is! int || endMs < startMs)) return null;
    return MinutesSegment(
      text: text.trim(),
      start: Duration(milliseconds: startMs),
      end: endMs is int ? Duration(milliseconds: endMs) : null,
      speaker: speaker is String && speaker.trim().isNotEmpty
          ? speaker.trim()
          : null,
    );
  }
}

/// A record imported from a notes app (妙记 JSON/TXT) plus its optional audio.
///
/// The original audio is never embedded here; [audioPath] points at the
/// library original so deleting a derived copy cannot delete the recording.
class MinutesDocument {
  const MinutesDocument({
    required this.id,
    required this.title,
    required this.sourceName,
    required this.importedAt,
    this.capturedAt,
    this.audioPath,
    this.audioDuration,
    this.audioHash,
    required this.segments,
    required this.timingReliable,
    this.warning,
  });

  final String id;
  final String title;
  final String sourceName;
  final DateTime importedAt;

  /// Only an explicit recording time from the imported file. Import time is
  /// never used as a substitute.
  final DateTime? capturedAt;
  final String? audioPath;
  final Duration? audioDuration;

  /// Hash declared by the export, used to reject a wrong audio pairing.
  final String? audioHash;
  final List<MinutesSegment> segments;

  /// Whether every segment has a usable, strictly increasing timecode.
  final bool timingReliable;
  final String? warning;

  bool get textOnly => audioPath == null;

  /// Text exists but the attached audio or its timecodes cannot locate a
  /// sentence. Whole-file playback is still possible when audio exists.
  bool get unaligned => audioPath != null && !timingReliable;

  String get bodyText => segments
      .map(
        (segment) => segment.speaker == null
            ? segment.text
            : '${segment.speaker}：${segment.text}',
      )
      .join('\n');

  Duration? get lastEnd {
    if (segments.isEmpty) return null;
    final last = segments.last;
    return last.end ?? last.start;
  }

  MinutesDocument copyWith({
    String? audioPath,
    Duration? audioDuration,
    bool clearAudio = false,
  }) => MinutesDocument(
    id: id,
    title: title,
    sourceName: sourceName,
    importedAt: importedAt,
    capturedAt: capturedAt,
    audioPath: clearAudio ? null : (audioPath ?? this.audioPath),
    audioDuration: clearAudio ? null : (audioDuration ?? this.audioDuration),
    audioHash: audioHash,
    segments: segments,
    timingReliable: timingReliable,
    warning: warning,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'sourceName': sourceName,
    'importedAt': importedAt.toIso8601String(),
    if (capturedAt != null) 'capturedAt': capturedAt!.toIso8601String(),
    if (audioPath != null) 'audioPath': audioPath,
    if (audioDuration != null) 'audioDurationMs': audioDuration!.inMilliseconds,
    if (audioHash != null) 'audioHash': audioHash,
    'timingReliable': timingReliable,
    if (warning != null) 'warning': warning,
    'segments': segments.map((segment) => segment.toJson()).toList(),
  };

  static MinutesDocument? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final title = value['title'];
    final importedAt = DateTime.tryParse('${value['importedAt']}');
    final rawSegments = value['segments'];
    if (id is! String ||
        id.isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        importedAt == null ||
        rawSegments is! List) {
      return null;
    }
    final segments = rawSegments
        .map(MinutesSegment.decode)
        .whereType<MinutesSegment>()
        .toList(growable: false);
    if (segments.isEmpty || segments.length != rawSegments.length) return null;
    final durationMs = value['audioDurationMs'];
    return MinutesDocument(
      id: id,
      title: title.trim(),
      sourceName: value['sourceName'] is String
          ? value['sourceName'] as String
          : '$title.txt',
      importedAt: importedAt,
      capturedAt: value['capturedAt'] is String
          ? DateTime.tryParse(value['capturedAt'] as String)
          : null,
      audioPath: value['audioPath'] is String
          ? value['audioPath'] as String
          : null,
      audioDuration: durationMs is int
          ? Duration(milliseconds: durationMs)
          : null,
      audioHash: value['audioHash'] is String
          ? value['audioHash'] as String
          : null,
      segments: segments,
      timingReliable: value['timingReliable'] == true,
      warning: value['warning'] is String ? value['warning'] as String : null,
    );
  }
}

class MinutesParseResult {
  const MinutesParseResult(this.document);
  final MinutesDocument document;
}

class MinutesImportOutcome {
  const MinutesImportOutcome({required this.document, required this.duplicate});
  final MinutesDocument document;
  final bool duplicate;
}

class MinutesAttachOutcome {
  const MinutesAttachOutcome({
    required this.ok,
    required this.message,
    this.document,
  });
  final bool ok;
  final String message;
  final MinutesDocument? document;
}

/// Parses a 妙记-style JSON/TXT export.
///
/// JSON accepts the common shape `{title, recordedAt, segments:[{speaker,
/// start, end, text}]}` and tolerates alternative field names. Numeric starts
/// are seconds unless the field name says `ms` (or the value is very large).
MinutesParseResult parseMinutesDocument(String fileName, String raw) {
  final trimmed = raw.trim();
  if (trimmed.startsWith('{')) {
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      // Fall through to the line parser so a malformed JSON export still opens
      // as readable text instead of disappearing.
    }
    if (decoded is Map) return _parseMinutesJson(fileName, decoded, raw);
  }
  return _parseMinutesText(fileName, raw);
}

MinutesParseResult _parseMinutesJson(
  String fileName,
  Map<dynamic, dynamic> value,
  String raw,
) {
  final title =
      _firstText(value, const ['title', 'name', 'subject']) ??
      _fileStem(fileName);
  final capturedAt = _firstDate(value, const [
    'recordedAt',
    'capturedAt',
    'recordingTime',
    'recorded_at',
    'startTime',
  ]);
  final audioHash = _firstText(value, const [
    'audioSha256',
    'audioHash',
    'audio_sha256',
    'audio.hash',
  ]);
  final list = _firstList(value, const [
    'segments',
    'sentences',
    'paragraphs',
    'utterances',
    'items',
    'lines',
  ]);
  final segments = <MinutesSegment>[];
  if (list != null) {
    for (final item in list) {
      final segment = _segmentFromJson(item);
      if (segment != null) segments.add(segment);
    }
  }
  if (segments.isEmpty) {
    final text = _firstText(value, const ['transcript', 'text', 'content']);
    if (text != null) {
      segments.add(MinutesSegment(text: text, start: Duration.zero));
    }
  }
  if (segments.isEmpty) {
    throw const FormatException('没有找到可导入的文字段');
  }
  final reliable = _timingsReliable(segments);
  return MinutesParseResult(
    MinutesDocument(
      id: _contentId(raw),
      title: title,
      sourceName: p.basename(fileName),
      importedAt: DateTime.now(),
      capturedAt: capturedAt,
      audioHash: audioHash,
      segments: List.unmodifiable(segments),
      timingReliable: reliable,
      warning: reliable ? null : '导入文字没有可用的逐段时码，只能整段阅读。',
    ),
  );
}

MinutesSegment? _segmentFromJson(Object? item) {
  if (item is String) {
    return item.trim().isEmpty
        ? null
        : MinutesSegment(text: item.trim(), start: Duration.zero);
  }
  if (item is! Map) return null;
  final text = _firstText(item, const [
    'text',
    'content',
    'sentence',
    'words',
    'body',
  ]);
  if (text == null) return null;
  final startEntry = _firstEntry(item, const [
    'startMs',
    'start',
    'startTime',
    'beginTime',
    'begin_time',
    'offset',
    'time',
  ]);
  final start = _duration(
    startEntry?.value,
    millisecondsHint: startEntry?.key.toLowerCase().contains('ms') ?? false,
  );
  final endEntry = _firstEntry(item, const [
    'endMs',
    'end',
    'endTime',
    'finishTime',
  ]);
  final end = _duration(
    endEntry?.value,
    millisecondsHint: endEntry?.key.toLowerCase().contains('ms') ?? false,
  );
  final speaker = _firstText(item, const [
    'speaker',
    'speakerName',
    'speaker_name',
    'speakerLabel',
    'name',
    'role',
  ]);
  return MinutesSegment(
    text: text,
    start: start ?? Duration.zero,
    end: end,
    speaker: speaker,
  );
}

MinutesParseResult _parseMinutesText(String fileName, String raw) {
  final segments = <MinutesSegment>[];
  var sawTiming = false;
  var untimed = 0;
  Duration? pendingStart;
  String? pendingSpeaker;
  for (final line in const LineSplitter().convert(raw)) {
    if (line.trim().isEmpty) continue;
    final match = RegExp(
      r'^\s*\[?(\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?)\]?\s*(.*)$',
    ).firstMatch(line);
    if (match != null) {
      final start = _clock(match.group(1)!);
      if (start != null) {
        sawTiming = true;
        final body = _splitSpeaker(match.group(2)!);
        if (body.text.trim().isEmpty) {
          // Keep a timestamp-only line for the following text instead of
          // persisting an empty segment that decode would reject.
          pendingStart = start;
          pendingSpeaker = body.speaker;
          continue;
        }
        segments.add(
          MinutesSegment(
            text: body.text,
            start: start,
            speaker: body.speaker ?? pendingSpeaker,
          ),
        );
        pendingStart = null;
        pendingSpeaker = null;
        continue;
      }
    }
    if (segments.isNotEmpty) {
      final body = _splitSpeaker(line.trim());
      if (pendingStart != null) {
        segments.add(
          MinutesSegment(
            text: body.text,
            start: pendingStart,
            speaker: body.speaker ?? pendingSpeaker,
          ),
        );
        pendingStart = null;
        pendingSpeaker = null;
        continue;
      }
      final previous = segments.removeLast();
      if (body.speaker != null && body.speaker != previous.speaker) {
        segments.add(previous);
        segments.add(
          MinutesSegment(
            text: body.text,
            start: previous.start,
            speaker: body.speaker,
          ),
        );
        continue;
      }
      segments.add(
        MinutesSegment(
          text: '${previous.text}\n${body.text}',
          start: previous.start,
          speaker: body.speaker ?? previous.speaker,
        ),
      );
    } else {
      if (pendingStart == null) untimed++;
      final body = _splitSpeaker(line.trim());
      segments.add(
        MinutesSegment(
          text: body.text,
          start: pendingStart ?? Duration.zero,
          speaker: body.speaker ?? pendingSpeaker,
        ),
      );
      pendingStart = null;
      pendingSpeaker = null;
    }
  }
  if (segments.isEmpty) throw const FormatException('没有找到可导入的文字段');
  final reliable = sawTiming && _timingsReliable(segments);
  return MinutesParseResult(
    MinutesDocument(
      id: _contentId(raw),
      title: _fileStem(fileName),
      sourceName: p.basename(fileName),
      importedAt: DateTime.now(),
      segments: List.unmodifiable(segments),
      timingReliable: reliable,
      warning: reliable
          ? null
          : sawTiming
          ? '部分行没有时码或时码顺序不可靠，只能整段阅读。'
          : untimed == 0
          ? '导入文字没有时码，只能阅读。'
          : '导入文字没有时码，只能阅读。',
    ),
  );
}

({String text, String? speaker}) _splitSpeaker(String value) {
  final match = RegExp(
    r'^\s*((?:说话人\s*\d+)|[^\s：:]{1,12})\s*[：:]\s*(.*)$',
  ).firstMatch(value);
  if (match == null) return (text: value.trim(), speaker: null);
  final speaker = match.group(1)!.trim();
  final text = match.group(2)!.trim();
  if (text.isEmpty) return (text: value.trim(), speaker: null);
  return (text: text, speaker: speaker);
}

bool _timingsReliable(List<MinutesSegment> segments) {
  if (segments.length < 2) return false;
  var previous = -1;
  var nonZero = false;
  for (final segment in segments) {
    final start = segment.start.inMilliseconds;
    if (start <= previous) return false;
    final end = segment.end?.inMilliseconds;
    if (end != null && end < start) return false;
    if (start > 0) nonZero = true;
    previous = start;
  }
  return nonZero;
}

Duration? _duration(Object? value, {required bool millisecondsHint}) {
  if (value == null) return null;
  if (value is num) {
    if (value < 0) return null;
    final milliseconds = millisecondsHint || value > 100000
        ? value.toInt()
        : (value * 1000).round();
    return Duration(milliseconds: milliseconds);
  }
  if (value is String) return _clock(value);
  return null;
}

Duration? _clock(String value) {
  final text = value.trim().replaceAll(',', '.');
  final match = RegExp(
    r'^(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,3}))?$',
  ).firstMatch(text);
  if (match == null) return null;
  final first = int.parse(match.group(1)!);
  final second = int.parse(match.group(2)!);
  final third = int.tryParse(match.group(3) ?? '');
  final fraction = int.tryParse((match.group(4) ?? '').padRight(3, '0')) ?? 0;
  if (third != null) {
    return Duration(
      hours: first,
      minutes: second,
      seconds: third,
      milliseconds: fraction,
    );
  }
  return Duration(minutes: first, seconds: second, milliseconds: fraction);
}

Object? _firstValue(Map<dynamic, dynamic> value, List<String> keys) {
  for (final key in keys) {
    if (value.containsKey(key) && value[key] != null) return value[key];
  }
  return null;
}

MapEntry<String, Object?>? _firstEntry(
  Map<dynamic, dynamic> value,
  List<String> keys,
) {
  for (final key in keys) {
    if (value.containsKey(key) && value[key] != null) {
      return MapEntry(key, value[key]);
    }
  }
  return null;
}

String? _firstText(Map<dynamic, dynamic> value, List<String> keys) {
  final raw = _firstValue(value, keys);
  if (raw is! String || raw.trim().isEmpty) return null;
  return raw.trim();
}

DateTime? _firstDate(Map<dynamic, dynamic> value, List<String> keys) {
  final raw = _firstValue(value, keys);
  if (raw is! String && raw is! num) return null;
  if (raw is num) {
    final milliseconds = raw > 10000000000 ? raw.toInt() : (raw * 1000).round();
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
  return DateTime.tryParse(raw as String);
}

List<dynamic>? _firstList(Map<dynamic, dynamic> value, List<String> keys) {
  final raw = _firstValue(value, keys);
  return raw is List ? raw : null;
}

String _fileStem(String fileName) {
  final stem = p.basenameWithoutExtension(fileName).trim();
  return stem.isEmpty ? '导入的文字' : stem;
}

/// Stable content fingerprint used to avoid importing the same export twice.
String _contentId(String raw) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(raw.trim())) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

class MinutesDocumentStore {
  MinutesDocumentStore({this.file, this.inMemory = false});

  static const fileName = 'minutes_documents.json';

  final File? file;
  final bool inMemory;
  final Map<String, MinutesDocument> _documents = {};
  Future<void> _pendingSave = Future<void>.value();

  String? recoveryNotice;
  String? saveError;

  List<MinutesDocument> get documents => List.unmodifiable(_documents.values);

  MinutesDocument? byId(String id) => _documents[id];

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
        recoveryNotice = '导入文字记录无法读取，原文字文件仍保留';
        return;
      }
      _documents.addAll(decoded);
    } catch (error) {
      recoveryNotice = '导入文字记录无法读取，原文字文件仍保留';
      debugPrint('[MinutesDocumentStore] load failed: $error');
    }
  }

  @visibleForTesting
  static Map<String, MinutesDocument>? decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final entries = value['documents'];
      if (entries is! List) return null;
      final output = <String, MinutesDocument>{};
      for (final entry in entries) {
        final document = MinutesDocument.decode(entry);
        if (document != null) output[document.id] = document;
      }
      return output;
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static Map<String, Object?> encode(Iterable<MinutesDocument> documents) => {
    'version': 1,
    'documents': documents.map((document) => document.toJson()).toList(),
  };

  Future<void> upsert(MinutesDocument document, {bool strict = true}) async {
    final previous = _documents[document.id];
    _documents[document.id] = document;
    try {
      await save(strict: strict);
    } catch (_) {
      if (previous == null) {
        _documents.remove(document.id);
      } else {
        _documents[document.id] = previous;
      }
      rethrow;
    }
  }

  Future<void> remove(String id, {bool strict = true}) async {
    final previous = _documents.remove(id);
    try {
      await save(strict: strict);
    } catch (_) {
      if (previous != null) _documents[id] = previous;
      rethrow;
    }
  }

  Future<void> updateAudioPath(String oldPath, String newPath) async {
    final previous = Map<String, MinutesDocument>.of(_documents);
    var changed = false;
    for (final entry in _documents.entries.toList()) {
      if (entry.value.audioPath != oldPath) continue;
      _documents[entry.key] = entry.value.copyWith(audioPath: newPath);
      changed = true;
    }
    if (!changed) return;
    try {
      await save(strict: true);
    } catch (_) {
      _documents
        ..clear()
        ..addAll(previous);
      rethrow;
    }
  }

  Future<void> clearAudioForPaths(Set<String> paths) async {
    final previous = Map<String, MinutesDocument>.of(_documents);
    var changed = false;
    for (final entry in _documents.entries.toList()) {
      final path = entry.value.audioPath;
      if (path == null || !paths.contains(path)) continue;
      _documents[entry.key] = entry.value.copyWith(clearAudio: true);
      changed = true;
    }
    if (!changed) return;
    try {
      await save(strict: true);
    } catch (_) {
      _documents
        ..clear()
        ..addAll(previous);
      rethrow;
    }
  }

  Future<void> save({bool strict = true}) {
    if (inMemory) return Future<void>.value();
    final snapshot = List<MinutesDocument>.of(_documents.values);
    final operation = _pendingSave.then((_) => _write(snapshot, strict));
    _pendingSave = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(List<MinutesDocument> snapshot, bool strict) async {
    try {
      final target = await _file();
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(encode(snapshot)),
        flush: true,
      );
      await temporary.rename(target.path);
      saveError = null;
    } catch (error) {
      saveError = '导入文字保存失败';
      debugPrint('[MinutesDocumentStore] save failed: $error');
      if (strict) rethrow;
    }
  }
}
