part of '../recorder_controller.dart';

/// What an export of one material would contain, shown before the user
/// commits to it.
class MaterialExportPreview {
  const MaterialExportPreview({
    required this.title,
    required this.hasText,
    required this.edited,
    required this.segments,
    required this.speakers,
    required this.bookmarks,
    this.place,
    this.topic,
    this.audioBytes,
    this.audioUnavailable,
    this.identityUnavailable,
  });

  final String title;
  final bool hasText;
  final bool edited;
  final int segments;
  final int speakers;
  final int bookmarks;
  final String? place;
  final String? topic;

  /// Size of the original when it can go into the pack.
  final int? audioBytes;

  /// Why the original cannot go into the pack, when it cannot.
  final String? audioUnavailable;

  /// Why no restorable pack can be made at all (the reading copy still can).
  final String? identityUnavailable;

  bool get audioAvailable => audioUnavailable == null && audioBytes != null;
}

/// What an import did, for the message and where to go next.
class MaterialPackImportOutcome {
  const MaterialPackImportOutcome({
    required this.message,
    this.path,
    this.minutesId,
    this.duplicate = false,
    this.conflict = false,
  });

  final String message;

  /// The recording restored or merged into.
  final String? path;

  /// The text record created for a pack without audio.
  final String? minutesId;

  /// Nothing new: the same material and the same content were already here.
  final bool duplicate;

  /// A different hand-edited version was kept side by side, not overwritten.
  final bool conflict;
}

