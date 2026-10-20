part of '../recorder_controller.dart';

/// What [RecorderController.stopTextCapture] produced.
class TextCaptureOutcome {
  const TextCaptureOutcome({
    this.document,
    this.recordingPath,
    this.pendingSeconds = 0,
    required this.message,
  });

  /// The saved text record; null when the text went onto a kept recording
  /// or nothing was recognized.
  final MinutesDocument? document;

  /// The original saved when the user chose to keep the audio.
  final String? recordingPath;

  /// Speech not yet turned into text because the network was gone; it is
  /// recognized from the phone later and appended to [document].
  final int pendingSeconds;
  final String message;
}

/// Text-only capture (纯文字记录): while it is open, the phone microphone
/// streams to the speech service chosen in settings and only the recognized
/// text is kept.
///
/// Audio is spooled to the phone only so nothing said is lost: a dropped
/// connection reconnects on its own and re-sends what the service had not
/// finished; speech captured with no network is sent once a connection comes
/// back, or recognized from file after the user stops; the recognized text
/// is saved every few sentences so a crash keeps it. The spool is deleted
/// once its text is saved, unless the user chooses to keep the audio as an
/// original.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderTextCapture on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  abstract final MinutesDocumentStore minutes;
  abstract final Future<void> _minutesLoaded;
  abstract final Map<SttProvider, _SttEngine> _sttEngines;
  abstract String? phoneRecordingError;
  PhoneMicStream get _micStream;
  SttStreamSession Function(SpeechConfiguration config)?
  get _speechStreamOverride;
  SpeechConfiguration get _settingsConfiguration;
  bool get phoneRecordingActive;
  bool get phoneRecordingEnabled;
  VoiceTarget? get voiceHoldTarget;
  bool _isConfigured(SpeechConfiguration config);
  Future<Directory> _importDirectory();
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
  void rememberTranscript(
    String path,
    String text, {
    SttProvider? provider,
    String? sourceLanguage,
    List<TranscriptSegment>? segments,
  });
  Future<void> stopPlayback();
  String _takeLabel(DateTime at);
  // END DEPS

  static const _bytesPerSecond = TextCaptureSpool.bytesPerSecond;
  static const _chunkBytes = 6400;

  /// The first retry is immediate; a longer outage backs off to 30 s.
  static const _retryDelays = [
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// Backlog beyond this is sent at about four times real time.
  static const _unpacedBacklog = _bytesPerSecond * 2;

  /// After a drop, speech since the last finished sentence is sent again
  /// unless that is more than this, when the partial text is kept instead.
  static const _maxResendBytes = _bytesPerSecond * 60;

  /// At stop, a backlog up to this length still goes through the stream;
  /// a longer one is recognized from file.
  static const _streamTailLimit = _bytesPerSecond * 30;
  static const _draftInterval = Duration(seconds: 5);
  static const _waitingLine = '（这段话等网络恢复后补识别）';

  String? _textId;
  DateTime? _textStartedAt;
  SpeechConfiguration? _textConfig;
  TextCaptureSpool? _textSpool;
  StreamSubscription<Uint8List>? _textMic;
  StreamSubscription<PhoneMicState>? _textMicStates;
  SttStreamSession? _textSession;
  StreamSubscription<SttStreamEvent>? _textEvents;
  int _textGeneration = 0;
  int _textRetry = 0;
  Timer? _textRetryTimer;
  Future<void>? _textPump;
  Timer? _textDraftTimer;
  DateTime? _textLastDraft;
  Future<void> _textSaves = Future<void>.value();
  final Set<String> _textTails = {};
  bool _textBusy = false;
  bool _textStopping = false;

  /// Offset of the next spooled byte to send to the service.
  int _textSent = 0;

  /// Offset sent when the current connection last finished a sentence.
  int _textFinalMark = 0;
  String _textCommitted = '';
  String _textLive = '';
  String _textAtFinal = '';

  /// Line indexes of [textCaptureText] the user marked as key points.
  final Set<int> _textMarks = {};

  /// Why capture cannot start, or what is wrong while it runs; null when
  /// all is well.
  String? textCaptureError;

  /// The microphone is paused by the system, for example by a call.
  bool textCapturePaused = false;

  bool get textCaptureActive => _textId != null;
  bool get textCaptureStopping => _textStopping;
  bool get textCaptureConnected => _textSession?.isServerReady ?? false;

  /// Everything recognized so far, the sentence in progress included.
  String get textCaptureText => _joinText(_textCommitted, _textLive);

  /// The recognized lines so far, each with whether it is marked.
  List<(String, bool)> get textCaptureLines => [
    for (final (index, line) in _textLines(textCaptureText).indexed)
      (line, _textMarks.contains(index)),
  ];

  /// Marks the sentence being spoken, or the last finished one, as a key
  /// point. Returns false when there is nothing to mark yet.
  bool markTextCaptureHighlight() {
    if (!textCaptureActive || _textStopping) return false;
    final lines = _textLines(textCaptureText);
    if (lines.isEmpty) return false;
    _textMarks.add(lines.length - 1);
    _scheduleTextDraft();
    notifyListeners();
    return true;
  }

  static List<String> _textLines(String text) => [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// Captured speech the service has not received yet.
  int get textCaptureBacklogSeconds =>
      ((_textSpool?.length ?? 0) - _textSent) ~/ _bytesPerSecond;

  Duration get textCaptureElapsed => Duration(
    milliseconds: (_textSpool?.length ?? 0) * 1000 ~/ _bytesPerSecond,
  );

  static String _joinText(String a, String b) {
    final left = a.trim();
    final right = b.trim();
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    return '$left\n$right';
  }

  Future<Directory> _textCaptureDirectory() async =>
      Directory(p.join((await _importDirectory()).parent.path, 'text_capture'));

  SttStreamSession _openTextStream(SpeechConfiguration config) {
    final override = _speechStreamOverride;
    if (override != null) return override(config);
    final engine = _sttEngines[config.provider];
    if (engine == null) throw StateError('该语音服务已停用');
    return engine.openStream(config);
  }

  /// Starts capture. Returns false, with the reason in [textCaptureError],
  /// when the speech service or microphone cannot be used.
  Future<bool> startTextCapture() async {
    if (!phoneRecordingEnabled || textCaptureActive || _textBusy) return false;
    if (phoneRecordingActive || voiceHoldTarget != null) {
      textCaptureError = '麦克风正在录音，先结束那段再开始';
      notifyListeners();
      return false;
    }
    _textBusy = true;
    try {
      await _minutesLoaded;
      final config = _settingsConfiguration;
      if (!_isConfigured(config)) {
        textCaptureError = config.provider.needsCredentials
            ? '请先在设置中配置 ${config.provider.label}'
            : '请先在设置中选择并下载识别语言';
        notifyListeners();
        return false;
      }
      if (!await _micStream.requestPermission()) {
        textCaptureError = '没有麦克风权限。可在系统设置里允许 Koe 使用麦克风';
        notifyListeners();
        return false;
      }
      await stopPlayback();
      final startedAt = DateTime.now();
      final id = 'live-${startedAt.microsecondsSinceEpoch}';
      final spool = await TextCaptureSpool.create(
        await _textCaptureDirectory(),
        id,
      );
      final Stream<Uint8List> samples;
      try {
        samples = await _micStream.start();
      } catch (_) {
        await spool.delete();
        textCaptureError = '无法开始录音，麦克风可能正被其他应用使用';
        notifyListeners();
        return false;
      }
      _textId = id;
      _textStartedAt = startedAt;
      _textConfig = config;
      _textSpool = spool;
      _textSent = 0;
      _textFinalMark = 0;
      _textCommitted = '';
      _textLive = '';
      _textAtFinal = '';
      _textMarks.clear();
      _textRetry = 0;
      _textLastDraft = null;
      textCaptureError = null;
      textCapturePaused = false;
      _textMic = samples.listen(_onTextSamples, onDone: _onTextMicDone);
      _textMicStates = _micStream.states.listen(_onTextMicState);
      unawaited(_saveTextState());
      notifyListeners();
      unawaited(_connectText());
      return true;
    } finally {
      _textBusy = false;
    }
  }

  void _onTextSamples(Uint8List samples) {
    final spool = _textSpool;
    if (spool == null) return;
    unawaited(spool.append(samples).then((_) => _pumpText()));
  }

  void _onTextMicDone() {
    if (!textCaptureActive || _textStopping || _disposed) return;
    textCaptureError = '麦克风被系统停止了，已识别的文字都在；结束保存后可以重新开始';
    notifyListeners();
  }

  void _onTextMicState(PhoneMicState state) {
    if (!textCaptureActive || _disposed) return;
    textCapturePaused = state == PhoneMicState.paused;
    notifyListeners();
  }

  void _detachTextSession() {
    _textGeneration++;
    final session = _textSession;
    final events = _textEvents;
    _textSession = null;
    _textEvents = null;
    if (session == null) return;
    unawaited(() async {
      try {
        await events?.cancel();
        await session.close();
        await session.dispose();
      } catch (e) {
        debugPrint('[TextCapture] close: $e');
      }
    }());
  }

  Future<void> _connectText() async {
    final config = _textConfig;
    if (!textCaptureActive || _textStopping || config == null) return;
    _detachTextSession();
    final generation = _textGeneration;
    final SttStreamSession session;
    try {
      session = _openTextStream(config);
    } catch (e) {
      textCaptureError = '无法连接语音服务：$e';
      notifyListeners();
      return;
    }
    _textSession = session;
    _textEvents = session.events.listen((event) {
      if (generation == _textGeneration) _onTextEvent(event);
    });
    try {
      await session.start();
    } catch (e) {
      if (generation != _textGeneration) return;
      debugPrint('[TextCapture] connect failed: $e');
      _detachTextSession();
      textCaptureError = '暂时连不上语音服务，说的话先存在手机上，连上后补识别';
      _retryTextLater();
      notifyListeners();
      return;
    }
    if (generation != _textGeneration) return;
    _textRetry = 0;
    _textFinalMark = _textSent;
    _textLive = '';
    _textAtFinal = '';
    textCaptureError = null;
    notifyListeners();
    unawaited(_pumpText());
    // A working connection means the network is back for earlier tails too.
    unawaited(_recoverTextCaptures());
  }

  void _retryTextLater() {
    if (!textCaptureActive || _textStopping || _disposed) return;
    final delay = _retryDelays[math.min(_textRetry, _retryDelays.length - 1)];
    _textRetry++;
    _textRetryTimer?.cancel();
    _textRetryTimer = Timer(delay, () {
      _textRetryTimer = null;
      unawaited(_connectText());
    });
  }

  /// Sends spooled audio the service has not received, in order. Called
  /// after every write and after each connect; one pump runs at a time.
  Future<void> _pumpText() {
    final running = _textPump;
    if (running != null) return running;
    final pump = _runTextPump().whenComplete(() => _textPump = null);
    return _textPump = pump;
  }

  Future<void> _runTextPump() async {
    while (true) {
      final session = _textSession;
      final spool = _textSpool;
      if (session == null || spool == null || !session.isServerReady) return;
      final generation = _textGeneration;
      final available = spool.length - _textSent;
      if (available <= 0) return;
      final from = _textSent;
      final take = available < _chunkBytes ? available : _chunkBytes;
      final chunk = await spool.read(from, from + take);
      if (generation != _textGeneration || _textSent != from) return;
      if (chunk.isEmpty) return;
      session.sendPcm(chunk);
      _textSent = from + chunk.length;
      if (spool.length - _textSent > _unpacedBacklog) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

  void _onTextEvent(SttStreamEvent event) {
    switch (event.type) {
      case 'partial':
        if (event.text.trim().isEmpty) return;
        _textLive = normalizeSttText(event.text);
        if (event.speechFinal) {
          _textAtFinal = _textLive;
          _textFinalMark = _textSent;
          _scheduleTextDraft();
        }
        notifyListeners();
      case 'done':
        if (event.text.trim().isNotEmpty) {
          _textLive = normalizeSttText(event.text);
        }
        _textAtFinal = _textLive;
        _textFinalMark = _textSent;
        if (!_textStopping) _onTextSessionLost('语音服务结束了这一段连接');
      case 'error':
      case 'closed':
        if (!_textStopping) _onTextSessionLost('连接中断');
      default:
        break;
    }
  }

  void _onTextSessionLost(String reason) {
    _rewindText();
    _detachTextSession();
    textCaptureError = '$reason，正在重新连接；这期间说的话连上后会补上';
    _scheduleTextDraft();
    _retryTextLater();
    notifyListeners();
  }

  /// Keeps the finished sentences of a lost connection and sends what
  /// followed them again, so the unfinished sentence is neither lost nor
  /// doubled.
  void _rewindText() {
    if (_textSent - _textFinalMark <= _maxResendBytes) {
      _textCommitted = _joinText(_textCommitted, _textAtFinal);
      _textSent = _textFinalMark;
    } else {
      _textCommitted = _joinText(_textCommitted, _textLive);
    }
    _textLive = '';
    _textAtFinal = '';
    _textFinalMark = _textSent;
  }

  MinutesDocument? _textDocument(
    String id,
    DateTime startedAt,
    String text, {
    String? warning,
    Set<int> marks = const {},
  }) {
    final lines = _textLines(text);
    if (lines.isEmpty) return null;
    return MinutesDocument(
      id: id,
      title: '纯文字记录 ${_takeLabel(startedAt)}',
      sourceName: '纯文字记录',
      importedAt: startedAt,
      capturedAt: startedAt,
      segments: [
        for (final (index, line) in lines.indexed)
          MinutesSegment(
            text: line,
            start: Duration.zero,
            highlighted: marks.contains(index),
          ),
      ],
      timingReliable: false,
      warning: warning,
    );
  }

  Future<void> _queueTextSave(Future<void> Function() save) =>
      _textSaves = _textSaves.then((_) async {
        try {
          await save();
        } catch (e) {
          debugPrint('[TextCapture] save: $e');
        }
      });

  void _scheduleTextDraft() {
    if (_textDraftTimer != null || !textCaptureActive || _textStopping) return;
    final last = _textLastDraft;
    var wait = last == null
        ? Duration.zero
        : _draftInterval - DateTime.now().difference(last);
    if (wait.isNegative) wait = Duration.zero;
    _textDraftTimer = Timer(wait, () {
      _textDraftTimer = null;
      _textLastDraft = DateTime.now();
      unawaited(_saveTextDraft());
    });
  }

  /// Saves the finished sentences, and where they end in the audio, so a
  /// crash loses neither the text nor the speech after it.
  Future<void> _saveTextDraft() {
    final id = _textId;
    final startedAt = _textStartedAt;
    if (id == null || startedAt == null) return _textSaves;
    final text = _joinText(_textCommitted, _textAtFinal);
    final mark = _textFinalMark;
    final marks = {..._textMarks};
    return _queueTextSave(() async {
      final document = _textDocument(
        id,
        startedAt,
        text,
        warning: '记录还在进行，或在结束前中断；中断后没识别的部分会在下次联网时补上',
        marks: marks,
      );
      if (document == null) return;
      await minutes.upsert(document, strict: false);
      await _saveTextState(sentBytes: mark);
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _saveTextState({int sentBytes = 0}) async {
    final id = _textId;
    final startedAt = _textStartedAt;
    final spool = _textSpool;
    if (id == null || startedAt == null || spool == null) return;
    try {
      await spool.saveState(
        TextCaptureSpoolState(
          documentId: id,
          startedAt: startedAt,
          sentBytes: sentBytes,
        ),
      );
    } catch (e) {
      debugPrint('[TextCapture] state: $e');
    }
  }

  void _clearTextCapture() {
    _textRetryTimer?.cancel();
    _textRetryTimer = null;
    _textDraftTimer?.cancel();
    _textDraftTimer = null;
    _textId = null;
    _textStartedAt = null;
    _textConfig = null;
    _textSpool = null;
    _textSent = 0;
    _textFinalMark = 0;
    _textCommitted = '';
    _textLive = '';
    _textAtFinal = '';
    _textMarks.clear();
    textCapturePaused = false;
  }

  Future<void> _stopTextMicrophone() async {
    _textRetryTimer?.cancel();
    _textRetryTimer = null;
    _textDraftTimer?.cancel();
    _textDraftTimer = null;
    try {
      await _micStream.stop();
    } catch (_) {}
    await _textMic?.cancel();
    _textMic = null;
    await _textMicStates?.cancel();
    _textMicStates = null;
  }

  /// Ends capture and saves the text. With [keepAudio] the audio is kept as
  /// an original too and the text becomes its transcript. Speech the
  /// service never received is recognized from the phone, now or once the
  /// network is back.
  Future<TextCaptureOutcome?> stopTextCapture({bool keepAudio = false}) async {
    final id = _textId;
    final spool = _textSpool;
    final startedAt = _textStartedAt;
    final config = _textConfig;
    if (id == null ||
        spool == null ||
        startedAt == null ||
        config == null ||
        _textStopping) {
      return null;
    }
    _textStopping = true;
    notifyListeners();
    try {
      await _stopTextMicrophone();
      await spool.flush();
      final session = _textSession;
      var finished = false;
      if (session != null &&
          session.isServerReady &&
          spool.length - _textSent <= _streamTailLimit) {
        await _pumpText();
        await _pumpText();
        try {
          final done = await session.finish();
          final incoming = normalizeSttText(done?.text ?? '');
          if (incoming.isNotEmpty &&
              (_textLive.isEmpty || incoming.contains(_textLive))) {
            _textLive = incoming;
          }
          finished = true;
        } catch (e) {
          debugPrint('[TextCapture] finish: $e');
        }
      }
      if (finished) {
        _textCommitted = _joinText(_textCommitted, _textLive);
        _textLive = '';
        _textAtFinal = '';
        _textFinalMark = _textSent;
      } else {
        _rewindText();
      }
      _detachTextSession();
      await _textSaves;

      final text = _textCommitted.trim();
      final tailBytes = spool.length - _textSent;
      final pendingSeconds = tailBytes >= _bytesPerSecond ~/ 2
          ? (tailBytes + _bytesPerSecond - 1) ~/ _bytesPerSecond
          : 0;

      String? recordingPath;
      if (keepAudio) {
        final dir = await _importDirectory();
        await dir.create(recursive: true);
        final path = p.join(
          dir.path,
          'textcap_${startedAt.microsecondsSinceEpoch}.wav',
        );
        await spool.writeWav(path);
        if (pendingSeconds == 0 && text.isNotEmpty) {
          rememberTranscript(
            path,
            text,
            provider: config.provider,
            sourceLanguage: config.sourceLanguage,
          );
        }
        recordingPath = await _adoptPhoneTake(path, startedAt, label: '纯文字记录');
        if (recordingPath != null && pendingSeconds == 0) {
          await _removeTextDocument(id);
          await spool.delete();
          _clearTextCapture();
          return TextCaptureOutcome(
            recordingPath: recordingPath,
            message: text.isEmpty ? '原声已保存，没有识别到文字' : '文字和原声已保存',
          );
        }
      }

      if (text.isEmpty && pendingSeconds == 0) {
        await _removeTextDocument(id);
        await spool.delete();
        _clearTextCapture();
        return TextCaptureOutcome(
          recordingPath: recordingPath,
          message: recordingPath == null ? '没有识别到文字，未保存' : '原声已保存，没有识别到文字',
        );
      }

      final document = _textDocument(
        id,
        startedAt,
        text.isEmpty ? _waitingLine : text,
        marks: text.isEmpty ? const {} : {..._textMarks},
        warning: pendingSeconds > 0
            ? '还有约 $pendingSeconds 秒的话没识别，联网后自动补上并接在后面'
            : null,
      )!;
      try {
        await minutes.upsert(document, strict: true);
      } catch (_) {
        textCaptureError = '文字保存失败，请再点一次结束';
        return null;
      }
      if (pendingSeconds > 0) {
        final state = TextCaptureSpoolState(
          documentId: id,
          startedAt: startedAt,
          sentBytes: _textSent,
        );
        await spool.saveState(state);
        await spool.close();
        unawaited(_recognizeTextTail(spool, state));
      } else {
        await spool.delete();
      }
      _clearTextCapture();
      return TextCaptureOutcome(
        document: document,
        recordingPath: recordingPath,
        pendingSeconds: pendingSeconds,
        message: pendingSeconds > 0
            ? '文字已保存；还有约 $pendingSeconds 秒联网后补上'
            : recordingPath != null
            ? '原声已保存，文字已保存到资料'
            : '文字已保存到资料',
      );
    } finally {
      _textStopping = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Throws the capture away: its text and its audio. The UI confirms first.
  Future<void> discardTextCapture() async {
    final id = _textId;
    final spool = _textSpool;
    if (id == null || spool == null || _textStopping) return;
    _textStopping = true;
    try {
      await _stopTextMicrophone();
      _detachTextSession();
      await _textSaves;
      await _removeTextDocument(id);
      await spool.delete();
      _clearTextCapture();
      textCaptureError = null;
    } finally {
      _textStopping = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _removeTextDocument(String id) async {
    if (minutes.byId(id) == null) return;
    try {
      await minutes.remove(id, strict: false);
    } catch (_) {}
  }

  /// Recognizes speech left in spools by a crash or a stop without network
  /// and appends it to its text record. Failed attempts keep the spool for
  /// the next launch or connection.
  Future<void> _recoverTextCaptures() async {
    try {
      final pending = await TextCaptureSpool.pending(
        await _textCaptureDirectory(),
      );
      for (final (spool, state) in pending) {
        if (_disposed) return;
        if (spool.pcm.path == _textSpool?.pcm.path) continue;
        await _recognizeTextTail(spool, state);
      }
    } catch (e) {
      debugPrint('[TextCapture] recover: $e');
    }
  }

  Future<void> _recognizeTextTail(
    TextCaptureSpool spool,
    TextCaptureSpoolState state,
  ) async {
    if (!_textTails.add(spool.pcm.path)) return;
    final wav = p.setExtension(spool.pcm.path, '.wav');
    try {
      await _minutesLoaded;
      final existing = minutes.byId(state.documentId);
      final kept = [
        for (final segment in existing?.segments ?? const <MinutesSegment>[])
          if (segment.text != _waitingLine) segment,
      ];
      var tail = '';
      if (spool.length - state.sentBytes >= _bytesPerSecond ~/ 2) {
        final config = _settingsConfiguration;
        if (!_isConfigured(config)) return;
        await spool.writeWav(wav, start: state.sentBytes);
        final result = await _transcribePath(wav, configuration: config);
        tail = normalizeSttText(result.text).trim();
      }
      final document = _textDocument(
        state.documentId,
        state.startedAt,
        _joinText(kept.map((segment) => segment.text).join('\n'), tail),
        marks: {
          for (final (index, segment) in kept.indexed)
            if (segment.highlighted) index,
        },
      );
      if (document == null) {
        await _removeTextDocument(state.documentId);
      } else {
        await minutes.upsert(document, strict: true);
      }
      await spool.delete();
      if (!_disposed) notifyListeners();
    } catch (e) {
      debugPrint('[TextCapture] tail: $e');
    } finally {
      try {
        final file = File(wav);
        if (await file.exists()) await file.delete();
      } catch (_) {}
      _textTails.remove(spool.pcm.path);
    }
  }

  void _disposeTextCapture() {
    _textRetryTimer?.cancel();
    _textDraftTimer?.cancel();
    unawaited(_textMic?.cancel());
    unawaited(_textMicStates?.cancel());
    _detachTextSession();
    // The spool stays on disk: the next launch recognizes what is left.
    unawaited(_textSpool?.close());
  }
}
