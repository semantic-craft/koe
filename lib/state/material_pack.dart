import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';

import '../ai/speech_provider.dart';
import '../ai/stt_types.dart';
import '../archive/archive_atomic_link.dart';
import 'recording.dart';
import 'recording_analysis.dart';
import 'meeting_minutes.dart';
import 'recording_bookmarks.dart';
import 'recording_library.dart';
import 'topic_store.dart';

/// A restorable material pack (`.koepack`, format in docs/material-pack.md).
///
/// One recording per pack: what it is (content digest, recorder file id),
/// its transcript with timecodes, speakers, corrections and translation, its
/// bookmarks, place and topic, and optionally the original audio. Nothing in
/// it names a file on the exporting device, a key, or pairing data, so it can
/// be restored on another device or after a reinstall.
class MaterialPack {
  const MaterialPack({
    required this.exportedAt,
    required this.material,
    required this.transcript,
    this.bookmarks = const [],
    this.topic,
    this.audio,
    this.minutes,
  });

  static const formatName = 'koe-material-pack';
  static const version = 2;
  static const extension = '.koepack';

  /// First line of every pack; anything else is not a pack.
  static const magic = 'KOEPACK1';

  /// Manifests are small; a larger header means a damaged or foreign file.
  static const maxManifestBytes = 32 * 1024 * 1024;

  final DateTime exportedAt;
  final PackMaterial material;
  final PackTranscript? transcript;
  final List<PackBookmark> bookmarks;
  final PackTopic? topic;

  /// The original audio carried after the manifest, or null for a pack
  /// without audio.
  final PackAudio? audio;

  final PackMinutes? minutes;

  bool get includesAudio => audio != null;

  Map<String, Object?> toJson() => {
    'format': formatName,
    'version': minutes == null ? 1 : version,
    'exportedAt': exportedAt.toIso8601String(),
    'material': material.toJson(),
    if (transcript != null) 'transcript': transcript!.toJson(),
    if (bookmarks.isNotEmpty)
      'bookmarks': [for (final bookmark in bookmarks) bookmark.toJson()],
    if (topic != null) 'topic': topic!.toJson(),
    if (minutes != null) 'minutes': minutes!.toJson(),
    'audio': audio == null ? {'included': false} : audio!.toJson(),
  };

  /// Reads a manifest written by [toJson]. Throws [MaterialPackException]
  /// naming what is missing instead of restoring a partial record.
  static MaterialPack fromJson(Object? value) {
    if (value is! Map) throw const MaterialPackException('资料包说明无法读取');
    if (value['format'] != formatName) {
      throw const MaterialPackException('这不是 Koe 资料包');
    }
    final packVersion = value['version'];
    if (packVersion is! int || packVersion < 1 || packVersion > version) {
      throw const MaterialPackException('资料包来自更新版本的 Koe，请先更新 App');
    }
    if (packVersion == 1 && value.containsKey('minutes')) {
      throw const MaterialPackException('旧版资料包不能携带纪要，请重新导出');
    }
    final minutes = value['minutes'] == null
        ? null
        : PackMinutes.decode(value['minutes']);
    final exportedAt = DateTime.tryParse('${value['exportedAt']}');
    final material = PackMaterial.decode(value['material']);
    if (exportedAt == null || material == null) {
      throw const MaterialPackException('资料包缺少资料身份');
    }
    final rawTranscript = value['transcript'];
    final transcript = rawTranscript == null
        ? null
        : PackTranscript.decode(rawTranscript);
    if (rawTranscript != null && transcript == null) {
      throw const MaterialPackException('资料包里的正文不完整');
    }
    final rawBookmarks = value['bookmarks'];
    final bookmarks = <PackBookmark>[];
    if (rawBookmarks != null) {
      if (rawBookmarks is! List) {
        throw const MaterialPackException('资料包里的书签不完整');
      }
      for (final raw in rawBookmarks) {
        final bookmark = PackBookmark.decode(raw);
        if (bookmark == null) {
          throw const MaterialPackException('资料包里的书签不完整');
        }
        bookmarks.add(bookmark);
      }
    }
    final rawAudio = value['audio'];
    PackAudio? audio;
    if (rawAudio is Map && rawAudio['included'] == true) {
      audio = PackAudio.decode(rawAudio);
      if (audio == null || audio.sha256 != material.contentHash) {
        throw const MaterialPackException('资料包里的原音频说明不完整');
      }
    } else if (rawAudio is! Map) {
      throw const MaterialPackException('资料包没有说明是否包含原音频');
    }
    return MaterialPack(
      exportedAt: exportedAt,
      material: material,
      transcript: transcript,
      bookmarks: bookmarks,
      topic: PackTopic.decode(value['topic']),
      audio: audio,
      minutes: minutes,
    );
  }
}

