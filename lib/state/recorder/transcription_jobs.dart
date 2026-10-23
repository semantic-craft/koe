part of '../recorder_controller.dart';

/// File transcription jobs: the persisted job journal and its recovery, the
/// deferred queue, cloud/Apple file transcription and recording translation.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderTranscriptionJobs on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  SpeechConfiguration get _activeConfiguration;
  abstract final AppleSpeechService _appleSpeech;
  abstract bool _disposed;
  abstract final DoubaoSttService _doubaoStt;
  abstract final Map<SttProvider, _SttEngine> _sttEngines;
  Future<T> _whileAiWorks<T>(Future<T> Function() request);
  bool _isConfigured(SpeechConfiguration config);
  bool _isRecordingAudioLocked(int? id, String? path);
  bool _isTrashedPath(String path);
  Future<void> _labelSpeakersLater(
    String path,
    List<TranscriptSegment> previous,
  );
  abstract final Future<void> _libraryLoaded;
  bool get _liveProcessing;
  Future<void> _persistTranscripts({bool strict = false});
  abstract final QwenSttService _qwenStt;
  abstract final Map<String, String> _recordingErrors;
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  abstract final Map<String, RecordingTranslation> _recordingTranslations;
  String _referenceKey(RecordingReference ref);
  bool _sameSegments(String path, List<TranscriptSegment> fresh);
  Future<void> _scheduleTopicAssist(String recordingKey, String transcript);
  _RecordingSession? _sessionForReference(RecordingReference ref);
  SpeechConfiguration _configurationForProvider(
    SttProvider provider, {
    String? sourceLanguage,
    bool cloudUploadConfirmed,
  });
  SpeechConfiguration get _settingsConfiguration;
  abstract final Future<void> _settingsLoaded;
  String _speechErrorMessage(Object error);
  bool _takenAsVoiceNote(String? path);
  abstract final Map<String, TranscriptMetadata> _transcriptMetadata;
  abstract Future<void> _transcriptsLoaded;
  abstract String appleSourceLanguage;
  int? expectedSpeakersForPath(String path);
  int? fileIdFromPath(String path);
  abstract SttFileProgress? fileTranscriptionProgress;
  RecordingViewData recordingView(RecordingReference ref);
  void rememberTranscript(
    String path,
    String text, {
    SttProvider? provider,
    String? sourceLanguage,
    List<TranscriptSegment>? segments,
  });
  Map<String, String> speakerAliasesForPath(String path);
  abstract bool meetingLocalOnly;
  String get meetingLocalOnlyUnavailableMessage;
  bool get onDeviceSpeechSupported;
  abstract SttProvider speechProvider;
  abstract String? statusMessage;
  abstract bool streamingSttActive;
  abstract final bool topicsEnabled;
  abstract bool transcribing;
  abstract String? transcribingPath;
  String? transcriptForPath(String path);
  List<TranscriptSegment> transcriptSegmentsForPath(String path);
  abstract String translationTargetLanguage;
  // END DEPS

  bool get doubaoFileProcessing => _fileJobProvider == SttProvider.doubao;

  /// The provider currently running a file transcription job for [ref], or
  /// null when no file job is actively running for this recording.
  SttProvider? activeFileJobProviderFor(RecordingReference ref) {
    final key = _referenceKey(ref);
    if (_fileJobKey == null || _fileJobKey != key) return null;
    return _fileJobProvider;
  }

  void cancelDoubaoFileProcessing() {
    if (doubaoFileProcessing) {
      _doubaoStt.cancelCurrent();
      statusMessage = '正在停止等待；结果未确认时，重试会重新上传并可能重复计费';
      notifyListeners();
    }
  }

  void cancelQwenFileProcessing() {
    if (_fileJobProvider == SttProvider.qwen) {
      _qwenStt.cancelCurrent();
      statusMessage = '正在停止等待；云端任务如已提交会保留，稍后可继续查询';
      notifyListeners();
    }
  }

  Completer<void>? _activeFileJobCompleter;

  bool _fileJobPreparing = false;
  late final FileJobJournal _fileJobs;
  late final Future<void> _fileJobsLoaded;
  String? fileJobRecoveryError;

  Future<void> _restoreFileJobs() async {
    try {
      await Future.wait([_settingsLoaded, _transcriptsLoaded, _libraryLoaded]);
      await _fileJobs.load();
      var blockedAny = false;
      for (final job in _fileJobs.jobs.values.toList()) {
        if (_disposed) return;
        if (!job.recoverable) continue;
        final resolved = job.resolve(_settingsConfiguration);
        final needsUpload =
            !resolved.provider.onDevice &&
            job.stage != 'result' &&
            job.taskId == null;
        if (meetingLocalOnly && !_takenAsVoiceNote(job.path) && needsUpload) {
          const message = '已开启「录音只留本机」，云端转写会上传音频，请确认后再试';
          job.stage = 'failed';
          job.error = message;
          _recordingErrors[job.key] = message;
          blockedAny = true;
          continue;
        }
        await _deferredJobs.enqueue(job.key, job.path, resolved);
      }
      if (blockedAny) {
        try {
          await _fileJobs.save();
        } catch (_) {}
      }
    } catch (_) {
      fileJobRecoveryError = '无法读取转写任务记录；请保留数据并检查存储空间';
    }
    notifyListeners();
  }

  bool get fileProcessingBusy =>
      _fileJobKey != null || _fileJobPreparing || _liveProcessing;

  Future<SpeechResourceStatus> recordingSpeechStatus(
    String sourceLanguage,
  ) async {
    final capabilities = await _appleSpeech.capabilities(
      sourceLanguage: sourceLanguage,
    );
    return capabilities.speechStatus;
  }

  SttProvider? _pendingTranscribeProvider;
  bool _pendingCloudUploadConfirmed = false;

  /// Runs manual transcription on [ref] with an explicit [provider] and/or
  /// user confirmation for uploading meeting audio to a cloud engine (#376).
  /// Never mutates the global [speechProvider].
  Future<void> confirmCloudTranscribeRecording(
    RecordingReference ref, {
    SttProvider? provider,
    String? sourceLanguage,
    bool prepareLanguages = false,
    bool confirmCloudUpload = true,
  }) async {
    final previousProvider = _pendingTranscribeProvider;
    final previousConfirmed = _pendingCloudUploadConfirmed;
    _pendingTranscribeProvider = provider;
    _pendingCloudUploadConfirmed = confirmCloudUpload;
    try {
      await transcribeRecording(
        ref,
        sourceLanguage: sourceLanguage,
        prepareLanguages: prepareLanguages,
      );
    } finally {
      _pendingTranscribeProvider = previousProvider;
      _pendingCloudUploadConfirmed = previousConfirmed;
    }
  }

  Future<void> transcribeRecording(
    RecordingReference ref, {
    String? sourceLanguage,
    bool prepareLanguages = false,
  }) async {
    final explicitProvider = _pendingTranscribeProvider;
    final confirmCloudUpload = _pendingCloudUploadConfirmed;
    _pendingTranscribeProvider = null;
    _pendingCloudUploadConfirmed = false;
    final view = recordingView(ref);
    if (view.path == null) {
      _recordingErrors[_referenceKey(ref)] = '请先下载录音';
      notifyListeners();
      return;
    }
    await _settingsLoaded;
    await _libraryLoaded;
    if (_disposed) return;
    final targetProvider = explicitProvider ?? speechProvider;
    if (meetingLocalOnly &&
        !_takenAsVoiceNote(view.path) &&
        !targetProvider.onDevice &&
        !confirmCloudUpload) {
      _recordingErrors[_referenceKey(ref)] = '已开启「录音只留本机」，云端转写会上传音频，请确认后再试';
      notifyListeners();
      return;
    }
    await transcribeLocalFile(
      view.path!,
      provider: targetProvider,
      confirmCloudUpload: confirmCloudUpload,
      sourceLanguage:
          sourceLanguage ??
          (targetProvider.requiresSourceLanguage &&
                  view.sourceLanguage != 'auto'
              ? view.sourceLanguage
              : null),
      prepareLanguages: prepareLanguages,
    );
  }

  /// File jobs never write the current live transcript.
  Future<void> transcribeLocalFile(
    String path, {
    String? sourceLanguage,
    bool prepareLanguages = false,
    SttProvider? provider,
    bool confirmCloudUpload = false,
  }) async {
    await _settingsLoaded;
    if (_disposed) return;
    final targetProvider = provider ?? speechProvider;
    final config = _configurationForProvider(
      targetProvider,
      sourceLanguage: sourceLanguage,
      cloudUploadConfirmed: confirmCloudUpload,
    );
    await _fileJobsLoaded;
    await _libraryLoaded;
    // Manual retry runs straight through the deferred mechanism's executor so
    // the engine answers a busy start with its own readable error.
    await _deferredJobs.runNow(
      path,
      config,
      prepareLanguages: prepareLanguages,
    );
  }

  /// Returns false when a queued deferred job should wait and try again.
  Future<bool> _runFileTranscription(
    String path,
    SpeechConfiguration config, {
    bool prepareLanguages = false,
    bool fromQueue = false,
  }) async {
    if (_disposed) return true;
    await _libraryLoaded;
    await _fileJobsLoaded;
    await _settingsLoaded;
    final key = _recordingKey(path: path);
    if (_isTrashedPath(path)) {
      await _fileJobs.discard(key);
      _deferredJobs.discard(key);
      return true;
    }
    if (fileProcessingBusy ||
        _isRecordingAudioLocked(fileIdFromPath(path), path)) {
      if (!fromQueue) {
        _recordingErrors[key] = '请在当前录音或处理结束后重试';
        notifyListeners();
      }
      return !fromQueue;
    }
    final isMeeting = !_takenAsVoiceNote(path);
    final existingJob = _fileJobs.jobs[key];
    final resumesWithoutUpload =
        existingJob != null &&
        (existingJob.stage == 'result' ||
            existingJob.stage == 'running' && existingJob.taskId != null);
    final effectiveProvider = resumesWithoutUpload
        ? (SttProvider.parse(existingJob.config['provider']) ?? config.provider)
        : config.provider;
    if (isMeeting &&
        meetingLocalOnly &&
        !effectiveProvider.onDevice &&
        !resumesWithoutUpload &&
        !config.cloudUploadConfirmed) {
      const message = '已开启「录音只留本机」，云端转写会上传音频，请确认后再试';
      _recordingErrors[key] = message;
      if (existingJob != null &&
          existingJob.taskId == null &&
          existingJob.stage != 'result') {
        existingJob.stage = 'failed';
        existingJob.error = message;
        try {
          await _fileJobs.save();
        } catch (_) {}
      }
      notifyListeners();
      return true;
    }
    if (_fileJobs.jobs[key]?.stage != 'result' &&
        (config.provider.needsCredentials
            ? !_isConfigured(config)
            : config.sourceLanguage.isEmpty)) {
      if (!config.provider.needsCredentials &&
          isMeeting &&
          meetingLocalOnly &&
          !onDeviceSpeechSupported) {
        _recordingErrors[key] = meetingLocalOnlyUnavailableMessage;
      } else {
        _recordingErrors[key] = config.provider.needsCredentials
            ? '请在设置中配置 ${config.provider.label}'
            : '请选择录音语言';
      }
      final pending = _fileJobs.jobs[key];
      if (pending != null) {
        pending.error = _recordingErrors[key];
        if (pending.taskId == null) pending.stage = 'failed';
        try {
          await _fileJobs.save();
        } catch (_) {}
      }
      notifyListeners();
      return true;
    }
    _fileJobPreparing = true;
    final jobCompleter = Completer<void>();
    _activeFileJobCompleter = jobCompleter;
    void finishJobCompleter() {
      if (!jobCompleter.isCompleted) jobCompleter.complete();
      if (identical(_activeFileJobCompleter, jobCompleter)) {
        _activeFileJobCompleter = null;
      }
    }

    FileJob job;
    try {
      final version = await audioVersion(path);
      final previous = _fileJobs.jobs[key];
      // A missing file has no version; it is not "changed" audio and must
      // reach the readable missing-recording failure below instead.
      if (version != null &&
          previous?.audioHash != null &&
          previous!.audioHash != version &&
          (fromQueue ||
              previous.stage == 'result' ||
              previous.stage == 'running' && previous.taskId != null)) {
        previous.audioChanged = true;
        previous.error = '音频内容已变化，原任务与结果保留；请恢复原音频后重试';
        _recordingErrors[key] = previous.error!;
        await _fileJobs.save();
        _fileJobPreparing = false;
        finishJobCompleter();
        notifyListeners();
        return true;
      }
      job = await _fileJobs.enqueue(key, path, config, retry: !fromQueue);
      if (version != null &&
          previous?.audioHash != null &&
          previous!.audioHash != version) {
        job.audioChanged = true;
      }
      if (version != null && job.audioHash == null) {
        job.audioHash = version;
        await _fileJobs.save();
      }
      if (fromQueue && !job.recoverable) {
        _fileJobPreparing = false;
        finishJobCompleter();
        return true;
      }
      config = job.resolve(config);
      if (isMeeting &&
          meetingLocalOnly &&
          !config.provider.onDevice &&
          job.stage != 'result' &&
          job.taskId == null &&
          !config.cloudUploadConfirmed) {
        _fileJobPreparing = false;
        const message = '已开启「录音只留本机」，云端转写会上传音频，请确认后再试';
        job.stage = 'failed';
        job.error = message;
        _recordingErrors[key] = message;
        await _fileJobs.save();
        finishJobCompleter();
        notifyListeners();
        return true;
      }
      if (job.stage != 'result' &&
          config.provider.needsCredentials &&
          !_isConfigured(config)) {
        _fileJobPreparing = false;
        job.error = '任务使用的服务地址已变更，请恢复原配置后重试';
        _recordingErrors[key] = job.error!;
        await _fileJobs.save();
        finishJobCompleter();
        notifyListeners();
        return true;
      }
    } catch (_) {
      _fileJobPreparing = false;
      _recordingErrors[key] = '无法保存转写任务，请检查存储空间后重试';
      finishJobCompleter();
      notifyListeners();
      return true;
    }
    _fileJobPreparing = false;
    if (_disposed) {
      finishJobCompleter();
      return true;
    }
    if (_isRecordingAudioLocked(fileIdFromPath(path), path) ||
        config.provider.onDevice && _liveProcessing) {
      _recordingErrors[key] = '处理因录音暂停，可在录音结束后重试';
      finishJobCompleter();
      notifyListeners();
      return !fromQueue;
    }
    final revision = ++_fileJobRevision;
    _fileJobKey = key;
    _fileJobProvider = config.provider;
    transcribingPath = path;
    transcribing = true;
    fileTranscriptionProgress = const SttFileProgress(SttFileStage.preparing);
    _recordingErrors.remove(key);
    notifyListeners();
    bool uploadStillPermitted() =>
        !isMeeting ||
        !meetingLocalOnly ||
        config.provider.onDevice ||
        job.stage == 'result' ||
        job.taskId != null ||
        config.cloudUploadConfirmed;
    try {
      if (fromQueue && !await File(path).exists()) {
        throw StateError('录音文件不存在');
      }
      if (job.stage != 'result') {
        job.stage = 'running';
        job.error = null;
        await _fileJobs.save();
      }
      if (!uploadStillPermitted()) {
        const message = '已开启「录音只留本机」，云端转写会上传音频，请确认后再试';
        job.stage = 'failed';
        job.error = message;
        _recordingErrors[key] = message;
        await _fileJobs.save();
        return true;
      }
      // A run cut off before this mark is rerun on the next launch; after it
      // only the user retries, since the request may have been paid for.
      final cloud = switch (config.provider) {
        SttProvider.qwen => _qwenStt,
        SttProvider.doubao => _doubaoStt,
        _ => null,
      };
      cloud?.onSending = () async {
        job.sent = true;
        await _fileJobs.save();
      };
      if (config.provider == SttProvider.qwen) {
        _qwenStt.recovery = QwenTaskRecovery(
          taskId: job.taskId,
          onSubmitted: (id) async {
            job.taskId = id;
            await _fileJobs.save();
          },
        );
      }
      if (config.provider == SttProvider.apple && job.stage != 'result') {
        final capabilities = await _appleSpeech.capabilities(
          sourceLanguage: config.sourceLanguage,
        );
        if (_disposed || revision != _fileJobRevision) return true;
        if (!capabilities.supported) {
          throw PlatformException(code: 'unsupported');
        }
        if (capabilities.speechStatus == SpeechResourceStatus.unsupported) {
          throw PlatformException(code: 'language_unsupported');
        }
        if (capabilities.speechStatus == SpeechResourceStatus.needsDownload) {
          if (!prepareLanguages) {
            throw PlatformException(code: 'resources_missing');
          }
          await _appleSpeech.prepareLanguages(
            sourceLanguage: config.sourceLanguage,
          );
          if (_disposed || revision != _fileJobRevision) return true;
        }
      }
      if (_isTrashedPath(path)) {
        await _fileJobs.discard(key);
        return true;
      }
      if (!uploadStillPermitted()) {
        const message = '已开启「录音只留本机」，云端转写会上传音频，请确认后再试';
        job.stage = 'failed';
        job.error = message;
        _recordingErrors[key] = message;
        await _fileJobs.save();
        return true;
      }
      final result = job.stage == 'result'
          ? SttResult(
              text: job.text!,
              sourcePath: path,
              language: job.language,
              segments: job.segments,
            )
          : await _transcribePath(
              path,
              configuration: config,
              expectedSpeakers: expectedSpeakersForPath(path),
              isCurrent: () =>
                  !_disposed &&
                  revision == _fileJobRevision &&
                  uploadStillPermitted(),
              onProgress: (progress) {
                if (_disposed || revision != _fileJobRevision) return;
                fileTranscriptionProgress = progress;
                notifyListeners();
              },
            );
      if (_disposed || revision != _fileJobRevision) return true;
      if (job.audioHash != null && await audioVersion(path) != job.audioHash) {
        job.audioChanged = true;
        throw const AudioVersionException('音频内容已变化，迟到结果未覆盖原有文字；请手动重新转写');
      }
      if (_disposed || revision != _fileJobRevision) return true;
      if (result.text.trim().isEmpty) {
        _recordingErrors[key] = '未识别到语音，可重试';
        job.stage = 'failed';
        job.error = _recordingErrors[key];
        await _fileJobs.save();
      } else {
        job.stage = 'result';
        job.text = result.text;
        job.language = result.language;
        job.segments = result.segments;
        await _fileJobs.save();
        final currentPath =
            recordingView(RecordingReference(path: path)).path ?? path;
        final rememberedSegments = RecorderController._rememberedSegments(
          result.segments,
        );
        final shownSegments = transcriptSegmentsForPath(currentPath);
        final remembered =
            transcriptForPath(currentPath) != result.text ||
            _transcriptMetadata[key]?.provider != config.provider ||
            _transcriptMetadata[key]?.sourceLanguage != config.sourceLanguage ||
            !_sameSegments(currentPath, rememberedSegments);
        if (remembered) {
          rememberTranscript(
            currentPath,
            result.text,
            provider: config.provider,
            sourceLanguage: config.provider.requiresSourceLanguage
                ? config.sourceLanguage
                : result.language ?? config.sourceLanguage,
            segments: rememberedSegments,
          );
        }
        try {
          await _persistTranscripts(strict: !_fileJobs.inMemory);
        } catch (error, stack) {
          // The paid result is kept in the job; only local storage failed.
          Error.throwWithStackTrace(_TranscriptSaveFailure(error), stack);
        }
        job.stage = 'complete';
        job.error = null;
        job.audioChanged = false;
        await _fileJobs.save();
        // Meetings kept on this device get their speakers labelled here too,
        // after the words are saved: one pass reads the whole recording.
        if (isMeeting && meetingLocalOnly && config.provider.onDevice) {
          unawaited(_labelSpeakersLater(currentPath, shownSegments));
        }
        if (topicsEnabled && !remembered) {
          unawaited(_scheduleTopicAssist(key, result.text));
        }
        statusMessage = '转写已保存';
        // Refresh a closed live route without retaining an obsolete error.
        final session = _sessionForReference(
          RecordingReference(path: currentPath),
        );
        if (session != null && !session.active) session.error = null;
      }
    } catch (error) {
      if (!_disposed && revision == _fileJobRevision) {
        _recordingErrors[key] = !uploadStillPermitted()
            ? '已开启「录音只留本机」，云端转写会上传音频，请确认后再试'
            : error is PlatformException && error.code == 'resources_missing'
            ? '请下载所选录音语言后重试'
            : error is _TranscriptSaveFailure
            ? '转写结果未能保存；请检查存储空间后重试'
            : _speechErrorMessage(error);
        job.error = _recordingErrors[key];
        if (job.text != null && job.stage == 'complete') job.stage = 'result';
        if (error is QwenTaskFailedException) {
          job.taskId = null;
          job.stage = 'failed';
        }
        // Known task IDs and saved results remain resumable; uncertain requests
        // require an explicit retry and never automatically resubmit.
        if (job.stage != 'result' && job.taskId == null) job.stage = 'failed';
        try {
          await _fileJobs.save();
        } catch (_) {
          _recordingErrors[key] = '无法保存任务状态；请检查存储空间后重试';
        }
      }
    } finally {
      _qwenStt.recovery = null;
      _qwenStt.onSending = null;
      _doubaoStt.onSending = null;
      finishJobCompleter();
      if (!_disposed && revision == _fileJobRevision) {
        _fileJobKey = null;
        _fileJobProvider = null;
        transcribingPath = null;
        fileTranscriptionProgress = null;
        transcribing = streamingSttActive;
        notifyListeners();
      }
    }
    return true;
  }

  Future<void> prepareRecordingTranslation(
    RecordingReference ref, {
    required String sourceLanguage,
    required String targetLanguage,
  }) => translateRecording(
    ref,
    sourceLanguage: sourceLanguage,
    targetLanguage: targetLanguage,
    prepareLanguages: true,
  );

  Future<void> translateRecording(
    RecordingReference ref, {
    String? sourceLanguage,
    String? targetLanguage,
    bool prepareLanguages = false,
  }) async {
    final view = recordingView(ref);
    final key = _referenceKey(ref);
    if (fileProcessingBusy || view.audioLocked) {
      _recordingErrors[key] = '请在当前录音或处理结束后重试';
      notifyListeners();
      return;
    }
    if (view.text.trim().isEmpty) return;
    final source =
        sourceLanguage ??
        (view.sourceLanguage == null || view.sourceLanguage == 'auto'
            ? appleSourceLanguage
            : view.sourceLanguage!);
    final target = targetLanguage ?? translationTargetLanguage;
    if (source.isEmpty) {
      _recordingErrors[key] = '请在设置中选择录音语言';
      notifyListeners();
      return;
    }
    final revision = ++_fileJobRevision;
    final sourceRevision = _transcriptMetadata[key]?.revision ?? 0;
    _fileJobKey = key;
    _fileJobProvider = SttProvider.apple;
    _recordingErrors.remove(key);
    fileTranscriptionProgress = const SttFileProgress(SttFileStage.processing);
    notifyListeners();
    try {
      if (prepareLanguages) {
        await _appleSpeech.prepareTranslation(
          sourceLanguage: source,
          targetLanguage: target,
        );
        if (_disposed || revision != _fileJobRevision) return;
      }
      // Sentence-timed text is translated sentence by sentence so each
      // translated line keeps its source sentence and that sentence's audio.
      // Without such a mapping the whole text is translated and stays
      // read-only; no time is ever derived from the translated text.
      final path = view.path;
      final sourceSegments = view.segments;
      final aligned =
          path != null &&
          transcriptSegmentsMatchText(
            sourceSegments,
            normalizeSttText(view.text),
            aliases: speakerAliasesForPath(path),
          );
      final String translated;
      List<String>? translatedSegments;
      if (aligned) {
        translatedSegments = [];
        for (final segment in sourceSegments) {
          if (_disposed || revision != _fileJobRevision) return;
          final line = segment.text.trim();
          translatedSegments.add(
            line.isEmpty
                ? ''
                : (await _appleSpeech.translate(
                    line,
                    sourceLanguage: source,
                    targetLanguage: target,
                  )).trim(),
          );
        }
        translated = translatedSegments
            .where((line) => line.isNotEmpty)
            .join('\n\n');
      } else {
        translated = await _appleSpeech.translate(
          view.text,
          sourceLanguage: source,
          targetLanguage: target,
        );
      }
      if (_disposed ||
          revision != _fileJobRevision ||
          sourceRevision != (_transcriptMetadata[key]?.revision ?? 0) ||
          recordingView(ref).text != view.text ||
          (aligned &&
              !listEquals(recordingView(ref).segments, sourceSegments))) {
        return;
      }
      if (translated.trim().isEmpty) throw StateError('empty_translation');
      _transcriptMetadata.putIfAbsent(
        key,
        () => TranscriptMetadata(
          provider: view.provider,
          sourceLanguage: source,
          revision: sourceRevision,
        ),
      );
      _recordingTranslations[key] = RecordingTranslation(
        text: translated,
        sourceLanguage: source,
        targetLanguage: target,
        provider: SttProvider.apple,
        sourceRevision: sourceRevision,
        sourceDigest: transcriptSourceDigest(view.text),
        segments: translatedSegments == null
            ? null
            : List<String>.unmodifiable(translatedSegments),
      );
      _sessionForReference(ref)?.error = null;
      await _persistTranscripts();
    } catch (error) {
      if (!_disposed && revision == _fileJobRevision) {
        _recordingErrors[key] = '翻译失败，原文未改动：${_speechErrorMessage(error)}';
      }
    } finally {
      if (!_disposed && revision == _fileJobRevision) {
        _fileJobKey = null;
        _fileJobProvider = null;
        fileTranscriptionProgress = null;
        notifyListeners();
      }
    }
  }

  Future<SttResult> _transcribePath(
    String path, {
    SpeechConfiguration? configuration,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    final config = configuration ?? _activeConfiguration;
    return _whileAiWorks(
      () => _sttEngines[config.provider]!.transcribe(
        path,
        config,
        expectedSpeakers: expectedSpeakers,
        onProgress: onProgress,
        isCurrent: isCurrent,
      ),
    );
  }

  late final DeferredFileJobs<SpeechConfiguration> _deferredJobs;

  int _fileJobRevision = 0;
  String? _fileJobKey;
  SttProvider? _fileJobProvider;
  // Used by other parts through their abstract declarations.
  // ignore: prefer_final_fields, unused_field
  Future<void> _fileCancellation = Future<void>.value();
}
