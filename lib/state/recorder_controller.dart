import '../platform/credential_store.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/qwen_stt.dart';
import '../ai/cloud_stt_stream.dart';
import '../ai/doubao_stt.dart';
import '../ai/cloud_stt_service.dart';
import '../ai/engine_config.dart';
import '../ai/speech_languages.dart';
import '../ai/stt_types.dart';
import '../ai/apple_speech.dart';
import '../ai/speech_provider.dart';
import '../audio/audio_duration.dart';
import '../audio/audio_version.dart';
import '../audio/retrieved_audio.dart';
import '../audio/ogg_opus.dart';
import '../audio/opus_pcm_decoder.dart';
import '../audio/opus_wave.dart';
import '../archive/mac_archive_controller.dart';
import '../archive/archive_store.dart';
import '../archive/archive_wire.dart';
import '../ble/ble_service.dart';
import '../ble/ble_file_pull.dart';
import '../ble/realtime_stream.dart';
import '../crypto/device_crypto.dart';
import '../platform/background_sync_service.dart';
import '../platform/place_capture.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';
import '../wifi/wifi_export_service.dart';
import 'app_settings_store.dart';
import 'device_store.dart';
import 'export_catalog.dart';
import 'transcript_store.dart';
import 'recording.dart';
import 'recording_analysis.dart';
import 'recording_library.dart';
import 'listening_queue.dart';
import 'minutes_document.dart';
import 'playback_history.dart';
import 'recording_bookmarks.dart';
import 'speech_configuration.dart';
import 'deferred_file_jobs.dart';
import 'file_job_journal.dart';
import 'topic_store.dart';
import 'topic_note.dart';
import 'topic_summary.dart';

export 'recording.dart';
export 'recording_library.dart';
export 'listening_queue.dart';
export 'playback_history.dart';
export 'topic_store.dart';
export 'topic_note.dart';
export 'topic_summary.dart';
export '../archive/mac_archive_controller.dart';
export '../archive/archive_store.dart';
export '../archive/archive_pairing.dart';
export '../archive/archive_wire.dart';
export '../ai/speech_provider.dart';

part 'recorder/playback.dart';
part 'recorder/library.dart';
part 'recorder/place.dart';
part 'recorder/archive.dart';
part 'recorder/topics.dart';
part 'recorder/transcription_jobs.dart';
part 'recorder/transcripts.dart';
part 'recorder/live_transcription.dart';

enum AppPhase { idle, scanning, connecting, ready, busy }

/// The user-visible intent behind a summary invocation.
enum TopicSummaryRetry {
  /// First run or a safe continuation; never discards an unconfirmed request.
  auto,

  /// User confirmed retry after an uncertain or invalid paid result.
  confirmedRetry,

  /// User confirmed replacement of an existing result with a fresh run.
  overwrite,
}

/// Latest transcript waiting on an in-flight topic-assist run.
class _TopicAssistLatest {
  _TopicAssistLatest(this.transcript);
  String transcript;
  bool dirty = false;
}

typedef TranscriptPersister = Future<void> Function({bool strict});