/// Current structured minutes plus a bounded portable history. Only local
/// recording keys are remapped during import; source hashes remain evidence.
class PackMinutes {
  const PackMinutes({required this.current, this.history = const []});
  static const maxHistory = 10;
  final AnalysisResult current;
  final List<AnalysisResult> history;

  Map<String, Object?> toJson() => {
    'current': current.toPortableJson(),
    'history': [for (final item in history) item.toPortableJson()],
  };

  static PackMinutes decode(Object? value) {
    if (value is! Map ||
        value['history'] is! List ||
        (value['history'] as List).length > maxHistory) {
      throw const MaterialPackException('资料包里的纪要历史不完整或超过10版');
    }
    return PackMinutes(
      current: _result(value['current']),
      history: List.unmodifiable((value['history'] as List).map(_result)),
    );
  }

  static AnalysisResult _result(Object? value) {
    try {
      if (value is! Map) throw const FormatException();
      String text(String key, {bool empty = true}) {
        final raw = value[key];
        if (raw is! String || (!empty && raw.trim().isEmpty)) {
          throw const FormatException();
        }
        return raw;
      }

      DateTime date(String key) {
        final raw = text(key, empty: false);
        final result = DateTime.tryParse(raw);
        if (result == null) throw const FormatException();
        return result;
      }

      final rawSources = value['sources'];
      if (rawSources is! List || rawSources.any((s) => s is! String)) {
        throw const FormatException();
      }
      final sources = List<String>.from(rawSources);
      final sourceHash = text('sourceHash');
      if (!_sha256Hex.hasMatch(sourceHash)) throw const FormatException();
      final templateVersion = value['templateVersion'];
      if (templateVersion is! int ||
          templateVersion < 1 ||
          value['isDraft'] is! bool) {
        throw const FormatException();
      }
      if (value['templateId'] != null && value['templateId'] is! String) {
        throw const FormatException();
      }
      final minutes = validateMinutes(text('text', empty: false), sources);
      return AnalysisResult(
        text: minutes,
        sourceHash: sourceHash,
        model: text('model', empty: false),
        instruction: text('instruction'),
        sources: List.unmodifiable(sources),
        createdAt: date('createdAt'),
        editedAt: value['editedAt'] == null ? null : date('editedAt'),
        templateId: value['templateId'] as String?,
        templateVersion: templateVersion,
        isDraft: value['isDraft'] as bool,
      );
    } catch (_) {
      throw const MaterialPackException('资料包里的纪要或原文依据无法校验，未导入');
    }
  }
}

/// A pack that cannot be used; [message] is shown as is.
class MaterialPackException implements Exception {
  const MaterialPackException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The user cancelled while the pack was written.
class MaterialPackCancelled implements Exception {
  const MaterialPackCancelled();
}

/// What the material is, independent of where it is stored.
class PackMaterial {
  const PackMaterial({
    required this.contentHash,
    required this.title,
    required this.source,
    this.deviceFileId,
    this.recordedAt,
    this.place,
    this.audioExtension,
  });

  /// SHA-256 of the original audio (`audioVersion`): the identity used to
  /// find the same material again and to check a later audio pairing.
  final String contentHash;
  final String title;
  final RecordingSource source;

  /// The recorder's own file number, for a device recording.
  final int? deviceFileId;
  final DateTime? recordedAt;
  final RecordingPlace? place;

  /// Extension of the original (`.wav`, `.m4a`, …), so a pack without audio
  /// can still say what to pair.
  final String? audioExtension;

  Map<String, Object?> toJson() => {
    'contentHash': contentHash,
    'title': title,
    'source': source.name,
    if (deviceFileId != null) 'deviceFileId': deviceFileId,
    if (recordedAt != null) 'recordedAt': recordedAt!.toIso8601String(),
    if (place != null) 'place': place!.toJson(),
    if (audioExtension != null) 'audioExtension': audioExtension,
  };

