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
part 'recorder/settings.dart';
part 'recorder/device.dart';

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
        _RecorderLiveTranscription,
        _RecorderSettings,
        _RecorderDevice {
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

  @override
  final BleService _ble;
  @override
  final PersistedDeviceLoader _persistedDeviceLoader;
  @override
  final Duration recordingShortcutScanTimeout;
  @override
  late final Future<void> _persistedDeviceLoaded;
  @override
  final DeviceCrypto _crypto = DeviceCrypto();
  @override
  late final WifiExportService _wifi;
  @override
  late final RealtimeBleStream _realtime;
  @override
  late final BleFilePull _blePull;
  @override
  final AudioPlayer _player;
  @override
  final List<StreamSubscription> _subs = [];

  @override
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
  @override
  bool get blocksRecordingControl =>
      phase == AppPhase.busy && !_autoTransferRunning;

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

  @override
  final AppleSpeechService _appleSpeech;
  @override
  bool _disposed = false;
  @override
  String? statusMessage;
  @override
  String? errorMessage;

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
  @override
  bool get isExporting =>
      exportProgress.phase != ExportPhase.idle &&
      exportProgress.phase != ExportPhase.done &&
      exportProgress.phase != ExportPhase.error &&
      exportProgress.phase != ExportPhase.awaitJoin;

  /// SoftAP open succeeded; waiting for user to join network.
  @override
  bool get needsWifiJoin => exportProgress.phase == ExportPhase.awaitJoin;

  /// Any active Wi‑Fi export session (opening SoftAP → transfer → closing).
  /// Used to avoid yanking the user back to Scan when BLE drops mid-export.
  @override
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

  @override
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

  @override
  Future<void> _startCurrentRecordingTransfer(int fileId) async {
    _bindCurrentRecording(fileId: fileId);
    await _yieldAutoTransfer();
    if (!connected || !_ble.isConnected) return;
    if (!recording && info?.recording != true) return;
    await _realtime.startForFile(fileId);
  }

  @override
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

  @override
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

  @override
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
  @override
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
  @override
  List<OfflineFileEntry> _sortFilesNewestFirst(List<OfflineFileEntry> list) {
    final copy = List<OfflineFileEntry>.from(list);
    copy.sort((a, b) {
      final ta = a.endTime ?? a.fileId;
      final tb = b.endTime ?? b.fileId;
      return tb.compareTo(ta);
    });
    return copy;
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