class RecorderController extends ChangeNotifier
    with
        _RecorderPlayback,
        _RecorderLibrary,
        _RecorderPlace,
        _RecorderArchive,
        _RecorderTopics,
        _RecorderTranscriptionJobs,
        _RecorderTranscripts,
        _RecorderLiveTranscription {
  @override
  late final RecordingAnalysis analysis =
      _analysisOverride ??
      RecordingAnalysis(
        service: QwenAnalysisService(origin: () => _qwenStt.baseUrl),
      );
  final RecordingAnalysis? _analysisOverride;
  @override
  final Map<String, String> _audioVersions = {};
  @override
  final AnalysisService? _topicRecommendationOverride;
  String analysisKey(RecordingReference ref) => _referenceKey(ref);
  String recordingKeyFor(RecordingReference ref) => _referenceKey(ref);
  @override
  bool recordingAudioChanged(RecordingReference ref) =>
      _fileJobs.jobs[_referenceKey(ref)]?.audioChanged == true;

  @override
  String? _audioPathFor(RecordingReference ref) {
    final path = recordingView(ref).path ?? ref.path;
    if (path == null || path.isEmpty) return null;
    return path;
  }

  @override
  RecordingReference _referenceFromKey(String key, {String? pathHint}) {
    final resolvedPath = pathHint ?? _transcriptPathsByKey[key];
    if (key.startsWith('file:')) {
      final id = int.tryParse(key.substring(5));
      if (id != null) {
        return RecordingReference(
          fileId: id,
          path: resolvedPath ?? localPathsByFileId[id],
        );
      }
    }
    if (key.startsWith('path:')) {
      return RecordingReference(path: resolvedPath ?? key.substring(5));
    }
    return RecordingReference(path: resolvedPath);
  }

  @override
  String get analysisApiKey => _qwenStt.apiKey ?? '';

  static const _bleScanTimeout = Duration(seconds: 30);
  static const _boundReconnectDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  RecorderController({
    BleService? ble,
    bool loadPersistedState = true,
    PersistedDeviceLoader? persistedDeviceLoader,
    AppleSpeechService? appleSpeech,
    QwenSttService? qwenSpeech,
    DoubaoSttService? doubaoSpeech,
    FileJobJournal? fileJobJournal,
    RecordingAnalysis? analysisController,
    AnalysisService? topicRecommendationService,
    TopicStore? topicStore,
    bool? topicsEnabled,
    this.recordingShortcutScanTimeout = const Duration(seconds: 30),
    this.retrievedAudioSettleTime = retrievedAudioSettle,
    Future<String> Function(String rawPath)? rawExportConverter,
    Future<Duration?> Function(String path)? localDurationReader,
    Future<Duration?> Function(String path)? audioDurationProbe,
    this.blePullInactivityTimeout = const Duration(seconds: 90),
    RecordingLibraryStore? libraryStore,
    Directory? libraryDirectory,
    PlaceCapture? placeCapture,
    MinutesDocumentStore? minutesStore,
    TranscriptPersister? transcriptPersister,
    PlaybackHistoryStore? playbackHistoryStore,
    ListeningQueueStore? listeningQueueStore,
    RecordingBookmarkStore? bookmarkStore,
    AudioPlayer? player,
    MacArchiveController? archiveController,
    ArchivePhoneStore? archivePhoneStore,
    ArchiveDeskStore? archiveDeskStore,
  }) : _analysisOverride = analysisController,
       _topicRecommendationOverride = topicRecommendationService,
       topicsEnabled =
           topicsEnabled ?? defaultTargetPlatform == TargetPlatform.iOS,
       _rawExportConverter = rawExportConverter ?? OpusWave.convertRawFile,
       _localDurationReader = localDurationReader ?? AudioDuration.read,
       _audioDurationProbe = audioDurationProbe ?? _probeAudioDuration,
       _ble = ble ?? BleService(),
       _appleSpeech = appleSpeech ?? AppleSpeechService(),
       _qwenStt = qwenSpeech ?? QwenSttService(),
       _doubaoStt = doubaoSpeech ?? DoubaoSttService(),
       _persistedDeviceLoader = persistedDeviceLoader ?? DeviceStore.load,
       _libraryDirectoryOverride = libraryDirectory,
       _placeCapture = placeCapture ?? const DevicePlaceCapture(),
       // Keep the injection seam public while the field stays private.
       // ignore: prefer_initializing_formals
       _transcriptPersister = transcriptPersister,
       _player = player ?? AudioPlayer() {
    library =
        libraryStore ?? RecordingLibraryStore(inMemory: !loadPersistedState);
    playbackHistory =
        playbackHistoryStore ??
        PlaybackHistoryStore(inMemory: !loadPersistedState);
    _playbackHistoryLoaded = playbackHistory.load().then((_) {
      if (_disposed) return;
      playbackSpeed = playbackHistory.speed;
      notifyListeners();
    });
    bookmarks =
        bookmarkStore ?? RecordingBookmarkStore(inMemory: !loadPersistedState);
    _bookmarksLoaded = bookmarks.load().then((_) {
      if (!_disposed) notifyListeners();
    });
    listeningQueue =
        listeningQueueStore ??
        ListeningQueueStore(inMemory: !loadPersistedState);
    _listeningQueueLoaded = listeningQueue.load().then((_) {
      if (!_disposed) notifyListeners();
    });
    _libraryLoaded = _loadRecordingLibrary();
    minutes =
        minutesStore ?? MinutesDocumentStore(inMemory: !loadPersistedState);
    _minutesLoaded = _loadMinutesDocuments();
    _subs.add(
      _ble.scanResults.listen((list) {
        devices = list;
        // If we have no saved unit yet, promote a bound D3200 from ads.
        if (lastKnownDevice == null) {
          for (final d in list) {
            if (d.isD3200 || d.looksLikeSoundcore) {
              if (d.isBoundAdvertised || bound) {
                lastKnownDevice = d;
                if (d.isBoundAdvertised) bound = true;
                activeDevice ??= d;
                unawaited(_persistDevice());
                break;
              }
            }
          }
        } else {
          // Refresh MAC/name from ads for the saved id.
          for (final d in list) {
            final saved = lastKnownDevice!;
            if (d.id == saved.id ||
                (d.macAddress != null && d.macAddress == saved.macAddress)) {
              lastKnownDevice = d;
              if (d.isBoundAdvertised) bound = true;
              if (!connected) activeDevice = d;
              break;
            }
          }
        }
        // Bound devices reconnect independently of the scan sheet. Previously
        // auto-connect only lived in that sheet, so a persisted bound device
        // stayed offline until the user opened it manually.
        unawaited(_tryAutoConnectBoundDevice(list));
        notifyListeners();
      }),
    );
    _subs.add(
      _ble.connectionState.listen((up) {
        connected = up;
        if (!up) {
          final wifiHandoff = isWifiExportSession;
          // Ignore transient "not ready" while a connect attempt is still running.
          // Emitting false mid-GATT used to force phase=idle and re-enable multi-tap.
          if (phase == AppPhase.connecting || _ble.isConnecting) {
            notifyListeners();
            return;
          }
          phase = wifiHandoff ? AppPhase.busy : AppPhase.idle;
          // Keep lastKnown* + bound + activeDevice for Device-tab offline UI.
          if (info != null) lastKnownInfo = info;
          if (activeDevice != null) lastKnownDevice = activeDevice;
          info = null;
          files = [];
          selectedFileIds.clear();
          selecting = false;
          recording = false;
          _snapshotLiveText();
          _currentRecording?.active = false;
          _recordWireStatus = 0;
          if (!wifiHandoff) {
            encryptReady = false;
            _crypto.resetSession();
            _encryptCompleter = null;
          }
          _stopBatteryPoll();
          _fileListPageTimeout?.cancel();
          _loadingFileListPages = false;
          _completeFileRefresh();
          unawaited(_realtime.stop());
          realtimeState = const RealtimeStreamState();
          unawaited(_finishStreamStt());
          unawaited(stopPlayback());
          // Reconnect unexpected drops immediately, except for the expected
          // BLE→Wi-Fi handoff; that reconnect starts after transfer cleanup.
          if (bound && !_explicitDisconnect && !wifiHandoff) {
            _resetBoundReconnectBackoff();
            unawaited(startScan());
          }
        } else {
          _resetBoundReconnectBackoff();
          // Connected (or reconnected) — keep battery fresh while linked.
          // Also drop any stale "未连接"-type error a command fired mid-drop
          // (e.g. a battery poll racing the Wi‑Fi SoftAP handoff) — it no
          // longer reflects reality and would otherwise stick around
          // forever next to a now-online status pill.
          errorMessage = null;
          _startBatteryPoll();
        }
        notifyListeners();
      }),
    );
    _subs.add(_ble.packets.listen(_onPacket));
    _subs.add(
      _ble.logs.listen((m) {
        logs = [m, ...logs].take(80).toList();
        notifyListeners();
      }),
    );

    _wifi = WifiExportService(
      blePackets: _ble.packets,
      bleWrite: _ble.writeCommand,
      crypto: _crypto,
    );
    _realtime = RealtimeBleStream(
      packets: _ble.packets,
      write: _ble.writeCommand,
      crypto: _crypto,
      onDecryptedFrame: _onRealtimeOpusFrame,
    );
    _blePull = BleFilePull(
      packets: _ble.packets,
      write: _ble.writeCommand,
      crypto: _crypto,
    );
    _subs.add(
      _wifi.progress.listen((p) {
        exportProgress = p;
        notifyListeners();
      }),
    );
    _subs.add(_realtime.stateStream.listen(_onRealtimeState));
    _wirePlayer();
    _fileJobs = fileJobJournal ?? FileJobJournal(inMemory: !loadPersistedState);
    _deferredJobs = DeferredFileJobs<SpeechConfiguration>(
      canStart: () =>
          !_disposed &&
          _fileJobKey == null &&
          !_fileJobPreparing &&
          !_liveProcessing,
      engine: (config) => config.provider,
      accept: (recordingKey, path, config) async {
        final version = await audioVersion(path);
        final job = await _fileJobs.enqueue(recordingKey, path, config);
        if (job.audioHash == null && version != null) {
          job.audioHash = version;
          await _fileJobs.save();
        }
        return !job.recoverable;
      },
      run: _runFileTranscription,
    );
    _settingsReady = !loadPersistedState;
    _settingsLoaded = loadPersistedState
        ? _loadPersistedSettings().whenComplete(() => _settingsReady = true)
        : Future<void>.value();
    if (loadPersistedState) {
      unawaited(_settingsLoaded);
      unawaited(_loadLocalExports());
      _transcriptsLoaded = _loadPersistedTranscripts();
    }
    _fileJobsLoaded = _restoreFileJobs();
    // Topics are iPhone-only in the first version (#50); elsewhere the store
    // stays empty in memory and nothing is placed.
    _ownsTopics = topicStore == null;
    topics =
        topicStore ??
        TopicStore(inMemory: !loadPersistedState || !this.topicsEnabled);
    _topicsLoaded = this.topicsEnabled ? topics.load() : Future<void>.value();
    if (this.topicsEnabled) {
      topics.addListener(_onTopicsChanged);
      if (topics.loaded) {
        _observedPlacements = Map<String, TopicPlacement>.from(
          topics.placements,
        );
        _topicsObserved = true;
      } else {
        unawaited(
          _topicsLoaded.then((_) {
            if (_disposed) return;
            _observedPlacements = Map<String, TopicPlacement>.from(
              topics.placements,
            );
            _topicsObserved = true;
          }),
        );
      }
    }
    _ownsArchive = archiveController == null;
    archive =
        archiveController ??
        MacArchiveController(
          source: _RecorderArchiveSource(this),
          isDesk: !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS,
          phoneStore: archivePhoneStore,
          deskStore: archiveDeskStore,
          inMemory: !loadPersistedState,
        );
    archive.addListener(_onArchiveChanged);
    unawaited(archive.initialize());
    unawaited(_purgeTrashWhenReady());
    if (this.topicsEnabled && loadPersistedState) {
      _lifecycle = AppLifecycleListener(onResume: topics.checkDay);
    }
    if (loadPersistedState || persistedDeviceLoader != null) {
      _persistedDeviceLoaded = _loadPersistedDevice();
      unawaited(_persistedDeviceLoaded);
    } else {
      _persistedDeviceLoaded = Future<void>.value();
    }
  }

  /// Whether topic notes (#49) are active. First version: iPhone only.
  @override
  final bool topicsEnabled;
  @override
  final Directory? _libraryDirectoryOverride;
  @override
  final PlaceCapture _placeCapture;

  /// How long a retrieved WAV must keep the same size and modification time
  /// before it can be submitted; see [incompleteRetrievedAudioReason].
  final Duration retrievedAudioSettleTime;
  @override
  final Future<String> Function(String rawPath) _rawExportConverter;
  @override
  final Future<Duration?> Function(String path) _localDurationReader;
  @override
  final Future<Duration?> Function(String path) _audioDurationProbe;

  static Future<Duration?> _probeAudioDuration(String path) async {
    final player = AudioPlayer();
    try {
      final reported = await player
          .setFilePath(path)
          .timeout(const Duration(seconds: 15));
      return reported ?? player.duration;
    } catch (_) {
      return null;
    } finally {
      await player.dispose();
    }
  }

  /// Longest gap without a BLE file packet before a pull stops waiting; see
  /// [BleFilePull.pullFile].
  final Duration blePullInactivityTimeout;

  /// Device file ids whose latest transfer was kept without the done signal /
  /// every byte. They do not count as exported, so a manual or automatic
  /// retrieval pulls them again instead of reusing the partial file. Kept in
  /// the file-job journal directory so this survives a restart.
  @override
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
          await _fileJobs.markRetrieval(fileId, complete: complete);
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
  @override
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

  String? settingsStorageError;
  Future<void> _settingsWriting = SynchronousFuture<void>(null);

  Future<void> reloadSettings() async {
    try {
      await CredentialStore().authorize();
    } catch (_) {
      settingsStorageError = const CredentialStorageException().message;
      notifyListeners();
      return;
    }
    await _loadPersistedSettings();
  }

  Future<void> _loadPersistedSettings() async {
    final s = await AppSettingsStore.load();
    settingsStorageError = s.storageError;
    for (final entry in _engineAdapters.entries) {
      entry.value.applySaved(entry.value.load(s));
    }
    autoTranscribe = s.autoTranscribe;
    autoRealtime = s.autoRealtime;
    transcriptLanguage = s.transcriptLanguage;
    appleSourceLanguage = s.appleSourceLanguage;
    translationTargetLanguage = s.translationTargetLanguage;
    ownerLanguage = isSpeechLanguage(s.ownerLanguage)
        ? s.ownerLanguage.toLowerCase()
        : 'zh';
    guestLanguage = isSpeechLanguage(s.guestLanguage)
        ? s.guestLanguage.toLowerCase()
        : 'en';
    if (ownerLanguage == guestLanguage) {
      ownerLanguage = 'zh';
      guestLanguage = 'en';
    }
    sttMode = autoTranscribe ? s.sttMode : SttDisplayMode.transcription;
    await refreshAppleCapabilities();
    if (_disposed) return;
    speechProvider = initialSpeechProvider(
      saved: s.speechProvider,
      appleSupported: appleCapabilities.supported,
      qwenConfigured: _engineAdapters[SttProvider.qwen]!.isReady(),
    );
    if (speechProvider.defersTranscription ||
        (speechProvider == SttProvider.apple &&
            sttMode == SttDisplayMode.conversation)) {
      sttMode = SttDisplayMode.transcription;
    }
    if (s.speechProvider == null && s.storageError == null) {
      unawaited(_persistSettings());
    }
    notifyListeners();
  }

  @visibleForTesting
  Future<void> get settingsSaved => _settingsWriting;

  Future<void> _persistSettings({
    bool strict = false,
    SttProvider? provider,
    EngineConfig? config,
  }) {
    final operation = _settingsWriting.then((_) async {
      try {
        await AppSettingsStore.save(
          AppSettings(
            speechProvider: speechProvider,
            appleSourceLanguage: appleSourceLanguage,
            engines: {
              ..._persistedEngines(),
              if (provider != null) provider.name: config!,
            },
            autoTranscribe: autoTranscribe,
            autoRealtime: autoRealtime,
            transcriptLanguage: transcriptLanguage,
            sttMode: sttMode,
            translationTargetLanguage: translationTargetLanguage,
            ownerLanguage: ownerLanguage,
            guestLanguage: guestLanguage,
          ),
          strict: true,
        );
        if (provider != null) _engineAdapters[provider]!.applySaved(config!);
        settingsStorageError = null;
        if (!_disposed) notifyListeners();
      } catch (_) {
        settingsStorageError = '无法保存配置，请解锁设备并重试读取安全配置';
        if (!_disposed) notifyListeners();
        if (strict) rethrow;
      }
    });
    _settingsWriting = operation.catchError((Object _) {});
    return operation;
  }

  Map<String, EngineConfig> _persistedEngines() => {
    for (final entry in _engineAdapters.entries)
      if (entry.value.grouped) entry.key.name: entry.value.readSaved(),
  };

  bool get appleSpeechReady =>
      appleSourceLanguage.isNotEmpty &&
      appleCapabilities.supported &&
      appleCapabilities.speechStatus == SpeechResourceStatus.ready &&
      !appleCapabilitiesLoading;

  @override
  bool get appleTranslationAvailable =>
      appleSourceLanguage.isNotEmpty &&
      appleCapabilities.supported &&
      appleCapabilities.translationStatus == SpeechResourceStatus.ready &&
      !appleCapabilitiesLoading;

  bool get conversationModeAvailable => false;

  Future<void> refreshAppleCapabilities() async {
    final revision = ++_capabilityRevision;
    appleCapabilitiesLoading = true;
    appleSetupError = null;
    notifyListeners();
    try {
      var result = await _appleSpeech.capabilities(
        sourceLanguage: appleSourceLanguage.isEmpty
            ? null
            : appleSourceLanguage,
        targetLanguage: translationTargetLanguage,
      );
      if (_disposed || revision != _capabilityRevision) return;
      if (appleSourceLanguage.isEmpty &&
          result.suggestedSourceLanguage != null) {
        appleSourceLanguage = result.suggestedSourceLanguage!;
        result = await _appleSpeech.capabilities(
          sourceLanguage: appleSourceLanguage,
          targetLanguage: translationTargetLanguage,
        );
        if (_disposed || revision != _capabilityRevision) return;
      }
      appleCapabilities = result;
    } catch (error) {
      if (_disposed || revision != _capabilityRevision) return;
      appleCapabilities = const AppleSpeechCapabilities.unsupported();
      appleSetupError = _speechErrorMessage(error);
    } finally {
      if (!_disposed && revision == _capabilityRevision) {
        appleCapabilitiesLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> prepareAppleLanguages() async {
    if (appleLanguagePreparationBusy) return;
    if (appleSourceLanguage.isEmpty) {
      appleSetupError = '请选择录音语言';
      notifyListeners();
      return;
    }
    appleLanguagePreparationBusy = true;
    appleSetupError = null;
    notifyListeners();
    try {
      await _appleSpeech.prepareLanguages(
        sourceLanguage: appleSourceLanguage,
        targetLanguage: translationTargetLanguage,
      );
      if (_disposed) return;
      await refreshAppleCapabilities();
      await _persistSettings();
    } catch (error) {
      if (!_disposed) {
        // Speech may have installed even if the optional translation pair failed.
        await refreshAppleCapabilities();
        appleSetupError = _speechErrorMessage(error);
      }
    } finally {
      if (!_disposed) {
        appleLanguagePreparationBusy = false;
        notifyListeners();
      }
    }
  }

  void setSpeechProvider(SttProvider provider) {
    if (provider.retired || provider == speechProvider) return;
    speechProvider = provider;
    if (provider.defersTranscription ||
        (provider == SttProvider.apple &&
            sttMode == SttDisplayMode.conversation)) {
      sttMode = SttDisplayMode.transcription;
    }
    notifyListeners();
    unawaited(_persistSettings());
    if (provider == SttProvider.apple) unawaited(refreshAppleCapabilities());
  }

  void setAppleSourceLanguage(String language) {
    final code = language.trim();
    if (appleSourceLanguage == code) return;
    appleSourceLanguage = code;
    unawaited(refreshAppleCapabilities());
    unawaited(_persistSettings());
  }

  @override
  SpeechConfiguration get _settingsConfiguration => SpeechConfiguration(
    provider: speechProvider,
    sourceLanguage: speechProvider == SttProvider.apple
        ? appleSourceLanguage
        : transcriptLanguage,
    targetLanguage: translationTargetLanguage,
    ownerLanguage: ownerLanguage,
    guestLanguage: guestLanguage,
    mode: speechProvider.defersTranscription
        ? SttDisplayMode.transcription
        : sttMode,
    enabled: autoTranscribe,
    appleReady: appleSpeechReady,
    appleTranslationReady: appleTranslationAvailable,
    engines: {
      for (final entry in _engineAdapters.entries)
        entry.key: entry.value.snapshot(),
    },
  );

  @override
  bool get _activeSttConfigured => _isConfigured(_activeConfiguration);
  @override
  bool get _activeAutoTranscribe => _activeConfiguration.enabled;
  @override
  String get activeTranslationTargetLanguage =>
      _activeConfiguration.targetLanguage;
  @override
  String get activeOwnerLanguage => _activeConfiguration.ownerLanguage;
  @override
  String get activeGuestLanguage => _activeConfiguration.guestLanguage;

  @override
  String _recordingKey({int? fileId, String? path}) {
    final id = fileId ?? (path == null ? null : fileIdFromPath(path));
    return id == null ? 'path:$path' : 'file:$id';
  }

  @override
  String _referenceKey(RecordingReference ref) {
    final session = _recordingSessions[ref.sessionId];
    return _recordingKey(
      fileId: session?.fileId ?? ref.fileId,
      path: session?.path ?? ref.path,
    );
  }

  @override
  _RecordingSession? _sessionForReference(RecordingReference ref) {
    if (ref.sessionId != null) return _recordingSessions[ref.sessionId];
    final id =
        ref.fileId ?? (ref.path == null ? null : fileIdFromPath(ref.path!));
    for (final session in _recordingSessions.values.toList().reversed) {
      if (id != null && session.fileId == id ||
          ref.path != null && session.path == ref.path) {
        return session;
      }
    }
    return null;
  }

  @override
  RecordingViewData recordingView(RecordingReference ref) {
    final session = _sessionForReference(ref);
    final id =
        session?.fileId ??
        ref.fileId ??
        (ref.path == null ? null : fileIdFromPath(ref.path!));
    var path = id == null ? null : localPathsByFileId[id];
    if (path == null && id != null) {
      for (final candidate in exportedPaths) {
        if (fileIdFromPath(candidate) == id) {
          path = candidate;
          break;
        }
      }
    }
    path ??= session?.path ?? ref.path;
    final key = _recordingKey(fileId: id, path: path);
    final metadata = _transcriptMetadata[key];
    final stored = path == null
        ? (id == null ? null : transcriptForFileId(id))
        : transcriptForPath(path);
    final current = session != null && session.id == _currentSessionId;
    final readingLive = current && (session.active || session.finalizing);
    final text = readingLive ? session.text : (stored ?? session?.text ?? '');
    final savedTranslation = _recordingTranslations[key];
    final translated = readingLive
        ? session.translation
        : (savedTranslation?.sourceRevision == metadata?.revision
              ? savedTranslation
              : null);
    final label = path == null ? '' : ExportCatalog.editableLabelFromPath(path);
    final asset = path == null ? null : library.assetForPath(path);
    final archiveRecord = path == null ? null : archive.recordForPath(path);
    final title = asset?.displayName.isNotEmpty == true
        ? asset!.displayName
        : archiveRecord?.displayName.isNotEmpty == true
        ? archiveRecord!.displayName
        : label.isNotEmpty
        ? label
        : id == null
        ? '当前录音'
        : _recordingDateTitle(id);
    final recordedAt =
        asset?.recordedAt ??
        archiveRecord?.recordedAt ??
        _recordedAtFromFileId(id);
    // Device recordings have no library entry until they are renamed or
    // archived; their retrieval time is still the local file timestamp.
    final importedAt =
        asset?.importedAt ??
        archiveRecord?.updatedAt ??
        _localFileTimestamp(path);
    return RecordingViewData(
      reference: RecordingReference(
        sessionId: ref.sessionId,
        fileId: id,
        path: path,
      ),
      path: path,
      title: title,
      text: text,
      translation: translated ?? (stored == null ? session?.translation : null),
      sourceLanguage:
          metadata?.sourceLanguage ?? session?.configuration.sourceLanguage,
      mode: session?.configuration.mode ?? SttDisplayMode.transcription,
      provider:
          metadata?.provider ??
          session?.configuration.provider ??
          speechProvider,
      transcriptionEnabled: session?.configuration.enabled ?? autoTranscribe,
      speechReady: _isConfigured(
        session?.configuration ?? _settingsConfiguration,
      ),
      live: current && recording,
      paused: current && _recordWireStatus == 2 && session.paused,
      audioLocked:
          (current && (recording || session.finalizing)) ||
          _isRecordingAudioLocked(id, path),
      processing:
          _fileJobKey == key ||
          (_fileJobs.jobs[key]?.stage == 'queued' &&
              _fileJobs.jobs[key]?.error == null &&
              _recordingErrors[key] == null) ||
          session?.finalizing == true,
      error:
          _recordingErrors[key] ?? _fileJobs.jobs[key]?.error ?? session?.error,
      progress: _fileJobKey == key ? fileTranscriptionProgress : null,
      source: asset?.source ?? RecordingSource.device,
      recordedAt: recordedAt,
      importedAt: importedAt,
      originalPath: asset?.originalPath,
      originalPresent: path == null ? false : File(path).existsSync(),
      originalComplete:
          (asset?.originalComplete ?? true) &&
          (id == null || !_incompleteRetrievalIds.contains(id)),
      archived: asset?.trashed ?? false,
      segments: path == null ? const [] : transcriptSegmentsForPath(path),
      manuallyEdited:
          path != null &&
          _manualTranscripts.containsKey(_recordingKey(path: path)),
      hasPendingTranscript:
          path != null &&
          _incomingTranscripts.containsKey(_recordingKey(path: path)),
    );
  }

  String _recordingDateTitle(int id) {
    final date = _recordedAtFromFileId(id);
    if (date == null) return '当前录音';
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${date.year}/${pad(date.month)}/${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }

  /// Device file ids are Unix seconds. Imported originals use a microsecond
  /// timestamp prefix, which must never be treated as a recording date.
  @override
  DateTime? _recordedAtFromFileId(int? id) {
    if (id == null || id < 1000000000 || id > 4102444800) return null;
    return DateTime.fromMillisecondsSinceEpoch(id * 1000);
  }

  @override
  DateTime? _localFileTimestamp(String? path) {
    if (path == null) return null;
    try {
      return File(path).lastModifiedSync();
    } catch (_) {
      return null;
    }
  }

  @override
  bool _isRecordingAudioLocked(int? id, String? path) {
    final current = _currentRecording;
    final matches =
        current != null &&
        ((id != null && current.fileId == id) ||
            (path != null && current.path == path));
    return matches &&
            (recording || realtimeState.active || current.finalizing) ||
        (id != null && recording && realtimeState.fileId == id) ||
        _finalizingRecordings.contains(_recordingKey(fileId: id, path: path));
  }

  @override
  bool _isTrashedPath(String path) {
    final id = ExportCatalog.fileIdFromPath(path);
    for (final asset in library.assets) {
      if (!asset.trashed) continue;
      if (asset.path == path) return true;
      if (id != null && ExportCatalog.fileIdFromPath(asset.path) == id) {
        return true;
      }
    }
    return false;
  }

  @override
  void _requireFinishedRecording(String path) {
    if (_isRecordingAudioLocked(fileIdFromPath(path), path)) {
      throw StateError('录音保存后再试');
    }
  }

  Future<void> _loadPersistedDevice() async {
    final saved = await _persistedDeviceLoader();
    if (saved.device == null && !saved.bound) return;
    _explicitDisconnect = saved.manuallyDisconnected;
    lastKnownDevice = saved.device;
    lastKnownInfo = saved.info;
    if (saved.bound) bound = true;
    // Surface on Device tab even before this session connects.
    activeDevice ??= lastKnownDevice;
    notifyListeners();
    if (!_explicitDisconnect && saved.bound && saved.device != null) {
      unawaited(_startBoundDeviceReconnect());
    }
  }

  Future<void> _startBoundDeviceReconnect() async {
    if (_explicitDisconnect ||
        connected ||
        phase == AppPhase.scanning ||
        phase == AppPhase.connecting ||
        _ble.isConnecting) {
      return;
    }
    statusMessage = '正在自动连接已绑定设备…';
    await startScan();
  }

  /// Handle the one-shot action exposed through the iOS Action Button.
  ///
  /// Repeated invocations coalesce while a request is pending or sending. A
  /// request is never retained beyond its reconnect attempt, preventing a
  /// later unrelated auto-reconnect from unexpectedly starting a recording.
  Future<void> requestRecordingFromShortcut() async {
    shortcutNavigationRevision++;
    notifyListeners();

    if (_recordingShortcutPending || _recordingShortcutStarting) return;
    if (recording) {
      statusMessage = '录音中';
      errorMessage = null;
      notifyListeners();
      return;
    }
    if (isWifiExportSession || isExporting) {
      _failRecordingShortcut('正在导出录音，暂时无法开始新的录音');
      return;
    }

    _recordingShortcutPending = true;
    statusMessage = connected ? '正在开始快捷录音…' : '快捷录音：正在准备连接…';
    errorMessage = null;
    notifyListeners();

    await _persistedDeviceLoaded;
    if (!_recordingShortcutPending) return;

    if (_explicitDisconnect) {
      _failRecordingShortcut('已手动断开，请先在应用中连接录音豆');
      return;
    }

    if (recording) {
      _finishRecordingShortcut();
      statusMessage = '录音中';
      notifyListeners();
      return;
    }

    if (connected && _ble.isConnected) {
      if (blocksRecordingControl) {
        _failRecordingShortcut('设备正忙，请稍后再按一次操作按钮');
        return;
      }
      await _runPendingRecordingShortcutIfReady();
      return;
    }

    if (!bound || lastKnownDevice == null) {
      _failRecordingShortcut('未找到已绑定的录音豆，请先在应用中连接设备');
      return;
    }

    statusMessage = '快捷录音：正在连接 ${lastKnownDevice!.displayName}…';
    _startRecordingShortcutScanTimeout();
    if (phase == AppPhase.connecting || _ble.isConnecting) {
      _recordingShortcutConnecting = true;
      _recordingShortcutTimer?.cancel();
      _recordingShortcutTimer = null;
    }
    notifyListeners();

    if (phase != AppPhase.scanning &&
        phase != AppPhase.connecting &&
        !_ble.isConnecting) {
      await startScan();
      if (_recordingShortcutPending &&
          !connected &&
          phase == AppPhase.idle &&
          errorMessage != null) {
        _failRecordingShortcut(errorMessage!);
      }
    }
  }

  void _startRecordingShortcutScanTimeout() {
    _recordingShortcutTimer?.cancel();
    _recordingShortcutTimer = Timer(recordingShortcutScanTimeout, () {
      if (!_recordingShortcutPending || _recordingShortcutConnecting) return;
      _failRecordingShortcut('未在 30 秒内找到已绑定的录音豆，请靠近设备后重试');
    });
  }

  void _finishRecordingShortcut() {
    _recordingShortcutPending = false;
    _recordingShortcutConnecting = false;
    _recordingShortcutTimer?.cancel();
    _recordingShortcutTimer = null;
  }

  void _failRecordingShortcut(String message) {
    _finishRecordingShortcut();
    statusMessage = '快捷录音未开始';
    errorMessage = message;
    notifyListeners();
  }

  /// Returns null when there was no shortcut request, true for success/no-op,
  /// and false when the BLE start command failed.
  Future<bool?> _runPendingRecordingShortcutIfReady() async {
    if (!_recordingShortcutPending || _recordingShortcutStarting) return null;
    if (recording) {
      _finishRecordingShortcut();
      statusMessage = '录音中';
      notifyListeners();
      return true;
    }
    if (!connected || !_ble.isConnected) return null;
    if (isWifiExportSession || isExporting) {
      _failRecordingShortcut('正在导出录音，暂时无法开始新的录音');
      return false;
    }
    if (blocksRecordingControl) {
      _failRecordingShortcut('设备正忙，请稍后再按一次操作按钮');
      return false;
    }

    _finishRecordingShortcut();
    _recordingShortcutStarting = true;
    try {
      final started = await _startRecordChecked();
      if (!started) {
        statusMessage = '快捷录音未开始';
        notifyListeners();
      }
      return started;
    } finally {
      _recordingShortcutStarting = false;
    }
  }

  Future<void> _tryAutoConnectBoundDevice(List<ScannedDevice> scanned) async {
    if (_explicitDisconnect ||
        !bound ||
        connected ||
        phase == AppPhase.connecting ||
        _ble.isConnecting) {
      return;
    }
    final saved = lastKnownDevice;
    if (saved == null) return;

    ScannedDevice? target;
    for (final candidate in scanned) {
      final sameId = candidate.id == saved.id;
      final sameMac =
          saved.macAddress != null &&
          candidate.macAddress != null &&
          candidate.macAddress == saved.macAddress;
      if (sameId || sameMac) {
        target = candidate;
        break;
      }
    }
    if (target == null) return;

    await connect(target);
  }

  Future<void> _persistDevice() async {
    final d = activeDevice ?? lastKnownDevice;
    if (d == null && !bound) {
      await DeviceStore.clear();
      return;
    }
    await DeviceStore.save(
      bound: bound,
      manuallyDisconnected: _explicitDisconnect,
      device: d,
      info: info ?? lastKnownInfo,
    );
  }

  static List<TranscriptSegment> _rememberedSegments(
    List<SttSegment> segments,
  ) => [
    for (final segment in segments)
      TranscriptSegment(
        text: segment.text,
        start: Duration(milliseconds: segment.startMs),
        end: segment.endMs == null
            ? null
            : Duration(milliseconds: segment.endMs!),
        speaker: segment.speaker,
        speakerChanged: segment.speakerChanged,
      ),
  ];

  void setAutoTranscribe(bool v) {
    autoTranscribe = v;
    if (!v) {
      sttMode = SttDisplayMode.transcription;
      if (!_liveProcessing) _resetTranslationTurns();
    }
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setAutoRealtime(bool v) {
    autoRealtime = v;
    if (!v && _autoTransferRunning) _blePull.cancel();
    notifyListeners();
    unawaited(_persistSettings());
    if (v && connected) {
      if (recording || info?.recording == true) {
        unawaited(_maybeStartAutoRealtime(reason: 'setting_enabled'));
      } else {
        unawaited(refreshFilesOnTabEnter());
      }
    }
  }

  void setTranscriptLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    transcriptLanguage = normalized.isEmpty ? 'auto' : normalized;
    notifyListeners();
    unawaited(_persistSettings());
  }

  /// The saved credential trio for [provider] (key-only engines expose just
  /// their key; Apple has none). This is the data source the engine lineup
  /// renders from.
  EngineConfig engineConfig(SttProvider provider) => switch (provider) {
    SttProvider.apple => const EngineConfig(),
    _ => _engineAdapters[provider]?.readSaved() ?? const EngineConfig(),
  };

  /// Whether [provider] is ready to be selected and used.
  bool engineConfigured(SttProvider provider) => switch (provider) {
    SttProvider.apple => appleCapabilities.supported,
    _ => _engineAdapters[provider]?.isReady() ?? false,
  };

  /// Saves a cloud engine's whole credential group at once. The base URL is
  /// normalized on save; an invalid one throws the engine's exception and
  /// leaves the current configuration untouched. Key-only engines keep
  /// their dedicated setters.
  Future<void> setEngineConfig(SttProvider provider, EngineConfig config) {
    final adapter = _engineAdapters[provider];
    if (adapter == null || !adapter.grouped) {
      throw ArgumentError.value(provider, 'provider', 'has no engine trio');
    }
    final apiKey = _blankToNull(config.apiKey);
    final model = _blankToNull(config.model);
    final rawBaseUrl = _blankToNull(config.baseUrl);
    final baseUrl = rawBaseUrl == null
        ? null
        : adapter.normalizeBaseUrl(rawBaseUrl);
    return _persistSettings(
      strict: true,
      provider: provider,
      config: EngineConfig(apiKey: apiKey, baseUrl: baseUrl, model: model),
    );
  }

  /// Saves the whole Qwen credential trio at once. The base URL is
  /// normalized on save; an invalid one throws [QwenSttException] and leaves
  /// the current configuration untouched.
  Future<void> setQwenConfig(EngineConfig config) =>
      setEngineConfig(SttProvider.qwen, config);

  /// Saves the whole Doubao credential trio at once. The base URL is
  /// normalized on save; an invalid one throws [DoubaoSttException] and
  /// leaves the current configuration untouched.
  Future<void> setDoubaoConfig(EngineConfig config) =>
      setEngineConfig(SttProvider.doubao, config);

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  bool get sttConfigured =>
      _settingsReady && _isConfigured(_settingsConfiguration);

  void setSttMode(SttDisplayMode mode) {
    if (speechProvider.defersTranscription &&
        mode != SttDisplayMode.transcription) {
      return;
    }
    if (mode != SttDisplayMode.transcription &&
        (!autoTranscribe ||
            (mode == SttDisplayMode.conversation &&
                !conversationModeAvailable) ||
            (mode == SttDisplayMode.translation &&
                !translationModeAvailable))) {
      return;
    }
    if (sttMode == mode) return;
    sttMode = mode;
    if (!_liveProcessing) {
      _preferStreamStt = true;
      transcriptError = null;
      _resetTranslationTurns();
    }
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setTranslationTargetLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    if (normalized.isEmpty) return;
    if (translationTargetLanguage == normalized) return;
    translationTargetLanguage = normalized;
    if (!_liveProcessing) _resetTranslationTurns();
    unawaited(refreshAppleCapabilities());
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setOwnerLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    if (!isSpeechLanguage(normalized) || normalized == guestLanguage) return;
    if (ownerLanguage == normalized) return;
    ownerLanguage = normalized;
    if (!_liveProcessing) _resetTranslationTurns();
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setGuestLanguage(String code) {
    final normalized = code.trim().toLowerCase();
    if (!isSpeechLanguage(normalized) || normalized == ownerLanguage) return;
    if (guestLanguage == normalized) return;
    guestLanguage = normalized;
    if (!_liveProcessing) _resetTranslationTurns();
    notifyListeners();
    unawaited(_persistSettings());
  }

  void swapCommunicationLanguages() {
    final previousOwner = ownerLanguage;
    ownerLanguage = guestLanguage;
    guestLanguage = previousOwner;
    if (!_liveProcessing) _resetTranslationTurns();
    notifyListeners();
    unawaited(_persistSettings());
  }

  final BleService _ble;
  final PersistedDeviceLoader _persistedDeviceLoader;
  final Duration recordingShortcutScanTimeout;
  @override
  late final Future<void> _settingsLoaded;
  bool _settingsReady = false;
  late final Future<void> _persistedDeviceLoaded;
  final DeviceCrypto _crypto = DeviceCrypto();
  late final WifiExportService _wifi;
  late final RealtimeBleStream _realtime;
  late final BleFilePull _blePull;
  @override
  final AudioPlayer _player;
  @override
  final List<StreamSubscription> _subs = [];

  /// Auto BLE realtime transfer while device is recording (no SoftAP).
  bool autoRealtime = true;
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

  /// Near-realtime AI transcription (PCM WS stream + Ogg batch fallback).
  @override
  bool autoTranscribe = true;

  String transcriptLanguage = 'auto';
  SttDisplayMode sttMode = SttDisplayMode.transcription;
  @override
  String translationTargetLanguage = 'zh';
  String ownerLanguage = 'zh';
  String guestLanguage = 'en';
  @override
  bool transcribing = false;
  @override
  String? transcribingPath;
  @override
  SttFileProgress? fileTranscriptionProgress;
  @override
  final QwenSttService _qwenStt;
  @override
  final DoubaoSttService _doubaoStt;

  /// How every non-Apple engine plugs into this controller: loading and
  /// saving its credentials, readiness, the resolved snapshot a take
  /// freezes, and its file-transcription dispatch. The provider switches
  /// elsewhere collapse to one lookup here; adding a cloud engine is a
  /// service plus one entry in this map.
  @override
  late final Map<SttProvider, _EngineAdapter> _engineAdapters = {
    SttProvider.qwen: _EngineAdapter(
      load: (settings) => settings.engineConfig(SttProvider.qwen),
      readSaved: () => EngineConfig(
        apiKey: _qwenStt.apiKeyOverride,
        baseUrl: _qwenStt.baseUrlOverride,
        model: _qwenStt.modelOverride,
      ),
      applySaved: (config) {
        _qwenStt.apiKeyOverride = config.apiKey;
        _qwenStt.baseUrlOverride = config.baseUrl;
        _qwenStt.modelOverride = config.model;
      },
      isReady: () => _qwenStt.isConfigured,
      snapshot: () => EngineConfig(
        apiKey: _qwenStt.apiKey,
        baseUrl: _resolveSnapshotBaseUrl(_qwenStt),
        model: _qwenStt.model,
      ),
      grouped: true,
      normalizeBaseUrl: normalizeDashScopeBaseUrl,
      transcribe: (path, engine, {language, onProgress, isCurrent}) =>
          _qwenStt.transcribePath(
            path,
            apiKey: engine.apiKey,
            baseUrl: engine.baseUrl,
            model: engine.model,
            language: language,
            onProgress: onProgress,
            isCurrent: isCurrent,
          ),
    ),
    SttProvider.doubao: _EngineAdapter(
      load: (settings) => settings.engineConfig(SttProvider.doubao),
      readSaved: () => EngineConfig(
        apiKey: _doubaoStt.apiKeyOverride,
        baseUrl: _doubaoStt.baseUrlOverride,
        model: _doubaoStt.modelOverride,
      ),
      applySaved: (config) {
        _doubaoStt.apiKeyOverride = config.apiKey;
        _doubaoStt.baseUrlOverride = config.baseUrl;
        _doubaoStt.modelOverride = config.model;
      },
      isReady: () => _doubaoStt.isConfigured,
      snapshot: () => EngineConfig(
        apiKey: _doubaoStt.apiKey,
        baseUrl: _resolveSnapshotBaseUrl(_doubaoStt),
        model: _doubaoStt.model,
      ),
      grouped: true,
      normalizeBaseUrl: normalizeDoubaoBaseUrl,
      // The service maps ISO short codes (`zh`) to Volcano BCP-47 (`zh-CN`).
      transcribe: (path, engine, {language, onProgress, isCurrent}) =>
          _doubaoStt.transcribePath(
            path,
            apiKey: engine.apiKey,
            baseUrl: engine.baseUrl,
            model: engine.model,
            language: language,
            onProgress: onProgress,
            isCurrent: isCurrent,
          ),
    ),
  };

  /// The engine's resolved origin, or its default when the saved value is
  /// invalid (snapshots must never throw on bad settings).
  static String _resolveSnapshotBaseUrl(CloudFileSttService service) {
    try {
      return service.baseUrl;
    } on CloudSttException {
      return service.fallbackBaseUrl;
    }
  }

  @override
  final AppleSpeechService _appleSpeech;
  @override
  SttProvider speechProvider = SttProvider.qwen;
  @override
  String appleSourceLanguage = '';
  AppleSpeechCapabilities appleCapabilities =
      const AppleSpeechCapabilities.unsupported();
  bool appleCapabilitiesLoading = false;
  @override
  bool appleLanguagePreparationBusy = false;
  String? appleSetupError;
  int _capabilityRevision = 0;
  @override
  bool _disposed = false;
  Completer<bool>? _encryptCompleter;
  AppPhase phase = AppPhase.idle;
  @override
  bool connected = false;
  List<ScannedDevice> devices = [];
  DeviceInfoModel? info;
  List<OfflineFileEntry> files = [];
  List<String> logs = [];
  @override
  String? statusMessage;
  @override
  String? errorMessage;
  @override
  bool recording = false;
  bool bound = false;
  ScannedDevice? activeDevice;

  /// Incremented for each shortcut invocation so AppShell can select Home.
  int shortcutNavigationRevision = 0;
  bool _recordingShortcutPending = false;
  bool _recordingShortcutConnecting = false;
  bool _recordingShortcutStarting = false;
  Timer? _recordingShortcutTimer;
  Timer? _scanTimeoutTimer;
  Timer? _boundReconnectTimer;
  int _boundReconnectAttempt = 0;
  bool get recordingShortcutPending => _recordingShortcutPending;

  /// Persisted user intent; only explicit connection resumes reconnection.
  bool _explicitDisconnect = false;
  bool get manuallyDisconnected => _explicitDisconnect;

  /// Survives disconnect so the Device tab can still show a known/bound unit.
  ScannedDevice? lastKnownDevice;
  DeviceInfoModel? lastKnownInfo;

  /// Multi-select for batch export.
  bool selecting = false;
  final Set<int> selectedFileIds = {};

  /// ECDH session established (needed to decrypt exports).
  bool encryptReady = false;

  /// Device file currently being downloaded on demand over BLE.
  int? downloadingFileId;

  @override
  final TranscriptPersister? _transcriptPersister;

  /// Legacy expand id (device list no longer expands for playback).
  int? expandedFileId;

  /// Available playback rates for the speed dropdown.
  static const List<double> playbackSpeeds = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

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

  int get adsSeen => _ble.adsSeen;

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

  Future<void> startScan() async {
    await _persistedDeviceLoaded;
    if (connected ||
        phase == AppPhase.scanning ||
        phase == AppPhase.connecting) {
      return;
    }
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _scanTimeoutTimer?.cancel();
    errorMessage = null;
    phase = AppPhase.scanning;
    statusMessage = '正在检查蓝牙…';
    notifyListeners();
    try {
      final saved = bound && !_explicitDisconnect ? lastKnownDevice : null;
      if (saved != null && await _ble.isD3200ConnectedToSystem(saved.id)) {
        statusMessage = '正在恢复 ${saved.displayName} 的连接…';
        notifyListeners();
        await connect(saved);
        if (connected) return;

        // The restored link went stale while being adopted. Fall back to a
        // normal scan without leaving the failed direct-connect error visible.
        errorMessage = null;
        phase = AppPhase.scanning;
        statusMessage = '正在检查蓝牙…';
        notifyListeners();
      }
      await _ble.startScan(timeout: _bleScanTimeout);
      statusMessage = '正在扫描安克录音豆（D3200）…';
      notifyListeners();
      if (!connected && phase == AppPhase.scanning) {
        // FlutterBluePlus stops its native scan when the timeout elapses, but
        // startScan() returns as soon as scanning begins. Mirror that timeout
        // in controller state so the UI cannot remain stuck on a dead scan.
        _scanTimeoutTimer = Timer(_bleScanTimeout, () {
          if (!connected && phase == AppPhase.scanning) {
            unawaited(_finishTimedOutScan());
          }
        });
      }
    } catch (e) {
      _scanTimeoutTimer?.cancel();
      errorMessage = e.toString().replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError):\s*'),
        '',
      );
      phase = AppPhase.idle;
      statusMessage = null;
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _scanTimeoutTimer?.cancel();
    await _ble.stopScan();
    if (!connected) phase = AppPhase.idle;
    statusMessage = devices.isEmpty && adsSeen > 0
        ? '已见 $adsSeen 条 BLE 广播，无匹配 D3200 — 请重启录音豆后重试'
        : null;
    notifyListeners();
  }

  Future<void> _finishTimedOutScan() async {
    await stopScan();
    _scheduleBoundReconnect();
  }

  bool get _canRetryBoundConnection =>
      !_explicitDisconnect &&
      bound &&
      lastKnownDevice != null &&
      !connected &&
      phase == AppPhase.idle &&
      !_ble.isConnecting &&
      !isWifiExportSession &&
      !isExporting &&
      !needsWifiJoin;

  void _scheduleBoundReconnect() {
    if (!_canRetryBoundConnection || _boundReconnectTimer != null) return;
    final index = _boundReconnectAttempt < _boundReconnectDelays.length
        ? _boundReconnectAttempt
        : _boundReconnectDelays.length - 1;
    final delay = _boundReconnectDelays[index];
    _boundReconnectAttempt++;
    statusMessage = '未找到已绑定设备，${delay.inSeconds} 秒后自动重试…';
    notifyListeners();
    _boundReconnectTimer = Timer(delay, () {
      _boundReconnectTimer = null;
      if (_canRetryBoundConnection) {
        unawaited(startScan());
      }
    });
  }

  void _resetBoundReconnectBackoff() {
    _boundReconnectTimer?.cancel();
    _boundReconnectTimer = null;
    _boundReconnectAttempt = 0;
  }

  Future<void> connect(ScannedDevice d) async {
    await _persistedDeviceLoaded;
    // Single-flight: ignore extra taps while connecting (or BLE layer busy).
    if (phase == AppPhase.connecting || _ble.isConnecting) {
      statusMessage = '正在连接…';
      notifyListeners();
      return;
    }

    _explicitDisconnect = false;
    if (_recordingShortcutPending) {
      _recordingShortcutConnecting = true;
      _recordingShortcutTimer?.cancel();
      _recordingShortcutTimer = null;
    }

    _scanTimeoutTimer?.cancel();
    errorMessage = null;
    activeDevice = d;
    phase = AppPhase.connecting;
    statusMessage = '正在连接 ${d.displayName}…';
    connected = false;
    notifyListeners();
    // Start while the activity is visible. Android 12+ restricts launching a
    // foreground service after the app has already entered the background.
    await BackgroundSyncService.start();
    bool? shortcutResult;
    String? shortcutFailure;
    try {
      await _persistDevice();
      await _ble.connect(d.id, serviceUuidHint: d.serviceUuid);
      // Retry after GATT is ready in case Android initially rejected the
      // connected-device service before Bluetooth permission settled.
      await BackgroundSyncService.start();
      connected = true;
      phase = AppPhase.ready;
      statusMessage = '已连接';
      lastKnownDevice = d;
      // D3200 treats the first successful GATT connection as ownership: after
      // connecting it stops discoverable advertising to other hosts even when
      // no separate bind command was sent. Persist that observed device state
      // so only this exact recorder is eligible for automatic reconnection.
      bound = true;
      unawaited(_persistDevice());
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await refreshInfo();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await syncTime();
      // ECDH encrypt handshake so file exports can be decrypted.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await establishEncryptSession();
      shortcutResult = await _runPendingRecordingShortcutIfReady();
      if (shortcutResult == false) shortcutFailure = errorMessage;
      _startBatteryPoll();
      // Home may already be visible before an iOS connection completes, so its
      // initial tab refresh has already returned while disconnected. Always
      // request the device inventory once the GATT session is fully ready.
      await listFiles();
      // If the bean is already recording, start BLE realtime pull automatically.
      if (recording || info?.recording == true) {
        await _maybeStartAutoRealtime(reason: 'connected');
      }
      if (shortcutResult == false) {
        statusMessage = '快捷录音未开始';
        errorMessage = shortcutFailure ?? '无法开始录音';
        notifyListeners();
      } else if (shortcutResult == true && recording) {
        statusMessage = '录音中';
        notifyListeners();
      }
    } catch (e) {
      // Prefer cleaned message from BleService / strip noisy prefixes.
      final connectionError = e.toString().replaceFirst(
        RegExp(r'^(Bad state|Exception|StateError|TimeoutException):\s*'),
        '',
      );
      errorMessage = connectionError;
      phase = AppPhase.idle;
      statusMessage = null;
      // Keep lastKnownDevice if we had one from a prior session.
      activeDevice = lastKnownDevice;
      connected = false;
      if (!_ble.isConnected) {
        await BackgroundSyncService.stop();
      }
      _scheduleBoundReconnect();
      if (_recordingShortcutPending) {
        _failRecordingShortcut(connectionError);
      } else {
        notifyListeners();
      }
    }
  }

  Future<void> disconnect() async {
    await _persistedDeviceLoaded;
    _explicitDisconnect = true;
    await _persistDevice();
    _resetBoundReconnectBackoff();
    _scanTimeoutTimer?.cancel();
    _postBindFileRefreshTimer?.cancel();
    _stopBatteryPoll();
    await _ble.stopScan();
    await _wifi.cancel();
    await stopPlayback();
    if (info != null) lastKnownInfo = info;
    if (activeDevice != null) lastKnownDevice = activeDevice;
    await _ble.disconnect();
    // Keep lastKnownDevice / bound for offline Device tab; clear live session only.
    activeDevice = lastKnownDevice;
    info = null;
    files = [];
    selectedFileIds.clear();
    selecting = false;
    recording = false;
    _snapshotLiveText();
    _currentRecording?.active = false;
    _recordWireStatus = 0;
    encryptReady = false;
    _crypto.resetSession();
    phase = AppPhase.idle;
    statusMessage = null;
    connected = false;
    await BackgroundSyncService.stop();
    unawaited(_persistDevice());
    notifyListeners();
  }

  /// Display name for Device tab (live or last known).
  String get displayDeviceName =>
      activeDevice?.displayName ?? lastKnownDevice?.displayName ?? '设备';

  /// Snapshot used when offline.
  ScannedDevice? get displayDevice => activeDevice ?? lastKnownDevice;

  /// BLE `0x2E/0x01` ECDH handshake (Feishu `notifyEncryptFileData`).
  Future<bool> establishEncryptSession({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    if (!_ble.isConnected) return false;
    if (encryptReady && _crypto.hasSession) return true;

    final mac =
        activeDevice?.macAddress ??
        info?.boxMac ??
        activeDevice?.id ??
        'unknown';
    statusMessage = '正在准备设备…';
    phase = AppPhase.busy;
    notifyListeners();

    _encryptCompleter = Completer<bool>();
    try {
      final pub = _crypto.ensureKeyPair();
      // Feishu stores MAC on EncryptMessageDispatch for session storage key.
      logs = [
        'ENCRYPT TX pub ${pub.length}B mac=$mac',
        ...logs,
      ].take(80).toList();
      await _ble.writeCommand(DeviceCommands.notifyEncryptPublicKey(pub));
      final ok = await _encryptCompleter!.future.timeout(timeout);
      encryptReady = ok;
      statusMessage = ok ? '设备已就绪' : '设备准备失败，请重新连接';
      phase = AppPhase.ready;
      notifyListeners();
      return ok;
    } on TimeoutException {
      encryptReady = false;
      errorMessage = '设备准备超时，请重新连接';
      statusMessage = '设备准备超时，请重新连接';
      phase = AppPhase.ready;
      notifyListeners();
      return false;
    } catch (e) {
      encryptReady = false;
      errorMessage = e.toString();
      phase = AppPhase.ready;
      notifyListeners();
      return false;
    } finally {
      _encryptCompleter = null;
    }
  }

  Future<bool> _sendChecked(List<int> frame, {String? label}) async {
    if (!_ble.isConnected) {
      errorMessage = '未连接';
      notifyListeners();
      return false;
    }
    phase = AppPhase.busy;
    if (label != null) statusMessage = label;
    notifyListeners();
    try {
      await _ble.writeCommand(frame);
      // A command just went through — any earlier error (e.g. a stale
      // "未连接" from a command that raced a disconnect) is no longer true.
      errorMessage = null;
      return true;
    } catch (e) {
      errorMessage = e.toString();
      return false;
    } finally {
      phase = connected ? AppPhase.ready : AppPhase.idle;
      notifyListeners();
    }
  }

  Future<void> _send(List<int> frame, {String? label}) async {
    await _sendChecked(frame, label: label);
  }

  Future<void> refreshInfo({bool silent = false}) =>
      _send(DeviceCommands.getDeviceInfo(), label: silent ? null : '正在获取设备信息…');

  Timer? _batteryPollTimer;

  /// Poll device info while connected so mic/case battery stay fresh.
  /// Live 0x01/0x03 pushes are also handled, but many firmwares only update on query.
  void _startBatteryPoll() {
    _batteryPollTimer?.cancel();
    if (!connected) return;
    _batteryPollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!connected || !_ble.isConnected) return;
      if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
      if (isWifiExportSession || isExporting) return;
      unawaited(refreshInfo(silent: true));
    });
  }

  void _stopBatteryPoll() {
    _batteryPollTimer?.cancel();
    _batteryPollTimer = null;
  }

  /// Called when Device tab is shown — force a fresh battery snapshot.
  Future<void> refreshInfoOnDeviceTabEnter() async {
    if (!connected || !_ble.isConnected) return;
    if (phase == AppPhase.busy || phase == AppPhase.connecting) return;
    if (isWifiExportSession || isExporting) return;
    await refreshInfo(silent: true);
  }

  Future<void> syncTime() => _send(DeviceCommands.syncTime(), label: '正在同步时钟…');

  Future<void> startRecord() async {
    await _startRecordChecked();
  }

  Future<bool> _startRecordChecked() async {
    await _settingsLoaded;
    if (_disposed) return false;
    await _yieldAutoTransfer();
    final sent = await _sendChecked(
      DeviceCommands.startRecord(),
      label: '正在开始录音…',
    );
    if (!sent) return false;
    // Optimistic; device will confirm via 0x18/0x82 or 1A06.
    _applyRecordStatus(1, source: 'app_start');
    return true;
  }

  Future<void> pauseRecord() async {
    final sent = await _sendChecked(
      DeviceCommands.pauseRecord(),
      label: '正在暂停录音…',
    );
    if (!sent) return;
    // Optimistic; device will confirm via 0x18/0x82 status 0/2.
    _applyRecordStatus(2, source: 'app_pause');
  }

  /// Feishu `onAudioStatusChanged` / device-info recording bit:
  /// status `0` stop, `1` recording, `2` pause.
  /// Last wire status: 0=stop, 1=recording, 2=pause (for resume vs new take).
  @override
  int _recordWireStatus = 0;
  bool get recordingPaused =>
      _recordWireStatus == 2 && _currentRecording != null;

  void _applyRecordStatus(
    int status, {
    int? fileId,
    int? durationSec,
    String source = '',
  }) {
    if (!_settingsReady) {
      unawaited(
        _settingsLoaded.then((_) {
          if (!_disposed) {
            _applyRecordStatus(
              status,
              fileId: fileId,
              durationSec: durationSec,
              source: source,
            );
          }
        }),
      );
      return;
    }
    final wasRecording = recording;
    final prevWire = _recordWireStatus;
    final active = status == 1;
    final retargetFile = active && fileId != null && fileId > 0;
    // Skip no-ops; still apply when a new live file id must retarget realtime.
    if (recording == active && !retargetFile && status == prevWire) {
      return;
    }
    recording = active;
    _recordWireStatus = status;
    // Keep DeviceInfoModel bit aligned so later device-info packets don't re-stick UI.
    if (info != null && info!.recordingStatus != status) {
      info = info!.copyWith(recordingStatus: status);
      lastKnownInfo = info;
    }

    if (active) {
      // Continue the existing take regardless of its speech provider. A
      // different device file id is an explicit new take, never a continuation.
      final current = _currentRecording;
      final differentFile =
          fileId != null &&
          current?.fileId != null &&
          current!.fileId != fileId;
      final resuming = prevWire == 2 && current != null && !differentFile;
      if (current == null ||
          differentFile ||
          (prevWire == 0 && !wasRecording) ||
          (source == 'app_start' && !wasRecording && !resuming)) {
        unawaited(_beginNewLiveTranscriptSession());
      }
      _bindCurrentRecording(fileId: fileId);
      _currentRecording?.active = true;
      _currentRecording?.paused = false;
      // New take: re-enable PCM stream STT (may have fallen back last session).
      _preferStreamStt = true;
      pcmFramesDecoded = 0;
      statusMessage = fileId != null && fileId > 0 ? '录音中 · 文件 $fileId' : '录音中';
      // The current recording always streams live over BLE — transcription
      // depends on it. `autoRealtime` ("自动传输") only gates catching up on
      // already-finished, un-exported recordings (see _autoTransferMissingFiles).
      if (!isWifiExportSession) {
        if (fileId != null && fileId > 0) {
          unawaited(_startCurrentRecordingTransfer(fileId));
        } else if (resuming && current.fileId != null) {
          unawaited(_startCurrentRecordingTransfer(current.fileId!));
        } else {
          unawaited(
            _maybeStartAutoRealtime(
              reason: source.isEmpty ? 'record_status' : source,
            ),
          );
        }
      }
    } else {
      _snapshotLiveText();
      _currentRecording?.active = false;
      _currentRecording?.paused = status == 2;
      if (status == 0) _currentRecording?.ended = true;
      _currentRecording?.finalizing =
          status == 0 && (realtimeState.active || _sttStream != null);
      final label = status == 2 ? '已暂停' : '已停止录音';
      if (durationSec != null && durationSec > 0) {
        statusMessage = '$label（${durationSec}s）';
      } else {
        statusMessage = label;
      }
      if (wasRecording || realtimeState.active) {
        _realtime.onRecordingStopped();
      }
      if (status == 2) {
        // Pause is a hard boundary: disconnect the speech stream immediately and reject
        // queued callbacks or a batch fallback from the paused take.
        _cancelStreamSttAfterPause();
      } else {
        // A full stop may finish gracefully while realtime audio settles.
        try {
          _sttStream?.finalizeUtterance();
        } catch (_) {}
      }
      if (status == 0 && !realtimeState.active) {
        final owner = _currentRecording;
        if (owner?.path != null) {
          unawaited(_enqueueDeferredRecording(owner!, owner.path!));
        }
      }
      // Refresh inventory after hardware/app stop so Files tab shows the clip.
      if (status == 0 && connected) {
        unawaited(listFiles());
      }
    }
    debugPrint(
      '[Record] status=$status active=$active src=$source '
      'fileId=$fileId was=$wasRecording',
    );
    notifyListeners();
  }

  /// Resolve current recording file id and start BLE realtime stream.
  /// Not gated by `autoRealtime` — the current recording always streams live
  /// so transcription keeps working regardless of the backlog-transfer setting.
  Future<void> _maybeStartAutoRealtime({required String reason}) async {
    if (!connected || !_ble.isConnected) return;
    if (isWifiExportSession) return;
    final recordingNow = recording || info?.recording == true;
    if (recordingNow) await _yieldAutoTransfer();

    if (!encryptReady) {
      await establishEncryptSession();
    }

    // Prefer list-with-end-time: includes currentTransportTimestamp.
    try {
      await _ble.writeCommand(DeviceCommands.listFilesWithEndTime());
    } catch (_) {
      try {
        await _ble.writeCommand(DeviceCommands.listFiles());
      } catch (e) {
        debugPrint('[Realtime] listFiles failed: $e');
      }
    }
    // Packet handler will call _kickRealtimeFromFileList when list arrives.
    statusMessage = recordingNow ? '实时传输：等待当前录音文件…' : '正在检查未导出录音…';
    notifyListeners();
    debugPrint('[Realtime] arm auto stream ($reason)');
  }

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

  @override
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

  @visibleForTesting
  Future<void> waitForRecordingLibrary() => _libraryLoaded;

  /// Moving a material to the trash keeps the original file, transcript,
  /// speaker names, topics and notes. Only its visibility is changed.
  static const trashRetention = Duration(days: 30);

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

  /// Last bind/unbind we sent: true=bind, false=unbind, null=unknown.
  /// Feishu uses the same RX id (0x87) for both; we need this to interpret ACKs.
  bool? _pendingBindRequest;
  Timer? _postBindFileRefreshTimer;

  void _schedulePostBindFileRefresh() {
    _postBindFileRefreshTimer?.cancel();
    _postBindFileRefreshTimer = Timer(const Duration(milliseconds: 700), () {
      if (!connected || !bound || isExporting || needsWifiJoin) return;
      unawaited(listFiles());
    });
  }

  Future<void> bindDevice() async {
    _pendingBindRequest = true;
    await _send(DeviceCommands.bind(), label: '正在绑定…');
  }

  /// Unbind with the stock Feishu payload. This preserves recordings and
  /// disconnects BLE after a successful ACK.
  Future<void> unbindDevice() async {
    _postBindFileRefreshTimer?.cancel();
    _pendingBindRequest = false;
    await _send(DeviceCommands.unbind(), label: '正在解绑…');
  }

  Future<void> resetDevice() =>
      _send(DeviceCommands.resetDevice(), label: '正在恢复出厂…');

  Future<void> setFindMy(bool on) =>
      _send(DeviceCommands.setFindMy(on), label: on ? '正在开启查找…' : '正在关闭查找…');

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

  // ── Playback (local exported files only) ──────────────────────────────

  /// Which local export row shows inline transport (path key).
  @override
  String? expandedLocalPath;

  void toggleLocalExpanded(String path) {
    expandedLocalPath = expandedLocalPath == path ? null : path;
    notifyListeners();
  }

  void toggleFileExpanded(int fileId) {
    if (selecting) {
      toggleFileSelected(fileId);
      return;
    }
    expandedFileId = expandedFileId == fileId ? null : fileId;
    notifyListeners();
  }

  String? localPathFor(int fileId) => localPathsByFileId[fileId];

  @override
  int? fileIdFromPath(String path) => _fileIdFromPath(path);

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

  void _onPacket(DecodedPacket p) {
    // Device info family (type 0x01)
    if (p.cmdType == RxCmd.deviceInfoType) {
      if (p.cmdId == RxCmd.deviceInfoId) {
        info = DeviceInfoModel.parsePacket(p.raw);
        lastKnownInfo = info;
        if (activeDevice != null) lastKnownDevice = activeDevice;
        unawaited(_persistDevice());
        statusMessage =
            '麦克风 ${info?.battery ?? "—"}% · 充电盒 ${info?.boxBattery ?? "—"}%';
        final hex = info?.rawHex ?? '';
        if (hex.isNotEmpty) {
          logs = [
            'DEVINFO ${hex.length > 120 ? '${hex.substring(0, 120)}…' : hex}',
            ...logs,
          ].take(80).toList();
        }
      } else if (p.cmdId == RxCmd.batteryId && p.payload.length >= 2) {
        // Convert D3200's 0–9 battery buckets to display percentages.
        final micRaw = p.payload[0] & 0xFF;
        final boxRaw = p.payload[1] & 0xFF;
        final mic = DeviceInfoModel.batteryRemaining(micRaw) ?? 0;
        final box = DeviceInfoModel.batteryRemaining(boxRaw) ?? 0;
        info = (info ?? DeviceInfoModel()).copyWith(
          battery: mic,
          boxBattery: box,
        );
        lastKnownInfo = info;
        statusMessage = '麦克风 $mic% · 充电盒 $box%';
        logs = [
          'BATT mic=$mic% (raw $micRaw) box=$box% (raw $boxRaw)',
          ...logs,
        ].take(80).toList();
        debugPrint('[Battery] mic=$mic% raw=$micRaw box=$box% raw=$boxRaw');
      } else if (p.cmdId == RxCmd.chargingId && p.payload.length >= 2) {
        final micChg = (p.payload[0] & 0xFF) == 1;
        final boxChg = (p.payload[1] & 0xFF) == 1;
        info = (info ?? DeviceInfoModel()).copyWith(
          charging: micChg,
          boxCharging: boxChg,
        );
        lastKnownInfo = info;
        statusMessage = micChg || boxChg ? '充电中…' : '未充电';
        // Charging transitions often don't include % — refresh full device info.
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 400),
            () => refreshInfo(silent: true),
          ),
        );
      } else if (p.cmdId == RxCmd.resetId) {
        statusMessage = p.isSuccess ? '设备已重置' : '重置失败';
      } else if (p.cmdId == RxCmd.syncTimeId) {
        statusMessage = p.isSuccess ? '时钟已同步' : '时钟同步失败';
      }
    }

    // File list (newest first — fileId is a unix timestamp for D3200).
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.fileListId) {
      final list = OfflineFileList.parse(p.payload);
      files = _sortFilesNewestFirst(list.files);
      statusMessage = '${files.length} 条录音';
      _kickRealtimeFromFileList(list);
      _scheduleAutoTransferMissing();
    }
    if (p.cmdType == RxCmd.transportTypeAlt && p.cmdId == RxCmd.fileListId) {
      final list = OfflineFileList.parse(p.payload, withEndTime: true);
      _handleFileListPage(list);
    }

    // 1A06 — new file while recording (Feishu: always status=recording + fileId LE @payload[0]).
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.recordStatusId) {
      if (p.payload.length >= 4) {
        final fileId = readU32Le(p.payload, 0);
        if (fileId > 0) {
          _applyRecordStatus(1, fileId: fileId, source: '1A06');
        }
      }
    }

    // Delete
    if (p.cmdType == RxCmd.transportType && p.cmdId == RxCmd.deleteId) {
      statusMessage = p.isSuccess ? '文件已删除' : '删除失败';
      if (p.isSuccess) {
        listFiles();
      }
    }

    // 0x18/0x82 — Feishu onReceiveAudioStatusChanged (not cmdId 6 path):
    // payload[0]: 0=stop, 1=resume/record, 2=pause; stop may include duration u32 @1.
    if (p.cmdType == RxCmd.audioType && p.cmdId == RxCmd.audioControlId) {
      if (p.payload.isNotEmpty) {
        final status = p.payload[0] & 0xFF;
        int? durationSec;
        if (status == 0 && p.payload.length >= 5) {
          durationSec = readU32Le(p.payload, 1);
        }
        // Only apply known statuses; ignore empty ACKs without a status byte meaning.
        if (status == 0 || status == 1 || status == 2) {
          _applyRecordStatus(
            status,
            durationSec: durationSec,
            source: '0x18/0x82',
          );
        }
      }
    }

    // Preserve device-info stopped/recording/paused states independently.
    // Always sync UI so hardware mic-off clears the sticky 「录音中」 pill.
    if (p.cmdType == RxCmd.deviceInfoType && p.cmdId == RxCmd.deviceInfoId) {
      final deviceStatus = info?.recordingStatus ?? 0;
      final deviceRecording = deviceStatus == 1;
      if (deviceStatus != _recordWireStatus && deviceStatus <= 2) {
        _applyRecordStatus(deviceStatus, source: 'device_info');
      } else if (deviceRecording &&
          !realtimeState.active &&
          !isWifiExportSession) {
        unawaited(_maybeStartAutoRealtime(reason: 'device_info_recording'));
      }
    }

    // Binding — Feishu BindingMessageDispatch:
    //  0x87 = bind/unbind command result (successFlag low nibble of status)
    //  0x88 = device confirm after bind (not used for unbind)
    if (p.cmdType == RxCmd.bindType) {
      if (p.cmdId == RxCmd.bindResultId) {
        final ok = p.isSuccess;
        if (_pendingBindRequest == false) {
          // Unbind ACK
          if (ok) {
            bound = false;
            statusMessage = '已解绑（可重新扫描连接）';
            unawaited(_persistDevice());
            // Match Feishu: drop link after successful unbind.
            unawaited(
              Future<void>.delayed(
                const Duration(milliseconds: 400),
                () => disconnect(),
              ),
            );
          } else {
            statusMessage = '解绑失败';
            errorMessage = '解绑失败，请重新连接后重试';
          }
        } else {
          // Bind ACK (or unknown — treat as bind)
          if (ok) {
            bound = true;
            if (activeDevice != null) lastKnownDevice = activeDevice;
            unawaited(_persistDevice());
            statusMessage = '正在绑定…';
            _schedulePostBindFileRefresh();
          } else {
            statusMessage = '绑定失败';
            errorMessage = '绑定失败，请重新连接后重试';
          }
        }
      } else if (p.cmdId == RxCmd.bindConfirmId) {
        if (p.isSuccess) {
          bound = true;
          if (activeDevice != null) lastKnownDevice = activeDevice;
          unawaited(_persistDevice());
          statusMessage = '已绑定';
          _schedulePostBindFileRefresh();
        } else {
          statusMessage = '绑定确认失败';
          errorMessage = '绑定失败，请重新连接后重试';
        }
      }
    }

    // Encrypt handshake RX (type 0x2E id 0x01)
    if (p.cmdType == RxCmd.encryptType && p.cmdId == RxCmd.encryptHandshakeId) {
      _onEncryptResponse(p);
    }

    notifyListeners();
  }

  void _onEncryptResponse(DecodedPacket p) {
    // Feishu EncryptMessageDispatch: need full frame ≥ 106
    // device pubkey @9 (65B), shared @74 (32B)
    final raw = p.raw;
    logs = [
      'ENCRYPT RX ok=${p.isSuccess} len=${raw.length}',
      ...logs,
    ].take(80).toList();
    if (raw.length < 106) {
      if (!(_encryptCompleter?.isCompleted ?? true)) {
        _encryptCompleter!.complete(false);
      }
      return;
    }
    final devPub = Uint8List.fromList(raw.sublist(9, 74));
    final devShared = Uint8List.fromList(raw.sublist(74, 106));
    final ok = _crypto.completeHandshake(
      devicePublicKey: devPub,
      deviceSharedKey: devShared,
    );
    encryptReady = ok;
    if (!(_encryptCompleter?.isCompleted ?? true)) {
      _encryptCompleter!.complete(ok);
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
      unawaited(_deferredJobs.pump());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    archive.removeListener(_onArchiveChanged);
    if (_ownsArchive) archive.dispose();
    _lifecycle?.dispose();
    if (topicsEnabled) topics.removeListener(_onTopicsChanged);
    if (_ownsTopics) topics.dispose();
    _completeFileRefresh();
    _fileJobRevision++;
    _capabilityRevision++;
    _sttLifecycleRevision++;
    _postBindFileRefreshTimer?.cancel();
    _fileListPageTimeout?.cancel();
    _recordingShortcutTimer?.cancel();
    _scanTimeoutTimer?.cancel();
    _boundReconnectTimer?.cancel();
    _stopBatteryPoll();
    for (final s in _subs) {
      s.cancel();
    }
    unawaited(_sttStreamSub?.cancel());
    unawaited(_sttStream?.dispose());
    _opusPcm.dispose();
    unawaited(_player.dispose());
    unawaited(_realtime.dispose());
    analysis.dispose();
    _topicRecommender.dispose();
    _qwenStt.dispose();
    _doubaoStt.dispose();
    _deferredJobs.dispose();
    unawaited(_appleSpeech.dispose());
    _wifi.dispose();
    _ble.dispose();
    super.dispose();
  }
}