  static PackMaterial? decode(Object? value) {
    if (value is! Map) return null;
    final hash = value['contentHash'];
    final title = value['title'];
    if (hash is! String || !_sha256Hex.hasMatch(hash)) return null;
    if (title is! String || title.trim().isEmpty) return null;
    final source =
        RecordingSource.values
            .where((item) => item.name == value['source'])
            .firstOrNull ??
        RecordingSource.localImport;
    final extension = value['audioExtension'];
    return PackMaterial(
      contentHash: hash,
      title: title.trim(),
      source: source,
      deviceFileId: value['deviceFileId'] is int
          ? value['deviceFileId'] as int
          : null,
      recordedAt: value['recordedAt'] is String
          ? DateTime.tryParse(value['recordedAt'] as String)
          : null,
      place: RecordingPlace.decode(value['place']),
      audioExtension: extension is String && _extension.hasMatch(extension)
          ? extension.toLowerCase()
          : null,
    );
  }
}

/// Everything the transcript of one material holds, keyed by nothing local.
class PackTranscript {
  const PackTranscript({
    this.text,
    this.manual,
    this.segments = const [],
    this.segmentSpeakers = const {},
    this.speakerAliases = const {},
    this.provider,
    this.sourceLanguage,
    this.revision = 0,
    this.translation,
  });

  /// The provider's text, before any correction.
  final String? text;

  /// The user's corrected text, when they edited it.
  final String? manual;

  /// Provider-timed segments as stored (speaker fixes kept separately).
  final List<TranscriptSegment> segments;

  /// Segment index → corrected speaker id.
  final Map<int, String> segmentSpeakers;

  /// Speaker id → name the user gave.
  final Map<String, String> speakerAliases;
  final SttProvider? provider;
  final String? sourceLanguage;
  final int revision;
  final RecordingTranslation? translation;

  /// The text a reader sees, before speaker names are applied.
  String? get visible => manual ?? text;

  bool get isEmpty => (visible ?? '').trim().isEmpty && segments.isEmpty;

  Map<String, Object?> toJson() => {
    if (text != null) 'text': text,
    if (manual != null) 'manual': manual,
    if (segments.isNotEmpty)
      'segments': [for (final segment in segments) segment.toJson()],
    if (segmentSpeakers.isNotEmpty)
      'segmentSpeakers': segmentSpeakers.map(
        (index, speaker) => MapEntry('$index', speaker),
      ),
    if (speakerAliases.isNotEmpty) 'speakerAliases': speakerAliases,
    if (provider != null) 'provider': provider!.name,
    if (sourceLanguage != null) 'sourceLanguage': sourceLanguage,
    'revision': revision,
    if (translation != null) 'translation': translation!.toJson(),
  };

  static PackTranscript? decode(Object? value) {
    if (value is! Map) return null;
    String? text(Object? raw) =>
        raw is String && raw.trim().isNotEmpty ? raw : null;
    final rawSegments = value['segments'];
    final segments = <TranscriptSegment>[];
    if (rawSegments != null) {
      if (rawSegments is! List) return null;
      for (final raw in rawSegments) {
        final segment = TranscriptSegment.decode(raw);
        // One unreadable segment shifts every later index the speaker fixes
        // and bookmarks refer to, so the whole transcript is refused.
        if (segment == null) return null;
        segments.add(segment);
      }
    }
    final speakers = <int, String>{};
    final rawSpeakers = value['segmentSpeakers'];
    if (rawSpeakers is Map) {
      for (final entry in rawSpeakers.entries) {
        final index = int.tryParse('${entry.key}');
        if (index == null ||
            index < 0 ||
            index >= segments.length ||
            entry.value is! String) {
          return null;
        }
        speakers[index] = (entry.value as String).trim();
      }
    }
    final aliases = <String, String>{};
    final rawAliases = value['speakerAliases'];
    if (rawAliases is Map) {
      for (final entry in rawAliases.entries) {
        final id = '${entry.key}'.trim();
        final alias = entry.value;
        if (id.isNotEmpty && alias is String && alias.trim().isNotEmpty) {
          aliases[id] = alias.trim();
        }
      }
    }
    final transcript = PackTranscript(
      text: text(value['text']),
      manual: text(value['manual']),
      segments: List.unmodifiable(segments),
      segmentSpeakers: Map.unmodifiable(speakers),
      speakerAliases: Map.unmodifiable(aliases),
      provider: SttProvider.parse(value['provider']),
      sourceLanguage: value['sourceLanguage'] is String
          ? value['sourceLanguage'] as String
          : null,
      revision: value['revision'] is int ? value['revision'] as int : 0,
      translation: RecordingTranslation.decode(value['translation']),
    );
    return transcript.isEmpty ? null : transcript;
  }

