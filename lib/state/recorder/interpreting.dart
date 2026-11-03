part of '../recorder_controller.dart';

mixin _RecorderInterpreting on ChangeNotifier {
  // Provided by controller / settings / recording parts.
  RecordingAnalysis get analysis;
  LiveMinutesStore get liveMeetingStore;
  bool get analysisConfigured;
  String get analysisApiKey;
  AnalysisBackendKind get analysisBackend;
  EngineConfig get analysisOpenAiConfig;
  QwenSttService get _qwenStt;
  String get appleSourceLanguage;
  String get translationTargetLanguage;
  bool get phoneRecordingActive;
  bool get textCaptureActive;
  bool get textCaptureFromDevice;
  VoiceTarget? get voiceHoldTarget;
  // END DEPS
  MacInterpretingState? interpreting;
  int _microphoneTransitions = 0;
  bool _autoEnabling = false;
  bool get interpretingCanInstall =>
      !_autoEnabling &&
      _microphoneTransitions == 0 &&
      !phoneRecordingActive &&
      (!textCaptureActive || textCaptureFromDevice) &&
      voiceHoldTarget == null;
  void _initInterpreting() {
    if (!runsOnMac) return;
    late final MacInterpretingState state;
    state = MacInterpretingState(
      bridge: MacInterpreting(),
      store: liveMeetingStore,
      configuration: () => [
        analysisBackend.name,
        analysisOpenAiConfig.baseUrl ?? '',
        _qwenStt.baseUrl,
        analysis.model ?? '',
        state.sourceLanguage,
        state.targetLanguage,
      ].join('|'),
      translate: (source, abort, current) => analysis.runTranslation(
        source: source,
        instruction:
            '将${state.sourceLanguage}原文翻译为${state.targetLanguage}，仅返回译文。',
        selectedModel: analysis.model ?? 'qwen3.8-flash',
        apiKey: analysisApiKey,
        abort: abort,
        isCurrent: current,
      ),
    );
    String language(String value, String fallback) {
      final base = value.split('-').first;
      if (base == 'zh') return 'zh-CN';
      return const ['en', 'ja', 'ko', 'fr', 'de', 'es'].contains(base)
          ? base
          : fallback;
    }

    state.sourceLanguage = language(appleSourceLanguage, 'zh-CN');
    state.targetLanguage = language(translationTargetLanguage, 'en');
    if (state.sourceLanguage == state.targetLanguage) {
      state.targetLanguage = state.sourceLanguage == 'en' ? 'zh-CN' : 'en';
    }
    interpreting = state;
    state.addListener(notifyListeners);
    addListener(state.configurationChanged);
    analysis.addListener(state.configurationChanged);
  }

  Future<void> enableInterpreting(
    String input,
    String output,
    bool automatic,
  ) async {
    final state = interpreting;
    if (state == null) return;
    if (!analysisConfigured) {
      state.message = '请先配置文字分析服务';
      notifyListeners();
      return;
    }
    if (state.sourceLanguage.split('-').first ==
        state.targetLanguage.split('-').first) {
      state.message = '源语种与目标语种必须不同';
      notifyListeners();
      return;
    }
    if (automatic && !interpretingCanInstall) {
      state.message = '麦克风正在使用或切换，请结束后启用自动输入，或使用手动路由';
      notifyListeners();
      return;
    }
    if (_autoEnabling) return;
    _autoEnabling = automatic;
    try {
      await state.enable(input: input, output: output, automatic: automatic);
    } finally {
      _autoEnabling = false;
    }
  }

  /// Reservation precedes every await, including permission and native shutdown.
  Future<T> withMicrophoneTransition<T>(
    Future<T> Function() operation, {
    bool starting = false,
  }) async {
    if (starting && _autoEnabling) throw StateError('同传正在切换输入，请稍后重试');
    _microphoneTransitions++;
    try {
      final state = interpreting;
      if (starting && state != null) {
        if (state.autoInput) await state.disable();
        await state.bridge.call('prepareCapture');
      }
      return await operation();
    } finally {
      _microphoneTransitions--;
    }
  }

  void _disposeInterpreting() {
    if (interpreting case final state?) {
      removeListener(state.configurationChanged);
      analysis.removeListener(state.configurationChanged);
    }
    interpreting?.removeListener(notifyListeners);
    interpreting?.dispose();
  }
}
