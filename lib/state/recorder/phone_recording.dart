part of '../recorder_controller.dart';

/// When a take says the disk is filling up (#403): under 1 GB as it starts
/// and under 300 MB while it records, as Shiyin warns
/// (Capture/Recorder.swift:404-420). Unlike Shiyin's one-off warning, the
/// notice stays on screen, so it keeps the room left current until there is
/// 1 GB again. Tests shorten [checkEvery].
abstract final class TakeSpaceCheck {
  static const startingBelow = 1000000000;
  static const recordingBelow = 300000000;
  static Duration checkEvery = const Duration(seconds: 30);

  /// 16 kHz mono 16-bit PCM.
  static const _bytesPerMinute = 16000 * 2 * 60;

  /// What to tell the user with [available] bytes left.
  static String notice(int available, {int lanes = 1}) {
    final minutes = available ~/ (_bytesPerMinute * lanes);
    final time = minutes < 60
        ? '$minutes 分钟'
        : minutes % 60 == 0
        ? '${minutes ~/ 60} 小时'
        : '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
    return '磁盘只剩 ${available ~/ 1000000} MB，大约还能录 $time。'
        '空间用完时录音会停下，已录的部分会保存。';
  }
}

/// Phone microphone takes: start, pause, resume, stop and save as an original
/// in the library, plus recovery of a take cut off by a crash or kill.
///
/// On Android a take runs as microphone work of Koe's foreground service, so
/// it keeps recording behind the lock screen; its notification says whether
/// it records or is paused, and 停止 there saves the take like the sheet does.
///
/// Notes typed and highlights marked during a take (#400) are kept in a file
/// beside it while it records and become its bookmarks when it is saved.
///
/// While a take records, its input level drives a meter and hints about a
/// silent, quiet or noisy microphone (#401); a take the system ends, such as
/// on an unplugged microphone or a full disk, is saved like 结束并保存.
///
/// On the Mac the microphone to record from can be chosen (#402); the choice
/// is kept on the Mac and applies to every take, hold-to-talk and text
/// capture started after it. A chosen microphone that is not connected at
/// the start gives way to the system default, and the take says so.
///
/// On the Mac a take also says when the disk is filling up (#403), as
/// [TakeSpaceCheck] sets out, and is named after the calendar meeting it was
/// recorded in (#407), whose invitees go to its minutes.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderPhoneRecording on ChangeNotifier {
  String get appleSourceLanguage;
  // Provided by _RecorderInterpreting.
  Future<T> withMicrophoneTransition<T>(
    Future<T> Function() operation, {
    bool starting = false,
  });
  // Provided by _RecorderLiveMeeting.
  void beginLiveMeeting(
    String id, {
    String? recordingKey,
    bool available = true,
    String language = 'zh',
  });
  void closeLiveMeetingInput(String id);
  Future<void> discardLiveMeeting(String id);
  Future<void> finishLiveMeeting(String id, {String? recordingKey});

  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  abstract final Future<void> _libraryLoaded;
  abstract final Future<void> _settingsLoaded;
  abstract final Future<void> _bookmarksLoaded;
  abstract Future<void> _transcriptsLoaded;
  abstract final CalendarMeetings _calendarMeetings;
  abstract final MacArchiveController archive;
  abstract final RecordingBookmarkStore bookmarks;
  abstract String? errorMessage;
  abstract List<String> exportedPaths;
  abstract final RecordingLibraryStore library;
  abstract String? statusMessage;
  PhoneRecorder get _phoneRecorder;
  bool get phoneRecordingEnabled;
  bool get meetingFromCalendar;
  bool get textCaptureActive;
  Future<void> attachAutomaticPlace(String path);
  int? expectedSpeakersForPath(String path);
  Future<void> setExpectedSpeakers(String path, int? count);
  Future<Directory> _importDirectory();
  void _invalidateLocalDuration(String path);
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  void _registerExportedPaths(Iterable<String> paths);
  Future<void> stopPlayback();
  Future<void> generateDraftMinutes(
    RecordingReference ref, {
    required String liveText,
    String templateId,
    String language,
  });
  // END DEPS

  ValueListenable<DualRecordingView>? get dualRecordingView =>
      _phoneRecorder is MacDualRecorder
      ? (_phoneRecorder as MacDualRecorder).view
      : null;

  static const _takePrefix = 'phone_';
  static const _minimumTakeBytes = 8192;

  String? _phoneTakePath;
  DateTime? _phoneTakeStartedAt;
  DateTime? _phoneTakeRunningSince;
  Duration _phoneTakeElapsed = Duration.zero;
  bool _phoneTakeBusy = false;

  /// The stop under way; a second stop, or quitting, waits for it.
  Future<String?>? _phoneTakeStop;

  /// Paused by the user rather than by the system (a call).
  bool _phoneTakeHeld = false;
  StreamSubscription<PhoneMicState>? _phoneMicStates;

  String _phoneTakeNotes = '';
  List<Duration> _phoneTakeHighlights = const [];
  Future<void> _phoneNotesWrites = Future<void>.value();
  bool _phoneNotesQueued = false;

  /// The input level of the running take, from 0 (-60 dBFS and below) to 1
  /// (full scale), every 100 ms. Only the level meter listens, so a reading
  /// redraws nothing else.
  final phoneRecordingLevel = ValueNotifier<double>(0);
  InputLevelWatch? _phoneLevelWatch;
  StreamSubscription<double>? _phoneMicLevels;

  /// What the microphone's level suggests checking, or null.
  InputLevelHint? get phoneRecordingLevelHint => _phoneLevelWatch?.hint;

  /// The microphones to choose from, as last listed; Mac only.
  List<MicInput> phoneMicInputs = const [];

  /// The microphone chosen to record from; null is the system default.
  MicInput? get phoneMicChoice => _phoneMicChoice;
  MicInput? _phoneMicChoice;
  Future<void>? _phoneMicChoiceRead;
  Future<void> _phoneMicChoiceWrites = Future<void>.value();

  /// The microphone the current take records from on the Mac; null is the
  /// system default.
  MicInput? phoneRecordingMic;

  /// Why the current take does not record from the chosen microphone.
  String? phoneRecordingMicNotice;

  /// How little room the disk has left for the current take, when that is
  /// worth saying.
  String? phoneRecordingSpaceNotice;
  Timer? _phoneSpaceChecks;

  /// The notes typed during the current take; each line begins with the
  /// recording time it was started at.
  String get phoneRecordingNotes => _phoneTakeNotes;

  /// Recording times marked with 标重点 during the current take.
  List<Duration> get phoneRecordingHighlights => _phoneTakeHighlights;

  /// About how many people speak in the current take; null is 自动判断.
  int? get phoneRecordingExpectedSpeakers => switch (_phoneTakePath) {
    final path? => expectedSpeakersForPath(path),
    null => null,
  };

  /// Sets about how many people speak in the current take (R24.2). The take
  /// keeps its path once saved, so the number is stored for that path right
  /// away: a take recovered after a kill keeps it too.
  Future<void> setPhoneRecordingExpectedSpeakers(int? count) async {
    final path = _phoneTakePath;
    if (path == null) return;
    await setExpectedSpeakers(path, count);
  }

  /// Why the last start or save did not complete; null when it did.
  String? phoneRecordingError;

  /// Whether the last start failed because microphone permission was denied.
  bool phoneRecordingPermissionDenied = false;

  /// The meeting title of a calendar reminder tapped or fired on a phone
  /// (#373). Tapping the reminder opens Koe's recording preparation without
  /// auto-starting the microphone.
  String? pendingCalendarMeetingPrompt;
  int calendarMeetingPromptRevision = 0;
  final Set<String> _remindedCalendarMeetingIds = <String>{};
  final List<Timer> _calendarReminderTimers = <Timer>[];
  Future<void>? _calendarReminderSyncing;

  void _initPhoneCalendarReminders() {
    if (!runsOnPhone || !phoneRecordingEnabled) return;
    _calendarMeetings.setOnReminderTapped((title) async {
      _triggerCalendarMeetingPrompt(title);
    });
    unawaited(
      _settingsLoaded.then((_) async {
        if (_disposed) return;
        final tapped = await _calendarMeetings.consumePendingReminderTap();
        if (tapped != null && !_disposed) {
          _triggerCalendarMeetingPrompt(tapped);
        }
        await refreshPhoneCalendarReminders();
      }),
    );
  }

  /// Refreshes start-of-meeting reminders from the phone's calendar (#373)
  /// when [meetingFromCalendar] is on.
  Future<void> refreshPhoneCalendarReminders({DateTime? now}) {
    if (!runsOnPhone || !phoneRecordingEnabled) {
      return Future<void>.value();
    }
    return _calendarReminderSyncing ??= () async {
      try {
        await _settingsLoaded;
        if (_disposed) return;
        _clearCalendarReminderTimers();
        final current = now ?? DateTime.now();
        if (!meetingFromCalendar) {
          await _calendarMeetings.syncPhoneReminders(const [], now: current);
          return;
        }
        final upcoming = await _calendarMeetings.upcomingMeetings(
          current,
          current.add(ChannelCalendarMeetings.lookahead),
        );
        if (_disposed || !meetingFromCalendar) return;
        final pending = [
          for (final m in upcoming)
            if (!_remindedCalendarMeetingIds.contains(m.id)) m,
        ];
        await _calendarMeetings.syncPhoneReminders(pending, now: current);
        if (_disposed || !meetingFromCalendar) return;
        for (final meeting in pending) {
          final delay = meeting.delayFrom(current);
          _calendarReminderTimers.add(
            Timer(delay, () {
              if (_disposed || !meetingFromCalendar) return;
              if (!_remindedCalendarMeetingIds.add(meeting.id)) return;
              _triggerCalendarMeetingPrompt(meeting.title);
            }),
          );
        }
      } finally {
        _calendarReminderSyncing = null;
      }
    }();
  }

  void _triggerCalendarMeetingPrompt(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty || _disposed) return;
    if (phoneRecordingActive || textCaptureActive) return;
    pendingCalendarMeetingPrompt = trimmed;
    calendarMeetingPromptRevision++;
    notifyListeners();
  }

  /// Clears the shown calendar meeting prompt once handled or dismissed.
  void clearCalendarMeetingPrompt() {
    if (pendingCalendarMeetingPrompt == null) return;
    pendingCalendarMeetingPrompt = null;
    notifyListeners();
  }

  void _clearCalendarReminderTimers() {
    for (final timer in _calendarReminderTimers) {
      timer.cancel();
    }
    _calendarReminderTimers.clear();
  }

  bool get phoneRecordingActive => _phoneTakePath != null;

  /// Stop was pressed and the take is being saved.
  bool get phoneRecordingSaving => _phoneTakeStop != null;

  bool get phoneRecordingPaused =>
      phoneRecordingActive && _phoneTakeRunningSince == null;

  Duration get phoneRecordingElapsed {
    final since = _phoneTakeRunningSince;
    if (since == null) return _phoneTakeElapsed;
    return _phoneTakeElapsed + DateTime.now().difference(since);
  }

  /// Starts a microphone take. A denied permission leaves import available.
  Future<void> startPhoneRecording({bool captureSystem = false}) async {
    try {
      await withMicrophoneTransition(
        () => _startPhoneRecording(captureSystem: captureSystem),
        starting: true,
      );
    } catch (e) {
      phoneRecordingError = '$e';
      notifyListeners();
    }
  }

  Future<void> _startPhoneRecording({bool captureSystem = false}) async {
    if (!phoneRecordingEnabled || phoneRecordingActive || _phoneTakeBusy) {
      return;
    }
    _phoneTakeBusy = true;
    if (_phoneRecorder case final MacDualRecorder dual) {
      dual.enabled = captureSystem;
      dual.sourceLanguage = appleSourceLanguage;
    }
    try {
      await _libraryLoaded;
      // A take started right after launch must respect the saved calendar
      // choice even when loading settings is still waiting on the Keychain.
      if (runsOnMac || runsOnPhone) await _settingsLoaded;
      if (!await _phoneRecorder.requestPermission()) {
        phoneRecordingPermissionDenied = true;
        phoneRecordingError = '没有麦克风权限。可在系统设置里允许 Koe 使用麦克风，或先导入音频';
        notifyListeners();
        return;
      }
      phoneRecordingPermissionDenied = false;
      await stopPlayback();
      final dir = await _importDirectory();
      await dir.create(recursive: true);
      final startedAt = DateTime.now();
      final path = p.join(
        dir.path,
        '$_takePrefix${startedAt.microsecondsSinceEpoch}.wav',
      );
      final mic = await _useChosenMic(_phoneRecorder);
      try {
        await _phoneRecorder.start(path);
      } catch (_) {
        phoneRecordingError = '无法开始录音，麦克风可能正被其他应用使用';
        notifyListeners();
        return;
      }
      phoneRecordingError = null;
      phoneRecordingMic = mic.used;
      phoneRecordingMicNotice = switch (mic.missing) {
        final missing? => '选的麦克风「${missing.label}」没有连接，这次用系统默认麦克风录',
        null => null,
      };
      _phoneTakeNotes = '';
      _phoneTakeHighlights = const [];
      _phoneTakePath = path;
      beginLiveMeeting(
        'phone:$path',
        recordingKey: 'audio:$path',
        available: dualRecordingView?.value.active == true,
        language: appleSourceLanguage,
      );
      _phoneTakeStartedAt = startedAt;
      _phoneTakeRunningSince = startedAt;
      _phoneTakeElapsed = Duration.zero;
      _phoneTakeHeld = false;
      await _phoneMicStates?.cancel();
      _phoneMicStates = _phoneRecorder.states.listen(_onPhoneMicState);
      _watchPhoneMicLevels();
      _watchPhoneSpace(path);
      // The first take asks for the calendar here rather than when it is
      // saved; the meeting is looked up then.
      if ((runsOnMac || runsOnPhone) && meetingFromCalendar) {
        unawaited(
          _calendarMeetings.requestAccess().then((granted) {
            if (granted && runsOnPhone && !_disposed) {
              unawaited(refreshPhoneCalendarReminders());
            }
          }),
        );
      }
      notifyListeners();
    } finally {
      _phoneTakeBusy = false;
    }
    // Started from the sheet, while Koe is on screen, as Android requires;
    // outside the busy guard, so a refusal can stop the take.
    await BackgroundSyncService.shared.begin(
      BackgroundWork.phoneRecording,
      onStop: () => unawaited(stopPhoneRecording()),
      onRefused: () => unawaited(_onPhoneBackgroundRefused()),
    );
  }

  /// Android refused the microphone service, so the take cannot go on: save
  /// what was recorded and say why.
  Future<void> _onPhoneBackgroundRefused() async {
    if (!phoneRecordingActive) return;
    await stopPhoneRecording();
    if (_disposed || phoneRecordingActive) return;
    phoneRecordingError = 'Koe 不在屏幕上时 Android 不让它开始用麦克风，录音已停下';
    notifyListeners();
  }

  /// The system ended the take: save what was recorded, as 结束并保存 does,
  /// and say why.
  Future<void> _onPhoneTakeCutOff() async {
    final saved = await stopPhoneRecording();
    if (_disposed || phoneRecordingActive) return;
    const why = '录音被系统停下了，可能是麦克风断开或磁盘已满';
    phoneRecordingError = saved != null
        ? '$why。已录的部分已保存'
        : '$why。${phoneRecordingError ?? ''}';
    notifyListeners();
  }

  /// Follows the take's input level for the meter and the hints, where the
  /// platform reports it.
  void _watchPhoneMicLevels() {
    if (_phoneRecorder case final PhoneMicLevels mic) {
      // Apple platforms report average power, the measure the hints were set
      // for; Android reports peaks.
      final watch = _phoneLevelWatch = InputLevelWatch(loudness: runsOnApple);
      _phoneMicLevels = mic.levels(InputLevelWatch.interval).listen((db) {
        if (_disposed || _phoneLevelWatch != watch || phoneRecordingPaused) {
          return;
        }
        // Shiyin's meter scale (Capture/RecordingWriter.swift:96-100).
        phoneRecordingLevel.value = ((db + 60) / 60).clamp(0.0, 1.0);
        if (watch.add(db)) notifyListeners();
      });
    }
  }

  /// Checks the room left for the take at [path] as it starts and then every
  /// [TakeSpaceCheck.checkEvery], where the platform can tell. A disk that
  /// fills up anyway ends the take, which is saved like any take the system
  /// ends.
  void _watchPhoneSpace(String path) {
    if (_phoneRecorder case final PhoneDiskSpace disk) {
      Future<void> check({required bool starting}) async {
        final available = await disk.availableSpace(path);
        if (_disposed || _phoneTakePath != path) return;
        if (available == null) {
          _phoneSpaceChecks?.cancel();
          return;
        }
        final below = starting || phoneRecordingSpaceNotice != null
            ? TakeSpaceCheck.startingBelow
            : TakeSpaceCheck.recordingBelow;
        final notice = available < below
            ? TakeSpaceCheck.notice(
                available,
                lanes: dualRecordingView?.value.active == true ? 2 : 1,
              )
            : null;
        if (notice == phoneRecordingSpaceNotice) return;
        phoneRecordingSpaceNotice = notice;
        notifyListeners();
      }

      unawaited(check(starting: true));
      _phoneSpaceChecks = Timer.periodic(
        TakeSpaceCheck.checkEvery,
        (_) => unawaited(check(starting: false)),
      );
    }
  }

  Future<File> _phoneMicChoiceFile() async =>
      File(p.join((await _importDirectory()).parent.path, 'microphone.json'));

  Future<void> _readPhoneMicChoice() => _phoneMicChoiceRead ??= () async {
    _phoneMicChoice = await MicInput.read(await _phoneMicChoiceFile());
  }();

  /// Lists the microphones to choose from. Mac only: elsewhere Koe records
  /// from the system default.
  Future<void> refreshPhoneMicInputs() async {
    if (!runsOnMac) return;
    await _readPhoneMicChoice();
    if (_phoneRecorder case final PhoneMicInputs mic) {
      try {
        phoneMicInputs = await mic.inputs();
      } catch (error) {
        debugPrint('[PhoneRecording] microphones not listed: $error');
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// Records what is started from now on from [input]; null is the system
  /// default. The choice is kept across launches.
  Future<void> choosePhoneMic(MicInput? input) async {
    await _readPhoneMicChoice();
    _phoneMicChoice = input;
    notifyListeners();
    // Each write keeps the choice current when it runs, so quick changes
    // never leave an older one on disk.
    await (_phoneMicChoiceWrites = _phoneMicChoiceWrites.then((_) async {
      try {
        await MicInput.write(await _phoneMicChoiceFile(), _phoneMicChoice);
      } catch (error) {
        debugPrint('[PhoneRecording] microphone choice not kept: $error');
      }
    }));
  }

  /// Points [mic] at the chosen microphone for the start that follows, or at
  /// the system default when the chosen one is not connected. Returns the
  /// microphone used and the chosen one that was missing. Mac only.
  Future<({MicInput? used, MicInput? missing})> _useChosenMic(
    Object mic,
  ) async {
    if (!runsOnMac || mic is! PhoneMicInputs) {
      return (used: null, missing: null);
    }
    await _readPhoneMicChoice();
    final chosen = _phoneMicChoice;
    MicInput? used;
    if (chosen != null) {
      try {
        phoneMicInputs = await mic.inputs();
        used = phoneMicInputs
            .where((input) => input.id == chosen.id)
            .firstOrNull;
      } catch (error) {
        debugPrint('[PhoneRecording] microphones not listed: $error');
      }
    }
    mic.useInput(used);
    return (used: used, missing: used == null ? chosen : null);
  }

  /// Hides the level hint shown now for the rest of the take.
  void dismissPhoneRecordingLevelHint() {
    final watch = _phoneLevelWatch;
    if (watch == null || watch.hint == null) return;
    watch.dismiss();
    notifyListeners();
  }

  void _onPhoneMicState(PhoneMicState state) {
    if (!phoneRecordingActive || _disposed) return;
    switch (state) {
      case PhoneMicState.paused:
        _markPhoneTakePaused();
      case PhoneMicState.recording:
        if (_phoneTakeHeld) {
          // The system resumed after an interruption that came while the
          // user had paused; the user's pause wins.
          unawaited(_phoneRecorder.pause().catchError((_) {}));
          return;
        }
        _markPhoneTakeRunning();
      case PhoneMicState.stopped:
        // Stop and discard hold the take busy, so this is the system ending
        // it: an unplugged microphone, a full disk.
        if (!_phoneTakeBusy) unawaited(_onPhoneTakeCutOff());
        return;
    }
    _showPhoneTakeState();
    notifyListeners();
  }

  void _showPhoneTakeState() {
    unawaited(
      BackgroundSyncService.shared.updateText(
        BackgroundWork.phoneRecording,
        phoneRecordingPaused ? 'Koe 录音已暂停' : BackgroundWork.phoneRecording.text,
      ),
    );
  }

  void _markPhoneTakePaused() {
    final since = _phoneTakeRunningSince;
    if (since == null) return;
    _phoneTakeElapsed += DateTime.now().difference(since);
    _phoneTakeRunningSince = null;
    // The level is judged afresh after a pause, as Shiyin does.
    _phoneLevelWatch?.restart();
    phoneRecordingLevel.value = 0;
  }

  void _markPhoneTakeRunning() {
    _phoneTakeRunningSince ??= DateTime.now();
  }

  Future<void> pausePhoneRecording() async {
    if (!phoneRecordingActive || phoneRecordingPaused) return;
    _phoneTakeHeld = true;
    await _phoneRecorder.pause();
    _markPhoneTakePaused();
    _showPhoneTakeState();
    notifyListeners();
  }

  Future<void> resumePhoneRecording() async {
    if (!phoneRecordingActive || !phoneRecordingPaused) return;
    _phoneTakeHeld = false;
    await _phoneRecorder.resume();
    _markPhoneTakeRunning();
    _showPhoneTakeState();
    notifyListeners();
  }

  /// Keeps the notes typed so far and writes them beside the take.
  void setPhoneRecordingNotes(String text) {
    if (!phoneRecordingActive || text == _phoneTakeNotes) return;
    _phoneTakeNotes = text;
    unawaited(_writePhoneTakeNotes());
  }

  /// Marks the current recording time as a highlight and returns it; null
  /// when no take records.
  Duration? markPhoneRecordingHighlight() {
    if (!phoneRecordingActive) return null;
    final at = phoneRecordingElapsed;
    _phoneTakeHighlights = [..._phoneTakeHighlights, at];
    unawaited(_writePhoneTakeNotes());
    notifyListeners();
    return at;
  }

  /// Writes the current notes beside the take. At most one write waits
  /// behind the one running, and it writes what is current when it starts,
  /// so fast typing never piles up writes.
  Future<void> _writePhoneTakeNotes() {
    final path = _phoneTakePath;
    if (path == null || _phoneNotesQueued) return _phoneNotesWrites;
    _phoneNotesQueued = true;
    return _phoneNotesWrites = _phoneNotesWrites.then((_) async {
      _phoneNotesQueued = false;
      if (_phoneTakePath != path) return;
      final draft = TakeNotes(
        text: _phoneTakeNotes,
        highlights: _phoneTakeHighlights,
      );
      try {
        await draft.writeTo(TakeNotes.fileFor(path));
      } catch (error) {
        debugPrint('[PhoneRecording] notes draft not written: $error');
      }
    });
  }

  /// Saves the notes of the take at [path] as its bookmarks: [draft] for a
  /// take just stopped, else the file a killed take left beside it. On
  /// failure the notes stay in that file and the next launch tries again.
  Future<void> _saveTakeNotes(String path, {TakeNotes? draft}) async {
    final file = TakeNotes.fileFor(path);
    try {
      var notes = draft ?? await TakeNotes.read(file);
      final liveFile = File(MacDualRecorder.textPath(path));

      if (await liveFile.exists()) {
        final liveText = await liveFile.readAsString();
        if (liveText.trim().isNotEmpty) {
          notes = TakeNotes(
            text: [
              if (notes != null && notes.text.isNotEmpty) notes.text,
              '本机实时识别（未校对）\n$liveText',
            ].join('\n\n'),
            highlights: notes?.highlights ?? const [],
          );
        }
      }
      if (notes != null && !notes.isEmpty) {
        await _bookmarksLoaded;
        final marks = notes.bookmarks(
          recordingKey: _recordingKey(path: path),
          takeName: p.basenameWithoutExtension(path),
          audioVersion: library.assetForPath(path)?.contentHash,
          now: DateTime.now(),
        );
        await bookmarks.addNew(marks);
        if (!_disposed) notifyListeners();
      }
      if (await file.exists()) await file.delete();
      if (await liveFile.exists()) await liveFile.delete();
    } catch (error) {
      debugPrint('[PhoneRecording] notes not saved as bookmarks: $error');
      if (draft != null) {
        try {
          await draft.writeTo(file);
        } catch (_) {}
      }
      if (_disposed) return;
      statusMessage = '录音已保存，但笔记没能存成书签；重新打开 Koe 时会再试';
      notifyListeners();
    }
  }

  Future<void> _deleteTakeNotes(String path) async {
    try {
      final file = TakeNotes.fileFor(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Stops the take and saves it as an original. Returns the saved path, or
  /// null when nothing usable was recorded or the save failed; a failed save
  /// keeps the audio file and is retried on the next launch. A stop while
  /// one is under way waits for it.
  Future<String?> stopPhoneRecording() =>
      withMicrophoneTransition(_stopPhoneRecording);
  Future<String?> _stopPhoneRecording() {
    if (_phoneTakeStop case final stopping?) return stopping;
    final path = _phoneTakePath;
    final startedAt = _phoneTakeStartedAt;
    if (path == null || startedAt == null || _phoneTakeBusy) {
      return Future.value();
    }
    final stopping = _phoneTakeStop = _stopPhoneTake(path, startedAt);
    notifyListeners();
    return stopping;
  }

  Future<String?> _stopPhoneTake(String path, DateTime startedAt) async {
    final dual = dualRecordingView?.value.active == true;
    closeLiveMeetingInput('phone:$path');
    _phoneTakeBusy = true;
    try {
      try {
        await _phoneRecorder.stop();
      } catch (_) {
        // The file written so far is still adopted below.
      }
      // Every change schedules a write, so once these finish the notes are
      // on disk before the take is, and a kill from here on loses nothing.
      await _phoneNotesWrites;
      final notes = TakeNotes(
        text: _phoneTakeNotes,
        highlights: _phoneTakeHighlights,
      );
      _clearPhoneTake();
      notifyListeners();
      final system = MacDualRecorder.systemPath(path);
      if (dual && await File(system).exists()) {
        await _adoptPhoneTake(system, startedAt, label: '系统声音');
      }
      final hasLiveText =
          dual && await File(MacDualRecorder.textPath(path)).exists();
      final saved = await _adoptPhoneTake(path, startedAt);
      if (saved == null && !await File(path).exists()) {
        // Nothing of the take is kept, so neither are its notes and the
        // number of people chosen for it.
        await _deleteTakeNotes(path);
        await setExpectedSpeakers(path, null);
      } else if (notes.isEmpty && !hasLiveText) {
        // Nothing to keep; a draft is left only if clearing it failed.
        unawaited(_deleteTakeNotes(path));
      } else if (saved != null) {
        await _saveTakeNotes(saved, draft: notes);
      }
      await finishLiveMeeting(
        'phone:$path',
        recordingKey: saved == null ? null : 'audio:$saved',
      );
      return saved;
    } finally {
      _phoneTakeBusy = false;
      _phoneTakeStop = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Throws the current take away. The UI confirms before calling this.
  Future<void> discardPhoneRecording() async {
    final path = _phoneTakePath;
    if (path == null || _phoneTakeBusy) return;
    _phoneTakeBusy = true;
    try {
      try {
        closeLiveMeetingInput('phone:$path');
        await discardLiveMeeting('phone:$path');
        await _phoneRecorder.cancel();
      } catch (_) {}
      _clearPhoneTake();
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
      await _phoneNotesWrites;
      await _deleteTakeNotes(path);
      await setExpectedSpeakers(path, null);
      statusMessage = '已放弃这段录音';
      notifyListeners();
    } finally {
      _phoneTakeBusy = false;
    }
  }

  void _clearPhoneTake() {
    unawaited(_phoneMicStates?.cancel());
    _phoneMicStates = null;
    _phoneTakePath = null;
    _phoneTakeStartedAt = null;
    _phoneTakeRunningSince = null;
    _phoneTakeElapsed = Duration.zero;
    _phoneTakeHeld = false;
    _phoneTakeNotes = '';
    _phoneTakeHighlights = const [];
    unawaited(_phoneMicLevels?.cancel());
    _phoneMicLevels = null;
    _phoneLevelWatch = null;
    phoneRecordingLevel.value = 0;
    phoneRecordingMic = null;
    phoneRecordingMicNotice = null;
    _phoneSpaceChecks?.cancel();
    _phoneSpaceChecks = null;
    phoneRecordingSpaceNotice = null;
    unawaited(BackgroundSyncService.shared.end(BackgroundWork.phoneRecording));
  }

  Future<String?> _adoptPhoneTake(
    String path,
    DateTime recordedAt, {
    String? label,
    bool voiceNote = false,
  }) async {
    final effectiveLabel = label ?? (runsOnMac ? '麦克风录音' : '手机录音');
    final file = File(path);
    var length = 0;
    var repaired = false;
    try {
      if (await file.exists()) {
        length = await file.length();
        repaired = await repairWavSizes(path);
      }
    } catch (_) {}
    // Under a quarter second of 16 kHz mono audio holds no speech; anything
    // larger is kept even if its header cannot be parsed.
    if (!repaired && length < _minimumTakeBytes) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      phoneRecordingPermissionDenied = false;
      phoneRecordingError = '没有录到声音，未保存';
      notifyListeners();
      return null;
    }
    // Looked up by the start time, so a take found after a crash is named
    // the same way.
    final meeting =
        label == null &&
            !voiceNote &&
            (runsOnMac || runsOnPhone) &&
            meetingFromCalendar
        ? await _calendarMeetings.meetingAt(recordedAt)
        : null;
    try {
      final hash = await audioVersion(path);
      final asset = RecordingAsset(
        path: path,
        displayName:
            '${meeting?.title ?? effectiveLabel} ${_takeLabel(recordedAt)}',
        source: RecordingSource.phone,
        recordedAt: recordedAt,
        importedAt: DateTime.now(),
        contentHash: hash,
        voiceNote: voiceNote,
        meeting: meeting,
      );
      await library.upsert(asset);
    } catch (_) {
      phoneRecordingPermissionDenied = false;
      phoneRecordingError = runsOnMac
          ? '录音已留在本机，但没能加入资料库；重新打开 Koe 时会再试'
          : '录音已留在手机上，但没能加入资料库；重新打开 Koe 时会再试';
      notifyListeners();
      return null;
    }
    phoneRecordingPermissionDenied = false;
    phoneRecordingError = null;
    _registerExportedPaths([...exportedPaths, path]);
    _invalidateLocalDuration(path);
    statusMessage = '原件已保存';
    errorMessage = null;
    notifyListeners();
    unawaited(archive.onLocalLibraryChanged());
    unawaited(attachAutomaticPlace(path));
    return path;
  }

  /// Adopts takes that never reached the library because the app was killed
  /// mid-recording or the save failed. The start time comes from the name.
  /// Notes left beside a take become its bookmarks once it is in the library.
  Future<void> _recoverInterruptedPhoneTakes() async {
    if (!phoneRecordingEnabled) return;
    await _libraryLoaded;
    // Whether a take is named after its calendar meeting is a saved choice.
    await _settingsLoaded;
    final dir = await _importDirectory();
    if (!await dir.exists()) return;
    var recovered = 0;
    final drafts = <String>[];
    await for (final entity in dir.list()) {
      if (_disposed) return;
      if (entity is! File) continue;
      final base = p.basename(entity.path);
      if (base.endsWith('.wav.dual.txt')) {
        final take = entity.path.substring(
          0,
          entity.path.length - '.dual.txt'.length,
        );
        if (take != _phoneTakePath && library.assetForPath(take) != null) {
          await _saveTakeNotes(take);
        }
        continue;
      }
      if (base.startsWith(_takePrefix) &&
          (base.endsWith(TakeNotes.draftExtension) ||
              base.endsWith('${TakeNotes.draftExtension}.part'))) {
        drafts.add(entity.path);
        continue;
      }
      final isSystem = entity.path.endsWith('.wav.system.wav');
      final name = p.basenameWithoutExtension(
        isSystem
            ? entity.path.substring(
                0,
                entity.path.length - '.system.wav'.length,
              )
            : entity.path,
      );
      if (!name.startsWith(_takePrefix) || p.extension(entity.path) != '.wav') {
        continue;
      }
      if (entity.path == _phoneTakePath ||
          (_phoneTakePath != null &&
              entity.path == MacDualRecorder.systemPath(_phoneTakePath!))) {
        continue;
      }
      if (library.assetForPath(entity.path) != null) continue;
      final primary = isSystem
          ? entity.path.substring(0, entity.path.length - '.system.wav'.length)
          : entity.path;
      if (await File('$primary.discarded').exists()) {
        for (final abandoned in [
          primary,
          MacDualRecorder.systemPath(primary),
          MacDualRecorder.textPath(primary),
        ]) {
          try {
            if (await File(abandoned).exists()) await File(abandoned).delete();
          } catch (_) {}
        }
        continue;
      }
      final micros = int.tryParse(name.substring(_takePrefix.length));
      if (micros == null) continue;
      final started = DateTime.fromMicrosecondsSinceEpoch(micros);
      if (await _adoptPhoneTake(
            entity.path,
            started,
            label: isSystem ? '系统声音' : null,
          ) !=
          null) {
        recovered++;
        if (!isSystem) await _saveTakeNotes(entity.path);
      } else if (!await entity.exists()) {
        // Too short to keep, and so is the number of people chosen for it.
        await _forgetTakeSpeakers(entity.path);
      }
    }
    for (final draft in drafts) {
      if (_disposed) return;
      final partial = draft.endsWith('.part');
      final stem = draft.substring(
        0,
        draft.length -
            TakeNotes.draftExtension.length -
            (partial ? '.part'.length : 0),
      );
      final take = '$stem.wav';
      if (take == _phoneTakePath) continue;
      if (partial) {
        // A write cut off by the kill; the file it was replacing is kept.
        try {
          await File(draft).delete();
        } catch (_) {}
      } else if (library.assetForPath(take) != null) {
        await _saveTakeNotes(take);
      } else if (!await File(take).exists()) {
        await _deleteTakeNotes(take);
        await _forgetTakeSpeakers(take);
      }
    }
    if (recovered > 0 && !_disposed) {
      statusMessage = runsOnMac
          ? '找回了 $recovered 段中断的麦克风录音'
          : '找回了 $recovered 段中断的手机录音';
      notifyListeners();
    }
  }

  /// Drops the number of people stored for a take found gone after a kill.
  /// The stored ones are loaded first, or loading would bring it back.
  Future<void> _forgetTakeSpeakers(String take) async {
    await _transcriptsLoaded;
    await setExpectedSpeakers(take, null);
  }

  @override
  void dispose() {
    unawaited(_phoneMicLevels?.cancel());
    _phoneSpaceChecks?.cancel();
    _clearCalendarReminderTimers();
    _calendarMeetings.setOnReminderTapped(null);
    phoneRecordingLevel.dispose();
    super.dispose();
  }

  String _takeLabel(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }
}
