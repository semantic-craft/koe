part of '../recorder_controller.dart';

/// Keeps Koe running while it transcribes or analyses recordings, so the
/// work goes on after the user leaves Koe or locks the phone. On Android
/// that is [BackgroundWork.aiProcessing] on the foreground service; Apple
/// platforms do nothing here.
///
/// Every model request holds the work while it runs. The work ends
/// [RecorderController.aiKeepAliveGrace] after the last request returns, so
/// the steps after a transcription (topics, todos, the summary) run under the
/// same service instead of asking Android again from behind the lock screen.
///
/// Android can take the work away: it refuses to start the service while
/// Koe is off screen with nothing else running, and Android 15+ stops
/// dataSync after six hours a day off screen. The next request asks again,
/// and so does Koe coming back on screen while a request still runs.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderAiKeepAlive on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract final Duration aiKeepAliveGrace;
  abstract bool _disposed;
  // END DEPS

  int _aiRequests = 0;
  bool _aiKeptAlive = false;
  Timer? _aiKeepAliveEnd;
  AppLifecycleListener? _aiKeepAliveResume;

  /// Runs [request], a call to a speech or language model, with Koe kept
  /// running until it returns.
  Future<T> _whileAiWorks<T>(Future<T> Function() request) async {
    _aiRequests++;
    _aiKeepAliveEnd?.cancel();
    _aiKeepAliveEnd = null;
    _keepAiAlive();
    try {
      return await request();
    } finally {
      if (--_aiRequests == 0 && _aiKeptAlive) {
        _aiKeepAliveEnd = Timer(aiKeepAliveGrace, _endAiKeepAlive);
      }
    }
  }

  /// [service] with each of its requests run through [_whileAiWorks].
  /// Used by other parts through their abstract declarations.
  // ignore: unused_element
  AnalysisService _keptAlive(AnalysisService service) =>
      _KeptAliveAnalysis(service, _whileAiWorks);

  void _keepAiAlive() {
    if (_disposed || _aiRequests == 0 || _aiKeptAlive) return;
    if (!BackgroundSyncService.shared.enabled) return;
    _aiKeptAlive = true;
    unawaited(
      BackgroundSyncService.shared.begin(
        BackgroundWork.aiProcessing,
        onRefused: _onAiKeepAliveRefused,
      ),
    );
  }

  void _onAiKeepAliveRefused() {
    _aiKeptAlive = false;
    // Back on screen, Android lets the service start again and counts the
    // day's time afresh.
    if (!_disposed) {
      _aiKeepAliveResume ??= AppLifecycleListener(onResume: _keepAiAlive);
    }
  }

  void _endAiKeepAlive() {
    _aiKeepAliveEnd = null;
    if (!_aiKeptAlive) return;
    _aiKeptAlive = false;
    unawaited(BackgroundSyncService.shared.end(BackgroundWork.aiProcessing));
  }

  void _disposeAiKeepAlive() {
    _aiKeepAliveEnd?.cancel();
    _aiKeepAliveResume?.dispose();
    _endAiKeepAlive();
  }
}

/// [_inner] with each request run through [_whileWorking].
class _KeptAliveAnalysis implements AnalysisService {
  _KeptAliveAnalysis(this._inner, this._whileWorking);

  final AnalysisService _inner;
  final Future<String> Function(Future<String> Function() request)
  _whileWorking;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) => _whileWorking(
    () => _inner.generate(
      model: model,
      apiKey: apiKey,
      source: source,
      instruction: instruction,
      abort: abort,
    ),
  );

  @override
  void dispose() => _inner.dispose();
}