  /// Segments as a reader sees them: speaker fixes applied and a label shown
  /// where the speaker changes, the same rule the transcript reader uses.
  List<TranscriptSegment> get effectiveSegments {
    final output = <TranscriptSegment>[];
    String? previous;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final raw = segmentSpeakers[index] ?? segment.speaker;
      final speaker = raw == null || raw.isEmpty ? null : raw;
      output.add(
        segment.copyWith(
          speaker: speaker,
          clearSpeaker: speaker == null,
          speakerChanged: speaker != null && speaker != previous,
        ),
      );
      previous = speaker;
    }
    return output;
  }
}

/// A bookmark without the local recording key it was saved under.
class PackBookmark {
  const PackBookmark(this.bookmark);
  final RecordingBookmark bookmark;

  Map<String, Object?> toJson() => bookmark.toJson()..remove('recordingKey');

  static PackBookmark? decode(Object? value) {
    if (value is! Map) return null;
    final bookmark = RecordingBookmark.decode({
      ...value,
      'recordingKey': 'pack',
    });
    return bookmark == null ? null : PackBookmark(bookmark);
  }

  /// The same bookmark filed under [recordingKey] in this library.
  RecordingBookmark under(String recordingKey, {String? id}) =>
      RecordingBookmark(
        id: id ?? bookmark.id,
        recordingKey: recordingKey,
        position: bookmark.position,
        note: bookmark.note,
        segmentText: bookmark.segmentText,
        segmentStart: bookmark.segmentStart,
        segmentEnd: bookmark.segmentEnd,
        transcriptRevision: bookmark.transcriptRevision,
        audioVersion: bookmark.audioVersion,
        createdAt: bookmark.createdAt,
        updatedAt: bookmark.updatedAt,
      );
}

/// The topic the material sat in, matched by name on import.
class PackTopic {
  const PackTopic({required this.title, required this.kind, this.author = ''});
  final String title;
  final TopicKind kind;
  final String author;

  Map<String, Object?> toJson() => {
    'title': title,
    'kind': kind.name,
    if (author.isNotEmpty) 'author': author,
  };

  static PackTopic? decode(Object? value) {
    if (value is! Map) return null;
    final title = value['title'];
    final kind = TopicKind.values
        .where((item) => item.name == value['kind'])
        .firstOrNull;
    if (title is! String || title.trim().isEmpty || kind == null) return null;
    return PackTopic(
      title: title.trim(),
      kind: kind,
      author: value['author'] is String ? value['author'] as String : '',
    );
  }
}

/// The original audio stored after the manifest.
class PackAudio {
  const PackAudio({
    required this.extension,
    required this.bytes,
    required this.sha256,
  });

  final String extension;
  final int bytes;
  final String sha256;

  Map<String, Object?> toJson() => {
    'included': true,
    'extension': extension,
    'bytes': bytes,
    'sha256': sha256,
  };

  static PackAudio? decode(Map value) {
    final extension = value['extension'];
    final bytes = value['bytes'];
    final hash = value['sha256'];
    if (extension is! String || !_extension.hasMatch(extension)) return null;
    if (bytes is! int || bytes <= 0) return null;
    if (hash is! String || !_sha256Hex.hasMatch(hash)) return null;
    return PackAudio(
      extension: extension.toLowerCase(),
      bytes: bytes,
      sha256: hash,
    );
  }
}

final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');
final _extension = RegExp(r'^\.[A-Za-z0-9]{1,8}$');

