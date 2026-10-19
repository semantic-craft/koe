part of '../recorder_controller.dart';

/// Where a hold-to-talk take goes. The entry the user pressed decides it;
/// Koe never guesses intent from what was said (#112).
enum VoiceTarget {
  /// 问 Koe: the recognized text becomes a question.
  ask,

  /// 新记录: the audio is saved as an original and processed as usual.
  note,
}

/// Hold-to-talk (#142): press to record from the phone microphone, release to
/// send, slide away to cancel. A note is saved as an original exactly like a
/// phone take; a question is recognized with the configured speech service
/// and sent to Ask Koe. A question's audio stays on the phone (and in the
/// session) until its text is in the conversation, so a denied permission,
/// a failed recognition or a lost network never loses what was said.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderVoiceInput on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  abstract final Future<void> _libraryLoaded;
  abstract final Future<void> _settingsLoaded;
  abstract final DeferredFileJobs<SpeechConfiguration> _deferredJobs;
  abstract String? phoneRecordingError;
  abstract final AskStore asks;
  abstract final MinutesDocumentStore minutes;
  abstract final Future<void> _minutesLoaded;
  PhoneRecorder get _phoneRecorder;
  SpeechConfiguration get _settingsConfiguration;
  bool get autoOrganize;
  bool get fileProcessingBusy;
  bool get phoneRecordingActive;
  bool get phoneRecordingEnabled;
  bool _isConfigured(SpeechConfiguration config);
  Future<Directory> _importDirectory();
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  Future<String?> _adoptPhoneTake(
    String path,
    DateTime recordedAt, {
    String label,
  });
  Future<SttResult> _transcribePath(
    String path, {
    SpeechConfiguration? configuration,
    // ignore: unused_element_parameter
    SttFileProgressCallback? onProgress,
    // ignore: unused_element_parameter
    bool Function()? isCurrent,
  });
  Future<void> ask(String sessionId, String question, {String? voiceClip});
  Future<void> stopPlayback();
  // END DEPS

  VoiceTarget? _voiceTarget;
  String? _voicePath;
  String? _voiceSessionId;
  DateTime? _voiceStartedAt;
  Future<void> _voiceClipSaved = Future<void>.value();
  bool _voiceBusy = false;
  final Set<String> _voiceRecognizing = {};

  /// Why the last hold on [target] did not start or produced nothing, in
  /// words for the user; null after a hold that worked.
  final Map<VoiceTarget, String> voiceInputErrors = {};

  /// The entry currently holding the microphone, if any.
  VoiceTarget? get voiceHoldTarget => _voiceTarget;

  /// Whether [sessionId]'s spoken question is being turned into text.
  bool voiceRecognizing(String sessionId) =>
      _voiceRecognizing.contains(sessionId);

  /// Starts a hold. Returns false, with a reason in [voiceInputErrors], when
  /// the microphone cannot be used; the text input stays available.
  Future<bool> startVoiceHold(VoiceTarget target, {String? sessionId}) async {
    if (_voiceTarget != null || _voiceBusy) return false;
    if (!phoneRecordingEnabled) {
      voiceInputErrors[target] = '按住说话只在 iPhone 上提供，可以直接输入文字';
      notifyListeners();
      return false;
    }
    if (phoneRecordingActive) {
      voiceInputErrors[target] = '手机录音正在进行，结束后再按住说话';
      notifyListeners();
      return false;
    }
    if (target == VoiceTarget.ask) {
      await asks.load();
      final session = asks.sessionById(sessionId);
      if (session == null) return false;
      if (session.voice != null) {
        voiceInputErrors[target] = '上一句语音问题还没发出，先重试或丢弃它';
        notifyListeners();
        return false;
      }
    }
    _voiceBusy = true;
    try {
      await _libraryLoaded;
      if (!await _phoneRecorder.requestPermission()) {
        voiceInputErrors[target] = '没有麦克风权限。可在系统设置里允许 Koe 使用麦克风，或直接输入文字';
        notifyListeners();
        return false;
      }
      await stopPlayback();
      final startedAt = DateTime.now();
      final imports = await _importDirectory();
      // A note uses the phone-take name so a take cut off by a crash is
      // recovered into the library like any phone recording.
      final dir = target == VoiceTarget.note
          ? imports
          : Directory(p.join(imports.parent.path, 'ask_voice'));
      await dir.create(recursive: true);
      final prefix = target == VoiceTarget.note
          ? _RecorderPhoneRecording._takePrefix
          : 'ask_';
      final path = p.join(
        dir.path,
        '$prefix${startedAt.microsecondsSinceEpoch}.wav',
      );
      try {
        await _phoneRecorder.start(path);
      } catch (_) {
        voiceInputErrors[target] = '无法开始收音，麦克风可能正被其他应用使用';
        notifyListeners();
        return false;
      }
      voiceInputErrors.remove(target);
      _voiceTarget = target;
      _voicePath = path;
      _voiceStartedAt = startedAt;
      _voiceSessionId = sessionId;
      if (target == VoiceTarget.ask) {
        final session = asks.sessionById(sessionId)!;
        _voiceClipSaved = asks
            .put(
              session.copyWith(
                voice: AskVoiceClip(path: path, at: startedAt),
              ),
            )
            .catchError((Object _) {});
      }
      notifyListeners();
      return true;
    } finally {
      _voiceBusy = false;
    }
  }

  /// Drops the current hold: the audio is deleted and nothing is sent or
  /// saved.
  Future<void> cancelVoiceHold() async {
    final path = _voicePath;
    final target = _voiceTarget;
    if (path == null || target == null) return;
    final sessionId = _voiceSessionId;
    _clearVoiceHold();
    notifyListeners();
    try {
      await _phoneRecorder.cancel();
    } catch (_) {}
    await _deleteQuietly(path);
    notifyListeners();
    if (target == VoiceTarget.ask) {
      await _voiceClipSaved;
      await _dropVoiceClip(sessionId, path);
    }
  }

  /// Ends a note hold and saves it as an original, then starts transcription
  /// unless automatic organizing already will. Returns the saved path, or
  /// null with a reason in [voiceInputErrors].
  Future<String?> finishVoiceNote() async {
    final path = _voicePath;
    final startedAt = _voiceStartedAt;
    if (_voiceTarget != VoiceTarget.note || path == null || startedAt == null) {
      return null;
    }
    _clearVoiceHold();
    notifyListeners();
    try {
      await _phoneRecorder.stop();
    } catch (_) {
      // Whatever reached the file is still saved below.
    }
    final saved = await _adoptPhoneTake(path, startedAt, label: '语音记录');
    if (saved == null) {
      voiceInputErrors[VoiceTarget.note] = phoneRecordingError ?? '没有保存';
      phoneRecordingError = null;
      notifyListeners();
      return null;
    }
    voiceInputErrors.remove(VoiceTarget.note);
    await _settingsLoaded;
    if (!autoOrganize && _isConfigured(_settingsConfiguration)) {
      await _deferredJobs.enqueue(
        _recordingKey(path: saved),
        saved,
        _settingsConfiguration,
      );
    }
    notifyListeners();
    return saved;
  }

  /// The typed alternative to a spoken note: saved as a text material, with
  /// the time it was written as its capture time.
  Future<MinutesDocument> saveTextNote(String text) async {
    final body = text.trim();
    if (body.isEmpty) throw StateError('先写点内容');
    await _minutesLoaded;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final document = MinutesDocument(
      id: 'note-${now.microsecondsSinceEpoch}',
      title:
          '文字记录 ${two(now.month)}-${two(now.day)} '
          '${two(now.hour)}:${two(now.minute)}',
      sourceName: '新记录',
      importedAt: now,
      capturedAt: now,
      segments: [
        for (final line in body.split('\n'))
          if (line.trim().isNotEmpty)
            MinutesSegment(text: line.trim(), start: Duration.zero),
      ],
      timingReliable: false,
    );
    try {
      await minutes.upsert(document, strict: true);
    } catch (_) {
      throw StateError('文字保存失败，内容还在输入框里，请重试');
    }
    notifyListeners();
    return document;
  }

  /// Ends a question hold, recognizes it and sends the text to Ask Koe.
  Future<void> finishVoiceQuestion() async {
    final path = _voicePath;
    final sessionId = _voiceSessionId;
    if (_voiceTarget != VoiceTarget.ask || path == null || sessionId == null) {
      return;
    }
    _clearVoiceHold();
    _voiceRecognizing.add(sessionId);
    notifyListeners();
    try {
      await _phoneRecorder.stop();
    } catch (_) {}
    await _voiceClipSaved;
    final session = asks.sessionById(sessionId);
    if (session != null && session.voice?.path != path) {
      // The save at press time failed; try once more before recognizing.
      try {
        await asks.put(
          session.copyWith(
            voice: AskVoiceClip(path: path, at: DateTime.now()),
          ),
        );
      } catch (_) {}
    }
    if (!await _hasSpeech(path)) {
      _voiceRecognizing.remove(sessionId);
      await _deleteQuietly(path);
      await _dropVoiceClip(sessionId, path);
      voiceInputErrors[VoiceTarget.ask] = '没有录到声音，未发送';
      notifyListeners();
      return;
    }
    await _recognizeVoiceQuestion(sessionId);
  }

  /// Tries the session's waiting spoken question again.
  Future<void> retryVoiceQuestion(String sessionId) async {
    if (_voiceRecognizing.contains(sessionId)) return;
    _voiceRecognizing.add(sessionId);
    notifyListeners();
    await _recognizeVoiceQuestion(sessionId);
  }

  /// Throws the session's waiting spoken question away.
  Future<void> discardVoiceQuestion(String sessionId) async {
    final clip = asks.sessionById(sessionId)?.voice;
    if (clip == null || _voiceRecognizing.contains(sessionId)) return;
    await _deleteQuietly(clip.path);
    await _dropVoiceClip(sessionId, clip.path);
  }

  Future<void> _recognizeVoiceQuestion(String sessionId) async {
    String? failure;
    try {
      final clip = asks.sessionById(sessionId)?.voice;
      if (clip == null) return;
      await _settingsLoaded;
      final config = _settingsConfiguration;
      if (!await File(clip.path).exists()) {
        failure = '这句语音已经不在手机上了，请重新说或输入文字';
      } else if (!_isConfigured(config)) {
        failure = '还没配置语音识别，这句话已保留；配置后点重试，或直接输入文字';
      } else if (fileProcessingBusy) {
        failure = '正在转写其他录音，这句话已保留；稍后点重试';
      } else {
        try {
          await repairWavSizes(clip.path);
        } catch (_) {}
        try {
          final result = await _transcribePath(
            clip.path,
            configuration: config,
          );
          final text = result.text.trim();
          if (text.isEmpty) {
            failure = '没听清，这句话已保留；可以重试或直接输入文字';
          } else {
            _voiceRecognizing.remove(sessionId);
            // The question and the dropped clip are saved together, so a
            // restart never shows both or neither.
            await ask(sessionId, text, voiceClip: clip.path);
            return;
          }
        } on SocketException {
          failure = '网络连接失败，这句话已保留；联网后点重试';
        } on http.ClientException {
          failure = '网络连接失败，这句话已保留；联网后点重试';
        } on StateError catch (error) {
          failure = '${error.message}；这句话已保留，可以重试';
        } on TimeoutException {
          failure = '识别超时，这句话已保留；可以重试';
        } catch (_) {
          failure = '识别失败，这句话已保留；可以重试或直接输入文字';
        }
      }
    } finally {
      _voiceRecognizing.remove(sessionId);
      if (failure != null) {
        final session = asks.sessionById(sessionId);
        final clip = session?.voice;
        if (session != null && clip != null) {
          final saved = asks.put(
            session.copyWith(voice: clip.withError(failure)),
          );
          // The reason is on screen at once; the file write follows.
          if (!_disposed) notifyListeners();
          try {
            await saved;
          } catch (_) {}
        }
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> _hasSpeech(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final repaired = await repairWavSizes(path);
      return repaired &&
          await file.length() >= _RecorderPhoneRecording._minimumTakeBytes;
    } catch (_) {
      return false;
    }
  }

  Future<void> _dropVoiceClip(String? sessionId, String path) async {
    final session = asks.sessionById(sessionId);
    if (session == null || session.voice?.path != path) return;
    try {
      await asks.put(session.copyWith(clearVoice: true));
    } catch (_) {}
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _clearVoiceHold() {
    _voiceTarget = null;
    _voicePath = null;
    _voiceSessionId = null;
    _voiceStartedAt = null;
  }
}
