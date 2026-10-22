import '../platform/credential_store.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:http/http.dart' as http;
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
import '../audio/recording_audio.dart';
import '../archive/mac_archive_controller.dart';
import '../archive/archive_store.dart';
import '../archive/archive_wire.dart';
import '../ble/ble_service.dart';
import '../ble/ble_file_pull.dart';
import '../ble/realtime_stream.dart';
import '../crypto/device_crypto.dart';
import '../platform/answer_speaker.dart';
import '../platform/background_sync_service.dart';
import '../platform/phone_mic_stream.dart';
import '../platform/phone_recorder.dart';
import '../platform/place_capture.dart';
import '../platform/system_tasks.dart';
import '../protocol/commands.dart';
import '../protocol/frame.dart';
import '../protocol/models.dart';
import '../protocol/slice_marks.dart';
import '../wifi/wifi_export_service.dart';
import 'app_settings_store.dart';
import 'context/commitments.dart';
import 'context/ask_retrieval.dart';
import 'context/ask_store.dart';
import 'context/context_export.dart';
import 'context/context_store.dart';
import 'context/diary_store.dart';
import 'context/project_store.dart';
import 'context/todo_store.dart';
import 'context/todo_system_sync.dart';
import 'device_store.dart';
import 'export_catalog.dart';
import 'organize_store.dart';
import 'transcript_store.dart';
import 'recording.dart';
import 'recording_analysis.dart';
import 'recording_library.dart';
import 'listening_queue.dart';
import 'atomic_file.dart';
import 'material_pack.dart';
import 'minutes_document.dart';
import 'playback_history.dart';
import 'recording_bookmarks.dart';
import 'speech_configuration.dart';
import 'text_capture_spool.dart';
import 'deferred_file_jobs.dart';
import 'device_copies.dart';
import 'file_job_journal.dart';
import 'topic_store.dart';
import 'topic_note.dart';
import 'topic_summary.dart';
import '../platform/device_kind.dart';

