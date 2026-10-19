import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/off_ui.dart';
import 'atomic_file.dart';
import 'recording.dart';

typedef TranscriptStoreData = ({
  Map<String, String> byPath,
  Map<int, String> byFileId,
  Map<String, Map<String, String>> aliasesByPath,
  Map<int, Map<String, String>> aliasesByFileId,
  Map<String, TranscriptMetadata> metadata,
  Map<String, RecordingTranslation> translations,
  Map<String, List<TranscriptSegment>> segments,
  Map<String, String> manualByKey,
  Map<String, String> incomingByKey,
  Map<String, Map<int, String>> segmentSpeakersByKey,
});

/// Persists completed per-recording transcripts on the app device.
class TranscriptStore {
  TranscriptStore._();

  static const _fileName = 'transcripts.json';
  static Future<void> _pendingSave = Future<void>.value();

  /// The save waiting behind the running one. Later saves replace its
  /// snapshot, so a burst of saves writes only the newest state.
  static _QueuedSave? _queued;

  /// Length of the last file read or written, used to decide whether the
  /// next encode runs on a background isolate.
  static int _lastLength = 0;

  /// Files at least this many characters long are encoded off the UI isolate.
  static const backgroundEncodeThreshold = 256 * 1024;

  static Future<File> _file() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'AnkerRecorder'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, _fileName));
  }

  static TranscriptStoreData _emptyData() => (
    byPath: <String, String>{},
    byFileId: <int, String>{},
    aliasesByPath: <String, Map<String, String>>{},
    aliasesByFileId: <int, Map<String, String>>{},
    metadata: <String, TranscriptMetadata>{},
    translations: <String, RecordingTranslation>{},
    segments: <String, List<TranscriptSegment>>{},
    manualByKey: <String, String>{},
    incomingByKey: <String, String>{},
    segmentSpeakersByKey: <String, Map<int, String>>{},
  );

  static Future<TranscriptStoreData> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return _emptyData();
      final text = await file.readAsString();
      _lastLength = text.length;
      final json = jsonDecode(text);
      return decode(json);
    } catch (e) {
      debugPrint('[TranscriptStore] load failed: $e');
      return _emptyData();
    }
  }

  @visibleForTesting
  static TranscriptStoreData decode(Object? json) {
    if (json is! Map) return _emptyData();

    final byPath = <String, String>{};
    final paths = json['byPath'];
    if (paths is Map) {
      for (final entry in paths.entries) {
        final text = entry.value;
        if (text is String && text.isNotEmpty) {
          byPath['${entry.key}'] = text;
        }
      }
    }

    final byFileId = <int, String>{};
    final ids = json['byFileId'];
    if (ids is Map) {
      for (final entry in ids.entries) {
        final id = int.tryParse('${entry.key}');
        final text = entry.value;
        if (id != null && text is String && text.isNotEmpty) {
          byFileId[id] = text;
        }
      }
    }

    final aliasesByPath = _decodeAliases<String>(
      json['aliasesByPath'],
      (key) => '$key',
    );
    final aliasesByFileId = _decodeAliases<int>(
      json['aliasesByFileId'],
      (key) => int.tryParse('$key'),
    );
    return (
      byPath: byPath,
      byFileId: byFileId,
      aliasesByPath: aliasesByPath,
      aliasesByFileId: aliasesByFileId,
      metadata: _decodeMetadata(json['metadata']),
      translations: _decodeTranslations(json['translations']),
      segments: _decodeSegments(json['segments']),
      manualByKey: _decodeTextByKey(json['manualByKey']),
      incomingByKey: _decodeTextByKey(json['incomingByKey']),
      segmentSpeakersByKey: _decodeSegmentSpeakers(
        json['segmentSpeakersByKey'],
      ),
    );
  }

  static Map<String, String> _decodeTextByKey(Object? value) {
    if (value is! Map) return {};
    return {
      for (final entry in value.entries)
        if (entry.key is String &&
            entry.value is String &&
            (entry.value as String).trim().isNotEmpty)
          entry.key as String: (entry.value as String).trim(),
    };
  }

  static Map<String, Map<int, String>> _decodeSegmentSpeakers(Object? value) {
    if (value is! Map) return {};
    final output = <String, Map<int, String>>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final overrides = <int, String>{};
      for (final item in (entry.value as Map).entries) {
        final index = int.tryParse('${item.key}');
        final speaker = item.value;
        if (index == null || index < 0 || speaker is! String) continue;
        overrides[index] = speaker.trim();
      }
      if (overrides.isNotEmpty) output[entry.key as String] = overrides;
    }
    return output;
  }

  static Map<String, List<TranscriptSegment>> _decodeSegments(Object? value) {
    if (value is! Map) return {};
    final output = <String, List<TranscriptSegment>>{};
    for (final entry in value.entries) {
      final key = entry.key;
      final raw = entry.value;
      if (key is! String || raw is! List) continue;
      final segments = raw
          .map(TranscriptSegment.decode)
          .whereType<TranscriptSegment>()
          .toList(growable: false);
      if (segments.isNotEmpty && segments.length == raw.length) {
        output[key] = segments;
      }
    }
    return output;
  }

  static Map<String, TranscriptMetadata> _decodeMetadata(Object? value) {
    if (value is! Map) return {};
    return {
      for (final entry in value.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: TranscriptMetadata.fromJson(entry.value as Map),
    };
  }

  static Map<String, RecordingTranslation> _decodeTranslations(Object? value) {
    final output = <String, RecordingTranslation>{};
    if (value is Map) {
      for (final entry in value.entries) {
        final translation = RecordingTranslation.decode(entry.value);
        if (entry.key is String && translation != null) {
          output[entry.key as String] = translation;
        }
      }
    }
    return output;
  }

  static Map<K, Map<String, String>> _decodeAliases<K>(
    Object? json,
    K? Function(Object? key) parseKey,
  ) {
    final decoded = <K, Map<String, String>>{};
    if (json is! Map) return decoded;
    for (final entry in json.entries) {
      final key = parseKey(entry.key);
      final rawAliases = entry.value;
      if (key == null || rawAliases is! Map) continue;
      final aliases = <String, String>{};
      for (final aliasEntry in rawAliases.entries) {
        final id = '${aliasEntry.key}'.trim();
        final alias = aliasEntry.value;
        if (id.isNotEmpty && alias is String && alias.trim().isNotEmpty) {
          aliases[id] = alias.trim();
        }
      }
      if (aliases.isNotEmpty) decoded[key] = aliases;
    }
    return decoded;
  }

  static Future<void> save({
    required Map<String, String> byPath,
    required Map<int, String> byFileId,
    required Map<String, Map<String, String>> aliasesByPath,
    required Map<int, Map<String, String>> aliasesByFileId,
    Map<String, TranscriptMetadata> metadata = const {},
    Map<String, RecordingTranslation> translations = const {},
    Map<String, List<TranscriptSegment>> segments = const {},
    Map<String, String> manualByKey = const {},
    Map<String, String> incomingByKey = const {},
    Map<String, Map<int, String>> segmentSpeakersByKey = const {},
    bool strict = false,
  }) {
    final paths = Map<String, String>.from(byPath);
    final ids = Map<int, String>.from(byFileId);
    final pathAliases = _copyAliases(aliasesByPath);
    final idAliases = _copyAliases(aliasesByFileId);
    final meta = Map<String, TranscriptMetadata>.from(metadata);
    final translated = Map<String, RecordingTranslation>.from(translations);
    final timed = <String, List<TranscriptSegment>>{
      for (final entry in segments.entries)
        if (entry.value.isNotEmpty)
          entry.key: List<TranscriptSegment>.unmodifiable(entry.value),
    };
    final manual = Map<String, String>.from(manualByKey);
    final incoming = Map<String, String>.from(incomingByKey);
    final speakers = {
      for (final entry in segmentSpeakersByKey.entries)
        if (entry.value.isNotEmpty)
          entry.key: Map<int, String>.from(entry.value),
    };
    final snapshot = _Snapshot(
      paths,
      ids,
      pathAliases,
      idAliases,
      meta,
      translated,
      timed,
      manual,
      incoming,
      speakers,
    );
    var queued = _queued;
    if (queued != null) {
      // Not started yet: it writes this newer snapshot instead.
      queued.snapshot = snapshot;
    } else {
      final next = queued = _queued = _QueuedSave(snapshot);
      _pendingSave = _pendingSave.then((_) async {
        if (identical(_queued, next)) _queued = null;
        try {
          await _write(next.snapshot);
          next.done.complete();
        } catch (error, stack) {
          next.done.completeError(error, stack);
        }
      });
    }
    final operation = queued.done.future;
    return strict ? operation : operation.catchError((Object _) {});
  }

  static Map<K, Map<String, String>> _copyAliases<K>(
    Map<K, Map<String, String>> source,
  ) => source.map(
    (key, aliases) => MapEntry(key, Map<String, String>.from(aliases)),
  );

  @visibleForTesting
  static Map<String, dynamic> encode({
    required Map<String, String> byPath,
    required Map<int, String> byFileId,
    required Map<String, Map<String, String>> aliasesByPath,
    required Map<int, Map<String, String>> aliasesByFileId,
    Map<String, TranscriptMetadata> metadata = const {},
    Map<String, RecordingTranslation> translations = const {},
    Map<String, List<TranscriptSegment>> segments = const {},
    Map<String, String> manualByKey = const {},
    Map<String, String> incomingByKey = const {},
    Map<String, Map<int, String>> segmentSpeakersByKey = const {},
  }) => <String, dynamic>{
    'version': 4,
    'byPath': byPath,
    'byFileId': byFileId.map((id, text) => MapEntry('$id', text)),
    'aliasesByPath': aliasesByPath,
    'aliasesByFileId': aliasesByFileId.map(
      (id, aliases) => MapEntry('$id', aliases),
    ),
    'metadata': metadata.map((key, value) => MapEntry(key, value.toJson())),
    'translations': translations.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'segments': segments.map(
      (key, value) => MapEntry(key, value.map((s) => s.toJson()).toList()),
    ),
    'manualByKey': manualByKey,
    'incomingByKey': incomingByKey,
    'segmentSpeakersByKey': segmentSpeakersByKey.map(
      (key, value) => MapEntry(
        key,
        value.map((index, speaker) => MapEntry('$index', speaker)),
      ),
    ),
  };

  static Future<void> _write(_Snapshot snapshot) async {
    try {
      final file = await _file();
      String encodeSnapshot() => jsonEncode(
        encode(
          byPath: snapshot.byPath,
          byFileId: snapshot.byFileId,
          aliasesByPath: snapshot.aliasesByPath,
          aliasesByFileId: snapshot.aliasesByFileId,
          metadata: snapshot.metadata,
          translations: snapshot.translations,
          segments: snapshot.segments,
          manualByKey: snapshot.manualByKey,
          incomingByKey: snapshot.incomingByKey,
          segmentSpeakersByKey: snapshot.segmentSpeakersByKey,
        ),
      );
      final contents = await runOffUi(
        encodeSnapshot,
        size: _lastLength,
        threshold: backgroundEncodeThreshold,
        debugName: 'TranscriptStore.encode',
      );
      _lastLength = contents.length;
      await writeFileAtomically(file, contents);
    } catch (e) {
      debugPrint('[TranscriptStore] save failed: $e');
      rethrow;
    }
  }
}

class _Snapshot {
  const _Snapshot(
    this.byPath,
    this.byFileId,
    this.aliasesByPath,
    this.aliasesByFileId,
    this.metadata,
    this.translations,
    this.segments,
    this.manualByKey,
    this.incomingByKey,
    this.segmentSpeakersByKey,
  );

  final Map<String, String> byPath;
  final Map<int, String> byFileId;
  final Map<String, Map<String, String>> aliasesByPath;
  final Map<int, Map<String, String>> aliasesByFileId;
  final Map<String, TranscriptMetadata> metadata;
  final Map<String, RecordingTranslation> translations;
  final Map<String, List<TranscriptSegment>> segments;
  final Map<String, String> manualByKey;
  final Map<String, String> incomingByKey;
  final Map<String, Map<int, String>> segmentSpeakersByKey;
}

class _QueuedSave {
  _QueuedSave(this.snapshot);

  _Snapshot snapshot;
  final done = Completer<void>();
}