/// Material packs (#145): export one recording as a reading copy or as a
/// restorable `.koepack`, and import a pack into this library without
/// duplicating what is already here.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderMaterialPack on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract final Future<void> _bookmarksLoaded;
  abstract final Future<void> _libraryLoaded;
  abstract final Future<void> _minutesLoaded;
  abstract final Map<String, Map<int, String>> _segmentSpeakers;
  abstract final Map<String, List<TranscriptSegment>> _transcriptSegments;
  abstract final Map<String, String> _incomingTranscripts;
  abstract final Map<String, String> _manualTranscripts;
  abstract final Map<String, RecordingTranslation> _recordingTranslations;
  abstract final Map<String, TranscriptMetadata> _transcriptMetadata;
  abstract final Map<String, String> _transcriptPathsByKey;
  abstract final RecordingBookmarkStore bookmarks;
  abstract final RecordingLibraryStore library;
  abstract final Map<int, String> localPathsByFileId;
  abstract final MinutesDocumentStore minutes;
  abstract final Map<String, Map<String, String>> speakerAliasesByPath;
  abstract final Map<int, Map<String, String>> speakerAliasesByFileId;
  abstract final TopicStore topics;
  abstract final Map<int, String> transcriptsByFileId;
  abstract final Map<String, String> transcriptsByPath;
  abstract List<String> exportedPaths;
  Future<void> get _transcriptsLoaded;
  String? canonicalTranscriptForPath(String path);
  int? fileIdFromPath(String path);
  Future<({String path, bool duplicate, RecordingAsset asset})>
  importLocalAudio(
    String sourcePath, {
    DateTime? recordedAt,
    bool recordSourcePath = true,
  });
  Future<void> _persistTranscripts({bool strict = false});
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  String _referenceKey(RecordingReference ref);
  RecordingViewData recordingView(RecordingReference ref);
  List<TranscriptSpeaker> transcriptSpeakersForPath(String path);
  // END DEPS

  /// Where exports are prepared and incoming audio is unpacked; tests
  /// point it at a temporary folder.
  @visibleForTesting
  Directory? materialPackWorkDirectory;

  Future<Directory> _packWorkDirectory(String name) async {
    Directory base;
    final override = materialPackWorkDirectory;
    if (override != null) {
      base = override;
    } else {
      try {
        base = await getTemporaryDirectory();
      } catch (_) {
        base = Directory.systemTemp;
      }
    }
    final directory = Directory(
      p.join(
        base.path,
        name,
        DateTime.now().microsecondsSinceEpoch.toRadixString(36),
      ),
    );
    await directory.create(recursive: true);
    return directory;
  }

  MaterialExportPreview materialExportPreview(RecordingReference ref) {
    final recording = recordingView(ref);
    final path = recording.path;
    final key = _referenceKey(ref);
    final text = recording.text.trim();
    final place = path == null ? null : library.assetForPath(path)?.place;
    final topic = topics.topicOf(key)?.title;
    String? audioUnavailable;
    int? audioBytes;
    if (path == null || !recording.originalPresent) {
      audioUnavailable = '本机没有这条资料的原音频';
    } else if (recording.audioLocked || recording.live) {
      audioUnavailable = '录音还在进行或取回，完成后再导出';
    } else if (!recording.originalComplete) {
      audioUnavailable = '原音频还不完整，取回完成后再导出';
    } else if (RecordingAudio.of(path).kind == RecordingAudioKind.deviceRaw) {
      audioUnavailable = '原音频还未解密，暂不能带音频导出';
    } else {
      try {
        audioBytes = File(path).lengthSync();
      } catch (_) {
        audioUnavailable = '无法读取原音频';
      }
    }
    final hash = path == null ? null : library.assetForPath(path)?.contentHash;
    return MaterialExportPreview(
      title: recording.title,
      hasText: text.isNotEmpty,
      edited: recording.manuallyEdited,
      segments: recording.manuallyEdited ? 0 : recording.segments.length,
      speakers: path == null ? 0 : transcriptSpeakersForPath(path).length,
      bookmarks: bookmarks.forRecording(key).length,
      place: place?.label,
      topic: topic,
      audioBytes: audioBytes,
      audioUnavailable: audioUnavailable,
      identityUnavailable: recording.live || recording.audioLocked
          ? '录音还在进行或取回，完成后再导出'
          : (audioBytes == null && (hash == null || hash.isEmpty))
          ? '没有原音频，无法确认资料身份；只能导出阅读稿'
          : null,
    );
  }

  /// The pack for [ref] as it stands now. The content digest is read from
  /// the original when present; otherwise the library's recorded one is
  /// used, and without either there is no identity to restore against.
  Future<({MaterialPack pack, String? audioPath})> _buildMaterialPack(
    RecordingReference ref, {
    required bool includeAudio,
  }) async {
    await _transcriptsLoaded;
    await _bookmarksLoaded;
    await _libraryLoaded;
    await topics.load();
    final recording = recordingView(ref);
    final path = recording.path;
    if (recording.live || recording.audioLocked) {
      throw const MaterialPackException('录音还在进行或取回，完成后再导出');
    }
    final key = _referenceKey(ref);
    final asset = path == null ? null : library.assetForPath(path);
    final preview = materialExportPreview(ref);
    if (includeAudio && !preview.audioAvailable) {
      throw MaterialPackException(preview.audioUnavailable ?? '原音频不可用');
    }
    String? hash;
    if (path != null && recording.originalPresent) {
      try {
        hash = await audioVersion(path);
      } on AudioVersionException catch (error) {
        throw MaterialPackException(error.message);
      }
    }
    hash ??= asset?.contentHash;
    if (hash == null || hash.isEmpty) {
      throw const MaterialPackException('没有原音频，无法确认资料身份；只能导出阅读稿');
    }
    final fileId = recording.reference.fileId;
    PackTranscript? transcript;
    if (path != null) {
      final raw =
          transcriptsByPath[path] ??
          (fileId == null ? null : transcriptsByFileId[fileId]);
      final metadata = _transcriptMetadata[key];
      final aliases =
          speakerAliasesByPath[path] ??
          (fileId == null ? null : speakerAliasesByFileId[fileId]) ??
          const <String, String>{};
      final candidate = PackTranscript(
        text: raw == null ? null : normalizeSttText(raw),
        manual: _manualTranscripts[key],
        segments: _transcriptSegments[key] ?? const [],
        segmentSpeakers: _segmentSpeakers[key] ?? const {},
        speakerAliases: aliases,
        provider: metadata?.provider,
        sourceLanguage: metadata?.sourceLanguage,
        revision: metadata?.revision ?? 0,
        translation: _recordingTranslations[key],
      );
      if (!candidate.isEmpty) transcript = candidate;
    }
    final topic = topics.topicOf(key);
    final audioPath = includeAudio ? path : null;
    final pack = MaterialPack(
      exportedAt: DateTime.now(),
      material: PackMaterial(
        contentHash: hash,
        title: recording.title,
        source: asset?.source ?? recording.source,
        deviceFileId:
            (asset?.source ?? recording.source) == RecordingSource.device
            ? fileId
            : null,
        recordedAt: recording.recordedAt,
        place: asset?.place,
        audioExtension: path == null ? null : RecordingAudio.of(path).extension,
      ),
      transcript: transcript,
      bookmarks: [
        for (final bookmark in bookmarks.forRecording(key))
          PackBookmark(bookmark),
      ],
      topic: topic == null
          ? null
          : PackTopic(
              title: topic.title,
              kind: topic.kind,
              author: topic.author,
            ),
      audio: audioPath == null
          ? null
          : PackAudio(
              extension: RecordingAudio.of(audioPath).extension,
              bytes: await File(audioPath).length(),
              sha256: hash,
            ),
    );
    return (pack: pack, audioPath: audioPath);
  }

  /// Writes the restorable pack for [ref] and returns the finished file.
  /// A cancelled or failed export leaves no file behind.
  Future<File> exportMaterialPack(
    RecordingReference ref, {
    required bool includeAudio,
    bool Function()? cancelled,
  }) async {
    final built = await _buildMaterialPack(ref, includeAudio: includeAudio);
    final directory = await _packWorkDirectory('koe-export');
    final target = File(
      p.join(
        directory.path,
        materialExportFileName(
          built.pack.material.title,
          MaterialPack.extension,
        ),
      ),
    );
    try {
      await writeMaterialPack(
        built.pack,
        target,
        audioPath: built.audioPath,
        cancelled: cancelled,
      );
    } on FileSystemException catch (error) {
      throw MaterialPackException(
        isOutOfSpace(error) ? '存储空间不足，资料包未生成' : '资料包写入失败，请重试',
      );
    }
    return target;
  }

  /// The Markdown reading copy for [ref]; it is not a restorable pack.
  Future<File> exportReadingText(RecordingReference ref) async {
    final recording = recordingView(ref);
    final key = _referenceKey(ref);
    final path = recording.path;
    final fileId = recording.reference.fileId;
    final topic = topics.topicOf(key);
    final pack = MaterialPack(
      exportedAt: DateTime.now(),
      material: PackMaterial(
        contentHash: '0' * 64,
        title: recording.title,
        source: recording.source,
        recordedAt: recording.recordedAt,
        place: path == null ? null : library.assetForPath(path)?.place,
      ),
      transcript: PackTranscript(
        text: recording.text.trim().isEmpty ? null : recording.text,
        manual: null,
        segments: recording.manuallyEdited ? const [] : recording.segments,
        speakerAliases:
            (path == null ? null : speakerAliasesByPath[path]) ??
            (fileId == null ? null : speakerAliasesByFileId[fileId]) ??
            const {},
      ),
      bookmarks: [
        for (final bookmark in bookmarks.forRecording(key))
          PackBookmark(bookmark),
      ],
      topic: topic == null
          ? null
          : PackTopic(title: topic.title, kind: topic.kind),
    );
    final directory = await _packWorkDirectory('koe-export');
    final target = File(
      p.join(directory.path, materialExportFileName(recording.title, '.md')),
    );
    try {
      await writeFileAtomically(target, renderReadingText(pack));
    } on FileSystemException catch (error) {
      throw MaterialPackException(
        isOutOfSpace(error) ? '存储空间不足，阅读稿未生成' : '阅读稿写入失败，请重试',
      );
    }
    return target;
  }

  /// Imports the pack at [packPath].
  ///
  /// The same material (recorder file number or audio content) is merged,
  /// never added twice. Text, speakers and bookmarks fill in what is
  /// missing; a different hand-edited text is kept beside the current one
  /// for the user to compare. A damaged pack changes nothing.
  Future<MaterialPackImportOutcome> importMaterialPack(String packPath) async {
    await _libraryLoaded;
    await _transcriptsLoaded;
    await _bookmarksLoaded;
    await _minutesLoaded;
    await topics.load();
    final work = await _packWorkDirectory('koe-pack-import');
    try {
      final opened = await openMaterialPack(packPath, workDirectory: work);
      final pack = opened.pack;
      var existing = _existingPackMaterial(pack.material);
      if (existing == null && opened.audioFile != null) {
        final imported = await importLocalAudio(
          opened.audioFile!.path,
          recordedAt: pack.material.recordedAt,
          recordSourcePath: false,
        );
        if (imported.duplicate) {
          existing = imported.path;
        } else {
          await library.upsert(
            imported.asset.copyWith(
              displayName: pack.material.title,
              place: pack.material.place,
            ),
          );
          final restored = await _restorePackOnto(imported.path, pack);
          notifyListeners();
          return MaterialPackImportOutcome(
            path: imported.path,
            message: '已恢复「${pack.material.title}」：${restored.summary}',
          );
        }
      }
      if (existing != null) {
        final restored = await _restorePackOnto(existing, pack);
        notifyListeners();
        if (restored.nothingNew) {
          return MaterialPackImportOutcome(
            path: existing,
            duplicate: true,
            message: '这份资料已在资料库中，未重复导入',
          );
        }
        return MaterialPackImportOutcome(
          path: existing,
          conflict: restored.conflict,
          message: restored.conflict
              ? '资料已在资料库中；资料包的正文与当前校订不同，已并列保留，可在详情页比较'
              : '资料已在资料库中，已补充：${restored.summary}',
        );
      }
      return await _importPackAsText(pack);
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// A local recording that is the same material as [material]: the same
  /// recorder file, or a library original with the same audio content.
  String? _existingPackMaterial(PackMaterial material) {
    final fileId = material.deviceFileId;
    if (fileId != null) {
      final known = localPathsByFileId[fileId];
      if (known != null && File(known).existsSync()) return known;
      for (final candidate in exportedPaths) {
        if (fileIdFromPath(candidate) == fileId &&
            library.assetForPath(candidate)?.source !=
                RecordingSource.localImport &&
            File(candidate).existsSync()) {
          return candidate;
        }
      }
    }
    final asset = library.assetForHash(material.contentHash);
    if (asset != null && !asset.trashed) return asset.path;
    return null;
  }

  /// A pack without audio for material this library does not have: kept
  /// as a text record that says what is missing. Pairing the original
  /// later restores the rest ([_completePackAfterPairing]).
  Future<MaterialPackImportOutcome> _importPackAsText(MaterialPack pack) async {
    final id = 'pack-${pack.material.contentHash.substring(0, 32)}';
    if (minutes.byId(id) != null) {
      return MaterialPackImportOutcome(
        minutesId: id,
        duplicate: true,
        message: '这份资料包已导入为文字资料，未重复导入',
      );
    }
    final transcript = pack.transcript;
    final aliases = transcript?.speakerAliases ?? const <String, String>{};
    final segments = <MinutesSegment>[];
    final edited = transcript?.manual != null;
    if (transcript != null && !edited && transcript.segments.isNotEmpty) {
      for (final segment in transcript.effectiveSegments) {
        final speaker = segment.speaker;
        segments.add(
          MinutesSegment(
            text: segment.text,
            start: segment.start,
            end: segment.end,
            speaker: speaker == null
                ? null
                : (aliases[speaker]?.trim().isNotEmpty == true
                      ? aliases[speaker]!.trim()
                      : '说话人 $speaker'),
          ),
        );
      }
    } else if ((transcript?.visible ?? '').trim().isNotEmpty) {
      final visible = applyTranscriptSpeakerAliases(
        transcript!.visible!.trim(),
        aliases,
      );
      for (final paragraph in visible.split('\n')) {
        if (paragraph.trim().isEmpty) continue;
        segments.add(
          MinutesSegment(text: paragraph.trim(), start: Duration.zero),
        );
      }
    }
    if (segments.isEmpty) {
      throw const MaterialPackException('资料包没有原音频也没有正文，无法导入');
    }
    final timed =
        !edited &&
        transcriptSegmentsLocatable(transcript?.segments ?? const []);
    final missing = [
      '原音频',
      if (pack.bookmarks.isNotEmpty) '${pack.bookmarks.length} 个书签的回听',
    ].join('、');
    final document = MinutesDocument(
      id: id,
      title: pack.material.title,
      sourceName: materialExportFileName(
        pack.material.title,
        MaterialPack.extension,
      ),
      importedAt: DateTime.now(),
      capturedAt: pack.material.recordedAt,
      audioHash: pack.material.contentHash,
      segments: segments,
      timingReliable: timed,
      warning: '资料包没有包含原音频；缺少$missing。补配同一份原音频后完整恢复。',
      restore: pack.toJson(),
    );
    try {
      await minutes.upsert(document, strict: true);
    } catch (_) {
      throw const MaterialPackException('文字资料保存失败，请检查存储空间后重试');
    }
    notifyListeners();
    return MaterialPackImportOutcome(
      minutesId: id,
      message: '资料包没有原音频，已作为文字资料导入；补配原音频后可回听和恢复书签',
    );
  }

  /// After the original audio of a pack imported without it was paired:
  /// restore the pack onto that recording and drop the stand-in text record.
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  Future<String?> _completePackAfterPairing(
    MinutesDocument document,
    String audioPath,
  ) async {
    final raw = document.restore;
    if (raw == null) return null;
    final MaterialPack pack;
    try {
      pack = MaterialPack.fromJson(raw);
    } on MaterialPackException {
      return null;
    }
    await _transcriptsLoaded;
    await _bookmarksLoaded;
    await topics.load();
    final asset = library.assetForPath(audioPath);
    if (asset != null && asset.source == RecordingSource.localImport) {
      await library.upsert(
        asset.copyWith(
          displayName: pack.material.title,
          recordedAt: asset.recordedAt ?? pack.material.recordedAt,
          place: asset.place ?? pack.material.place,
        ),
      );
    }
    await _restorePackOnto(audioPath, pack);
    await minutes.remove(document.id, strict: true);
    notifyListeners();
    return audioPath;
  }

  /// Merges [pack] into the recording at [path]. Only fills what is
  /// missing; a different local version always stays as it is.
  Future<_PackRestore> _restorePackOnto(String path, MaterialPack pack) async {
    final key = _recordingKey(path: path);
    final fileId = fileIdFromPath(path);
    final restore = _PackRestore();
    final transcript = pack.transcript;
    if (transcript != null) {
      var differs = false;
      final local = canonicalTranscriptForPath(path);
      String flat(String? value) =>
          normalizeSttText(value ?? '').replaceAll(RegExp(r'\s+'), '');
      if (local == null || local.trim().isEmpty) {
        final base = transcript.text ?? transcript.manual!;
        transcriptsByPath[path] = base;
        if (fileId != null) transcriptsByFileId[fileId] = base;
        _transcriptPathsByKey[key] = path;
        if (transcript.manual != null) {
          _manualTranscripts[key] = transcript.manual!;
        }
        if (transcript.segments.isNotEmpty) {
          _transcriptSegments[key] = List.unmodifiable(transcript.segments);
        }
        if (transcript.segmentSpeakers.isNotEmpty) {
          _segmentSpeakers[key] = Map.of(transcript.segmentSpeakers);
        }
        _transcriptMetadata[key] = TranscriptMetadata(
          provider: transcript.provider ?? SttProvider.soniox,
          sourceLanguage: transcript.sourceLanguage,
          revision: transcript.revision,
        );
        if (transcript.translation != null) {
          _recordingTranslations[key] = transcript.translation!;
        }
        restore
          ..text = true
          ..segments = transcript.segments.length;
      } else if (flat(local) != flat(transcript.visible)) {
        differs = true;
        final incoming = _incomingTranscripts[key];
        if (incoming == null) {
          _incomingTranscripts[key] = transcript.visible!;
          restore
            ..changed = true
            ..conflict = true;
        } else if (flat(incoming) != flat(transcript.visible)) {
          // Another version already waits for review; the pack's text is
          // not stored over it and the user is told so.
          restore.conflict = true;
        }
      }
      if (!differs) {
        final aliases = Map<String, String>.of(
          speakerAliasesByPath[path] ??
              (fileId == null ? null : speakerAliasesByFileId[fileId]) ??
              const {},
        );
        var added = 0;
        for (final entry in transcript.speakerAliases.entries) {
          if (aliases.containsKey(entry.key)) continue;
          aliases[entry.key] = entry.value;
          added++;
        }
        if (added > 0) {
          speakerAliasesByPath[path] = aliases;
          if (fileId != null) speakerAliasesByFileId[fileId] = Map.of(aliases);
          restore.speakers = added;
        }
        if (_recordingTranslations[key] == null &&
            transcript.translation != null) {
          _recordingTranslations[key] = transcript.translation!;
          restore.changed = true;
        }
      }
      if (restore.text || restore.speakers > 0 || restore.changed) {
        await _persistTranscripts(strict: true);
      }
    }

    final local = bookmarks.forRecording(key);
    bool same(RecordingBookmark a, RecordingBookmark b) =>
        a.position == b.position &&
        a.note == b.note &&
        a.segmentText == b.segmentText;
    final additions = <RecordingBookmark>[];
    for (final item in pack.bookmarks) {
      final incoming = item.bookmark;
      if (local.any((bookmark) => same(bookmark, incoming))) continue;
      // An id already in use (here or on another material) gets a new one
      // so the local bookmark is never replaced.
      final taken =
          bookmarks.byId(incoming.id) != null ||
          additions.any((bookmark) => bookmark.id == incoming.id);
      additions.add(
        item.under(key, id: taken ? bookmarks.newId(DateTime.now()) : null),
      );
    }
    if (additions.isNotEmpty) {
      await bookmarks.addAll(additions);
      restore.bookmarks = additions.length;
    }

    final asset = library.assetForPath(path);
    if (pack.material.place != null && asset != null && asset.place == null) {
      await library.upsert(asset.copyWith(place: pack.material.place));
      restore.place = true;
    }

    final topic = pack.topic;
    final placement = topics.placementOf(key);
    if (topic != null && (placement == null || placement is PendingPlacement)) {
      final match =
          topics.openTopics
              .where((t) => t.kind == topic.kind && t.title == topic.title)
              .firstOrNull ??
          topics.topics
              .where((t) => t.kind == topic.kind && t.title == topic.title)
              .firstOrNull ??
          await topics.createTopic(
            kind: topic.kind,
            title: topic.title,
            author: topic.author,
          );
      await topics.moveRecording(key, match.id);
      restore.topic = true;
    }
    return restore;
  }
}

class _PackRestore {
  bool text = false;
  int segments = 0;
  int speakers = 0;
  int bookmarks = 0;
  bool place = false;
  bool topic = false;
  bool conflict = false;
  bool changed = false;

  bool get nothingNew =>
      !text &&
      speakers == 0 &&
      bookmarks == 0 &&
      !place &&
      !topic &&
      !conflict &&
      !changed;

  String get summary {
    final parts = [
      if (text) segments > 0 ? '正文和 $segments 段时间码' : '正文',
      if (speakers > 0) '$speakers 位发言人姓名',
      if (bookmarks > 0) '$bookmarks 个书签',
      if (place) '地点',
      if (topic) '主题',
    ];
    return parts.isEmpty ? '原音频' : parts.join('、');
  }
}