export 'context/context_store.dart';
export 'context/todo_store.dart';
export 'context/project_store.dart';
export 'context/diary_store.dart';
export 'context/ask_store.dart';
export 'context/context_export.dart';
export '../platform/system_tasks.dart';
export 'device_copies.dart' show DeviceCopies, DeviceCopyStatus;
export 'recording.dart';
export 'recording_library.dart';
export 'listening_queue.dart';
export 'material_pack.dart';
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
part 'recorder/organize.dart';
part 'recorder/phone_recording.dart';
part 'recorder/voice_input.dart';
part 'recorder/text_capture.dart';
part 'recorder/context.dart';
part 'recorder/todos.dart';
part 'recorder/projects.dart';
part 'recorder/diary.dart';
part 'recorder/ask.dart';
part 'recorder/brief.dart';
part 'recorder/context_export.dart';
part 'recorder/material_pack.dart';
part 'recorder/archive.dart';
part 'recorder/topics.dart';
part 'recorder/transcription_jobs.dart';
part 'recorder/transcripts.dart';
part 'recorder/live_transcription.dart';
part 'recorder/settings.dart';
part 'recorder/device.dart';
part 'recorder/device_files.dart';

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
        _RecorderOrganize,
        _RecorderPhoneRecording,
        _RecorderVoiceInput,
        _RecorderTextCapture,
        _RecorderContext,
        _RecorderTodos,
        _RecorderProjects,
        _RecorderDiary,
        _RecorderAsk,
        _RecorderBrief,
        _RecorderContextExport,
        _RecorderMaterialPack,
        _RecorderArchive,
        _RecorderTopics,
        _RecorderTranscriptionJobs,
        _RecorderTranscripts,
        _RecorderLiveTranscription,
        _RecorderSettings,
        _RecorderDevice,
        _RecorderDeviceFiles {
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
  @override
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
  bool _takenAsVoiceNote(String? path) =>
      path != null && (library.assetForPath(path)?.voiceNote ?? false);

  /// Whether [path] is treated as a meeting/formal recording (#376).
  ///
  /// Only hold-to-talk voice notes ([RecordingAsset.voiceNote]) are daily
  /// voice input; all other recordings, imports, device files and legacy
  /// records without a persisted flag are conservatively treated as meeting
  /// recordings.
  bool isMeetingRecording(String? path) => !_takenAsVoiceNote(path);

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
    DeviceCopies? deviceCopies,
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
    OrganizeStore? organizeStore,
    PhoneRecorder? phoneRecorder,
    PhoneMicStream? micStream,
    SttStreamSession Function(SpeechConfiguration config)? speechStream,
    AnswerSpeaker? answerSpeaker,
    bool? phoneRecordingEnabled,
    MinutesDocumentStore? minutesStore,
    TranscriptPersister? transcriptPersister,
    PlaybackHistoryStore? playbackHistoryStore,
    ListeningQueueStore? listeningQueueStore,
    RecordingBookmarkStore? bookmarkStore,
    AudioPlayer? player,
    MacArchiveController? archiveController,
    ArchivePhoneStore? archivePhoneStore,
    ArchiveDeskStore? archiveDeskStore,
    ContextStore? contextStore,
    TodoStore? todoStore,
    ProjectStore? projectStore,
    DiaryStore? diaryStore,
    AskStore? askStore,
    SystemTasks? systemTasks,
    AnalysisService? contextAnalysisService,
    bool meetingLocalOnly = true,
  }) : _analysisOverride = analysisController,
       _topicRecommendationOverride = topicRecommendationService,
       topicsEnabled = topicsEnabled ?? runsOnPhone,
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
       _phoneRecorderOverride = phoneRecorder,
       _micStreamOverride = micStream,
       _speechStreamOverride = speechStream,
       answerSpeaker = answerSpeaker ?? SystemAnswerSpeaker(),
       phoneRecordingEnabled =
           phoneRecordingEnabled ?? (runsOnPhone || runsOnMac),
       // Keep the injection seam public while the field stays private.
       // ignore: prefer_initializing_formals
       _transcriptPersister = transcriptPersister,
       _player = player ?? AudioPlayer() {
    this.meetingLocalOnly = meetingLocalOnly;
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
    _phoneTakesRecovered = _recoverInterruptedPhoneTakes();
    this.organizeStore =
        organizeStore ?? OrganizeStore(inMemory: !loadPersistedState);
    _ownsContextItems = contextStore == null;
    contextItems = contextStore ?? ContextStore(inMemory: !loadPersistedState);
    contextItems.addListener(notifyListeners);
    unawaited(contextItems.load());
    _contextServiceOverride = contextAnalysisService;
    _ownsTodos = todoStore == null;
    todos = todoStore ?? TodoStore(inMemory: !loadPersistedState);
    todos.addListener(notifyListeners);
    unawaited(todos.load());
    _todoSync = TodoSystemSync(
      todos,
      systemTasks ?? const ChannelSystemTasks(),
    );
    _ownsProjects = projectStore == null;
    projects = projectStore ?? ProjectStore(inMemory: !loadPersistedState);
    projects.addListener(notifyListeners);
    unawaited(projects.load());
    _ownsDiary = diaryStore == null;
    diary = diaryStore ?? DiaryStore(inMemory: !loadPersistedState);
    diary.addListener(notifyListeners);
    unawaited(diary.load());
    _ownsAsks = askStore == null;
    asks = askStore ?? AskStore(inMemory: !loadPersistedState);
    asks.addListener(notifyListeners);
    unawaited(asks.load());
    if (loadPersistedState) {
      _todoLifecycle = AppLifecycleListener(
        onResume: () => unawaited(syncSystemLinks()),
      );
    }
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
          _markInterruptedLiveTake();
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
      // No screen renders these lines. Notifying here rebuilt every listener
      // once per BLE packet during retrieval and live recording.
      _ble.logs.listen((m) {
        logs = [m, ...logs].take(80).toList();
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
      onMark: (fileId, sequence) => _onDeviceMark(fileId, sequence, live: true),
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
    _copies = (deviceCopies ?? DeviceCopies(inMemory: !loadPersistedState))
      ..bind(_ControllerCopyContext(this));
    unawaited(_copies.load());
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
    if (this.phoneRecordingEnabled) {
      // Text-only captures cut off by a crash, or stopped without network,
      // still have speech to recognize.
      unawaited(
        Future.wait([_settingsLoaded, _minutesLoaded]).then((_) async {
          await _recoverTextCaptures();
          await _resumeAllDayListening();
        }),
      );
    }
    _organizeLoaded = _loadOrganize();
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
          isDesk: runsOnMac,
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

  bool _ownsContextItems = true;
  bool _ownsTodos = true;
  bool _ownsProjects = true;
  bool _ownsDiary = true;
  bool _ownsAsks = true;
  AppLifecycleListener? _todoLifecycle;

  /// Whether topic notes (#49) are active. First version: iPhone only.
  @override
  final bool topicsEnabled;
  @override
  final Directory? _libraryDirectoryOverride;
  @override
  final PlaceCapture _placeCapture;
  final PhoneRecorder? _phoneRecorderOverride;
  PhoneRecorder? _devicePhoneRecorder;
  @override
  PhoneRecorder get _phoneRecorder =>
      _phoneRecorderOverride ??
      (_devicePhoneRecorder ??= DevicePhoneRecorder());
  final PhoneMicStream? _micStreamOverride;
  PhoneMicStream? _deviceMicStream;
  @override
  PhoneMicStream get _micStream =>
      _micStreamOverride ?? (_deviceMicStream ??= DevicePhoneMicStream());

  /// Test seam: replaces the configured engine's live recognition stream.
  @override
  final SttStreamSession Function(SpeechConfiguration config)?
  _speechStreamOverride;

  /// Reads Ask Koe answers aloud when the user turns it on.
  final AnswerSpeaker answerSpeaker;

  /// Phone microphone takes are an iPhone feature; the Mac reads and archives.
  @override
  final bool phoneRecordingEnabled;
  late final Future<void> _phoneTakesRecovered;

  @visibleForTesting
  Future<void> waitForPhoneTakeRecovery() => _phoneTakesRecovered;

  /// How long a retrieved WAV must keep the same size and modification time
  /// before it can be submitted; see [incompleteRetrievedAudioReason].
  @override
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
  @override
  final Duration blePullInactivityTimeout;

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
    final translated = readingLive ? session.translation : savedTranslation;
    // An old translation stays readable after its source changes, marked as
    // such, so the user can compare and regenerate it.
    final translationStale =
        !readingLive &&
        savedTranslation != null &&
        (metadata == null ||
            savedTranslation.sourceRevision != metadata.revision ||
            (savedTranslation.sourceDigest != null &&
                savedTranslation.sourceDigest != transcriptSourceDigest(text)));
    final asset = path == null ? null : library.assetForPath(path);
    final archiveRecord = path == null ? null : archive.recordForPath(path);
    final title = path == null
        ? (id == null ? '当前录音' : _recordingDateTitle(id))
        : _recordingTitleForPath(path, archiveName: archiveRecord?.displayName);
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
    final defaultConfig = _takenAsVoiceNote(path)
        ? _settingsConfiguration
        : _meetingConfiguration;
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
      translationStale: translated != null && translationStale,
      sourceLanguage:
          metadata?.sourceLanguage ?? session?.configuration.sourceLanguage,
      mode: session?.configuration.mode ?? SttDisplayMode.transcription,
      provider:
          metadata?.provider ??
          session?.configuration.provider ??
          defaultConfig.provider,
      transcriptionEnabled: session?.configuration.enabled ?? autoTranscribe,
      speechReady: _isConfigured(
        session?.configuration ?? defaultConfig,
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
          (asset?.originalComplete ?? true) && !_copies.isPartial(id),
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

  /// The one title a local recording shows everywhere: the name the user or
  /// the import gave it, else a renamed file's label, else the recording time
  /// read from the device file id.
  ///
  /// A stored name that is only this file's own name (`1792377669.wav`) says
  /// nothing and is skipped: older builds wrote it when adding a place or
  /// moving a recording to the trash created the library entry (#232).
  @override
  String _recordingTitleForPath(String path, {String? archiveName}) {
    final id = fileIdFromPath(path);
    final ownNames = {
      p.basename(path),
      p.basenameWithoutExtension(path),
      if (id != null) '$id',
    };
    for (final stored in [
      library.assetForPath(path)?.displayName,
      archiveName,
    ]) {
      final name = stored?.trim() ?? '';
      if (name.isNotEmpty && !ownNames.contains(name)) return name;
    }
    final label = ExportCatalog.editableLabelFromPath(path).trim();
    if (label.isNotEmpty) return label;
    return id == null ? '当前录音' : _recordingDateTitle(id);
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

  @override
  final TranscriptPersister? _transcriptPersister;

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

  @visibleForTesting
  Future<void> waitForRecordingLibrary() => _libraryLoaded;

  /// Moving a material to the trash keeps the original file, transcript,
  /// speaker names, topics and notes. Only its visibility is changed.
  static const trashRetention = Duration(days: 30);

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

  @override
  String? localPathFor(int fileId) => localPathsByFileId[fileId];

  @override
  int? fileIdFromPath(String path) => _fileIdFromPath(path);

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
    removeListener(_scheduleOrganize);
    unawaited(_phoneMicStates?.cancel());
    unawaited(_devicePhoneRecorder?.dispose());
    _disposeTextCapture();
    unawaited(_deviceMicStream?.dispose());
    archive.removeListener(_onArchiveChanged);
    if (_ownsArchive) archive.dispose();
    contextItems.removeListener(notifyListeners);
    if (_ownsContextItems) contextItems.dispose();
    todos.removeListener(notifyListeners);
    if (_ownsTodos) todos.dispose();
    projects.removeListener(notifyListeners);
    if (_ownsProjects) projects.dispose();
    diary.removeListener(notifyListeners);
    if (_ownsDiary) diary.dispose();
    asks.removeListener(notifyListeners);
    if (_ownsAsks) asks.dispose();
    _todoLifecycle?.dispose();
    _disposeContextServices();
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

  /// Taken during all-day listening (#319): its text lives in text records,
  /// so the take itself is not transcribed or organized again.
  bool textOnly = false;
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
/// What [DeviceCopies] reads from the controller.
class _ControllerCopyContext implements DeviceCopyContext {
  _ControllerCopyContext(this._c);
  final RecorderController _c;

  @override
  String? localPathFor(int fileId) => _c.localPathFor(fileId);

  @override
  bool isDismissed(int fileId) => _c.library.assets.any(
    (asset) =>
        asset.trashed && ExportCatalog.fileIdFromPath(asset.path) == fileId,
  );

  @override
  int get recorderStatus => _c.info?.recordingStatus ?? 0;

  @override
  int? get currentRecordingFileId => _c._currentRecording?.fileId;

  @override
  bool isAudioLocked(int? fileId, String? path) =>
      _c._isRecordingAudioLocked(fileId, path);
}

class _EngineAdapter {
  const _EngineAdapter({
    required this.load,
    required this.readSaved,
    required this.applySaved,
    required this.isReady,
    required this.snapshot,
    required this.grouped,
    required this.normalizeBaseUrl,
  });

  final EngineConfig Function(AppSettings settings) load;
  final EngineConfig Function() readSaved;
  final void Function(EngineConfig config) applySaved;
  final bool Function() isReady;
  final EngineConfig Function() snapshot;
  final bool grouped;
  final String Function(String raw) normalizeBaseUrl;
}

/// How every available engine, Apple included, runs speech: a recorded
/// file and a live stream, both from the configuration a take or job froze.
class _SttEngine {
  const _SttEngine({required this.transcribe, required this.openStream});

  final Future<SttResult> Function(
    String path,
    SpeechConfiguration config, {
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  })
  transcribe;
  final SttStreamSession Function(SpeechConfiguration config) openStream;
}

/// Local transcript persistence failed after the cloud result was received.
class _TranscriptSaveFailure implements Exception {
  const _TranscriptSaveFailure(this.cause);
  final Object cause;

  @override
  String toString() => 'Transcript save failed: $cause';
}
