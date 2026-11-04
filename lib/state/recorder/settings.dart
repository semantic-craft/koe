part of '../recorder_controller.dart';

/// Settings: loading and saving app settings, speech provider and language
/// choices, cloud engine credentials and adapters, and Apple speech
/// capabilities.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderSettings on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  SpeechConfiguration get _activeConfiguration;
  abstract final AppleSpeechService _appleSpeech;
  abstract final RecordingAnalysis analysis;
  abstract bool _autoTransferRunning;
  abstract final BleFilePull _blePull;
  abstract final CalendarMeetings _calendarMeetings;
  Future<void> refreshPhoneCalendarReminders({DateTime? now});
  Future<String> _convertExportToWav(
    String path, {
    // ignore: unused_element_parameter
    bool register = true,
    // ignore: unused_element_parameter
    List<String>? conversionFailures,
  });
  abstract bool _disposed;
  abstract final DoubaoSttService _doubaoStt;
  bool _isConfigured(SpeechConfiguration config);
  bool get _liveProcessing;
  Future<void> _maybeStartAutoRealtime({required String reason});
  // ignore: unused_field
  abstract bool _preferStreamStt;
  abstract final QwenSttService _qwenStt;
  void _resetTranslationTurns();
  void _revokeCloudLiveStreamIfNeeded();
  String _speechErrorMessage(Object error);
  abstract bool connected;
  abstract final DiarizationModelStore diarizationModels;
  abstract DeviceInfoModel? info;
  abstract bool recording;
  Future<void> refreshFilesOnTabEnter();
  abstract String? transcriptError;
  bool get translationModeAvailable;
  void liveTargetChanged(String language);
  void livePrivacyChanged();
  // END DEPS

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
    analysisBackend = s.analysisBackend;
    analysisOpenAiConfig = s.analysisOpenAiConfig;
    vocabulary = List<String>.unmodifiable(s.vocabulary);
    _savedVocabulary = vocabulary;
    _syncAnalysisModel();
    autoTranscribe = s.autoTranscribe;
    autoRealtime = s.autoRealtime;
    allDayListening = s.allDayListening;
    meetingLocalOnly = s.meetingLocalOnly;
    recordHotKey = s.recordHotKey;
    highlightHotKey = s.highlightHotKey;
    meetingAppPrompts = s.meetingAppPrompts;
    meetingAppPromptsMuted = s.meetingAppPromptsMuted;
    meetingFromCalendar = s.meetingFromCalendar;
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
    if (!speechProvider.supportsMode(sttMode)) {
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
    AnalysisBackendKind? backend,
    EngineConfig? openAiConfig,
    List<String>? nextVocabulary,
    String? vocabularyAddition,
    String? vocabularyRemoval,
  }) {
    final operation = _settingsWriting.then((_) async {
      try {
        final nextBackend = backend ?? analysisBackend;
        final nextOpenAi = openAiConfig ?? analysisOpenAiConfig;
        final committedVocabulary = _savedVocabulary ?? vocabulary;
        final nextVocab = vocabularyAddition != null
            ? _normalizeVocabulary([...committedVocabulary, vocabularyAddition])
            : vocabularyRemoval != null
            ? [
                for (final word in committedVocabulary)
                  if (word.toLowerCase() != vocabularyRemoval) word,
              ]
            : nextVocabulary ?? vocabulary;
        await AppSettingsStore.save(
          AppSettings(
            speechProvider: speechProvider,
            appleSourceLanguage: appleSourceLanguage,
            engines: {
              ..._persistedEngines(),
              if (provider != null) provider.name: config!,
            },
            analysisBackend: nextBackend,
            analysisOpenAiConfig: nextOpenAi,
            vocabulary: nextVocab,
            autoTranscribe: autoTranscribe,
            autoRealtime: autoRealtime,
            allDayListening: allDayListening,
            meetingLocalOnly: meetingLocalOnly,
            recordHotKey: recordHotKey,
            highlightHotKey: highlightHotKey,
            meetingAppPrompts: meetingAppPrompts,
            meetingAppPromptsMuted: meetingAppPromptsMuted,
            meetingFromCalendar: meetingFromCalendar,
            transcriptLanguage: transcriptLanguage,
            sttMode: sttMode,
            translationTargetLanguage: translationTargetLanguage,
            ownerLanguage: ownerLanguage,
            guestLanguage: guestLanguage,
          ),
          strict: true,
        );
        if (provider != null) _engineAdapters[provider]!.applySaved(config!);
        if (backend != null) analysisBackend = backend;
        if (openAiConfig != null) analysisOpenAiConfig = openAiConfig;
        _savedVocabulary = List<String>.unmodifiable(nextVocab);
        if (nextVocabulary != null ||
            vocabularyAddition != null ||
            vocabularyRemoval != null) {
          vocabulary = _savedVocabulary!;
        }
        _syncAnalysisModel();
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

  bool get appleTranslationAvailable =>
      appleSourceLanguage.isNotEmpty &&
      appleCapabilities.supported &&
      appleCapabilities.translationStatus == SpeechResourceStatus.ready &&
      !appleCapabilitiesLoading;

  bool get conversationModeAvailable => false;

  /// The engines this device can offer, in lineup order.
  List<SttProvider> get speechProviders => [
    for (final provider in SttProvider.available)
      if (!provider.onDevice || _appleSpeech.offered) provider,
  ];

  /// Whether this device currently offers a supported on-device speech engine.
  bool get onDeviceSpeechSupported => appleCapabilities.supported;

  Future<bool> downloadDiarizationModels() => diarizationModels.download();

  Future<void> pauseDiarizationModels() => diarizationModels.pause();

  Future<void> deleteDiarizationModels() => diarizationModels.delete();

  /// Why a meeting recording cannot be transcribed locally when
  /// [meetingLocalOnly] is on and no on-device engine is ready.
  String get meetingLocalOnlyUnavailableMessage => !onDeviceSpeechSupported
      ? '已开启「录音只留本机」，此设备暂无可用的本机语音引擎，不会回落到云端'
      : '请在设置中选择并下载本机识别语言';

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
    if (!provider.supportsMode(sttMode)) {
      sttMode = SttDisplayMode.transcription;
    }
    notifyListeners();
    unawaited(_persistSettings());
    if (provider.onDevice) unawaited(refreshAppleCapabilities());
  }

  void setAppleSourceLanguage(String language) {
    final code = language.trim();
    if (appleSourceLanguage == code) return;
    appleSourceLanguage = code;
    unawaited(refreshAppleCapabilities());
    unawaited(_persistSettings());
  }

  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  SpeechConfiguration _configurationForProvider(
    SttProvider provider, {
    String? sourceLanguage,
    bool cloudUploadConfirmed = false,
  }) {
    final source = provider.requiresSourceLanguage
        ? (sourceLanguage?.trim().isNotEmpty == true
              ? sourceLanguage!.trim()
              : (appleSourceLanguage.isNotEmpty
                    ? appleSourceLanguage
                    : (appleCapabilities.suggestedSourceLanguage ?? '')))
        : (sourceLanguage?.trim().isNotEmpty == true
              ? sourceLanguage!.trim()
              : transcriptLanguage);
    final ready =
        onDeviceSpeechSupported &&
        source.isNotEmpty &&
        appleCapabilities.speechStatus == SpeechResourceStatus.ready &&
        !appleCapabilitiesLoading;
    return SpeechConfiguration(
      provider: provider,
      sourceLanguage: source,
      targetLanguage: translationTargetLanguage,
      ownerLanguage: ownerLanguage,
      guestLanguage: guestLanguage,
      mode: provider.supportsMode(sttMode)
          ? sttMode
          : SttDisplayMode.transcription,
      enabled: autoTranscribe,
      appleReady: ready,
      appleTranslationReady:
          onDeviceSpeechSupported && appleTranslationAvailable,
      engines: provider.onDevice
          ? const {}
          : {
              for (final entry in _engineAdapters.entries)
                entry.key: entry.value.snapshot(),
            },
      cloudUploadConfirmed: cloudUploadConfirmed,
    );
  }

  SpeechConfiguration get _settingsConfiguration => SpeechConfiguration(
    provider: speechProvider,
    sourceLanguage: speechProvider.requiresSourceLanguage
        ? appleSourceLanguage
        : transcriptLanguage,
    targetLanguage: translationTargetLanguage,
    ownerLanguage: ownerLanguage,
    guestLanguage: guestLanguage,
    mode: speechProvider.supportsMode(sttMode)
        ? sttMode
        : SttDisplayMode.transcription,
    enabled: autoTranscribe,
    appleReady: appleSpeechReady,
    appleTranslationReady: appleTranslationAvailable,
    engines: {
      for (final entry in _engineAdapters.entries)
        entry.key: entry.value.snapshot(),
    },
  );

  /// Speech configuration for meeting / formal recordings (#376).
  ///
  /// When [meetingLocalOnly] is on, only an [SttProvider.onDevice] engine may
  /// run and no cloud credentials are carried in the snapshot; if this device
  /// has no available on-device engine, the configuration stays unconfigured
  /// rather than falling back to a cloud service.
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  SpeechConfiguration get _meetingConfiguration => meetingLocalOnly
      ? _configurationForProvider(SttProvider.apple)
      : _settingsConfiguration;

  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  bool get _activeSttConfigured => _isConfigured(_activeConfiguration);
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  bool get _activeAutoTranscribe => _activeConfiguration.enabled;
  String get activeTranslationTargetLanguage =>
      _activeConfiguration.targetLanguage;
  String get activeOwnerLanguage => _activeConfiguration.ownerLanguage;
  String get activeGuestLanguage => _activeConfiguration.guestLanguage;

  void setAutoTranscribe(bool v) {
    autoTranscribe = v;
    if (!v) {
      sttMode = SttDisplayMode.transcription;
      if (!_liveProcessing) _resetTranslationTurns();
    }
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setAllDayListening(bool v) {
    allDayListening = v;
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setRecordHotKey(bool v) {
    recordHotKey = v;
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setHighlightHotKey(bool v) {
    highlightHotKey = v;
    notifyListeners();
    unawaited(_persistSettings());
  }

  void setMeetingAppPrompts(bool v) {
    meetingAppPrompts = v;
    notifyListeners();
    unawaited(_persistSettings());
  }

  /// 不再提醒 for the meeting app [app], by bundle ID (#406).
  void muteMeetingApp(String app) {
    if (meetingAppPromptsMuted.contains(app)) return;
    meetingAppPromptsMuted = [...meetingAppPromptsMuted, app];
    notifyListeners();
    unawaited(_persistSettings());
  }

  void unmuteMeetingApp(String app) {
    meetingAppPromptsMuted = [
      for (final muted in meetingAppPromptsMuted)
        if (muted != app) muted,
    ];
    notifyListeners();
    unawaited(_persistSettings());
  }

  /// Turning it on asks for calendar access, which the system does only the
  /// first time.
  void setMeetingFromCalendar(bool v) {
    meetingFromCalendar = v;
    notifyListeners();
    unawaited(_persistSettings());
    if (v) {
      unawaited(
        _calendarMeetings.requestAccess().then((_) {
          unawaited(refreshPhoneCalendarReminders());
        }),
      );
    } else {
      unawaited(refreshPhoneCalendarReminders());
    }
  }

  void setMeetingLocalOnly(bool v) {
    if (meetingLocalOnly == v) return;
    meetingLocalOnly = v;
    if (v) {
      _revokeCloudLiveStreamIfNeeded();
      livePrivacyChanged();
    }
    notifyListeners();
    unawaited(_persistSettings());
    if (v) unawaited(refreshAppleCapabilities());
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
  EngineConfig engineConfig(SttProvider provider) =>
      _engineAdapters[provider]?.readSaved() ?? const EngineConfig();

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

  AnalysisBackendKind analysisBackend = AnalysisBackendKind.qwen;
  EngineConfig analysisOpenAiConfig = const EngineConfig();
  List<String> vocabulary = const [];
  List<String>? _savedVocabulary;

  String get vocabularyPromptHint => vocabulary.isEmpty
      ? ''
      : '个人词汇表（专有名词、人名、术语，优先采用正确写法）：${vocabulary.join('、')}';

  static List<String> _normalizeVocabulary(Iterable<String> raw) {
    final seen = <String>{};
    final result = <String>[];
    for (final item in raw) {
      final trimmed = item.trim();
      if (trimmed.isEmpty || trimmed.runes.length > 40) continue;
      if (seen.add(trimmed.toLowerCase())) {
        result.add(trimmed);
      }
    }
    return List<String>.unmodifiable(result);
  }

  Future<void> setVocabulary(Iterable<String> terms) {
    final normalized = _normalizeVocabulary(terms);
    vocabulary = normalized;
    notifyListeners();
    return _persistSettings(nextVocabulary: normalized);
  }

  Future<void> addVocabularyTerm(String term) {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return SynchronousFuture<void>(null);
    return _persistSettings(vocabularyAddition: trimmed);
  }

  /// Local term adoption needs durable success, unlike best-effort settings UI.
  Future<void> addVocabularyTermStrict(String term) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 40) {
      throw const FormatException('词表名称须为 1–40 个字');
    }
    // Persist even when memory already contains the word: a prior best-effort
    // settings write may have failed before this explicit adoption.
    await _persistSettings(strict: true, vocabularyAddition: trimmed);
  }

  Future<void> removeVocabularyTerm(String term) {
    final target = term.trim().toLowerCase();
    if (target.isEmpty) return SynchronousFuture<void>(null);
    return _persistSettings(vocabularyRemoval: target);
  }

  void _syncAnalysisModel() {
    if (analysisBackend == AnalysisBackendKind.openaiCompatible) {
      final m = _blankToNull(analysisOpenAiConfig.model);
      if (m != null) analysis.model = m;
    } else if (analysisBackend == AnalysisBackendKind.qwen) {
      if (analysis.model == null ||
          analysis.model == analysisOpenAiConfig.model) {
        analysis.model = 'qwen3.8-flash';
      }
    }
  }

  Future<void> setAnalysisBackend(AnalysisBackendKind backend) {
    if (analysisBackend == backend) return SynchronousFuture<void>(null);
    analysisBackend = backend;
    _syncAnalysisModel();
    notifyListeners();
    return _persistSettings(backend: backend);
  }

  Future<void> setAnalysisOpenAiConfig(EngineConfig config) {
    final apiKey = _blankToNull(config.apiKey);
    final model = _blankToNull(config.model);
    final rawBaseUrl = _blankToNull(config.baseUrl);
    final baseUrl = rawBaseUrl == null
        ? null
        : normalizeOpenAiCompatibleBaseUrl(rawBaseUrl);
    final normalized = EngineConfig(
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
    );
    analysisOpenAiConfig = normalized;
    _syncAnalysisModel();
    notifyListeners();
    return _persistSettings(strict: true, openAiConfig: normalized);
  }

  bool get sttConfigured =>
      _settingsReady && _isConfigured(_settingsConfiguration);

  void setSttMode(SttDisplayMode mode) {
    if (!speechProvider.supportsMode(mode)) return;
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
    liveTargetChanged(normalized);
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

  // Used by other parts through their abstract declarations.
  // ignore: unused_field
  late final Future<void> _settingsLoaded;
  // Used by other parts through their abstract declarations.
  // ignore: prefer_final_fields
  bool _settingsReady = false;

  /// Auto BLE realtime transfer while device is recording (no SoftAP).
  bool autoRealtime = true;

  /// The record buttons start all-day, text-only listening (#319).
  bool allDayListening = false;

  /// Meeting / formal recordings stay on the device (#376).
  bool meetingLocalOnly = true;

  /// On the Mac, ⌃⌥⌘R starts or stops a take from any app (#405).
  bool recordHotKey = true;

  /// On the Mac, ⌃⌥⌘B marks a highlight from any app while a take or text
  /// capture runs (#405).
  bool highlightHotKey = true;

  /// On the Mac, asks to record when a meeting app takes the microphone,
  /// and to stop when the meeting is over (#406).
  bool meetingAppPrompts = true;

  /// The meeting apps, by bundle ID, the user chose 不再提醒 for.
  List<String> meetingAppPromptsMuted = const [];

  /// On the Mac, names a microphone take after the calendar meeting it was
  /// recorded in and gives its invitees to the minutes (#407).
  bool meetingFromCalendar = true;

  /// Near-realtime AI transcription (PCM WS stream + Ogg batch fallback).
  bool autoTranscribe = true;

  String transcriptLanguage = 'auto';
  SttDisplayMode sttMode = SttDisplayMode.transcription;
  String translationTargetLanguage = 'zh';
  String ownerLanguage = 'zh';
  String guestLanguage = 'en';

  /// How every credentialed engine keeps its credentials: loading and
  /// saving them, readiness, and the resolved snapshot a take freezes.
  /// Running speech goes through [_sttEngines]; adding a cloud engine is a
  /// service plus one entry in each map.
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
    ),
  };

  /// How each available engine runs a file job and a live stream. Retired
  /// engines have no entry.
  // Used by other parts through their abstract declarations.
  // ignore: unused_field
  late final Map<SttProvider, _SttEngine> _sttEngines = {
    SttProvider.apple: _SttEngine(
      // Speakers are labelled on this device afterwards, with the number of
      // people the recording carries.
      transcribe:
          (path, config, {expectedSpeakers, onProgress, isCurrent}) async {
            final wavPath = await _convertExportToWav(path);
            if (isCurrent != null && !isCurrent()) {
              throw PlatformException(code: 'cancelled');
            }
            if (!wavPath.endsWith('.wav')) {
              throw PlatformException(code: 'audio_invalid');
            }
            return _appleSpeech.transcribePath(
              wavPath,
              sourceLanguage: config.sourceLanguage,
              onProgress: onProgress,
            );
          },
      openStream: (config) => _appleSpeech.createStreamSession(
        sourceLanguage: config.sourceLanguage,
        targetLanguage:
            config.mode == SttDisplayMode.translation &&
                config.appleTranslationReady
            ? config.targetLanguage
            : null,
      ),
    ),
    SttProvider.qwen: _SttEngine(
      transcribe: (path, config, {expectedSpeakers, onProgress, isCurrent}) {
        final engine = config.engineConfig(SttProvider.qwen);
        return _qwenStt.transcribePath(
          path,
          apiKey: engine.apiKey,
          baseUrl: engine.baseUrl,
          model: engine.model,
          language: _cloudLanguage(config),
          expectedSpeakers: expectedSpeakers,
          onProgress: onProgress,
          isCurrent: isCurrent,
        );
      },
      openStream: (config) {
        final engine = config.engineConfig(SttProvider.qwen);
        return QwenSttStreamSession(
          apiKey: engine.apiKey!,
          baseUrl: engine.baseUrl,
          language: config.sourceLanguage,
        );
      },
    ),
    SttProvider.doubao: _SttEngine(
      // The service maps ISO short codes (`zh`) to Volcano BCP-47 (`zh-CN`).
      transcribe: (path, config, {expectedSpeakers, onProgress, isCurrent}) {
        final engine = config.engineConfig(SttProvider.doubao);
        return _doubaoStt.transcribePath(
          path,
          apiKey: engine.apiKey,
          baseUrl: engine.baseUrl,
          model: engine.model,
          language: _cloudLanguage(config),
          onProgress: onProgress,
          isCurrent: isCurrent,
        );
      },
      openStream: (config) {
        final engine = config.engineConfig(SttProvider.doubao);
        return DoubaoSttStreamSession(
          apiKey: engine.apiKey!,
          baseUrl: engine.baseUrl,
          language: config.sourceLanguage,
        );
      },
    ),
  };

  static String? _cloudLanguage(SpeechConfiguration config) =>
      config.sourceLanguage == 'auto' ? null : config.sourceLanguage;

  SttProvider speechProvider = SttProvider.qwen;
  String appleSourceLanguage = '';
  AppleSpeechCapabilities appleCapabilities =
      const AppleSpeechCapabilities.unsupported();
  bool appleCapabilitiesLoading = false;
  bool appleLanguagePreparationBusy = false;
  String? appleSetupError;
  int _capabilityRevision = 0;

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// The engine's resolved origin, or its default when the saved value is
  /// invalid (snapshots must never throw on bad settings).
  static String _resolveSnapshotBaseUrl(CloudFileSttService service) {
    try {
      return service.baseUrl;
    } on CloudSttException {
      return service.fallbackBaseUrl;
    }
  }
}
