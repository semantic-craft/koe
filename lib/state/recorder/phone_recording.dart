part of '../recorder_controller.dart';

/// Phone microphone takes: start, pause, resume, stop and save as an original
/// in the library, plus recovery of a take cut off by a crash or kill.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderPhoneRecording on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  abstract final Future<void> _libraryLoaded;
  abstract final MacArchiveController archive;
  abstract String? errorMessage;
  abstract List<String> exportedPaths;
  abstract final RecordingLibraryStore library;
  abstract String? statusMessage;
  PhoneRecorder get _phoneRecorder;
  bool get phoneRecordingEnabled;
  Future<void> attachAutomaticPlace(String path);
  Future<Directory> _importDirectory();
  void _invalidateLocalDuration(String path);
  void _registerExportedPaths(Iterable<String> paths);
  Future<void> stopPlayback();
  // END DEPS

  static const _takePrefix = 'phone_';
  static const _minimumTakeBytes = 8192;

  String? _phoneTakePath;
  DateTime? _phoneTakeStartedAt;
  DateTime? _phoneTakeRunningSince;
  Duration _phoneTakeElapsed = Duration.zero;
  bool _phoneTakeBusy = false;
  StreamSubscription<PhoneMicState>? _phoneMicStates;

  /// Why the last start or save did not complete; null when it did.
  String? phoneRecordingError;

  bool get phoneRecordingActive => _phoneTakePath != null;
  bool get phoneRecordingPaused =>
      phoneRecordingActive && _phoneTakeRunningSince == null;

  Duration get phoneRecordingElapsed {
    final since = _phoneTakeRunningSince;
    if (since == null) return _phoneTakeElapsed;
    return _phoneTakeElapsed + DateTime.now().difference(since);
  }

  /// Starts a microphone take. A denied permission leaves import available.
  Future<void> startPhoneRecording() async {
    if (!phoneRecordingEnabled || phoneRecordingActive || _phoneTakeBusy) {
      return;
    }
    _phoneTakeBusy = true;
    try {
      await _libraryLoaded;
      if (!await _phoneRecorder.requestPermission()) {
        phoneRecordingError = '没有麦克风权限。可在系统设置里允许 Koe 使用麦克风，或先导入音频';
        notifyListeners();
        return;
      }
      await stopPlayback();
      final dir = await _importDirectory();
      await dir.create(recursive: true);
      final startedAt = DateTime.now();
      final path = p.join(
        dir.path,
        '$_takePrefix${startedAt.microsecondsSinceEpoch}.wav',
      );
      try {
        await _phoneRecorder.start(path);
      } catch (_) {
        phoneRecordingError = '无法开始录音，麦克风可能正被其他应用使用';
        notifyListeners();
        return;
      }
      phoneRecordingError = null;
      _phoneTakePath = path;
      _phoneTakeStartedAt = startedAt;
      _phoneTakeRunningSince = startedAt;
      _phoneTakeElapsed = Duration.zero;
      await _phoneMicStates?.cancel();
      _phoneMicStates = _phoneRecorder.states.listen(_onPhoneMicState);
      notifyListeners();
    } finally {
      _phoneTakeBusy = false;
    }
  }

  void _onPhoneMicState(PhoneMicState state) {
    if (!phoneRecordingActive || _disposed) return;
    switch (state) {
      case PhoneMicState.paused:
        _markPhoneTakePaused();
      case PhoneMicState.recording:
        _markPhoneTakeRunning();
      case PhoneMicState.stopped:
        break;
    }
    notifyListeners();
  }

  void _markPhoneTakePaused() {
    final since = _phoneTakeRunningSince;
    if (since == null) return;
    _phoneTakeElapsed += DateTime.now().difference(since);
    _phoneTakeRunningSince = null;
  }

  void _markPhoneTakeRunning() {
    _phoneTakeRunningSince ??= DateTime.now();
  }

  Future<void> pausePhoneRecording() async {
    if (!phoneRecordingActive || phoneRecordingPaused) return;
    await _phoneRecorder.pause();
    _markPhoneTakePaused();
    notifyListeners();
  }

  Future<void> resumePhoneRecording() async {
    if (!phoneRecordingActive || !phoneRecordingPaused) return;
    await _phoneRecorder.resume();
    _markPhoneTakeRunning();
    notifyListeners();
  }

  /// Stops the take and saves it as an original. Returns the saved path, or
  /// null when nothing usable was recorded or the save failed; a failed save
  /// keeps the audio file and is retried on the next launch.
  Future<String?> stopPhoneRecording() async {
    final path = _phoneTakePath;
    final startedAt = _phoneTakeStartedAt;
    if (path == null || startedAt == null || _phoneTakeBusy) return null;
    _phoneTakeBusy = true;
    try {
      try {
        await _phoneRecorder.stop();
      } catch (_) {
        // The file written so far is still adopted below.
      }
      _clearPhoneTake();
      notifyListeners();
      return await _adoptPhoneTake(path, startedAt);
    } finally {
      _phoneTakeBusy = false;
    }
  }

  /// Throws the current take away. The UI confirms before calling this.
  Future<void> discardPhoneRecording() async {
    final path = _phoneTakePath;
    if (path == null || _phoneTakeBusy) return;
    _phoneTakeBusy = true;
    try {
      try {
        await _phoneRecorder.cancel();
      } catch (_) {}
      _clearPhoneTake();
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
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
  }

  Future<String?> _adoptPhoneTake(
    String path,
    DateTime recordedAt, {
    String label = '手机录音',
  }) async {
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
      phoneRecordingError = '没有录到声音，未保存';
      notifyListeners();
      return null;
    }
    try {
      final hash = await audioVersion(path);
      final asset = RecordingAsset(
        path: path,
        displayName: '$label ${_takeLabel(recordedAt)}',
        source: RecordingSource.phone,
        recordedAt: recordedAt,
        importedAt: DateTime.now(),
        contentHash: hash,
      );
      await library.upsert(asset);
    } catch (_) {
      phoneRecordingError = '录音已留在手机上，但没能加入资料库；重新打开 Koe 时会再试';
      notifyListeners();
      return null;
    }
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
  Future<void> _recoverInterruptedPhoneTakes() async {
    if (!phoneRecordingEnabled) return;
    await _libraryLoaded;
    final dir = await _importDirectory();
    if (!await dir.exists()) return;
    var recovered = 0;
    await for (final entity in dir.list()) {
      if (_disposed) return;
      if (entity is! File) continue;
      final name = p.basenameWithoutExtension(entity.path);
      if (!name.startsWith(_takePrefix) || p.extension(entity.path) != '.wav') {
        continue;
      }
      if (entity.path == _phoneTakePath) continue;
      if (library.assetForPath(entity.path) != null) continue;
      final micros = int.tryParse(name.substring(_takePrefix.length));
      if (micros == null) continue;
      final started = DateTime.fromMicrosecondsSinceEpoch(micros);
      if (await _adoptPhoneTake(entity.path, started) != null) recovered++;
    }
    if (recovered > 0 && !_disposed) {
      statusMessage = '找回了 $recovered 段中断的手机录音';
      notifyListeners();
    }
  }

  String _takeLabel(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  }
}