/// Publishes a verified replacement for a missing original without overwriting
/// a target created concurrently. The caller removes its staging file.
void publishPackAudio(String stagedPath, String targetPath) {
  try {
    archiveAtomicLinkNoReplace(stagedPath, targetPath);
  } catch (_) {
    throw const MaterialPackException('原音频未发布：目标已存在或无法原子恢复，请检查后重试');
  }
}

/// Writes [pack] (and [audioPath] when the pack includes audio) to [target]
/// through a `.part` file, so a cancelled or failed export never leaves a
/// file that looks finished. [cancelled] is checked between chunks.
Future<void> writeMaterialPack(
  MaterialPack pack,
  File target, {
  String? audioPath,
  bool Function()? cancelled,
}) async {
  if (pack.includesAudio && audioPath == null) {
    throw ArgumentError('audioPath is required for a pack with audio');
  }
  final partial = File('${target.path}.part');
  IOSink? sink;
  try {
    await partial.parent.create(recursive: true);
    sink = partial.openWrite();
    final manifest = utf8.encode(jsonEncode(pack.toJson()));
    if (manifest.length > MaterialPack.maxManifestBytes) {
      throw const MaterialPackException('资料包文字与纪要超过32 MiB，无法导出');
    }
    sink.add(utf8.encode('${MaterialPack.magic}\n${manifest.length}\n'));
    sink.add(manifest);
    if (pack.includesAudio) {
      var written = 0;
      await for (final chunk in File(audioPath!).openRead()) {
        if (cancelled?.call() == true) throw const MaterialPackCancelled();
        sink.add(chunk);
        written += chunk.length;
      }
      if (written != pack.audio!.bytes) {
        throw const MaterialPackException('原音频在导出时发生变化，请重试');
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (cancelled?.call() == true) throw const MaterialPackCancelled();
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  } catch (_) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
    rethrow;
  }
}

/// A pack read back from disk. When it carries audio, the audio has been
/// copied out to [audioFile] and its length and digest checked.
class OpenedMaterialPack {
  const OpenedMaterialPack(this.pack, {this.audioFile});
  final MaterialPack pack;
  final File? audioFile;

  Future<void> discard() async {
    try {
      final file = audioFile;
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Reads and checks the pack at [path]. The audio, if any, is written to a
/// new file in [workDirectory] named after the original's extension, so the
/// normal audio import can take it from there. Throws [MaterialPackException]
/// for a damaged, truncated or foreign file; nothing is left behind then.
Future<OpenedMaterialPack> openMaterialPack(
  String path, {
  required Directory workDirectory,
}) async {
  final file = File(path);
  RandomAccessFile? reader;
  File? audioFile;
  try {
    if (!await file.exists()) throw const MaterialPackException('所选文件不存在');
    reader = await file.open();
    final length = await reader.length();
    final header = await _readLine(reader, 16);
    if (header != MaterialPack.magic) {
      throw const MaterialPackException('这不是 Koe 资料包');
    }
    final sizeLine = await _readLine(reader, 16);
    final manifestBytes = int.tryParse(sizeLine ?? '');
    if (manifestBytes == null ||
        manifestBytes <= 0 ||
        manifestBytes > MaterialPack.maxManifestBytes) {
      throw const MaterialPackException('资料包已损坏：说明长度无法读取');
    }
    final manifestStart = await reader.position();
    if (manifestStart + manifestBytes > length) {
      throw const MaterialPackException('资料包不完整：说明被截断');
    }
    final Object? manifest;
    try {
      manifest = jsonDecode(utf8.decode(await reader.read(manifestBytes)));
    } on FormatException {
      throw const MaterialPackException('资料包已损坏：说明无法读取');
    }
    final pack = MaterialPack.fromJson(manifest);
    final audioStart = manifestStart + manifestBytes;
    final audio = pack.audio;
    if (audio == null) {
      if (length != audioStart) {
        throw const MaterialPackException('资料包已损坏：说明之后有多余内容');
      }
      return OpenedMaterialPack(pack);
    }
    if (length - audioStart != audio.bytes) {
      throw MaterialPackException(
        length - audioStart < audio.bytes ? '资料包不完整：原音频被截断' : '资料包已损坏：原音频长度不符',
      );
    }
    await workDirectory.create(recursive: true);
    audioFile = File(
      p.join(
        workDirectory.path,
        '${_safeName(pack.material.title)}${audio.extension}',
      ),
    );
    final sink = audioFile.openWrite();
    final digest = SHA256Digest();
    var remaining = audio.bytes;
    try {
      while (remaining > 0) {
        final chunk = await reader.read(
          remaining < 1 << 20 ? remaining : 1 << 20,
        );
        if (chunk.isEmpty) {
          throw const MaterialPackException('资料包不完整：原音频被截断');
        }
        digest.update(chunk, 0, chunk.length);
        sink.add(chunk);
        remaining -= chunk.length;
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    final output = Uint8List(digest.digestSize);
    digest.doFinal(output, 0);
    final hash = output.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    if (hash != audio.sha256) {
      throw const MaterialPackException('资料包已损坏：原音频校验不一致');
    }
    return OpenedMaterialPack(pack, audioFile: audioFile);
  } catch (error) {
    try {
      if (audioFile != null && await audioFile.exists()) {
        await audioFile.delete();
      }
    } catch (_) {}
    if (error is MaterialPackException) rethrow;
    if (error is FileSystemException) {
      throw MaterialPackException(
        isOutOfSpace(error) ? '存储空间不足，无法导入资料包' : '无法读取所选资料包',
      );
    }
    throw const MaterialPackException('无法读取所选资料包');
  } finally {
    await reader?.close();
  }
}

Future<String?> _readLine(RandomAccessFile reader, int maxBytes) async {
  final bytes = <int>[];
  while (bytes.length <= maxBytes) {
    final byte = await reader.readByte();
    if (byte < 0) return null;
    if (byte == 0x0a) return ascii.decode(bytes, allowInvalid: true);
    bytes.add(byte);
  }
  return null;
}

/// ENOSPC on Darwin and Linux.
bool isOutOfSpace(FileSystemException error) => error.osError?.errorCode == 28;

String _safeName(String title) {
  final safe = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (safe.isEmpty) return 'Koe 资料';
  return safe.length > 60 ? safe.substring(0, 60) : safe;
}

/// File name for an export of [title] with [extension].
String materialExportFileName(String title, String extension) =>
    '${_safeName(title)}$extension';

/// The reading copy: Markdown text for people, not for restoring.
String renderReadingText(MaterialPack pack, {DateTime? now}) {
  String two(int value) => value.toString().padLeft(2, '0');
  String time(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  final material = pack.material;
  final transcript = pack.transcript;
  final aliases = transcript?.speakerAliases ?? const <String, String>{};
  final buffer = StringBuffer('# ${material.title}\n\n');
  final recordedAt = material.recordedAt;
  if (recordedAt != null) {
    buffer.writeln(
      '- 录音时间：${recordedAt.year}-${two(recordedAt.month)}-'
      '${two(recordedAt.day)} ${two(recordedAt.hour)}:${two(recordedAt.minute)}',
    );
  }
  if (material.place != null) buffer.writeln('- 地点：${material.place!.label}');
  if (pack.topic != null) buffer.writeln('- 主题：${pack.topic!.title}');
  buffer
    ..writeln('- 来源：${recordingSourceLabel(material.source)}')
    ..writeln('- 这是阅读稿，不含原音频，不能重新导入 Koe')
    ..writeln();
  final segments = transcript?.effectiveSegments ?? const [];
  final edited = transcript?.manual != null;
  if (segments.isNotEmpty && !edited) {
    for (final segment in segments) {
      final label = transcriptSegmentLabel(segment, aliases: aliases);
      buffer.writeln('[${time(segment.start)}] $label');
      buffer.writeln();
    }
  } else if ((transcript?.visible ?? '').trim().isNotEmpty) {
    buffer.writeln(
      applyTranscriptSpeakerAliases(transcript!.visible!.trim(), aliases),
    );
    buffer.writeln();
  } else {
    buffer.writeln('（还没有正文）');
    buffer.writeln();
  }
  if (pack.bookmarks.isNotEmpty) {
    buffer.writeln('## 书签');
    buffer.writeln();
    for (final item in pack.bookmarks) {
      final bookmark = item.bookmark;
      final note = bookmark.note.isEmpty ? '' : '：${bookmark.note}';
      buffer.writeln('- ${time(bookmark.position)}$note');
    }
    buffer.writeln();
  }
  return buffer.toString();
}
