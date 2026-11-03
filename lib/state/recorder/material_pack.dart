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
    this.minutesVersions = 0,
  });

  final String title;
  final bool hasText;
  final int minutesVersions;
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
  abstract final RecordingAnalysis analysis;
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
    int? expectedSpeakers,
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
      minutesVersions: analysis.results['$key/minutes'] == null
          ? 0
          : 1 +
                analysis
                    .versionsFor('$key/minutes')
                    .length
                    .clamp(0, PackMinutes.maxHistory),
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
    await analysis.load();
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
    final currentMinutes = analysis.results['$key/minutes'];
    final history = analysis.versionsFor('$key/minutes');
    final portableMinutes = currentMinutes == null
        ? null
        : PackMinutes.decode(
            PackMinutes(
              current: currentMinutes,
              history: history
                  .skip(
                    history.length > PackMinutes.maxHistory
                        ? history.length - PackMinutes.maxHistory
                        : 0,
                  )
                  .toList(),
            ).toJson(),
          );
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
      minutes: portableMinutes,
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
      var existing = await _existingPackMaterial(pack.material);
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
        // A known asset may have lost only its original file. Restore it from
        // this already verified pack without replacing any existing file.
        if (opened.audioFile != null && !await File(existing).exists()) {
          await _restoreMissingPackAudio(
            existing,
            opened.audioFile!,
            pack.material.contentHash,
          );
        }
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
              ? '资料已在资料库中；正文或纪要存在不同版本，已保留本机内容；候选纪要可在版本历史中比较'
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
  Future<String?> _existingPackMaterial(PackMaterial material) async {
    final fileId = material.deviceFileId;
    final candidates = <String>{
      if (fileId != null && localPathsByFileId[fileId] != null)
        localPathsByFileId[fileId]!,
      if (fileId != null)
        for (final candidate in exportedPaths)
          if (fileIdFromPath(candidate) == fileId &&
              library.assetForPath(candidate)?.source !=
                  RecordingSource.localImport)
            candidate,
    };
    for (final path in candidates) {
      if (await File(path).exists() &&
          await audioVersion(path) == material.contentHash) {
        return path;
      }
    }
    final asset = library.assets
        .where((a) => a.contentHash == material.contentHash && !a.trashed)
        .firstOrNull;
    if (asset == null || asset.trashed) return null;
    if (await File(asset.path).exists() &&
        await audioVersion(asset.path) != material.contentHash) {
      throw const MaterialPackException('本机同身份原音频内容已变化，请检查后再导入');
    }
    return asset.path;
  }

  Future<void> _restoreMissingPackAudio(
    String path,
    File source,
    String hash,
  ) async {
    final target = File(path);
    final partial = File(
      '$path.pack-${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await target.parent.create(recursive: true);
      await source.copy(partial.path);
      if (await audioVersion(partial.path) != hash) {
        throw const MaterialPackException('恢复原音频时校验失败，请重试');
      }
      if (await target.exists()) {
        if (await audioVersion(path) != hash) {
          throw const MaterialPackException('本机原音频已变化，未覆盖');
        }
        return;
      }
      publishPackAudio(partial.path, path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  /// A pack without audio for material this library does not have: kept
  /// as a text record that says what is missing. Pairing the original
  /// later restores the rest ([_completePackAfterPairing]).
  Future<MaterialPackImportOutcome> _importPackAsText(MaterialPack pack) async {
    final id = 'pack-${pack.material.contentHash.substring(0, 32)}';
    final existing = minutes.byId(id);
    if (existing != null) {
      final previous = existing.restore == null
          ? null
          : MaterialPack.fromJson(existing.restore);
      final incoming = pack.minutes;
      final transcriptConflict =
          (previous?.transcript?.visible ??
              (previous == null ? existing.bodyText : null)) !=
          pack.transcript?.visible;
      const textConflictMessage = '资料包正文与当前文字不同；已保留当前文字，外来正文未保存，请保留资料包以便比较';
      if (previous == null || incoming == null) {
        return MaterialPackImportOutcome(
          minutesId: id,
          duplicate: !transcriptConflict,
          conflict: transcriptConflict,
          message: transcriptConflict
              ? textConflictMessage
              : '这份资料包已导入为文字资料，未重复导入',
        );
      }
      final current = previous.minutes?.current ?? incoming.current;
      final history = mergedMinutesHistory(
        current: current,
        incoming: incoming.current,
        existing: previous.minutes?.history ?? const [],
        history: incoming.history,
        limit: PackMinutes.maxHistory,
      );
      final merged = PackMinutes(current: current, history: history);
      final raw = previous.toJson()..['version'] = 2;
      raw['minutes'] = merged.toJson();
      if (previous.minutes != null &&
          listEquals(
            previous.minutes!.history.map((v) => v.portableIdentity).toList(),
            history.map((v) => v.portableIdentity).toList(),
          )) {
        return MaterialPackImportOutcome(
          minutesId: id,
          duplicate: !transcriptConflict,
          conflict: transcriptConflict,
          message: transcriptConflict
              ? textConflictMessage
              : '这份资料包已在资料库中，未重复导入',
        );
      }
      final conflict =
          current.portableIdentity != incoming.current.portableIdentity ||
          transcriptConflict;
      await minutes.upsert(
        MinutesDocument(
          id: existing.id,
          title: existing.title,
          sourceName: existing.sourceName,
          importedAt: existing.importedAt,
          capturedAt: existing.capturedAt,
          audioPath: existing.audioPath,
          audioDuration: existing.audioDuration,
          audioHash: existing.audioHash,
          segments: existing.segments,
          timingReliable: existing.timingReliable,
          warning: existing.warning,
          restore: raw,
        ),
        strict: true,
      );
      notifyListeners();
      return MaterialPackImportOutcome(
        minutesId: id,
        conflict: conflict,
        message: transcriptConflict
            ? '$textConflictMessage；纪要版本及其来源快照已合并'
            : conflict
            ? '已保留当前文字与纪要；候选纪要及其原文快照可在包内历史中查看'
            : '已补充纪要历史，原文字未改动',
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
    if (segments.isEmpty && transcript == null && pack.minutes != null) {
      for (final source in pack.minutes!.current.sources) {
        if (source.trim().isNotEmpty) {
          segments.add(MinutesSegment(text: source, start: Duration.zero));
        }
      }
    }
    if (segments.isEmpty) {
      throw const MaterialPackException('资料包没有原音频也没有可读正文，无法导入');
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
      warning: transcript == null
          ? '纪要原文快照，不是完整逐字稿；资料包未包含原音频，补配后仍需真实转写才能定位回听。'
          : '资料包没有包含原音频；缺少$missing。补配同一份原音频后完整恢复。',
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
    final incomingMinutes = pack.minutes;
    if (incomingMinutes != null) {
      final imported = await analysis.mergeImportedMinutes(
        '$key/minutes',
        incomingMinutes.current,
        incomingMinutes.history,
      );
      restore.minutes = imported.changed;
      restore.conflict = restore.conflict || imported.conflict;
    }
    return restore;
  }
}

class _PackRestore {
  bool text = false;
  bool minutes = false;
  int segments = 0;
  int speakers = 0;
  int bookmarks = 0;
  bool place = false;
  bool topic = false;
  bool conflict = false;
  bool changed = false;

  bool get nothingNew =>
      !text &&
      !minutes &&
      speakers == 0 &&
      bookmarks == 0 &&
      !place &&
      !topic &&
      !conflict &&
      !changed;

  String get summary {
    final parts = [
      if (text) segments > 0 ? '正文和 $segments 段时间码' : '正文',
      if (minutes) '纪要与历史版本',
      if (speakers > 0) '$speakers 位发言人姓名',
      if (bookmarks > 0) '$bookmarks 个书签',
      if (place) '地点',
      if (topic) '主题',
    ];
    return parts.isEmpty ? '原音频' : parts.join('、');
  }
}
