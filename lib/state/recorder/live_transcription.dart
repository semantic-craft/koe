part of '../recorder_controller.dart';

/// Live transcription while the recorder is recording: per-recording live
/// sessions, the realtime Opus → PCM → streaming STT pipeline, live
/// translation turns, and saving the live text when a recording ends.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderLiveTranscription on ChangeNotifier {
  // Provided by _RecorderLiveMeeting.
  void beginLiveMeeting(
    String id, {
    String? recordingKey,
    bool available = true,
    String language = 'zh',
    bool automaticMinutes = false,
  });
  void closeLiveMeetingInput(String id);
  Future<void> finishLiveMeeting(String id, {String? recordingKey});
  void acceptLiveSpeech(
    String id,
    String connection,
    SttStreamEvent event, {
    String? language,
  });
  void invalidateLiveMeeting(String reason);

  // --- Provided by RecorderController and its other parts. ---
  bool get _activeAutoTranscribe;
  bool get _activeSttConfigured;
  abstract final AppleSpeechService _appleSpeech;
  abstract final Map<SttProvider, _SttEngine> _sttEngines;
  Future<String> _convertExportToWav(
    String path, {
    // ignore: unused_element_parameter
    bool register = true,
    // ignore: unused_element_parameter
    List<String>? conversionFailures,
  });
  Future<void> _enqueueDeferredRecording(_RecordingSession owner, String path);
  abstract Future<void> _fileCancellation;
  abstract String? _fileJobKey;
  abstract SttProvider? _fileJobProvider;
  // ignore: unused_field
  abstract int _fileJobRevision;
  // ignore: unused_element_parameter
  Future<void> _persistTranscripts({bool strict = false});
  abstract int _recordWireStatus;
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  void _registerExportedPaths(Iterable<String> paths);
  void _scheduleAutoTransferMissing();
  _RecordingSession? _sessionForReference(RecordingReference ref);
  SpeechConfiguration get _meetingConfiguration;
  SpeechConfiguration get _settingsConfiguration;
  SttStreamSession Function(SpeechConfiguration config)?
  get _speechStreamOverride;
  String get activeGuestLanguage;
  String get activeOwnerLanguage;
  String get activeTranslationTargetLanguage;
  abstract bool appleLanguagePreparationBusy;
  bool get appleTranslationAvailable;
  abstract bool autoTranscribe;
  abstract bool connected;
  int? fileIdFromPath(String path);
  abstract SttFileProgress? fileTranscriptionProgress;
  abstract bool meetingLocalOnly;
  String get meetingLocalOnlyUnavailableMessage;
  bool get onDeviceSpeechSupported;
  abstract bool recording;
  void rememberTranscript(
    String path,
    String text, {
    SttProvider? provider,
    String? sourceLanguage,
    List<TranscriptSegment>? segments,
  });
  abstract SttProvider speechProvider;
  abstract String? statusMessage;
  abstract bool transcribing;
  abstract String? transcribingPath;
  abstract bool allDayListening;
  bool get textCaptureFromDevice;
  void feedDeviceTextCapture(Uint8List pcm);
  Future<void> _applyDeviceMarks(int fileId);
  // END DEPS

  _RecordingSession? get _currentRecording =>
      _recordingSessions[_currentSessionId];
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  bool get _liveProcessing =>
      recording ||
      realtimeState.active ||
      streamingSttActive ||
      _streamSttStarting ||
      (_currentRecording?.finalizing ?? false);
  // Final BLE/file callbacks can arrive after capture and stream flags clear.
  // They still belong to this take and must never adopt the next provider.
  SpeechConfiguration get _activeConfiguration =>
      _liveConfiguration ?? _meetingConfiguration;

  /// Whether the current live meeting recording is permitted to stream PCM
  /// audio to [_activeConfiguration]'s speech engine (#376).
  bool get _liveStreamSendPermitted {
    final config = _activeConfiguration;
    if (!config.provider.onDevice && meetingLocalOnly) return false;
    return true;
  }

  /// Synchronously revokes an active or handshaking cloud live stream when
  /// [meetingLocalOnly] is turned on mid-recording (#376).
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  void _revokeCloudLiveStreamIfNeeded() {
    if (_liveStreamSendPermitted) return;
    _pendingPcm.clear();
    final session = _sttStream;
    final subscription = _sttStreamSub;
    if (session == null && subscription == null && !_streamSttStarting) {
      return;
    }
    _snapshotLiveText();
    _sttLifecycleRevision++;
    _sttStream = null;
    _sttStreamSub = null;
    _streamSttStarting = false;
    streamingSttActive = false;
    if (transcribingPath == null) transcribing = false;
    _snapshotLiveText();
    Future<void>? closeFuture;
    try {
      closeFuture = session?.close();
    } catch (e) {
      debugPrint('[STT] local-only close: $e');
    }
    unawaited(() async {
      try {
        await subscription?.cancel();
        await closeFuture;
        await session?.dispose();
      } catch (e) {
        debugPrint('[STT] local-only dispose: $e');
      }
    }());
  }

  bool _isConfigured(SpeechConfiguration config) {
    if (config.provider.retired) return false;
    if (config.provider.needsCredentials) {
      return config.engineKey(config.provider)?.isNotEmpty == true;
    }
    return config.appleReady && config.sourceLanguage.isNotEmpty;
  }

  RecordingReference? get currentRecordingReference {
    final session = _currentRecording;
    if (session == null) return null;
    return RecordingReference(
      sessionId: session.id,
      fileId: session.fileId,
      path: session.path,
    );
  }

  void _bindCurrentRecording({int? fileId, String? path}) {
    final session = _currentRecording;
    if (session == null) return;
    // A previous take can finish asynchronously after the next one starts.
    if (session.fileId != null && fileId != null && session.fileId != fileId) {
      return;
    }
    session.fileId ??= fileId ?? (path == null ? null : fileIdFromPath(path));
    if (path != null) session.path = path;
  }

  void _snapshotLiveText() {
    final session = _currentRecording;
    if (session == null) return;
    session.text =
        (transcriptPartial?.isNotEmpty == true
                ? transcriptPartial!
                : transcript)
            .trim();
    session.error = transcriptError;
    final turns = translationTurns.where((turn) => turn.text.trim().isNotEmpty);
    if (turns.isNotEmpty) {
      session.translation = RecordingTranslation(
        text: turns.map((turn) => turn.text.trim()).join('\n\n'),
        sourceLanguage: session.configuration.sourceLanguage,
        targetLanguage: session.configuration.targetLanguage,
        provider: session.configuration.provider,
        sourceRevision: 0,
      );
    }
  }

  void _saveLiveRecording(_RecordingSession session, {String? path}) {
    final destination = path ?? session.path;
    if (destination == null || session.text.isEmpty) return;
    session.path = destination;
    rememberTranscript(
      destination,
      session.text,
      provider: session.configuration.provider,
      sourceLanguage: session.configuration.sourceLanguage,
    );
    final translated = session.translation;
    if (translated != null) {
      final key = _recordingKey(path: destination);
      _recordingTranslations[key] = RecordingTranslation(
        text: translated.text,
        sourceLanguage: translated.sourceLanguage,
        targetLanguage: translated.targetLanguage,
        provider: translated.provider,
        sourceRevision: _transcriptMetadata[key]!.revision,
        sourceDigest: transcriptSourceDigest(session.text),
      );
      unawaited(_persistTranscripts());
    }
  }

  String _speechErrorMessage(Object error) {
    if (error is CloudSttException) return error.message;
    if (error is AudioVersionException) return error.message;
    if (error is StateError) return '处理失败：${error.message}';
    if (error is SocketException) return '网络连接失败，请检查网络后重试';
    final code = error is PlatformException ? error.code : error.toString();
    return switch (code) {
      'unsupported' =>
        meetingLocalOnly
            ? meetingLocalOnlyUnavailableMessage
            : '此设备不支持设备端处理，请在设置中选择云端语音服务',
      'language_unsupported' => '不支持此语言，请更换语言',
      'resources_missing' => '请在设置中下载所需语言',
      'microphone_permission_denied' => '没有麦克风权限，请在系统设置中允许 Koe 使用麦克风',
      'cancelled' => '处理已取消，可重试',
      'busy' => '请等待当前处理完成后重试',
      'audio_invalid' => '无法读取录音，请重新下载',
      _ => '处理失败，请重试',
    };
  }

  void _onRealtimeState(RealtimeStreamState s) {
    if (s.fileId != null || s.path != null) {
      final owner = _sessionForReference(
        RecordingReference(fileId: s.fileId, path: s.path),
      );
      if (owner != null && owner.id != _currentSessionId) {
        if (s.path != null && s.bytesReceived > 0 && !s.active) {
          _registerExportedPaths([s.path!]);
          _saveLiveRecording(owner, path: s.path);
          final key = _recordingKey(path: s.path);
          _finalizingRecordings.add(key);
          unawaited(
            _convertExportToWav(s.path!).whenComplete(() {
              _finalizingRecordings.remove(key);
              if (s.fileId != null) unawaited(_applyDeviceMarks(s.fileId!));
              unawaited(_enqueueDeferredRecording(owner, s.path!));
              notifyListeners();
            }),
          );
        }
        notifyListeners();
        return;
      }
    }
    final wasActive = realtimeState.active;
    realtimeState = s;
    _bindCurrentRecording(fileId: s.fileId, path: s.path);
    if (s.path != null && s.bytesReceived > 0) {
      final path = s.path!;
      _registerExportedPaths([path]);
    }
    // When a session finishes with data, keep path listed for playback + final STT.
    if (!s.active && s.path != null && s.bytesReceived > 0) {
      final finishedPath = s.path!;
      final finishedKey = _recordingKey(path: finishedPath);
      _finalizingRecordings.add(finishedKey);
      unawaited(
        _convertExportToWav(finishedPath).whenComplete(() {
          _finalizingRecordings.remove(finishedKey);
          if (s.fileId != null) unawaited(_applyDeviceMarks(s.fileId!));
          final owner = _sessionForReference(
            RecordingReference(path: finishedPath),
          );
          if (owner?.configuration.provider.defersTranscription == true) {
            unawaited(_enqueueDeferredRecording(owner!, finishedPath));
          }
          notifyListeners();
        }),
      );
      statusMessage =
          '实时录音已保存 ${s.path!.split('/').last}（${(s.bytesReceived / 1024).toStringAsFixed(1)} KB）';
      // Attach any live transcript we already have to this file card.
      final session = _sessionForReference(
        RecordingReference(fileId: s.fileId, path: s.path),
      );
      if (session != null) {
        if (session.id == _currentSessionId) _snapshotLiveText();
        _saveLiveRecording(session, path: s.path);
      }
      if (_activeAutoTranscribe && _recordWireStatus != 2) {
        unawaited(_finishStreamStt(bindPath: s.path));
      }
    } else if (wasActive && !s.active) {
      unawaited(_finishStreamStt(bindPath: s.path));
      _scheduleAutoTransferMissing();
    }
    notifyListeners();
  }

  /// Live BLE Opus frame → PCM16 → provider WS STT (when auto-transcribe on).
  void _onRealtimeOpusFrame(Uint8List frame) {
    if (textCaptureFromDevice) {
      // All-day listening takes the recorder's speech instead (#319).
      if (!_opusPcm.ensureStarted()) return;
      final pcm = _opusPcm.decodeFrame(frame);
      if (pcm != null && pcm.isNotEmpty) feedDeviceTextCapture(pcm);
      return;
    }
    if (!_activeAutoTranscribe ||
        !_activeSttConfigured ||
        !_liveStreamSendPermitted ||
        _recordWireStatus == 2) {
      _pendingPcm.clear();
      return;
    }
    if (!_preferStreamStt) return;
    if (!_opusPcm.ensureStarted()) {
      _preferStreamStt = false;
      if (cloudTranslationModeActive) {
        transcriptError = '$_activeTranslationModeLabel无法启动实时音频解码';
        notifyListeners();
      }
      return;
    }
    final pcm = _opusPcm.decodeFrame(frame);
    if (pcm == null || pcm.isEmpty) return;
    pcmFramesDecoded = _opusPcm.framesDecoded;

    if (!_liveStreamSendPermitted) {
      _pendingPcm.clear();
      return;
    }
    final session = _sttStream;
    if (session != null && session.isServerReady) {
      session.sendPcm(pcm);
      return;
    }
    // Buffer PCM while WS handshakes so early frames are not dropped.
    _pendingPcm.add(pcm);
    if (_pendingPcm.length > 16000 * 2 * 5) {
      // Cap ~5s pending to avoid RAM blow-up if WS never comes up.
      final all = _pendingPcm.toBytes();
      _pendingPcm.clear();
      _pendingPcm.add(Uint8List.sublistView(all, all.length ~/ 2));
    }
    unawaited(_ensureStreamStt());
  }

  /// Prefer PCM WS when decode works; false after hard stream failure → Ogg batch.

  Future<bool> _ensureStreamStt() async {
    if (!_activeAutoTranscribe ||
        !_activeSttConfigured ||
        !_liveStreamSendPermitted ||
        !_preferStreamStt) {
      _pendingPcm.clear();
      return false;
    }
    if (_sttStream != null && _sttStream!.isServerReady) {
      streamingSttActive = true;
      _flushPendingPcm();
      return true;
    }
    if (_streamSttStarting) return false;
    final config = _activeConfiguration;
    if (config.mode == SttDisplayMode.translation &&
        !config.appleTranslationReady) {
      transcriptError = '请在设置中下载翻译语言';
      _snapshotLiveText();
      notifyListeners();
      // Recognition remains useful even if translation resources are missing.
    }
    if (!_opusPcm.ensureStarted()) {
      _preferStreamStt = false;
      if (cloudTranslationModeActive) {
        transcriptError = '$_activeTranslationModeLabel无法启动实时音频解码';
        notifyListeners();
      }
      return false;
    }

    _streamSttStarting = true;
    final revision = ++_sttLifecycleRevision;
    SttStreamSession? session;
    StreamSubscription<SttStreamEvent>? subscription;
    try {
      final previousSession = _sttStream;
      final previousSubscription = _sttStreamSub;
      _sttStream = null;
      _sttStreamSub = null;
      await previousSubscription?.cancel();
      await previousSession?.close();
      await previousSession?.dispose();
      if (revision != _sttLifecycleRevision) return false;

      if (config.provider.onDevice) {
        await _fileCancellation;
        if (revision != _sttLifecycleRevision) return false;
      }
      if (!_liveStreamSendPermitted) {
        _pendingPcm.clear();
        return false;
      }

      if (previousSession != null) {
        invalidateLiveMeeting('实时连接中断，可能存在未确认缺口，请在会后整理');
      }
      _streamTranscriptPrefix = (transcriptPartial ?? transcript).trim();
      _currentRecording?.transcriptionComplete = false;
      session = _createStreamSession(config);
      subscription = session.events.listen((event) {
        if (revision == _sttLifecycleRevision) {
          _onSttStreamEvent(event);
        }
      });
      _sttStream = session;
      _sttStreamSub = subscription;
      await session.start();
      if (revision != _sttLifecycleRevision || !_liveStreamSendPermitted) {
        if (revision == _sttLifecycleRevision) {
          _pendingPcm.clear();
        }
        if (identical(_sttStream, session)) _sttStream = null;
        if (identical(_sttStreamSub, subscription)) _sttStreamSub = null;
        await subscription.cancel();
        await session.close();
        await session.dispose();
        return false;
      }
      streamingSttActive = true;
      _preferStreamStt = true;
      transcriptError =
          config.mode == SttDisplayMode.translation &&
              !config.appleTranslationReady
          ? '请在设置中下载翻译语言，下次录音生效'
          : null;
      statusMessage = '正在转写';
      _snapshotLiveText();
      _flushPendingPcm();
      notifyListeners();
      return true;
    } catch (e) {
      if (revision != _sttLifecycleRevision) {
        if (identical(_sttStream, session)) _sttStream = null;
        if (identical(_sttStreamSub, subscription)) _sttStreamSub = null;
        await subscription?.cancel();
        await session?.close();
        await session?.dispose();
        return false;
      }
      debugPrint('[STT] ${config.provider.name} stream start failed: $e');
      streamingSttActive = false;
      _preferStreamStt = false;
      _pendingPcm.clear();
      transcriptError = config.provider.onDevice
          ? _speechErrorMessage(e)
          : '实时转写失败，可在录音保存后重试';
      _snapshotLiveText();
      if (identical(_sttStream, session)) _sttStream = null;
      if (identical(_sttStreamSub, subscription)) _sttStreamSub = null;
      await subscription?.cancel();
      await session?.close();
      await session?.dispose();
      notifyListeners();
      return false;
    } finally {
      if (revision == _sttLifecycleRevision) {
        _streamSttStarting = false;
      }
    }
  }

  SttStreamSession _createStreamSession(SpeechConfiguration config) {
    final override = _speechStreamOverride;
    if (override != null) return override(config);
    final engine = _sttEngines[config.provider];
    if (engine == null) throw StateError('该语音服务已停用');
    return engine.openStream(config);
  }

  void _flushPendingPcm() {
    if (!_liveStreamSendPermitted) {
      _pendingPcm.clear();
      return;
    }
    final session = _sttStream;
    if (session == null || !session.isServerReady) return;
    if (_pendingPcm.isEmpty) return;
    final buf = _pendingPcm.toBytes();
    _pendingPcm.clear();
    session.sendPcm(buf);
  }

  String _streamTranscriptPrefix = '';
  String _streamText(String text) => _streamTranscriptPrefix.isEmpty
      ? normalizeSttText(text)
      : normalizeSttText('$_streamTranscriptPrefix\n$text');

  /// A late final snapshot may only replace live text when it still contains
  /// everything shown or saved. A short tail must not erase the live draft.
  void _applyServerFinalText(String raw) {
    final incoming = _streamText(raw).trim();
    final partial = transcriptPartial?.trim() ?? '';
    final live = (partial.isNotEmpty ? partial : transcript).trim();
    final saved = (_currentRecording?.text ?? '').trim();
    var known = live;
    if (known.isEmpty) {
      known = saved;
    } else if (saved.isNotEmpty &&
        !known.contains(saved) &&
        saved.contains(known)) {
      known = saved;
    }
    final stable =
        incoming.isNotEmpty &&
        (live.isEmpty || incoming.contains(live)) &&
        (saved.isEmpty || incoming.contains(saved));
    transcript = stable ? incoming : known;
    transcriptPartial = null;
  }

  void _onSttStreamEvent(SttStreamEvent e) {
    if (_currentSessionId != null) {
      acceptLiveSpeech(
        _currentSessionId!,
        'ble-$_sttLifecycleRevision',
        e,
        language: _activeConfiguration.sourceLanguage,
      );
    }
    final translationSnapshotUpdated =
        (translationModeActive || communicationModeActive) &&
        (e.type == 'partial' || e.type == 'done');
    if (translationSnapshotUpdated) {
      if (translationModeActive) {
        translationTurns = e.translationTurns
            .where(
              (turn) => turn.targetLanguage == activeTranslationTargetLanguage,
            )
            .toList(growable: false);
        pendingTranslationSource = e.pendingTranslationSource;
      } else if (communicationModeActive) {
        ownerTranslationTurns = e.translationTurns
            .where((turn) => turn.targetLanguage == activeOwnerLanguage)
            .toList(growable: false);
        guestTranslationTurns = e.translationTurns
            .where((turn) => turn.targetLanguage == activeGuestLanguage)
            .toList(growable: false);
      }
    }
    switch (e.type) {
      case 'partial':
        if (e.text.isEmpty) {
          if (translationSnapshotUpdated) {
            transcribing = true;
            _snapshotLiveText();
            notifyListeners();
          }
          return;
        }
        final incoming = _streamText(e.text);
        if (incoming.isEmpty) return;
        // Every engine emits cumulative snapshots; revisions may be shorter
        // than a draft, so never append or prefer the longest text.
        if (e.speechFinal) {
          transcript = incoming;
          transcriptPartial = null;
        } else {
          transcriptPartial = incoming;
        }
        transcribing = true;
        _snapshotLiveText();
        notifyListeners();
      case 'done':
        _currentRecording?.transcriptionComplete = true;
        _applyServerFinalText(e.text);
        transcribing = false;
        streamingSttActive = false;
        statusMessage = '转写完成';
        _snapshotLiveText();
        notifyListeners();
      case 'error':
        transcriptError = _activeConfiguration.provider.onDevice
            ? _speechErrorMessage(
                PlatformException(code: e.error ?? 'processing_failed'),
              )
            : '实时转写中断，可在录音保存后重试';
        streamingSttActive = false;
        _preferStreamStt = false;
        _snapshotLiveText();
        notifyListeners();
      case 'translationError':
        transcriptError = '翻译失败，原文已保留；可在录音保存后重试';
        _snapshotLiveText();
        notifyListeners();
      case 'closed':
        streamingSttActive = false;
        transcribing = false;
        _snapshotLiveText();
        notifyListeners();
      default:
        break;
    }
  }

  @visibleForTesting
  void attachSttStreamForTesting(SttStreamSession session) {
    final revision = ++_sttLifecycleRevision;
    _sttStream = session;
    _sttStreamSub = session.events.listen((event) {
      if (revision == _sttLifecycleRevision) {
        _onSttStreamEvent(event);
      }
    });
    streamingSttActive = true;
  }

  @visibleForTesting
  void handleRealtimeOpusFrameForTesting(Uint8List frame) =>
      _onRealtimeOpusFrame(frame);

  @visibleForTesting
  void handleRealtimeStateForTesting(RealtimeStreamState state) =>
      _onRealtimeState(state);

  final Map<String, Future<void>> _finishingStreams = {};

  Future<void> _finishStreamStt({String? bindPath}) {
    final id = _currentSessionId;
    if (id == null) return _completeStreamStt(bindPath: bindPath);
    return _finishingStreams.putIfAbsent(
      id,
      () => _completeStreamStt(bindPath: bindPath).whenComplete(() {
        _finishingStreams.remove(id);
      }),
    );
  }

  Future<void> _completeStreamStt({String? bindPath}) async {
    final session = _sttStream;
    final recordingSession = _currentRecording;
    final transcriptPrefix = _streamTranscriptPrefix;
    if (recordingSession != null) closeLiveMeetingInput(recordingSession.id);
    if (session == null && _pendingPcm.isEmpty) {
      if (recordingSession != null) {
        recordingSession.finalizing = false;
        _snapshotLiveText();
        _saveLiveRecording(recordingSession, path: bindPath);
        await finishLiveMeeting(
          recordingSession.id,
          recordingKey: bindPath == null ? null : 'audio:$bindPath',
        );
      }
      return;
    }
    if (recordingSession != null) recordingSession.finalizing = true;
    final revision = _sttLifecycleRevision;
    final subscription = _sttStreamSub;
    _sttStream = null;
    _sttStreamSub = null;
    streamingSttActive = false;
    try {
      if (session != null && _liveStreamSendPermitted) {
        _flushPendingPcmTo(session);
        final done = await session.finish();
        if (revision != _sttLifecycleRevision) {
          if (recordingSession != null && done != null) {
            final incoming = normalizeSttText(
              transcriptPrefix.isEmpty
                  ? done.text
                  : '$transcriptPrefix\n${done.text}',
            ).trim();
            if (incoming.isNotEmpty &&
                incoming.contains(recordingSession.text.trim())) {
              recordingSession.text = incoming;
            }
            recordingSession.transcriptionComplete = true;
            _saveLiveRecording(recordingSession, path: bindPath);
          }
          return;
        }
        if (done != null) {
          if (recordingSession != null) {
            acceptLiveSpeech(
              recordingSession.id,
              'ble-$revision',
              done,
              language: _activeConfiguration.sourceLanguage,
            );
          }
          // The same rule as the subscribed `done` event: never let a short
          // final tail replace the longer text already shown or saved.
          _applyServerFinalText(done.text);
          recordingSession?.transcriptionComplete = true;
        }
      } else if (session != null) {
        _pendingPcm.clear();
        await session.close();
      }
      if (revision != _sttLifecycleRevision) return;
      _snapshotLiveText();
      if (recordingSession != null) {
        _saveLiveRecording(recordingSession, path: bindPath);
      }
    } catch (e) {
      debugPrint('[STT] stream finish: $e');
      recordingSession?.error = '实时转写收尾未完成，请在录音详情中重试';
      if (revision == _sttLifecycleRevision && recordingSession != null) {
        transcriptError = '部分处理未完成，可在录音详情中重试';
        _snapshotLiveText();
        _saveLiveRecording(recordingSession, path: bindPath);
      }
    } finally {
      if (recordingSession != null) {
        await finishLiveMeeting(
          recordingSession.id,
          recordingKey: (bindPath ?? recordingSession.path) == null
              ? null
              : 'audio:${bindPath ?? recordingSession.path}',
        );
      }
      await subscription?.cancel();
      await session?.dispose();
      if (recordingSession != null) {
        recordingSession.finalizing = false;
        final path = bindPath ?? recordingSession.path;
        if (path != null) {
          unawaited(_enqueueDeferredRecording(recordingSession, path));
        }
      }
      if (revision == _sttLifecycleRevision) {
        _pendingPcm.clear();
        transcribing = _fileJobKey != null;
      }
      notifyListeners();
    }
  }

  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  void _cancelStreamSttAfterPause() {
    _snapshotLiveText();
    final recordingSession = _currentRecording;
    if (recordingSession != null) {
      recordingSession.active = false;
      recordingSession.paused = true;
      recordingSession.finalizing = false;
      _saveLiveRecording(recordingSession);
    }
    final session = _sttStream;
    final subscription = _sttStreamSub;
    _sttLifecycleRevision++;
    _sttStream = null;
    _sttStreamSub = null;
    _streamSttStarting = false;
    _pendingPcm.clear();
    streamingSttActive = false;
    if (transcribingPath == null) transcribing = false;
    transcriptError = null;

    Future<void>? closeFuture;
    try {
      // Close synchronously marks the stream unavailable before awaiting I/O.
      closeFuture = session?.close();
    } catch (e) {
      debugPrint('[STT] pause close: $e');
    }
    unawaited(() async {
      try {
        await subscription?.cancel();
        await closeFuture;
        await session?.dispose();
      } catch (e) {
        debugPrint('[STT] pause dispose: $e');
      }
    }());
  }

  void _flushPendingPcmTo(SttStreamSession session) {
    if (!_liveStreamSendPermitted) {
      _pendingPcm.clear();
      return;
    }
    if (_pendingPcm.isEmpty) return;
    final buf = _pendingPcm.toBytes();
    _pendingPcm.clear();
    session.sendPcm(buf);
  }

  /// Background stream finalization can outlive a recorder disconnect after a
  /// long take; it must not keep the live page open once the device is gone.
  bool get isLiveSession =>
      connected && (recording || realtimeState.active || streamingSttActive);

  bool get translationModeAvailable =>
      autoTranscribe &&
      speechProvider.supportsMode(SttDisplayMode.translation) &&
      appleTranslationAvailable;

  bool get translationModeActive =>
      _activeConfiguration.enabled &&
      _activeConfiguration.mode == SttDisplayMode.translation;

  bool get communicationModeActive => false;
  bool get cloudTranslationModeActive => false;

  String get _activeTranslationModeLabel =>
      translationModeActive ? '翻译模式' : '交流模式';

  bool get isCommunicationLiveSession =>
      communicationModeActive && isLiveSession;

  void clearTranscript() {
    transcript = '';
    transcriptPartial = null;
    transcriptError = null;
    _resetTranslationTurns();
    notifyListeners();
  }

  void _resetTranslationTurns() {
    translationTurns = const [];
    pendingTranslationSource = null;
    ownerTranslationTurns = const [];
    guestTranslationTurns = const [];
  }

  /// Fresh recording session: clear live draft and STT stream (keep per-file history).
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  Future<void> _beginNewLiveTranscriptSession() async {
    final previous = _currentRecording;
    if (previous != null) {
      _snapshotLiveText();
      previous.active = false;
      if (previous.configuration.provider.defersTranscription) {
        previous.paused = false;
        previous.ended = true;
      }
      previous.finalizing = _finishingStreams.containsKey(previous.id);
      _saveLiveRecording(previous);
      if (previous.path != null &&
          !realtimeState.active &&
          !_finalizingRecordings.contains(_recordingKey(path: previous.path))) {
        unawaited(_enqueueDeferredRecording(previous, previous.path!));
      }
    }
    // During all-day listening the take's speech is recognized once, as
    // text records; the take itself is not transcribed again (#319).
    final textOnly = allDayListening;
    final config = textOnly
        ? _settingsConfiguration.withoutTranscription()
        : _meetingConfiguration;
    _currentSessionId =
        '${DateTime.now().microsecondsSinceEpoch}-${++liveSessionRevision}';
    _recordingSessions[_currentSessionId!] = _RecordingSession(
      _currentSessionId!,
      config,
    )..textOnly = textOnly;
    _liveConfiguration = config;
    if (!textOnly) {
      beginLiveMeeting(
        _currentSessionId!,
        available: config.provider != SttProvider.doubao,
        language: config.sourceLanguage,
        automaticMinutes: true,
      );
    }
    if (appleLanguagePreparationBusy) {
      _fileCancellation = _appleSpeech.cancelFileProcessing();
    }
    // Live capture takes the on-device recognizer back from file work.
    if (_fileJobKey != null && _fileJobProvider?.onDevice == true) {
      _fileJobRevision++;
      if (_fileJobKey != null) {
        _recordingErrors[_fileJobKey!] = '处理因录音暂停，可在录音结束后重试';
      }
      _fileCancellation = _appleSpeech.cancelFileProcessing();
      _fileJobKey = null;
      _fileJobProvider = null;
      transcribingPath = null;
      fileTranscriptionProgress = null;
    }
    _sttLifecycleRevision++;
    transcript = '';
    transcriptPartial = null;
    transcriptError = null;
    transcribing = _fileJobKey != null;
    if (config.enabled && !_isConfigured(config)) {
      transcriptError = config.provider.needsCredentials
          ? '请在设置中配置 ${config.provider.label}，下次录音生效'
          : meetingLocalOnly && !onDeviceSpeechSupported
          ? meetingLocalOnlyUnavailableMessage
          : '请在设置中选择并下载录音语言，下次录音生效';
      _currentRecording?.error = transcriptError;
    }
    _resetTranslationTurns();
    pcmFramesDecoded = 0;
    streamingSttActive = false;
    _streamSttStarting = false;
    _pendingPcm.clear();
    final session = _sttStream;
    final subscription = _sttStreamSub;
    _sttStream = null;
    _sttStreamSub = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
    if (session != null) {
      try {
        // Close without waiting for done — avoid pasting previous session text.
        await session.close();
        await session.dispose();
      } catch (e) {
        debugPrint('[STT] reset session: $e');
      }
    }
    notifyListeners();
  }

  RealtimeStreamState realtimeState = const RealtimeStreamState();

  List<SttTranslationTurn> translationTurns = const [];
  SttSourceChunk? pendingTranslationSource;
  List<SttTranslationTurn> ownerTranslationTurns = const [];
  List<SttTranslationTurn> guestTranslationTurns = const [];
  String transcript = '';
  String? transcriptPartial;

  String? transcriptError;

  /// Live streaming STT session active after Opus→PCM decode.
  bool streamingSttActive = false;

  /// Decoded Opus frames in the current session (diagnostics).
  int pcmFramesDecoded = 0;

  int liveSessionRevision = 0;
  String? _currentSessionId;
  final Map<String, _RecordingSession> _recordingSessions = {};
  SpeechConfiguration? _liveConfiguration;
  final Map<String, TranscriptMetadata> _transcriptMetadata = {};
  final Map<String, RecordingTranslation> _recordingTranslations = {};
  final Map<String, String> _recordingErrors = {};
  final Set<String> _finalizingRecordings = {};
  final OpusPcmDecoder _opusPcm = OpusPcmDecoder(outputSampleRate: 16000);
  SttStreamSession? _sttStream;
  StreamSubscription? _sttStreamSub;
  bool _streamSttStarting = false;
  int _sttLifecycleRevision = 0;

  /// When false, use rolling Ogg batch STT (stream failed or Opus unavailable).
  bool _preferStreamStt = true;
  final BytesBuilder _pendingPcm = BytesBuilder(copy: false);
}
