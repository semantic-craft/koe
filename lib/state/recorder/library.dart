part of '../recorder_controller.dart';

/// The local recording library: exported and imported audio on this device,
/// Feishu minutes documents, rename, share, trash and derived-cache cleanup,
/// and cached durations and WAV conversions.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderLibrary on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract final Future<Duration?> Function(String path) _audioDurationProbe;
  abstract final Map<String, int> _bookmarkGenerations;
  abstract final Future<void> _bookmarksLoaded;
  abstract final DeferredFileJobs<SpeechConfiguration> _deferredJobs;
  abstract bool _disposed;
  abstract String? _fileJobKey;
  abstract final FileJobJournal _fileJobs;
  abstract final Future<void> _fileJobsLoaded;
  abstract final Map<String, String> _incomingTranscripts;
  Set<int> get _incompleteRetrievalIds;
  abstract final Directory? _libraryDirectoryOverride;
  abstract final Future<Duration?> Function(String path) _localDurationReader;
  DateTime? _localFileTimestamp(String? path);
  abstract final Map<String, String> _manualTranscripts;
  set _observedPlacements(Map<String, TopicPlacement> value);
  // ignore: unused_element_parameter
  Future<void> _persistTranscripts({bool strict = false});
  abstract final Future<String> Function(String rawPath) _rawExportConverter;
  DateTime? _recordedAtFromFileId(int? id);
  // ignore: unused_element_parameter
  String _recordingTitleForPath(String path, {String? archiveName});
  abstract final Map<String, String> _recordingErrors;
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  abstract final Map<String, _RecordingSession> _recordingSessions;
  abstract final Map<String, RecordingTranslation> _recordingTranslations;
  void _requireFinishedRecording(String path);
  abstract final Map<String, Map<int, String>> _segmentSpeakers;
  abstract final Map<String, _TopicAssistLatest> _topicAssistLatest;
  abstract final Future<void> _topicsLoaded;
  abstract final Map<String, TranscriptMetadata> _transcriptMetadata;
  abstract final Map<String, String> _transcriptPathsByKey;
  abstract final Map<String, List<TranscriptSegment>> _transcriptSegments;
  abstract Future<void> _transcriptsLoaded;
  abstract final MacArchiveController archive;
  abstract final RecordingBookmarkStore bookmarks;
  abstract String? errorMessage;
  abstract String? expandedLocalPath;
  int? fileIdFromPath(String path);
  abstract final PlaybackHistoryStore playbackHistory;
  abstract int? playingFileId;
  abstract String? playingPath;
  abstract final Map<int, Map<String, String>> speakerAliasesByFileId;
  abstract final Map<String, Map<String, String>> speakerAliasesByPath;
  abstract String? statusMessage;
  Future<void> stopPlayback();
  abstract final TopicStore topics;
  String? transcriptForPath(String path);
  abstract final Map<int, String> transcriptsByFileId;
  abstract final Map<String, String> transcriptsByPath;
  abstract final RecordingAnalysis analysis;
  // END DEPS

  late final RecordingLibraryStore library;

  late final Future<void> _libraryLoaded;
  late final MinutesDocumentStore minutes;
  late final Future<void> _minutesLoaded;

  /// Local exported paths (standard WAV when decryption succeeds).
  List<String> exportedPaths = [];
  final Map<String, Future<String>> _wavConversions = {};
  bool _catalogConversionRunning = false;
  final Map<String, Duration> _localDurations = {};
  final Map<String, Object> _durationLoads = {};

  /// fileId → local path after Wi‑Fi export.
  final Map<int, String> localPathsByFileId = {};

  Future<Set<int>> _completeLocalExportIds(
    Iterable<OfflineFileEntry> deviceFiles,
  ) async {
    final complete = <int>{};
    try {
      // Restores the persisted incomplete-retrieval ids after a restart.
      await _fileJobs.load();
    } catch (_) {}
    final trashedIds = <int>{};
    for (final asset in library.assets.where((asset) => asset.trashed)) {
      final id = ExportCatalog.fileIdFromPath(asset.path);
      if (id != null) trashedIds.add(id);
    }
    for (final file in deviceFiles) {
      if (trashedIds.contains(file.fileId)) {
        complete.add(file.fileId);
        continue;
      }
      // A partial transfer converts to a full-size WAV header, so its size
      // alone would pass the threshold below; retrieve it again instead.
      if (_incompleteRetrievalIds.contains(file.fileId)) continue;
      // Pause/resume appends to the same device file. The local copy is a
      // decoded WAV, far larger than the compressed listing, so its size
      // alone cannot reveal that the device file grew; compare listings.
      final retrievedAt = _fileJobs.retrievedSizes[file.fileId];
      if (retrievedAt != null && file.sizeBytes > retrievedAt) continue;
      final path = localPathsByFileId[file.fileId];
      if (path == null) continue;
      try {
        final local = File(path);
        if (!await local.exists()) continue;
        final size = await local.length();
        final minimum = (file.sizeBytes * 0.95).floor();
        if (size > 0 && (file.sizeBytes <= 0 || size >= minimum)) {
          complete.add(file.fileId);
          // Copies from before sizes were recorded start their baseline now.
          if (retrievedAt == null && file.sizeBytes > 0) {
            await _fileJobs.noteRetrievedSize(file.fileId, file.sizeBytes);
          }
        }
      } catch (_) {}
    }
    return complete;
  }

  @visibleForTesting
  Future<Set<int>> completeLocalExportIdsForTesting(
    Iterable<OfflineFileEntry> deviceFiles,
  ) => _completeLocalExportIds(deviceFiles);

  Future<Directory> _localExportDirectory() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    return Directory(p.join(base.path, 'AnkerRecorder', 'exports'));
  }

  Future<Directory> _importDirectory() async {
    if (_libraryDirectoryOverride != null) {
      return _libraryDirectoryOverride;
    }
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    return Directory(p.join(base.path, 'AnkerRecorder', 'imports'));
  }

  Future<void> _loadRecordingLibrary() async {
    await library.load();
    final present = <String>[];
    for (final asset in library.assets) {
      if (asset.trashed) continue;
      if (File(asset.path).existsSync()) present.add(asset.path);
    }
    if (present.isNotEmpty && !_disposed) {
      _registerExportedPaths([...exportedPaths, ...present]);
      notifyListeners();
    }
  }

  RecordingAsset? recordingAssetForPath(String path) =>
      library.assetForPath(path);

  Future<void> _loadMinutesDocuments() async {
    await minutes.load();
    if (!_disposed) notifyListeners();
  }

  @visibleForTesting
  Future<void> waitForMinutesDocuments() => _minutesLoaded;

  List<MinutesDocument> get minutesDocuments => minutes.documents;

  MinutesDocument? minutesDocumentById(String id) => minutes.byId(id);

  /// Imports a 妙记-style JSON/TXT export. Equal source content is reused so a
  /// repeated import does not create a second text record.
  Future<MinutesImportOutcome> importMinutesText(
    String fileName,
    String contents,
  ) async {
    await _minutesLoaded;
    final parsed = parseMinutesDocument(fileName, contents);
    final existing = minutes.byId(parsed.document.id);
    if (existing != null) {
      return MinutesImportOutcome(document: existing, duplicate: true);
    }
    try {
      await minutes.upsert(parsed.document, strict: true);
    } catch (_) {
      throw StateError('文字保存失败，请重试');
    }
    notifyListeners();
    return MinutesImportOutcome(document: parsed.document, duplicate: false);
  }

  /// Attaches an original audio file to a text-only import.
  ///
  /// A declared hash must match. Otherwise the audio must be long enough for
  /// the last segment; a short file is reported as a wrong pairing and the
  /// text record keeps its previous state. Unreliable timecodes still allow
  /// whole-file playback but never claim sentence seeking.
  Future<MinutesAttachOutcome> attachMinutesAudio(
    String documentId,
    String sourcePath,
  ) async {
    await _minutesLoaded;
    final document = minutes.byId(documentId);
    if (document == null) {
      return const MinutesAttachOutcome(ok: false, message: '找不到这条导入文字');
    }
    final ({String path, bool duplicate, RecordingAsset asset}) imported;
    try {
      imported = await importLocalAudio(sourcePath);
    } catch (error) {
      return MinutesAttachOutcome(
        ok: false,
        message: error is StateError ? error.message : '无法读取所选音频，请重试',
      );
    }
    Future<void> discardNewCopy() async {
      if (imported.duplicate) return;
      try {
        await library.remove(imported.path, strict: false);
        exportedPaths.remove(imported.path);
        final file = File(imported.path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // The rejected copy stays on disk but is not linked to the text record.
      }
    }

    if (document.audioHash != null &&
        document.audioHash!.isNotEmpty &&
        imported.asset.contentHash != document.audioHash) {
      await discardNewCopy();
      return const MinutesAttachOutcome(
        ok: false,
        message: '音频内容与导入文字声明的来源不一致，未建立配对',
      );
    }
    var duration = localDurationForPath(imported.path);
    duration ??= await _localDurationReader(imported.path);
    duration ??= await _audioDurationProbe(imported.path);
    final required = document.lastEnd;
    if (document.timingReliable && duration == null) {
      await discardNewCopy();
      return const MinutesAttachOutcome(ok: false, message: '无法读取音频时长，未建立配对');
    }
    if (document.timingReliable &&
        required != null &&
        duration != null &&
        required > duration + const Duration(seconds: 1)) {
      await discardNewCopy();
      return const MinutesAttachOutcome(
        ok: false,
        message: '音频比文字时码短，无法覆盖最后一段；未建立配对',
      );
    }
    final updated = document.copyWith(
      audioPath: imported.path,
      audioDuration: duration,
    );
    try {
      await minutes.upsert(updated, strict: true);
    } catch (_) {
      await discardNewCopy();
      return const MinutesAttachOutcome(ok: false, message: '配对保存失败，请重试');
    }
    notifyListeners();
    return MinutesAttachOutcome(
      ok: true,
      document: updated,
      message: updated.unaligned ? '已取得音频，但时码不可靠；只能整段播放' : '已配对原音频，可按句回听',
    );
  }

  Future<void> detachMinutesAudio(String documentId) async {
    final document = minutes.byId(documentId);
    if (document == null) return;
    await minutes.upsert(document.copyWith(clearAudio: true), strict: true);
    notifyListeners();
  }

  DateTime? recordingRecordedAtForPath(String path) {
    final asset = library.assetForPath(path);
    if (asset?.recordedAt != null) return asset!.recordedAt;
    final id = fileIdFromPath(path);
    return _recordedAtFromFileId(id);
  }

  /// Copies a user-selected audio file into the app's original-audio library.
  ///
  /// The returned path is stable across restarts. Equal content is reused
  /// rather than imported twice. Metadata persistence is part of the commit:
  /// if it fails, the newly copied file is removed and the caller sees failure.
  Future<({String path, bool duplicate, RecordingAsset asset})>
  importLocalAudio(String sourcePath, {DateTime? recordedAt}) async {
    await _libraryLoaded;
    const extensions = {
      '.wav',
      '.m4a',
      '.mp3',
      '.aac',
      '.flac',
      '.ogg',
      '.opus',
    };
    final source = File(sourcePath);
    final extension = p.extension(sourcePath).toLowerCase();
    if (!extensions.contains(extension)) {
      throw StateError('不支持这种音频格式，请选择 WAV、M4A、MP3、AAC、FLAC、OGG 或 Opus');
    }
    if (!await source.exists()) throw StateError('所选音频不存在，请重新选择');
    if (await source.length() == 0) throw StateError('所选音频为空，无法保存');

    String? contentHash;
    try {
      contentHash = await audioVersion(sourcePath);
    } on AudioVersionException catch (error) {
      throw StateError(error.message);
    }
    if (contentHash == null) throw StateError('无法读取所选音频，请重新选择');

    final existing = library.assetForHash(contentHash);
    if (existing != null) {
      final restored = existing.trashed;
      if (restored) {
        await library.upsert(
          existing.copyWith(archived: false, clearDeletedAt: true),
        );
        analysis.resumeRecording(_recordingKey(path: existing.path));
      }
      _registerExportedPaths([...exportedPaths, existing.path]);
      statusMessage = restored ? '这条音频在回收站中，已恢复' : '这条音频已在资料库中';
      errorMessage = null;
      notifyListeners();
      unawaited(archive.onLocalLibraryChanged());
      return (
        path: existing.path,
        duplicate: true,
        asset: restored
            ? existing.copyWith(archived: false, clearDeletedAt: true)
            : existing,
      );
    }

    final now = DateTime.now();
    final importedAt = now;
    final dir = await _importDirectory();
    await dir.create(recursive: true);
    final rawName = p.basenameWithoutExtension(sourcePath).trim();
    final safeName = rawName
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final displayName = safeName.isEmpty ? '导入的录音' : safeName;
    final fileName =
        '${importedAt.microsecondsSinceEpoch}_${contentHash.substring(0, 12)}'
        '${safeName.isEmpty ? '' : '_$safeName'}$extension';
    final target = File(p.join(dir.path, fileName));
    final temporary = File('${target.path}.part');
    var copied = false;
    try {
      await source.copy(temporary.path);
      if (await temporary.length() != await source.length()) {
        throw StateError('音频复制不完整，请重试');
      }
      final copiedHash = await audioVersion(temporary.path);
      if (copiedHash != contentHash) {
        throw StateError('音频复制后内容发生变化，请重试');
      }
      await temporary.rename(target.path);
      copied = true;
      final asset = RecordingAsset(
        path: target.path,
        displayName: displayName,
        source: RecordingSource.localImport,
        recordedAt: recordedAt,
        importedAt: importedAt,
        originalPath: p.absolute(sourcePath),
        contentHash: contentHash,
      );
      await library.upsert(asset);
      _registerExportedPaths([...exportedPaths, target.path]);
      _invalidateLocalDuration(target.path);
      statusMessage = '原件已保存';
      errorMessage = null;
      notifyListeners();
      unawaited(archive.onLocalLibraryChanged());
      return (path: target.path, duplicate: false, asset: asset);
    } catch (error) {
      try {
        if (await temporary.exists()) await temporary.delete();
        if (copied && await target.exists()) await target.delete();
      } catch (_) {}
      errorMessage = error is StateError ? error.message : '原件保存失败，请检查存储空间后重试';
      statusMessage = '保存失败，原件未加入资料库';
      notifyListeners();
      rethrow;
    }
  }

  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  Future<void> _loadLocalExports({bool notify = true}) async {
    try {
      await _libraryLoaded;
      final dir = await _localExportDirectory();
      if (!await dir.exists()) {
        if (notify) notifyListeners();
        return;
      }
      final paths = <String>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (ExportCatalog.isSupportedExportPath(name)) {
          paths.add(entity.path);
        }
      }
      final trashedPaths = <String>{};
      final trashedIds = <int>{};
      for (final asset in library.assets.where((asset) => asset.trashed)) {
        trashedPaths.add(asset.path);
        final id = ExportCatalog.fileIdFromPath(asset.path);
        if (id != null) trashedIds.add(id);
      }
      paths.removeWhere((path) {
        final id = ExportCatalog.fileIdFromPath(path);
        return trashedPaths.contains(path) ||
            (id != null && trashedIds.contains(id));
      });
      _registerExportedPaths([...exportedPaths, ...paths]);
      final wavIds = paths
          .where((path) => path.endsWith('.wav'))
          .map(ExportCatalog.fileIdFromPath)
          .whereType<int>()
          .toSet();
      unawaited(_convertRawOnlyExports(paths, wavIds));
      if (notify) notifyListeners();
    } catch (error) {
      debugPrint('[Exports] load local catalog failed: $error');
    }
  }

  Future<void> _convertRawOnlyExports(
    Iterable<String> paths,
    Set<int> wavIds,
  ) async {
    if (_catalogConversionRunning) return;
    _catalogConversionRunning = true;
    try {
      for (final path in paths.where((path) => path.endsWith('.opus'))) {
        final id = ExportCatalog.fileIdFromPath(path);
        if (id == null || !wavIds.contains(id)) {
          await _convertExportToWav(path);
        }
      }
    } finally {
      _catalogConversionRunning = false;
    }
  }

  /// Copy local recordings and their transcripts to a user-selected folder.
  Future<({int audios, int transcripts, List<String> failed})> saveLocalCopies(
    Iterable<String> paths,
    String destinationPath,
  ) async {
    final destination = Directory(destinationPath);
    var audios = 0;
    var transcripts = 0;
    final failed = <String>[];

    try {
      if (!await destination.exists()) {
        await destination.create(recursive: true);
      }
    } catch (e) {
      return (audios: 0, transcripts: 0, failed: ['无法写入所选文件夹，请更换位置后重试']);
    }

    for (final path in paths.toSet()) {
      final source = File(path);
      final name = p.basename(path);
      try {
        _requireFinishedRecording(path);
        if (!await source.exists()) throw StateError('录音文件不存在');
        final audioTarget = p.join(destination.path, name);
        if (!p.equals(p.absolute(path), p.absolute(audioTarget))) {
          await source.copy(audioTarget);
        }
        audios++;

        final transcript = transcriptForPath(path)?.trim();
        if (transcript != null && transcript.isNotEmpty) {
          final stem = name.replaceFirst(
            RegExp(r'\.(?:wav|opus(?:\.bin)?)$'),
            '',
          );
          final textTarget = File(p.join(destination.path, '$stem.txt'));
          await textTarget.writeAsString(
            normalizeSttText(transcript),
            flush: true,
          );
          transcripts++;
        }
      } catch (e) {
        failed.add('$name：无法保存，请重试');
      }
    }

    statusMessage = failed.isEmpty
        ? '已另存 $audios 个录音、$transcripts 份转写'
        : '另存完成：$audios 个录音，${failed.length} 个失败';
    errorMessage = failed.isEmpty ? null : failed.join('\n');
    notifyListeners();
    return (audios: audios, transcripts: transcripts, failed: failed);
  }

  /// Materialize the selected recordings and transcript sidecars for the
  /// platform share sheet (AirDrop, Save to Files, and other apps on iOS).
  Future<List<String>> prepareLocalSharePaths(Iterable<String> paths) async {
    final result = <String>[];
    final sidecarDir = Directory(
      p.join(Directory.systemTemp.path, 'AnkerRecorder', 'share'),
    );
    await sidecarDir.create(recursive: true);

    for (final path in paths.toSet()) {
      _requireFinishedRecording(path);
      final audio = File(path);
      if (!await audio.exists()) continue;
      result.add(path);

      final transcript = transcriptForPath(path)?.trim();
      if (transcript == null || transcript.isEmpty) continue;
      final name = p.basename(path);
      final stem = name.replaceFirst(RegExp(r'\.(?:wav|opus(?:\.bin)?)$'), '');
      final sidecar = File(p.join(sidecarDir.path, '$stem.txt'));
      await sidecar.writeAsString(normalizeSttText(transcript), flush: true);
      result.add(sidecar.path);
    }
    return result;
  }

  Future<({int deleted, List<String> failed})> deleteLocalExports(
    Iterable<String> paths,
  ) async {
    await _minutesLoaded;

    final selected = paths.toSet();
    // Invalidate an in-flight restore before any asynchronous side effect, so
    // this explicit user action is the final writer for the path.
    for (final path in selected) {
      archive.invalidateRestore(path);
    }
    // Permanent deletion must run after persisted transcripts have loaded;
    // otherwise the load can repopulate the maps and save the entry back.
    await _transcriptsLoaded;
    final removed = <String>{};
    var deleted = 0;
    final failed = <String>[];
    var historyCleanupFailed = false;
    var bookmarkCleanupFailed = false;

    for (final path in selected) {
      final id = ExportCatalog.fileIdFromPath(path);
      final existing = library.assetForPath(path);
      final keepDeviceTombstone =
          id != null &&
          existing?.trashed == true &&
          existing?.source == RecordingSource.device;
      final tombstone = keepDeviceTombstone
          ? existing!.copyWith(permanentlyDeleted: true)
          : null;
      final logicalPaths = id == null
          ? <String>{path}
          : <String>{
              path,
              p.join(p.dirname(path), '$id.wav'),
              p.join(p.dirname(path), '$id.opus'),
              p.join(p.dirname(path), '$id.ogg'),
              p.join(p.dirname(path), '$id.opus.bin'),
            };
      for (final candidate in logicalPaths.toList()) {
        logicalPaths.add(
          candidate.endsWith('.opus')
              ? '${candidate.substring(0, candidate.length - 5)}.ogg'
              : '$candidate.ogg',
        );
      }
      final pairedBefore = [
        for (final document in minutes.documents)
          if (document.audioPath != null &&
              logicalPaths.contains(document.audioPath))
            document,
      ];
      var clearedPairing = false;
      final preDeleted = archive.phoneStore.recordForPath(path);
      var metadataForgotten = false;
      var forgottenVersion = -1;
      try {
        _requireFinishedRecording(path);
        if (_fileJobKey == _recordingKey(path: path)) {
          throw StateError('处理完成后再删除');
        }
        if (playingPath == path || (id != null && playingFileId == id)) {
          await stopPlayback();
        }
        // Detach minutes before removing anything so a failed pairing write
        // never leaves documents pointing at irreversibly deleted audio.
        await minutes.clearAudioForPaths(logicalPaths);
        clearedPairing = true;

        await archive.forgetLocalPath(path);
        metadataForgotten = true;
        forgottenVersion = archive.localChangeVersion(path);
        if (tombstone != null) await library.upsert(tombstone);
        for (final candidate in logicalPaths) {
          final file = File(candidate);
          if (await file.exists()) await file.delete();
          if (candidate != tombstone?.path) {
            await library.remove(candidate, strict: false);
          }
          transcriptsByPath.remove(candidate);
          speakerAliasesByPath.remove(candidate);
          _localDurations.remove(candidate);
        }
        if (id != null) {
          transcriptsByFileId.remove(id);
          speakerAliasesByFileId.remove(id);
        }
        final key = _recordingKey(path: path);
        try {
          await playbackHistory.forget(fileId: id, path: path);
        } catch (_) {
          // The recording is already gone; stale history must not turn a
          // completed deletion into a failure or skip the remaining cleanup.
          historyCleanupFailed = true;
        }
        _bookmarkGenerations[key] = (_bookmarkGenerations[key] ?? 0) + 1;
        try {
          await _bookmarksLoaded;
          await bookmarks.forgetRecording(key);
        } catch (_) {
          bookmarkCleanupFailed = true;
        }
        await _fileJobs.discard(key);
        await topics.forgetRecording(key);
        await analysis.forgetRecording(key);
        _transcriptPathsByKey.remove(key);
        _observedPlacements = Map<String, TopicPlacement>.from(
          topics.placements,
        );
        _deferredJobs.discard(key);
        _transcriptMetadata.remove(key);
        _recordingTranslations.remove(key);
        _transcriptSegments.remove(key);
        _manualTranscripts.remove(key);
        _incomingTranscripts.remove(key);
        _segmentSpeakers.remove(key);
        _recordingErrors.remove(key);
        _recordingSessions.removeWhere(
          (_, session) =>
              id != null && session.fileId == id || session.path == path,
        );
        removed.add(path);
        deleted++;
      } catch (error) {
        if (clearedPairing) {
          for (final document in pairedBefore) {
            final audio = document.audioPath;
            if (audio == null || !await File(audio).exists()) continue;
            try {
              await minutes.upsert(document, strict: true);
            } catch (_) {}
          }
        }
        if (metadataForgotten && preDeleted != null) {
          try {
            final restored = await archive.recoverForgottenRecord(
              preDeleted,
              expectedVersion: forgottenVersion,
            );
            if (!restored) {
              failed.add('${p.basename(path)}：删除失败，归档记录已有新操作，请检查资料状态');
            }
          } catch (_) {
            failed.add('${p.basename(path)}：删除失败，且归档记录无法恢复；请重新归档修复');
          }
        }
        if (tombstone != null && existing != null) {
          await library.upsert(existing, strict: false);
        }
        failed.add('${p.basename(path)}：无法删除，请稍后重试');
      }
    }

    exportedPaths.removeWhere((path) {
      final id = ExportCatalog.fileIdFromPath(path);
      return removed.contains(path) ||
          (id != null &&
              removed.any((item) => ExportCatalog.fileIdFromPath(item) == id));
    });
    _registerExportedPaths(exportedPaths);
    if (expandedLocalPath != null && selected.contains(expandedLocalPath)) {
      expandedLocalPath = null;
    }
    await _persistTranscripts();
    statusMessage = failed.isEmpty
        ? '已删除 $deleted 个本地录音'
        : '已删除 $deleted 个本地录音，${failed.length} 个未完成';
    final errors = [
      ...failed,
      if (historyCleanupFailed) '录音已删除，但播放进度记录未能清理',
      if (bookmarkCleanupFailed) '录音已删除，但书签记录未能清理',
    ];
    errorMessage = errors.isEmpty ? null : errors.join('\n');
    notifyListeners();
    return (deleted: deleted, failed: failed);
  }

  List<RecordingAsset> get trashedAssets {
    final items = library.assets
        .where((asset) => asset.trashed && !asset.permanentlyDeleted)
        .toList();
    items.sort((a, b) {
      final left = a.deletedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right = b.deletedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return right.compareTo(left);
    });
    return List.unmodifiable(items);
  }

  int trashDaysRemaining(RecordingAsset asset, {DateTime? now}) {
    final deletedAt = asset.deletedAt;
    if (deletedAt == null) return RecorderController.trashRetention.inDays;
    final elapsed = (now ?? DateTime.now()).difference(deletedAt);
    final remaining = RecorderController.trashRetention - elapsed;
    if (remaining <= Duration.zero) return 0;
    // A partial final day still allows restore; round up instead of
    // truncating 1 hour left to zero and disabling the action.
    return (remaining.inMinutes / Duration.minutesPerDay).ceil();
  }

  /// Hides materials from the library while keeping their only original.
  Future<({int trashed, List<String> failed})> trashLocalExports(
    Iterable<String> paths, {
    DateTime? now,
  }) async {
    final selected = paths.toSet();
    for (final path in selected) {
      archive.invalidateRestore(path);
    }
    await _libraryLoaded;
    final stamp = now ?? DateTime.now();
    var trashed = 0;
    final failed = <String>[];
    final queued = <String>{};
    for (final path in selected) {
      try {
        _requireFinishedRecording(path);
        if (_fileJobKey == _recordingKey(path: path)) {
          throw StateError('处理完成后再删除');
        }
        final id = ExportCatalog.fileIdFromPath(path);
        if (playingPath == path || (id != null && playingFileId == id)) {
          await stopPlayback();
        }
        final existing = library.assetForPath(path);
        final asset =
            existing ??
            RecordingAsset(
              path: path,
              displayName: _recordingTitleForPath(path),
              source: RecordingSource.device,
              recordedAt: id == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(id * 1000),
              importedAt: _localFileTimestamp(path) ?? stamp,
            );
        await library.upsert(asset.copyWith(archived: true, deletedAt: stamp));
        final key = _recordingKey(path: path);
        analysis.suspendRecording(key);
        _discardTrashedFileJob(key);
        _topicAssistLatest.remove(key);
        queued.add(path);
        trashed++;
      } catch (error) {
        failed.add('${p.basename(path)}：无法移到回收站，请稍后重试');
      }
    }
    if (queued.isNotEmpty) {
      exportedPaths.removeWhere((path) {
        if (queued.contains(path)) return true;
        final id = ExportCatalog.fileIdFromPath(path);
        return id != null &&
            queued.any((item) => ExportCatalog.fileIdFromPath(item) == id);
      });
      _registerExportedPaths(exportedPaths);
    }
    statusMessage = failed.isEmpty
        ? '已移到回收站，30 天内可恢复'
        : '已移到回收站 $trashed 个，${failed.length} 个失败';
    errorMessage = failed.isEmpty ? null : failed.join('\n');
    notifyListeners();
    return (trashed: trashed, failed: failed);
  }

  void _discardTrashedFileJob(String key) {
    _deferredJobs.discard(key);
    unawaited(
      _fileJobsLoaded
          .then((_) => _fileJobs.discard(key))
          .catchError((Object _) {}),
    );
  }

  Future<void> restoreTrashed(String path, {DateTime? now}) async {
    await _libraryLoaded;
    final asset = library.assetForPath(path);
    if (asset == null || !asset.trashed) {
      throw StateError('资料不在回收站中');
    }
    if (asset.permanentlyDeleted) {
      throw StateError('资料已彻底删除，无法恢复');
    }
    final deletedAt = asset.deletedAt;
    if (deletedAt != null &&
        (now ?? DateTime.now()).difference(deletedAt) >=
            RecorderController.trashRetention) {
      throw StateError('已超过 30 天保留期，无法恢复');
    }
    if (!await File(path).exists()) {
      throw StateError('原件已丢失，无法恢复');
    }
    await library.upsert(asset.copyWith(archived: false, clearDeletedAt: true));
    analysis.resumeRecording(_recordingKey(path: path));
    _registerExportedPaths([...exportedPaths, path]);
    statusMessage = '已从回收站恢复';
    errorMessage = null;
    notifyListeners();
  }

  /// Explicit, irreversible removal. Callers must confirm first.
  Future<({int deleted, List<String> failed})> emptyTrash({
    Iterable<String>? paths,
  }) async {
    await _libraryLoaded;
    final targets = (paths ?? trashedAssets.map((asset) => asset.path)).toSet();
    var deleted = 0;
    final failed = <String>[];
    for (final path in targets) {
      final result = await deleteLocalExports([path]);
      deleted += result.deleted;
      failed.addAll(result.failed);
    }
    if (deleted > 0) {
      statusMessage = '已彻底删除 $deleted 个资料';
    }
    notifyListeners();
    return (deleted: deleted, failed: failed);
  }

  Future<int> purgeExpiredTrash({DateTime? now}) async {
    await _libraryLoaded;
    await _topicsLoaded;
    await _transcriptsLoaded;
    return _purgeExpiredTrash(now: now);
  }

  Future<void> _purgeTrashWhenReady() async {
    await _libraryLoaded;
    await _topicsLoaded;
    await _transcriptsLoaded;
    if (_disposed) return;
    await _purgeExpiredTrash();
  }

  Future<int>? _trashPurgeInFlight;

  Future<int> _purgeExpiredTrash({DateTime? now}) async {
    final running = _trashPurgeInFlight;
    if (running != null) return running;
    final task = _runPurgeExpiredTrash(now: now);
    _trashPurgeInFlight = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_trashPurgeInFlight, task)) {
          _trashPurgeInFlight = null;
        }
      }),
    );
    return task;
  }

  Future<int> _runPurgeExpiredTrash({DateTime? now}) async {
    final stamp = now ?? DateTime.now();
    final expired = library.assets
        .where(
          (asset) =>
              asset.trashed &&
              !asset.permanentlyDeleted &&
              asset.deletedAt != null &&
              stamp.difference(asset.deletedAt!) >=
                  RecorderController.trashRetention,
        )
        .map((asset) => asset.path)
        .toList();
    var purged = 0;
    for (final path in expired) {
      if (_disposed) break;
      final result = await deleteLocalExports([path]);
      purged += result.deleted;
    }
    return purged;
  }

  /// Removes only derived playback files. The library original is never a
  /// candidate, even when the archive was not verified.
  Future<({int removed, int bytes, List<String> skipped})>
  clearRecoverableCache(String path) async {
    await _libraryLoaded;
    final asset = library.assetForPath(path);
    final original = asset?.path ?? path;
    final id = ExportCatalog.fileIdFromPath(original);
    if (id == null) {
      return (removed: 0, bytes: 0, skipped: <String>['无法确认缓存归属，已保留全部文件']);
    }
    if (!await File(original).exists()) {
      return (removed: 0, bytes: 0, skipped: <String>['原件不在本机，未清理任何文件']);
    }
    final directory = p.dirname(original);
    final hasRawSource =
        original.endsWith('.opus') ||
        original.endsWith('.opus.bin') ||
        await File(p.join(directory, '$id.opus')).exists() ||
        await File(p.join(directory, '$id.opus.bin')).exists();
    if (!hasRawSource) {
      return (removed: 0, bytes: 0, skipped: <String>['这条资料没有可重建的播放缓存']);
    }
    final candidates = <String>{
      p.join(directory, '$id.wav'),
      p.join(directory, '$id.ogg'),
      '$original.ogg',
      if (original.endsWith('.opus'))
        '${original.substring(0, original.length - 5)}.ogg',
    }..remove(original);
    var removed = 0;
    var bytes = 0;
    final skipped = <String>[];
    for (final candidate in candidates) {
      final file = File(candidate);
      if (!await file.exists()) continue;
      try {
        final length = await file.length();
        await file.delete();
        removed++;
        bytes += length;
        _invalidateLocalDuration(candidate);
      } catch (error) {
        skipped.add('${p.basename(candidate)}：无法清理');
      }
    }
    statusMessage = removed == 0
        ? '没有可清理的播放缓存，原件已保留'
        : '已清理 $removed 个可重建缓存，原件与原文字保留';
    errorMessage = skipped.isEmpty ? null : skipped.join('\n');
    notifyListeners();
    return (removed: removed, bytes: bytes, skipped: skipped);
  }

  bool hasRecoverableCacheForPath(String path) {
    final asset = library.assetForPath(path);
    final original = asset?.path ?? path;
    final id = ExportCatalog.fileIdFromPath(original);
    if (id == null || !File(original).existsSync()) return false;
    final directory = p.dirname(original);
    if (!original.endsWith('.opus') &&
        !original.endsWith('.opus.bin') &&
        !File(p.join(directory, '$id.opus')).existsSync() &&
        !File(p.join(directory, '$id.opus.bin')).existsSync()) {
      return false;
    }
    final candidates = <String>{
      p.join(directory, '$id.wav'),
      p.join(directory, '$id.ogg'),
      '$original.ogg',
      if (original.endsWith('.opus'))
        '${original.substring(0, original.length - 5)}.ogg',
    }..remove(original);
    return candidates.any((candidate) => File(candidate).existsSync());
  }

  Future<String> renameLocalExport(String path, String label) async {
    await _minutesLoaded;
    archive.invalidateRestore(path);
    _requireFinishedRecording(path);
    if (_fileJobKey == _recordingKey(path: path)) throw StateError('处理完成后再重命名');
    final source = File(path);
    if (!await source.exists()) throw StateError('文件不存在');

    final targetName = ExportCatalog.renamedFileName(path, label);
    final targetPath = p.join(p.dirname(path), targetName);
    if (targetPath == path) return path;
    archive.invalidateRestore(targetPath);
    final target = File(targetPath);
    if (await target.exists()) throw StateError('同名文件已存在');

    final id = ExportCatalog.fileIdFromPath(path);
    if (playingPath == path || (id != null && playingFileId == id)) {
      await stopPlayback();
    }
    if (_fileJobs.jobs[_recordingKey(path: path)]?.recoverable == true) {
      throw StateError('转写完成后再重命名');
    }
    // Persist the minutes pairing first; if it fails nothing else has moved.
    await minutes.updateAudioPath(path, targetPath);

    // Pre-commit archive metadata before touching the original file or the
    // library. If this fails, the local rename has not happened and can be
    // retried exactly as before.
    try {
      await archive.renameLocalPath(path, targetPath);
    } catch (_) {
      await _revertMinutesRename(targetPath, path);
      errorMessage = '归档状态预提交失败，未重命名本地原件；请检查存储空间后重试';
      statusMessage = '重命名未开始，原件保持不变';
      notifyListeners();
      throw StateError('归档状态预提交失败，未重命名本地原件，请重试');
    }
    final precommitted = archive.phoneStore.recordForPath(targetPath);
    var physicalRenamed = false;
    try {
      await source.rename(targetPath);
      physicalRenamed = true;
      final oldKey = _recordingKey(path: path);
      final newKey = _recordingKey(path: targetPath);
      await _fileJobs.rename(oldKey, newKey, targetPath);
      await topics.renameRecordingKey(oldKey, newKey);
      await analysis.renameRecordingKey(oldKey, newKey);
      if (_transcriptPathsByKey.remove(oldKey) != null) {
        _transcriptPathsByKey[newKey] = targetPath;
      }
      if (oldKey != newKey) {
        final segments = _transcriptSegments.remove(oldKey);
        if (segments != null) _transcriptSegments[newKey] = segments;
      }
      _observedPlacements = Map<String, TopicPlacement>.from(topics.placements);
      final transcript = transcriptsByPath.remove(path);
      if (transcript != null) transcriptsByPath[targetPath] = transcript;
      final aliases = speakerAliasesByPath.remove(path);
      if (aliases != null) speakerAliasesByPath[targetPath] = aliases;
      for (final session in _recordingSessions.values) {
        if (session.path == path) session.path = targetPath;
      }
      final cachedDuration = _localDurations.remove(path);
      if (cachedDuration != null) _localDurations[targetPath] = cachedDuration;
      final asset = library.assetForPath(path);
      if (asset != null) {
        await library.rename(
          path,
          asset.copyWith(path: targetPath, displayName: label.trim()),
          strict: false,
        );
      }
      final renamedPaths = exportedPaths
          .map((item) => item == path ? targetPath : item)
          .toList();
      exportedPaths = [];
      _registerExportedPaths(renamedPaths);
      if (expandedLocalPath == path) expandedLocalPath = targetPath;
      await _persistTranscripts();
    } catch (_) {
      if (!physicalRenamed) {
        await _revertMinutesRename(targetPath, path);
        final rolledBack = await _rollbackArchiveRename(
          targetPath,
          path,
          precommitted,
        );
        if (!rolledBack && precommitted != null) {
          errorMessage = '重命名未完成，但归档记录已预提交且无法安全回滚；请重新归档修复';
          statusMessage = '本地原件未改名，归档记录需要修复';
          notifyListeners();
          throw StateError('本地原件未改名，归档记录需要修复，请重新归档');
        }
        errorMessage = '重命名失败，原件保持不变；请重试';
        statusMessage = '重命名未生效，原件保持不变';
        notifyListeners();
        throw StateError('重命名失败，原件保持不变，请重试');
      }
      errorMessage = '文件已改名为 $targetName，但资料库/索引更新失败；请重试或重新归档';
      statusMessage = '文件已改名，资料库更新失败';
      notifyListeners();
      throw StateError('文件已改名，但后续资料库更新失败，请重试');
    }

    statusMessage = '已重命名为 $targetName';
    errorMessage = null;
    notifyListeners();
    return targetPath;
  }

  /// Best effort: a failed revert leaves minutes pointing at [from]; the
  /// minutes screen treats a missing file as unavailable audio.
  Future<void> _revertMinutesRename(String from, String to) async {
    try {
      await minutes.updateAudioPath(from, to);
    } catch (_) {}
  }

  Future<bool> _rollbackArchiveRename(
    String from,
    String to,
    ArchivePhoneRecord? precommitted,
  ) async {
    if (precommitted == null) return true;
    try {
      return await archive.phoneStore.rollbackRename(
        from: from,
        to: to,
        expected: precommitted,
      );
    } catch (_) {
      return false;
    }
  }

  void _registerExportedPaths(Iterable<String> paths) {
    final trashedPaths = <String>{};
    final trashedIds = <int>{};
    for (final asset in library.assets.where((asset) => asset.trashed)) {
      trashedPaths.add(asset.path);
      final id = ExportCatalog.fileIdFromPath(asset.path);
      if (id != null) trashedIds.add(id);
    }
    final accepted = <String>[];
    for (final path in [...exportedPaths, ...paths]) {
      if (trashedPaths.contains(path)) continue;
      final id = ExportCatalog.fileIdFromPath(path);
      if (id != null && trashedIds.contains(id)) continue;
      accepted.add(path);
    }
    exportedPaths = ExportCatalog.newestPathsFirst([...accepted]);
    localPathsByFileId.clear();
    for (final path in exportedPaths) {
      final id = ExportCatalog.fileIdFromPath(path);
      if (id != null) localPathsByFileId[id] = path;
    }
    _localDurations.removeWhere((path, _) => !exportedPaths.contains(path));
  }

  Duration? localDurationForPath(String path) {
    final cached = _localDurations[path];
    if (cached != null) return cached;
    if (!_durationLoads.containsKey(path)) {
      final token = Object();
      _durationLoads[path] = token;
      unawaited(_loadLocalDuration(path, token));
    }
    return null;
  }

  /// Drops a cached duration and invalidates any read already in flight.
  /// A read that started before the audio changed must not write its old value
  /// back after [AudioDuration.read] returns.
  void _invalidateLocalDuration(String path) {
    _localDurations.remove(path);
    _durationLoads.remove(path);
  }

  Future<void> _loadLocalDuration(String path, Object token) async {
    try {
      final value = await _localDurationReader(path);
      if (!identical(_durationLoads[path], token)) return;
      if (value != null && exportedPaths.contains(path)) {
        _localDurations[path] = value;
        notifyListeners();
      }
    } finally {
      if (identical(_durationLoads[path], token)) _durationLoads.remove(path);
    }
  }

  Future<String> _convertExportToWav(
    String path, {
    bool register = true,
    List<String>? conversionFailures,
  }) async {
    if (!path.endsWith('.opus')) return path;
    final existing = _wavConversions[path];
    final ownsConversion = existing == null;
    final conversion = existing ?? _rawExportConverter(path);
    if (ownsConversion) {
      _wavConversions[path] = conversion;
    }
    try {
      final wavPath = await conversion;
      // Pause/resume and reconnect append to the raw file, then reconvert the
      // same WAV path. Drop the old cached value before the list rebuilds so
      // the row reflects the longer audio without waiting for a restart.
      _invalidateLocalDuration(path);
      _invalidateLocalDuration(wavPath);
      if (register) {
        _registerExportedPaths([wavPath]);
        if (errorMessage == '无法准备播放，录音已保留，请重试') {
          errorMessage = null;
        }
        notifyListeners();
      }
      return wavPath;
    } catch (error) {
      debugPrint('[Exports] WAV conversion failed for $path: $error');
      final failure = '${p.basename(path)}: $error';
      if (conversionFailures != null) {
        conversionFailures.add(failure);
      } else {
        errorMessage = '无法准备播放，录音已保留，请重试';
        notifyListeners();
      }
      return path;
    } finally {
      if (ownsConversion && identical(_wavConversions[path], conversion)) {
        _wavConversions.remove(path);
      }
    }
  }
}