class _RecordingSession {
  _RecordingSession(this.id, this.configuration);
  final String id;
  final SpeechConfiguration configuration;
  int? fileId;
  String? path;
  String text = '';
  RecordingTranslation? translation;
  String? error;
  bool ended = false;
  bool active = true;
  bool paused = false;
  bool finalizing = false;
  bool transcriptionComplete = false;
}

/// One cloud engine's wiring into [RecorderController]. [load] reads the
/// engine's credentials from the persisted settings store (engines with a
/// legacy key field read that; grouped engines read the shared trio map),
/// [readSaved]/[applySaved] move the saved overrides in and out of the
/// engine service, [isReady] reports readiness, [snapshot] resolves the
/// credentials a take freezes, [normalizeBaseUrl] validates a pasted
/// origin, and [transcribe] dispatches one file transcription. [grouped]
/// marks engines persisted through the shared `engines` trio map rather
/// than a legacy key field.
class _EngineAdapter {
  const _EngineAdapter({
    required this.load,
    required this.readSaved,
    required this.applySaved,
    required this.isReady,
    required this.snapshot,
    required this.grouped,
    required this.normalizeBaseUrl,
    required this.transcribe,
  });

  final EngineConfig Function(AppSettings settings) load;
  final EngineConfig Function() readSaved;
  final void Function(EngineConfig config) applySaved;
  final bool Function() isReady;
  final EngineConfig Function() snapshot;
  final bool grouped;
  final String Function(String raw) normalizeBaseUrl;

  final Future<SttResult> Function(
    String path,
    EngineConfig engine, {
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  })
  transcribe;
}

/// Local transcript persistence failed after the cloud result was received.
class _TranscriptSaveFailure implements Exception {
  const _TranscriptSaveFailure(this.cause);
  final Object cause;

  @override
  String toString() => 'Transcript save failed: $cause';
}
