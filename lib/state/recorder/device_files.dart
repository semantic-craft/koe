part of '../recorder_controller.dart';

/// Recordings on the recorder: the device file list and selection, automatic
/// and manual BLE transfer, Wi-Fi export, deleting device files, and
/// completing retrieved recordings into the local library.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderDeviceFiles on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  // ignore: unused_element_parameter
  void _bindCurrentRecording({int? fileId, String? path});
  abstract final BleService _ble;
  abstract final BleFilePull _blePull;
  abstract bool _catalogConversionRunning;
  Future<Set<int>> _completeLocalExportIds(
    Iterable<OfflineFileEntry> deviceFiles,
  );
  Future<String> _convertExportToWav(
    String path, {
    bool register = true,
    List<String>? conversionFailures,
  });
  _RecordingSession? get _currentRecording;
  abstract final DeferredFileJobs<SpeechConfiguration> _deferredJobs;
  abstract bool _disposed;
  abstract bool _explicitDisconnect;
  abstract final FileJobJournal _fileJobs;
  abstract final Future<void> _fileJobsLoaded;
  abstract final Set<String> _finalizingRecordings;
  bool _isConfigured(SpeechConfiguration config);
  bool _isRecordingAudioLocked(int? id, String? path);
  bool get _liveProcessing;
  Future<void> _loadLocalExports({bool notify = true});
  abstract final RealtimeBleStream _realtime;
  abstract final Map<String, String> _recordingErrors;
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  void _registerExportedPaths(Iterable<String> paths);
  Future<void> _scheduleTopicAssist(String recordingKey, String transcript);
  Future<void> _send(List<int> frame, {String? label});
  SpeechConfiguration get _settingsConfiguration;
  abstract final Future<void> _settingsLoaded;
  void _stopBatteryPoll();
  abstract final Future<void> _topicsLoaded;
  abstract Future<void> _transcriptsLoaded;
  abstract final WifiExportService _wifi;
  abstract bool autoRealtime;
  abstract bool autoTranscribe;
  abstract final Duration blePullInactivityTimeout;
  abstract bool bound;
  abstract bool connected;
  abstract bool encryptReady;
  abstract String? errorMessage;
  Future<bool> establishEncryptSession({
    Duration timeout = const Duration(seconds: 12),
  });
  int? fileIdFromPath(String path);
  abstract List<OfflineFileEntry> files;
  abstract DeviceInfoModel? info;
  String? localPathFor(int fileId);
  abstract List<String> logs;
  abstract AppPhase phase;
  abstract RealtimeStreamState realtimeState;
  abstract bool recording;
  abstract final Duration retrievedAudioSettleTime;
  abstract final Set<int> selectedFileIds;
  abstract bool selecting;
  Future<void> startScan();
  abstract String? statusMessage;
  abstract final TopicStore topics;
  abstract final bool topicsEnabled;
  String? transcriptForPath(String path);
  // END DEPS

  /// Device file ids whose latest transfer was kept without the done signal /
  /// every byte. They do not count as exported, so a manual or automatic
  /// retrieval pulls them again instead of reusing the partial file. Kept in
  /// the file-job journal directory so this survives a restart.
  Set<int> get _incompleteRetrievalIds => _fileJobs.incompleteRetrievals;

  /// Recording keys whose current error was set by the completeness gate, so
  /// a later complete retrieval can clear exactly that message.
  final Map<String, String> _completenessErrors = {};

  /// The single completion point for every device transfer (BLE automatic,
  /// BLE manual, Wi-Fi export). Converts the raw transfer to WAV, registers it
  /// in the local catalog, and — only for decrypted transfers — hands it to
  /// [processRetrievedRecording], which owns auto-switch, configuration,
  /// completeness and audio-version de-duplication.
  ///
  /// [transferComplete] is false when the transport saved a file without
  /// the done signal / every byte (BLE: [BleFilePull.isIncomplete], Wi-Fi:
  /// [WifiExportService.incompletePaths], both via
  /// [retrievedTransferComplete]) or without decrypting every chunk; such
  /// audio is kept for playback but never submitted automatically.
  ///
  /// A WAV this call just produced through an awaited conversion is already
  /// final, so it skips the growth window; only files handed over as-is wait
  /// [retrievedAudioSettleTime]. Batch Wi-Fi exports therefore do not
  /// accumulate one window per file.
  Future<List<String>> _completeRetrievedRecordings(
    Iterable<String> rawPaths, {
    required bool decrypted,
    bool Function(String rawPath)? transferComplete,
    List<String>? conversionFailures,
    Map<int, int> listedSizes = const {},
  }) async {
    final converted = <({String path, bool complete, bool written})>[];
    for (final rawPath in rawPaths) {
      final path = await _convertExportToWav(
        rawPath,
        register: false,
        conversionFailures: conversionFailures,
      );
      final complete = transferComplete?.call(rawPath) ?? true;
      final fileId = ExportCatalog.fileIdFromPath(path);
      if (fileId != null) {
        try {
          await _fileJobs.markRetrieval(
            fileId,
            complete: complete,
            listedBytes: listedSizes[fileId],
          );
        } catch (error) {
          // The in-memory mark still holds for this session.
          logs = [
            'INCOMPLETE MARK $fileId not saved: $error',
            ...logs,
          ].take(80).toList();
        }
      }
      converted.add((path: path, complete: complete, written: path != rawPath));
    }
    final paths = [for (final c in converted) c.path];
    _registerExportedPaths(paths);
    if (decrypted) {
      for (final c in converted) {
        await _processRetrievedRecording(
          c.path,
          transferComplete: c.complete,
          settle: c.written ? Duration.zero : retrievedAudioSettleTime,
        );
      }
    }
    return paths;
  }

  /// Wi-Fi export post-processing, split out so the shared completion entry
  /// can be exercised without a SoftAP. [incompleteRawPaths] lists transfers
  /// the transport saved without the done marker / all bytes, or with chunks
  /// it could not decrypt.
  @visibleForTesting
  Future<List<String>> completeWifiTransfer(
    List<String> rawPaths, {
    required bool decrypted,
    Set<String> incompleteRawPaths = const {},
    List<String>? conversionFailures,
  }) => _completeRetrievedRecordings(
    rawPaths,
    decrypted: decrypted,
    transferComplete: (raw) => !incompleteRawPaths.contains(raw),
    conversionFailures: conversionFailures,
  );

  /// Only called after a device transfer has produced a playable local file.
  /// Startup scans and renames deliberately do not schedule paid work.
  /// Partial transfers and WAVs that are unfinished or still growing are kept
  /// but not submitted; see [incompleteRetrievedAudioReason].
  Future<void> processRetrievedRecording(
    String path, {
    bool transferComplete = true,
  }) => _processRetrievedRecording(
    path,
    transferComplete: transferComplete,
    settle: retrievedAudioSettleTime,
  );

  Future<void> _processRetrievedRecording(
    String path, {
    required bool transferComplete,
    required Duration settle,
  }) async {
    await Future.wait([_settingsLoaded, _transcriptsLoaded, _fileJobsLoaded]);
    if (_disposed || !path.toLowerCase().endsWith('.wav')) return;
    final key = _recordingKey(path: path);
    if (topicsEnabled) {
      // Placement is independent of the auto-transcribe switch and of
      // completeness: the recording exists locally either way, and a later
      // re-retrieval keeps whatever placement it already has.
      await _topicsLoaded;
      if (_disposed) return;
      await topics.placeRetrieved(key);
      final existingText = (transcriptForPath(path) ?? '').trim();
      if (existingText.isNotEmpty) {
        unawaited(_scheduleTopicAssist(key, existingText));
      }
    }
    if (!autoTranscribe) return;
    if (_isRecordingAudioLocked(fileIdFromPath(path), path)) return;
    final config = _settingsConfiguration;
    if (!_isConfigured(config) &&
        !_fileJobs.jobs.containsKey(key) &&
        (transcriptForPath(path) ?? '').trim().isEmpty) {
      _recordingErrors[key] = '录音已保存，请先配置语音服务后重试转写';
      notifyListeners();
      return;
    }
    // Completeness comes before the version comparison: a truncated or
    // still-growing file must neither be submitted nor be mistaken for a
    // changed recording that invalidates existing text.
    void blockIncomplete(String reason) {
      _recordingErrors[key] = reason;
      _completenessErrors[key] = reason;
      notifyListeners();
    }

    if (!transferComplete) {
      await _flagIncompleteOverwrite(key, path, config, blockIncomplete);
      return;
    }
    try {
      final incomplete = await incompleteRetrievedAudioReason(
        path,
        settle: settle,
      );
      if (incomplete != null) {
        blockIncomplete(incomplete);
        return;
      }
      // A complete retrieval clears only a message the gate itself left.
      final stale = _completenessErrors.remove(key);
      if (stale != null && _recordingErrors[key] == stale) {
        _recordingErrors.remove(key);
        notifyListeners();
      }
      final version = await audioVersion(path);
      if (version == null) return;
      final previous = _fileJobs.jobs[key];
      if (previous != null) {
        if (previous.audioHash != null && previous.audioHash != version) {
          previous.audioChanged = true;
          previous.error = '音频内容已变化，已有文字和分析保留；请手动重新转写';
          _recordingErrors[key] = previous.error!;
          await _fileJobs.save();
          notifyListeners();
        } else if (previous.audioChanged &&
            previous.audioHash == version &&
            previous.error == _staleAfterPartialRetrieval) {
          // A complete pull restored exactly the audio the text came from;
          // only the mark left by the partial overwrite is withdrawn.
          previous.audioChanged = false;
          previous.error = null;
          await _fileJobs.save();
          notifyListeners();
        } else if (previous.audioHash == null) {
          // Legacy records lack a prior digest. Establish a baseline without
          // replaying a paid request or claiming historical content equality.
          previous.audioHash = version;
          await _fileJobs.save();
        }
        return;
      }
      if ((transcriptForPath(path) ?? '').trim().isNotEmpty) return;
    } catch (_) {
      _recordingErrors[key] = '无法确认完整音频版本，录音已保留，请重试';
      notifyListeners();
      return;
    }
    if (!_isConfigured(config)) {
      _recordingErrors[key] = '录音已保存，请先配置语音服务后重试转写';
      notifyListeners();
      return;
    }
    try {
      await _deferredJobs.enqueue(key, path, config);
    } catch (_) {
      _recordingErrors[key] = '录音已保存，但无法保存转写任务，请重试';
    }
    notifyListeners();
  }

  static const _staleAfterPartialRetrieval =
      '录音未完整取回，已有文字对应之前的音频，已标为过期；请重新取回后手动重新转写';

  /// A transfer without the done signal / every byte replaced the local file.
  /// It is never submitted. When this recording already has a task or text,
  /// the partial audio is compared with the recorded version first: anything
  /// but identical content marks the existing text stale (persisted with the
  /// journal) so it is not shown or analysed as the result of this audio. The
  /// old text and task id stay; nothing is resubmitted or billed.
  Future<void> _flagIncompleteOverwrite(
    String key,
    String path,
    SpeechConfiguration config,
    void Function(String reason) block,
  ) async {
    const partial = '录音未完整取回，已保留已收到的部分；请重新取回后再转写';
    const stale = _staleAfterPartialRetrieval;
    final previous = _fileJobs.jobs[key];
    final text = (transcriptForPath(path) ?? '').trim();
    if (previous == null && text.isEmpty) return block(partial);
    try {
      final version = await audioVersion(path);
      if (version == null) return block(partial);
      if (previous != null && previous.audioHash == version) {
        return block(partial);
      }
      // No baseline (legacy record or text without a task) cannot prove the
      // partial file equals the transcribed audio, so it is treated as stale.
      final job =
          previous ??
          (FileJob(key: key, path: path, config: FileJob.snapshot(config))
            ..stage = 'complete'
            ..text = text);
      _fileJobs.jobs[key] = job;
      job.audioChanged = true;
      job.error = stale;
      await _fileJobs.save();
      block(stale);
    } catch (_) {
      block('录音未完整取回，且无法核对已有文字对应的音频；请重新取回后再转写');
    }
  }

  /// Hands a finished take to the shared deferred-job mechanism, which serves
  /// every engine that transcribes only after the take stops (Qwen,
  /// Doubao); see [DeferredFileJobs].
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  Future<void> _enqueueDeferredRecording(
    _RecordingSession owner,
    String path,
  ) async {
    if (_disposed ||
        owner.active ||
        owner.finalizing ||
        owner.transcriptionComplete ||
        owner.paused ||
        !owner.ended ||
        _finalizingRecordings.contains(_recordingKey(path: path)) ||
        !owner.configuration.provider.defersTranscription ||
        !owner.configuration.enabled ||
        !_isConfigured(owner.configuration)) {
      return;
    }
    try {
      await _deferredJobs.enqueue(
        _recordingKey(path: path),
        path,
        owner.configuration,
      );
    } catch (_) {
      owner.error = '无法保存转写任务，请在录音详情中重试';
      notifyListeners();
    }
  }

  bool _autoTransferRunning = false;
  Completer<void>? _autoTransferDone;
  bool _autoTransferYieldRequested = false;
  int? _autoDownloadingFileId;
  bool get autoTransferActive => _autoTransferRunning;
  int? get activeBleDownloadFileId =>
      downloadingFileId ?? _autoDownloadingFileId;
  bool get canDownloadOverBle =>
      connected &&
      !_liveProcessing &&
      !realtimeState.active &&
      downloadingFileId == null &&
      !isWifiExportSession &&
      !isExporting &&
      phase != AppPhase.connecting &&
      (phase != AppPhase.busy || autoTransferActive);
  bool get blocksRecordingControl =>
      phase == AppPhase.busy && !_autoTransferRunning;

  /// Device file currently being downloaded on demand over BLE.
  int? downloadingFileId;

  /// Legacy expand id (device list no longer expands for playback).
  int? expandedFileId;

  ExportProgress exportProgress = ExportProgress();
  bool get isExporting =>
      exportProgress.phase != ExportPhase.idle &&
      exportProgress.phase != ExportPhase.done &&
      exportProgress.phase != ExportPhase.error &&
      exportProgress.phase != ExportPhase.awaitJoin;

  /// SoftAP open succeeded; waiting for user to join network.
  bool get needsWifiJoin => exportProgress.phase == ExportPhase.awaitJoin;

  /// Any active Wi‑Fi export session (opening SoftAP → transfer → closing).
  /// Used to avoid yanking the user back to Scan when BLE drops mid-export.
  bool get isWifiExportSession {
    final p = exportProgress.phase;
    return p == ExportPhase.openingSoftAp ||
        p == ExportPhase.awaitJoin ||
        p == ExportPhase.connectingWs ||
        p == ExportPhase.transferring ||
        p == ExportPhase.closing;
  }

  /// Check whether a local interface joined the device's SoftAP subnet.
  /// This intentionally does not touch the device's WebSocket port.
  Future<bool> isOnSoftApNetwork() async {
    final ep = exportProgress.endpoint;
    if (ep == null) return false;
    return WifiExportService.isOnSoftApNetwork(ep);
  }

  void toggleSelecting() {
    selecting = !selecting;
    if (!selecting) selectedFileIds.clear();
    notifyListeners();
  }

  void toggleFileSelected(int fileId) {
    if (_isRecordingAudioLocked(fileId, localPathFor(fileId))) return;
    if (selectedFileIds.contains(fileId)) {
      selectedFileIds.remove(fileId);
    } else {
      selectedFileIds.add(fileId);
    }
    notifyListeners();
  }

  void selectAllFiles() {
    selectedFileIds
      ..clear()
      ..addAll(
        files
            .where(
              (f) => !_isRecordingAudioLocked(f.fileId, localPathFor(f.fileId)),
            )
            .map((f) => f.fileId),
      );
    selecting = true;
    notifyListeners();
  }

  void clearSelection() {
    selectedFileIds.clear();
    notifyListeners();
  }

  /// Select a single file and enter selection mode (for one-tap export).
  void selectOnly(int fileId) {
    if (_isRecordingAudioLocked(fileId, localPathFor(fileId))) return;
    selecting = true;
    selectedFileIds
      ..clear()
      ..add(fileId);
    notifyListeners();
  }

  List<OfflineFileEntry> get selectedFiles =>
      files.where((f) => selectedFileIds.contains(f.fileId)).toList();

  List<OfflineFileEntry> get unexportedFiles =>
      files.where((f) => localPathFor(f.fileId) == null).toList();

  List<OfflineFileEntry> get selectedUnexportedFiles =>
      selectedFiles.where((f) => localPathFor(f.fileId) == null).toList();

  void _kickRealtimeFromFileList(OfflineFileList list) {
    if (!connected) return;
    if (isWifiExportSession) return;
    if (!recording && info?.recording != true) return;

    final curr = list.currentTransportTimestamp;
    int? fileId;
    if (curr != null && curr > 0) {
      fileId = curr;
    } else {
      // Inventory contains completed files, sometimes oldest first. Only an
      // explicit current timestamp / 1A06 or this session's known identity can
      // identify live audio. Guessing an entry briefly replays an old recording.
      fileId = _currentRecording?.fileId;
    }

    if (fileId == null || fileId <= 0) {
      if (recording || info?.recording == true) {
        statusMessage = '等待录音开始…';
        notifyListeners();
      }
      return;
    }

    if (realtimeState.active && realtimeState.fileId == fileId) return;

    unawaited(() async {
      try {
        await _startCurrentRecordingTransfer(fileId!);
        statusMessage = '正在接收录音…';
        notifyListeners();
      } catch (e) {
        errorMessage = '无法接收录音，请重新连接设备';
        notifyListeners();
      }
    }());
  }

  Future<void> _startCurrentRecordingTransfer(int fileId) async {
    _bindCurrentRecording(fileId: fileId);
    await _yieldAutoTransfer();
    if (!connected || !_ble.isConnected) return;
    if (!recording && info?.recording != true) return;
    await _realtime.startForFile(fileId);
  }

  Future<void> _yieldAutoTransfer() async {
    final done = _autoTransferDone;
    if (done == null) return;
    _autoTransferYieldRequested = true;
    _blePull.cancel();
    // Wait for the old sink and packet subscription to close before another
    // caller takes ownership of the shared BLE puller.
    await done.future;
  }

  var _fileListPage = 0;
  var _loadingFileListPages = false;
  final List<OfflineFileEntry> _fileListPages = [];
  Timer? _fileListPageTimeout;
  Completer<void>? _fileRefreshDone;
  Timer? _fileRefreshTimeout;

  Future<void> refreshLocalFiles() async {
    if (_liveProcessing ||
        isExporting ||
        needsWifiJoin ||
        _catalogConversionRunning) {
      return;
    }
    await _loadLocalExports();
  }

  /// Pull-to-refresh remains active until the device inventory has arrived.
  Future<void> refreshDeviceFiles() {
    final pending = _fileRefreshDone;
    if (pending != null) return pending.future;
    if (!connected ||
        isExporting ||
        needsWifiJoin ||
        downloadingFileId != null ||
        phase == AppPhase.busy ||
        phase == AppPhase.connecting) {
      return Future<void>.value();
    }
    final done = _fileRefreshDone = Completer<void>();
    _fileRefreshTimeout = Timer(const Duration(seconds: 20), () {
      _loadingFileListPages = false;
      _fileListPageTimeout?.cancel();
      errorMessage = '刷新超时，请下拉重试';
      _completeFileRefresh();
      notifyListeners();
    });
    unawaited(() async {
      try {
        if (!_loadingFileListPages) await listFiles();
        if (!identical(_fileRefreshDone, done)) return;
        if (!connected || errorMessage != null) {
          _loadingFileListPages = false;
          _completeFileRefresh();
        }
      } catch (_) {
        if (!identical(_fileRefreshDone, done)) return;
        errorMessage = '刷新失败，请下拉重试';
        _loadingFileListPages = false;
        _completeFileRefresh();
        notifyListeners();
      }
    }());
    return done.future;
  }

  void _completeFileRefresh() {
    _fileRefreshTimeout?.cancel();
    _fileRefreshTimeout = null;
    final done = _fileRefreshDone;
    _fileRefreshDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  Future<void> listFiles() {
    _fileListPageTimeout?.cancel();
    _fileListPage = 0;
    _fileListPages.clear();
    _loadingFileListPages = true;
    // The D3200 SDK's public getAllAudioRecordFiles() uses 1B/0E and fetches
    // subsequent pages whenever a response contains the full 10 entries.
    return _send(
      DeviceCommands.listFilesWithEndTime(page: _fileListPage),
      label: '正在获取录音列表…',
    );
  }

  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  void _handleFileListPage(OfflineFileList list) {
    _fileListPageTimeout?.cancel();
    if (!_loadingFileListPages) {
      files = _sortFilesNewestFirst(list.files);
      statusMessage = '${files.length} 条录音';
      _kickRealtimeFromFileList(list);
      _scheduleAutoTransferMissing();
      return;
    }

    final byId = <int, OfflineFileEntry>{
      for (final file in _fileListPages) file.fileId: file,
      for (final file in list.files) file.fileId: file,
    };
    _fileListPages
      ..clear()
      ..addAll(byId.values);
    files = _sortFilesNewestFirst(_fileListPages);

    if (list.fileCount == 10) {
      _fileListPage++;
      final requestedPage = _fileListPage;
      statusMessage = '正在获取录音列表…（${files.length} 条）';
      notifyListeners();
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 50), () async {
          if (!connected || !_loadingFileListPages) return;
          try {
            await _ble.writeCommand(
              DeviceCommands.listFilesWithEndTime(page: _fileListPage),
            );
            // The device may silently never answer this page (BLE hiccup,
            // busy firmware) — without a timeout _loadingFileListPages would
            // stay stuck true and this partial list would never finalize.
            _fileListPageTimeout = Timer(const Duration(seconds: 8), () {
              if (!_loadingFileListPages || _fileListPage != requestedPage) {
                return;
              }
              _loadingFileListPages = false;
              statusMessage =
                  '${files.length} 条录音（第 ${requestedPage + 1} 页无响应）';
              _completeFileRefresh();
              notifyListeners();
            });
          } catch (error) {
            _loadingFileListPages = false;
            errorMessage = '无法获取全部录音，请刷新重试';
            _completeFileRefresh();
            notifyListeners();
          }
        }),
      );
      return;
    }

    _loadingFileListPages = false;
    statusMessage = '${files.length} 条录音';
    _completeFileRefresh();
    _kickRealtimeFromFileList(list);
    _scheduleAutoTransferMissing();
  }

  /// Auto-refresh offline file inventory when the Files tab is shown.
  /// Skips if disconnected, mid-export, or already busy on the wire.
  Future<void> refreshFilesOnTabEnter() async {
    if (!connected) return;
    if (isExporting || needsWifiJoin) return;
    if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
    await listFiles();
  }

  void _scheduleAutoTransferMissing() {
    if (_disposed || !autoRealtime || _autoTransferRunning) return;
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 200),
        _autoTransferMissingFiles,
      ),
    );
  }

  /// Catch up completed recordings over BLE without interrupting the current
  /// recording/realtime stream. Device and local lists remain newest-first.
  Future<void> _autoTransferMissingFiles() async {
    if (_disposed || _autoTransferRunning || !autoRealtime) return;
    if (_loadingFileListPages || downloadingFileId != null) return;
    if (!connected || !_ble.isConnected || files.isEmpty) return;
    if (recording || info?.recording == true || realtimeState.active) return;
    if (isWifiExportSession || isExporting) return;
    if (phase == AppPhase.connecting || phase == AppPhase.busy) return;

    _autoTransferRunning = true;
    final done = _autoTransferDone = Completer<void>();
    _autoTransferYieldRequested = false;
    notifyListeners();
    var exported = 0;
    final failed = <int>[];
    try {
      await _loadLocalExports(notify: false);
      final completeIds = await _completeLocalExportIds(files);
      final missing = ExportCatalog.unexportedNewestFirst(files, completeIds);
      if (_shouldYieldAutoTransfer) return;
      if (missing.isEmpty) {
        statusMessage = '已导出录音已是最新';
        return;
      }

      if (!encryptReady) await establishEncryptSession();
      if (_shouldYieldAutoTransfer) return;
      phase = AppPhase.busy;

      for (final file in missing) {
        if (_shouldYieldAutoTransfer) break;
        _autoDownloadingFileId = file.fileId;
        String progressMessage([String progress = '']) {
          final deviceIds = files.map((file) => file.fileId).toSet();
          final completed = deviceIds.intersection(completeIds).length;
          return '自动传输 $completed/${deviceIds.length}$progress · ${file.title}';
        }

        var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
        try {
          statusMessage = progressMessage();
          notifyListeners();
          final rawPath = await _blePull.pullFile(
            file,
            timeout: blePullInactivityTimeout,
            onProgress: (received, expected) {
              if (_shouldYieldAutoTransfer) return;
              final now = DateTime.now();
              if (now.difference(lastProgressAt) <
                  const Duration(milliseconds: 250)) {
                return;
              }
              lastProgressAt = now;
              final progress = expected > 0
                  ? ' ${(received * 100 / expected).clamp(0, 100).floor()}%'
                  : '';
              statusMessage = progressMessage(progress);
              notifyListeners();
            },
          );
          await _completeRetrievedRecordings(
            [rawPath],
            decrypted: true,
            transferComplete: (raw) => !_blePull.isIncomplete(raw),
            listedSizes: {file.fileId: file.sizeBytes},
          );
          // A partial file is kept but not reported as transferred.
          if (!_incompleteRetrievalIds.contains(file.fileId)) {
            completeIds.add(file.fileId);
            exported++;
          }
          if (!_shouldYieldAutoTransfer) statusMessage = progressMessage();
          notifyListeners();
        } on BleFilePullCancelled {
          break;
        } catch (error) {
          failed.add(file.fileId);
          logs = [
            'AUTO EXPORT ${file.fileId} failed: $error',
            ...logs,
          ].take(80).toList();
          if (!connected || !_ble.isConnected) break;
        }
      }

      if (failed.isNotEmpty) {
        errorMessage = '有 ${failed.length} 条录音自动传输失败，刷新后将重试';
      }
      if (!_autoTransferYieldRequested) {
        statusMessage = exported > 0
            ? '已自动传输 $exported 条录音'
            : failed.isEmpty
            ? statusMessage
            : '自动传输未完成';
      }
    } finally {
      _autoDownloadingFileId = null;
      _autoTransferRunning = false;
      _autoTransferDone = null;
      if (downloadingFileId == null) {
        phase = connected ? AppPhase.ready : AppPhase.idle;
      }
      done.complete();
      notifyListeners();
    }
  }

  bool get _shouldYieldAutoTransfer =>
      _disposed ||
      _autoTransferYieldRequested ||
      !autoRealtime ||
      !connected ||
      !_ble.isConnected ||
      downloadingFileId != null ||
      recording ||
      info?.recording == true ||
      realtimeState.active;

  /// On-demand single-file download over BLE — no Wi‑Fi SoftAP setup needed.
  /// Wi‑Fi export is only worth the join dance for multiple files at once.
  Future<void> downloadFileOverBle(OfflineFileEntry file) async {
    if (_liveProcessing ||
        _isRecordingAudioLocked(file.fileId, localPathFor(file.fileId))) {
      errorMessage = '录音保存后再下载';
      notifyListeners();
      return;
    }
    if (!connected || !_ble.isConnected) {
      errorMessage = '请先通过 BLE 连接';
      notifyListeners();
      return;
    }
    if (!canDownloadOverBle) {
      errorMessage = '当前传输结束后再下载';
      notifyListeners();
      return;
    }

    downloadingFileId = file.fileId;
    phase = AppPhase.busy;
    errorMessage = null;
    statusMessage = '正在下载 ${file.title}…';
    notifyListeners();
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await _yieldAutoTransfer();
      // The auto transfer may have finished this file while yielding.
      if ((await _completeLocalExportIds([file])).contains(file.fileId)) {
        statusMessage = '已下载 ${file.title}';
        return;
      }
      if (!encryptReady) await establishEncryptSession();
      if (!connected || !_ble.isConnected || _liveProcessing) return;

      phase = AppPhase.busy;
      notifyListeners();
      final rawPath = await _blePull.pullFile(
        file,
        timeout: blePullInactivityTimeout,
        onProgress: (received, expected) {
          final now = DateTime.now();
          if (now.difference(lastProgressAt) <
              const Duration(milliseconds: 250)) {
            return;
          }
          lastProgressAt = now;
          final progress = expected > 0
              ? ' ${(received * 100 / expected).clamp(0, 100).floor()}%'
              : '';
          statusMessage = '正在下载$progress · ${file.title}';
          notifyListeners();
        },
      );
      await _completeRetrievedRecordings(
        [rawPath],
        decrypted: true,
        transferComplete: (raw) => !_blePull.isIncomplete(raw),
        listedSizes: {file.fileId: file.sizeBytes},
      );
      statusMessage = '已下载 ${file.title}';
    } on BleFilePullCancelled {
      statusMessage = '已取消下载';
    } catch (e) {
      errorMessage = '下载失败，请重新连接设备后重试';
      statusMessage = '下载失败';
    } finally {
      downloadingFileId = null;
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
      _scheduleAutoTransferMissing();
    }
  }

  Future<void> deleteFile(int fileId) async {
    if (_isRecordingAudioLocked(fileId, localPathFor(fileId))) {
      errorMessage = '录音保存后再删除';
      notifyListeners();
      return;
    }
    await _send(DeviceCommands.deleteFile(fileId), label: '正在删除文件…');
  }

  Future<int> deleteSelectedDeviceFiles() async {
    if (!_ble.isConnected || selectedFileIds.isEmpty) return 0;
    final ids = selectedFileIds
        .where((id) => !_isRecordingAudioLocked(id, localPathFor(id)))
        .toList();
    if (ids.isEmpty) return 0;
    phase = AppPhase.busy;
    errorMessage = null;
    var deleted = 0;
    notifyListeners();
    try {
      for (var i = 0; i < ids.length; i++) {
        statusMessage = '正在删除 ${i + 1}/${ids.length}…';
        notifyListeners();
        await _ble.writeCommand(DeviceCommands.deleteFile(ids[i]));
        deleted++;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      files.removeWhere((file) => ids.contains(file.fileId));
      selectedFileIds.clear();
      selecting = false;
      statusMessage = '已删除 $deleted 个设备端录音';
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _ble.writeCommand(DeviceCommands.listFiles());
    } catch (error) {
      errorMessage = '部分录音未删除，请刷新后重试';
    } finally {
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
    return deleted;
  }

  // ── Wi‑Fi batch export ────────────────────────────────────────────────

  /// Snapshot of files to transfer, taken while still BLE-connected. Joining
  /// the device's SoftAP for the actual transfer causes a natural BLE drop,
  /// which wipes `files`/`selectedFileIds` — continueWifiExport() must not
  /// re-derive its target list from those afterwards or it sees nothing.
  List<OfflineFileEntry> _pendingExportTargets = [];
  int _wifiExportRun = 0;

  /// Open device SoftAP and wait for IP:port. UI should then prompt join.
  Future<WifiEndpoint?> beginWifiExport() async {
    if (_liveProcessing) {
      errorMessage = '录音保存后再导出';
      notifyListeners();
      return null;
    }
    _wifiExportRun++;
    if (!_ble.isConnected) {
      errorMessage = '请先通过 BLE 连接';
      notifyListeners();
      return null;
    }
    final targets =
        (selectedFileIds.isNotEmpty ? selectedUnexportedFiles : unexportedFiles)
            .where(
              (file) => !_isRecordingAudioLocked(
                file.fileId,
                localPathFor(file.fileId),
              ),
            )
            .toList();
    if (targets.isEmpty) {
      errorMessage = selectedFileIds.isNotEmpty ? '所选录音均已导出' : '所有录音均已导出';
      notifyListeners();
      return null;
    }
    _pendingExportTargets = List.of(targets);

    errorMessage = null;
    phase = AppPhase.busy;
    statusMessage = '正在准备下载…';
    notifyListeners();

    // Ensure ECDH session before SoftAP so file keys can be unwrapped.
    if (!encryptReady) {
      final ok = await establishEncryptSession();
      if (!ok) {
        statusMessage = '录音暂时无法解密，请重新连接设备后重试';
        notifyListeners();
      }
    }

    statusMessage = '正在开启设备 Wi‑Fi…';
    notifyListeners();

    try {
      final ep = await _wifi.openSoftAp(
        onConfigured: () async {
          // Match Soundcore SDK handleConfigSuccess(): preserve the encryption
          // session, disconnect BLE, then let the recorder finish SoftAP startup.
          _stopBatteryPoll();
          await _ble.disconnect();
        },
      );
      statusMessage = '请连接 Wi‑Fi「${ep.ssid}」，然后点「继续导出」';
      // Stay "busy" while awaiting join so other ops don't collide.
      notifyListeners();
      return ep;
    } catch (e) {
      errorMessage = e.toString();
      phase = connected ? AppPhase.ready : AppPhase.idle;
      statusMessage = null;
      notifyListeners();
      return null;
    }
  }

  /// After user joined SoftAP, run WebSocket transfer for selection (or all).
  Future<List<String>> continueWifiExport() async {
    final run = _wifiExportRun;
    final ep = exportProgress.endpoint;
    if (ep == null) {
      const msg = '设备 Wi‑Fi 未就绪，请重新开始导出';
      errorMessage = msg;
      // The join sheet only reads exportProgress.error, not errorMessage —
      // without this it silently resets with no visible feedback.
      exportProgress = exportProgress.copyWith(
        phase: ExportPhase.error,
        error: msg,
      );
      notifyListeners();
      return const [];
    }
    final targets = _pendingExportTargets;
    if (targets.isEmpty) {
      const msg = '未选择文件';
      errorMessage = msg;
      exportProgress = exportProgress.copyWith(
        phase: ExportPhase.error,
        error: msg,
      );
      notifyListeners();
      return const [];
    }

    phase = AppPhase.busy;
    statusMessage = encryptReady ? '正在通过 Wi‑Fi 传输并解密…' : '正在通过 Wi‑Fi 传输（原始密文）…';
    notifyListeners();

    try {
      final rawPaths = await _wifi.transferFiles(endpoint: ep, files: targets);
      if (run != _wifiExportRun) return const [];
      final conversionFailures = <String>[];
      final paths = await completeWifiTransfer(
        rawPaths,
        decrypted: encryptReady,
        incompleteRawPaths: _wifi.incompletePaths,
        conversionFailures: conversionFailures,
      );
      _pendingExportTargets = [];
      phase = connected ? AppPhase.ready : AppPhase.idle;
      statusMessage = paths.isEmpty
          ? '导出完成但无数据'
          : '已导出 ${paths.length} 个文件'
                '${encryptReady ? "（已解密）" : "（原始密文 — 无会话）"}';
      // WAV conversion runs per file after the transfer; surface failures
      // instead of silently leaving the raw .opus frame stream behind.
      errorMessage = conversionFailures.isEmpty
          ? null
          : 'WAV 转码失败，已保留原始 Opus 帧：${conversionFailures.join("; ")}';
      selecting = false;
      selectedFileIds.clear();
      notifyListeners();
      _reconnectBleAfterWifiExport();
      return paths;
    } catch (e) {
      if (run != _wifiExportRun) return const [];
      errorMessage = e.toString();
      phase = connected ? AppPhase.ready : AppPhase.idle;
      statusMessage = '导出失败';
      notifyListeners();
      _reconnectBleAfterWifiExport();
      return const [];
    }
  }

  Future<void> cancelWifiExport() async {
    _wifiExportRun++;
    await _wifi.cancel();
    _pendingExportTargets = [];
    phase = connected ? AppPhase.ready : AppPhase.idle;
    statusMessage = '已取消导出';
    notifyListeners();
    _reconnectBleAfterWifiExport();
  }

  void _reconnectBleAfterWifiExport() {
    if (!connected && bound && !_explicitDisconnect && !_ble.isConnecting) {
      unawaited(startScan());
    }
  }

  Future<void> copyWifiCredentials() async {
    final s = exportProgress.ssid;
    final pw = exportProgress.password;
    if (s == null || pw == null) return;
    await Clipboard.setData(ClipboardData(text: 'SSID：$s\n密码：$pw'));
    statusMessage = '凭证已复制';
    notifyListeners();
  }

  void clearExportState() {
    exportProgress = ExportProgress();
    notifyListeners();
  }

  /// Newest first. Prefer [OfflineFileEntry.endTime], else [fileId] (unix ts).
  List<OfflineFileEntry> _sortFilesNewestFirst(List<OfflineFileEntry> list) {
    final copy = List<OfflineFileEntry>.from(list);
    copy.sort((a, b) {
      final ta = a.endTime ?? a.fileId;
      final tb = b.endTime ?? b.fileId;
      return tb.compareTo(ta);
    });
    return copy;
  }
}
