part of '../recorder_controller.dart';

/// Where one recording stands in automatic organizing (#133).
enum OrganizeStage {
  /// Not queued and never organized.
  none,

  /// Queued; nothing has started yet.
  waiting,
  transcribing,

  /// Writing the summary or extracting todos.
  organizing,

  /// Transcript, summary and todo extraction are all current.
  done,
  failed,

  /// A paid request may have reached the provider without a saved answer.
  /// Koe does not resend it on its own; the user decides.
  needsCheck,
}

class OrganizeStatus {
  const OrganizeStatus(this.stage, [this.message]);
  final OrganizeStage stage;
  final String? message;

  String get label => switch (stage) {
    OrganizeStage.none => '',
    OrganizeStage.waiting => '待整理',
    OrganizeStage.transcribing => '转写中',
    OrganizeStage.organizing => '整理中',
    OrganizeStage.done => '已整理',
    OrganizeStage.failed => '整理失败',
    OrganizeStage.needsCheck => '待核实',
  };
}

/// History the user may choose to organize after switching the feature on.
enum OrganizeRange { lastWeek, lastMonth, all }

/// Automatic organizing: once switched on, every new recording is transcribed,
/// summarized and scanned for todos; history is processed only for a range
/// the user picks. Each step reuses a finished result, and a step whose paid
/// request ended in an unknown state waits for the user instead of resending.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderOrganize on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  abstract final DeferredFileJobs<SpeechConfiguration> _deferredJobs;
  abstract final FileJobJournal _fileJobs;
  abstract final Future<void> _fileJobsLoaded;
  abstract final Future<void> _libraryLoaded;
  abstract final Map<String, String> _recordingErrors;
  abstract final Map<String, String> _completenessErrors;
  abstract String? _fileJobKey;
  Set<int> get _incompleteRetrievalIds;
  abstract final Future<void> _settingsLoaded;
  abstract Future<void> _transcriptsLoaded;
  abstract final RecordingAnalysis analysis;
  abstract List<String> exportedPaths;
  abstract final TodoStore todos;
  SpeechConfiguration get _settingsConfiguration;
  String get analysisApiKey;
  bool _isConfigured(SpeechConfiguration config);
  bool _isRecordingAudioLocked(int? id, String? path);
  bool _isTrashedPath(String path);
  String analysisKey(RecordingReference ref);
  Future<int> extractTodos(RecordingReference ref, {bool confirmRetry = false});
  int? fileIdFromPath(String path);
  bool recordingAudioChanged(RecordingReference ref);
  DateTime? recordingRecordedAtForPath(String path);
  RecordingViewData recordingView(RecordingReference ref);
  Future<void> transcribeLocalFile(
    String path, {
    String? sourceLanguage,
    bool prepareLanguages = false,
  });
  // END DEPS

  late final OrganizeStore organizeStore;
  late final Future<void> _organizeLoaded;
  final Map<String, String> _organizeFailures = {};
  final Set<String> _organizeTranscribeRequested = {};
  bool _organizePumping = false;
  bool _organizeDirty = false;
  bool _organizeScheduled = false;

  bool get autoOrganize => organizeStore.enabled;

  Future<void> _loadOrganize() async {
    await Future.wait([
      organizeStore.load(),
      _settingsLoaded,
      _libraryLoaded,
      _fileJobsLoaded,
      _transcriptsLoaded,
      analysis.load(),
      todos.load(),
    ]);
    if (_disposed) return;
    addListener(_scheduleOrganize);
    _scheduleOrganize();
  }

  @visibleForTesting
  Future<void> waitForOrganize() async {
    await _organizeLoaded;
    for (var i = 0; i < 200 && (_organizePumping || _organizeScheduled); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Turning it on treats everything already here as history; only
  /// recordings that arrive afterwards are organized automatically.
  Future<void> setAutoOrganize(bool value) async {
    await _organizeLoaded;
    if (organizeStore.enabled == value) return;
    organizeStore.enabled = value;
    if (value) {
      organizeStore.known
        ..clear()
        ..addAll(exportedPaths);
    } else {
      organizeStore.queued.clear();
      _organizeFailures.clear();
    }
    await _saveOrganize();
    notifyListeners();
    _scheduleOrganize();
  }

  /// Recordings in [range] that are not yet fully organized.
  List<String> organizeCandidates(OrganizeRange range, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final since = switch (range) {
      OrganizeRange.lastWeek => today.subtract(const Duration(days: 7)),
      OrganizeRange.lastMonth => today.subtract(const Duration(days: 30)),
      OrganizeRange.all => null,
    };
    return [
      for (final path in exportedPaths)
        if (!_isTrashedPath(path) &&
            organizeStatusFor(path).stage != OrganizeStage.done &&
            (since == null ||
                !(recordingRecordedAtForPath(path) ?? today).isBefore(since)))
          path,
    ];
  }

  /// Queues history the user chose. Finished steps are reused, so a
  /// recording that already has a transcript only gets the missing steps.
  Future<int> organizeHistory(Iterable<String> paths) async {
    await _organizeLoaded;
    var added = 0;
    for (final path in paths) {
      if (organizeStore.queued.contains(path)) continue;
      organizeStore.queued.add(path);
      _organizeFailures.remove(path);
      added++;
    }
    if (added > 0) {
      await _saveOrganize();
      notifyListeners();
      _scheduleOrganize();
    }
    return added;
  }

  /// The user's answer to a failure or an unknown result: run that step again,
  /// confirming that an unknown paid request may be charged twice.
  Future<void> retryOrganize(String path) async {
    await _organizeLoaded;
    final status = organizeStatusFor(path);
    _organizeFailures.remove(path);
    if (!organizeStore.queued.contains(path)) organizeStore.queued.add(path);
    await _saveOrganize();
    final ref = _organizeRef(path);
    if (status.stage == OrganizeStage.needsCheck) {
      final key = analysisKey(ref);
      final summaryKey = RecordingAnalysis.keyForTemplate(
        key,
        summaryTemplateId,
      );
      if (_transcriptOf(path).isEmpty) {
        _organizeTranscribeRequested.add(path);
        unawaited(transcribeLocalFile(path));
      } else if (analysis.hasUnconfirmedNode(summaryKey)) {
        await _runSummary(path, confirmed: true);
      } else {
        await _runTodos(path, confirmed: true);
      }
    } else if (status.stage == OrganizeStage.failed &&
        _transcriptOf(path).isEmpty) {
      _recordingErrors.remove(analysisKey(ref));
      _organizeTranscribeRequested.add(path);
      unawaited(transcribeLocalFile(path));
    }
    notifyListeners();
    _scheduleOrganize();
  }

  /// The queue lives in memory either way; a failed write only means a
  /// restart may need the user to queue history again.
  Future<void> _saveOrganize() async {
    try {
      await organizeStore.save();
    } catch (error) {
      debugPrint('[Organize] save failed: $error');
    }
  }

  RecordingReference _organizeRef(String path) =>
      RecordingReference(fileId: fileIdFromPath(path), path: path);

  String _transcriptOf(String path) =>
      recordingView(_organizeRef(path)).text.trim();

  /// Derived from the saved transcript, analysis and todo records, so it is
  /// the same after a restart and for recordings organized by hand.
  OrganizeStatus organizeStatusFor(String path) {
    final queued = organizeStore.queued.contains(path);
    final failure = _organizeFailures[path];
    final ref = _organizeRef(path);
    final key = analysisKey(ref);
    final text = _transcriptOf(path);
    if (text.isEmpty) {
      final job = _fileJobs.jobs[key];
      // Running without a task id is unknown only when no transcription is
      // in flight for it now, i.e. the app stopped mid-request.
      if (job != null &&
          job.stage == 'running' &&
          job.taskId == null &&
          _fileJobKey != key) {
        return const OrganizeStatus(
          OrganizeStage.needsCheck,
          '转写请求结果未知；为避免重复收费，确认后再重新转写',
        );
      }
      if (failure != null) return OrganizeStatus(OrganizeStage.failed, failure);
      // A manual transcription that failed outside automatic organizing
      // shows its own error on the recording, not as an organizing step.
      if (job != null && job.stage == 'failed') {
        return queued
            ? OrganizeStatus(OrganizeStage.failed, job.error ?? '转写失败')
            : const OrganizeStatus(OrganizeStage.none);
      }
      if (job != null ||
          _organizeTranscribeRequested.contains(path) && queued) {
        return const OrganizeStatus(OrganizeStage.transcribing);
      }
      return OrganizeStatus(
        queued ? OrganizeStage.waiting : OrganizeStage.none,
      );
    }
    final summaryKey = RecordingAnalysis.keyForTemplate(key, summaryTemplateId);
    if (analysis.hasUnconfirmedNode(summaryKey) &&
        !analysis.running(summaryKey)) {
      return const OrganizeStatus(
        OrganizeStage.needsCheck,
        '摘要请求结果未知；为避免重复收费，确认后再重新生成',
      );
    }
    final extraction = todos.extractionFor(key);
    if (extraction != null && !extraction.done) {
      if (!_organizeExtracting.contains(path)) {
        return const OrganizeStatus(
          OrganizeStage.needsCheck,
          '提取待办的结果未知；确认后再重新提取',
        );
      }
    }
    if (failure != null) return OrganizeStatus(OrganizeStage.failed, failure);
    if (analysis.running(summaryKey) || _organizeExtracting.contains(path)) {
      return const OrganizeStatus(OrganizeStage.organizing);
    }
    if (_summaryCurrent(path, summaryKey, text) &&
        extraction != null &&
        extraction.fingerprint == analysisFingerprint(text)) {
      return const OrganizeStatus(OrganizeStage.done);
    }
    return OrganizeStatus(queued ? OrganizeStage.waiting : OrganizeStage.none);
  }

  final Set<String> _organizeExtracting = {};

  /// A user-edited summary counts as current: Koe never overwrites it.
  bool _summaryCurrent(String path, String summaryKey, String text) {
    final result = analysis.results[summaryKey];
    if (result == null) return false;
    return result.editedAt != null || !result.staleFor(text);
  }

  void _scheduleOrganize() {
    if (_disposed) return;
    if (_organizePumping) {
      _organizeDirty = true;
      return;
    }
    if (_organizeScheduled) return;
    _organizeScheduled = true;
    scheduleMicrotask(() {
      _organizeScheduled = false;
      unawaited(_pumpOrganize());
    });
  }

  Future<void> _pumpOrganize() async {
    if (_organizePumping || _disposed) return;
    _organizePumping = true;
    try {
      do {
        _organizeDirty = false;
        await _enqueueNewRecordings();
        for (final path in List<String>.of(organizeStore.queued)) {
          if (_disposed) return;
          await _advanceOrganize(path);
        }
      } while (_organizeDirty && !_disposed);
    } finally {
      _organizePumping = false;
    }
  }

  Future<void> _enqueueNewRecordings() async {
    if (!organizeStore.enabled) return;
    var changed = false;
    for (final path in exportedPaths) {
      if (!organizeStore.known.add(path)) continue;
      changed = true;
      if (!_isTrashedPath(path) && !organizeStore.queued.contains(path)) {
        organizeStore.queued.add(path);
      }
    }
    if (changed) {
      await _saveOrganize();
      notifyListeners();
    }
  }

  Future<void> _advanceOrganize(String path) async {
    if (_isTrashedPath(path) || !File(path).existsSync()) {
      await _dequeueOrganize(path);
      return;
    }
    final status = organizeStatusFor(path);
    switch (status.stage) {
      case OrganizeStage.done:
        await _dequeueOrganize(path);
        return;
      case OrganizeStage.failed:
      case OrganizeStage.needsCheck:
      case OrganizeStage.organizing:
        return;
      case OrganizeStage.transcribing:
        _checkTranscriptionGaveUp(path);
        return;
      case OrganizeStage.none:
      case OrganizeStage.waiting:
        break;
    }
    final ref = _organizeRef(path);
    if (_transcriptOf(path).isEmpty) {
      // A device recording still being retrieved, or cut short, waits for
      // the retrieval path's own completeness check.
      if (_isRecordingAudioLocked(ref.fileId, path) ||
          recordingAudioChanged(ref) ||
          ref.fileId != null && _incompleteRetrievalIds.contains(ref.fileId) ||
          _completenessErrors.containsKey(analysisKey(ref))) {
        return;
      }
      if (!_isConfigured(_settingsConfiguration)) {
        _organizeFailures[path] = '先在设置里配置语音服务，再重试整理';
        notifyListeners();
        return;
      }
      _organizeTranscribeRequested.add(path);
      await _deferredJobs.enqueue(
        analysisKey(ref),
        path,
        _settingsConfiguration,
      );
      notifyListeners();
      return;
    }
    if (recordingAudioChanged(ref)) return;
    final key = analysisKey(ref);
    final summaryKey = RecordingAnalysis.keyForTemplate(key, summaryTemplateId);
    if (!_summaryCurrent(path, summaryKey, _transcriptOf(path))) {
      await _runSummary(path, confirmed: false);
      if (organizeStatusFor(path).stage != OrganizeStage.waiting) return;
    }
    await _runTodos(path, confirmed: false);
    if (organizeStatusFor(path).stage == OrganizeStage.done) {
      await _dequeueOrganize(path);
    }
  }

  /// A queued transcription can fail before it writes a job record, for
  /// example when the engine rejects its settings; surface that error.
  void _checkTranscriptionGaveUp(String path) {
    final ref = _organizeRef(path);
    final key = analysisKey(ref);
    if (_fileJobs.jobs.containsKey(key)) return;
    final error = _recordingErrors[key];
    if (error == null) return;
    _organizeTranscribeRequested.remove(path);
    _organizeFailures[path] = error;
    notifyListeners();
  }

  Future<void> _runSummary(String path, {required bool confirmed}) async {
    final apiKey = analysisApiKey;
    if (apiKey.isEmpty) {
      _organizeFailures[path] = '先在设置里配置通义千问，再重试整理';
      notifyListeners();
      return;
    }
    final ref = _organizeRef(path);
    final key = analysisKey(ref);
    final summaryKey = RecordingAnalysis.keyForTemplate(key, summaryTemplateId);
    final source = _transcriptOf(path);
    await analysis.run(
      recording: key,
      source: source,
      apiKey: apiKey,
      templateId: summaryTemplateId,
      avoidDuplicateCharges: true,
      confirmedRestart: confirmed,
      currentSource: () =>
          recordingAudioChanged(ref) ? '' : _transcriptOf(path),
    );
    if (analysis.results[summaryKey] == null ||
        analysis.results[summaryKey]!.staleFor(source)) {
      final error = analysis.errors[summaryKey];
      if (!analysis.hasUnconfirmedNode(summaryKey)) {
        _organizeFailures[path] = error ?? '摘要没有生成，请重试';
      }
    }
    notifyListeners();
  }

  Future<void> _runTodos(String path, {required bool confirmed}) async {
    final ref = _organizeRef(path);
    final text = _transcriptOf(path);
    final previous = todos.extractionFor(analysisKey(ref));
    if (previous != null &&
        previous.done &&
        previous.fingerprint == analysisFingerprint(text)) {
      return;
    }
    if (analysisApiKey.isEmpty) {
      _organizeFailures[path] = '先在设置里配置通义千问，再重试整理';
      notifyListeners();
      return;
    }
    _organizeExtracting.add(path);
    notifyListeners();
    try {
      await extractTodos(ref, confirmRetry: confirmed);
    } on TodoExtractionUnknown {
      // Left as an unknown marker; the status asks the user.
    } on TimeoutException {
      // The provider may have run it; the marker stays for the user.
    } catch (error) {
      _organizeFailures[path] = error is StateError
          ? error.message
          : '提取待办失败，请重试';
    } finally {
      _organizeExtracting.remove(path);
      notifyListeners();
    }
  }

  Future<void> _dequeueOrganize(String path) async {
    _organizeTranscribeRequested.remove(path);
    if (!organizeStore.queued.remove(path)) return;
    await _saveOrganize();
    notifyListeners();
  }

  /// Counts for the Today progress entry.
  ({int waiting, int working, int attention}) get organizeProgress {
    var waiting = 0, working = 0, attention = 0;
    for (final path in organizeStore.queued) {
      switch (organizeStatusFor(path).stage) {
        case OrganizeStage.waiting:
        case OrganizeStage.none:
          waiting++;
        case OrganizeStage.transcribing:
        case OrganizeStage.organizing:
          working++;
        case OrganizeStage.failed:
        case OrganizeStage.needsCheck:
          attention++;
        case OrganizeStage.done:
          break;
      }
    }
    return (waiting: waiting, working: working, attention: attention);
  }
}
