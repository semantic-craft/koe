import 'dart:async';

/// One deferred file-job mechanism for every engine that transcribes a
/// recording only after the take stops (Moss, Qwen, Doubao).
///
/// It owns the queue, per-recording deduplication, the started set, and the
/// single-flight pump. Engines adapt through hooks:
///
/// - [accept] offers a newly enqueued job to a persistent engine. Moss's
///   journal accepts it and writes it to disk before any request runs, so a
///   crash between stop and start still recovers the take, and a job whose
///   submission response was never confirmed requires an explicit retry
///   instead of billing twice. Once an adapter accepts, it owns the job's
///   whole lifecycle — stage persistence, polling, cleanup — and this queue
///   never sees the job again.
/// - [run] executes one queued job. Qwen and Doubao persist through the
///   controller's file journal before entering this scheduling queue: the file transcription runs with the take's configuration
///   snapshot and reports its own progress, errors, and state changes
///   through the shared file-transcription executor. It returns whether the
///   job was accepted; a busy engine leaves the entry queued for the next
///   pump.
///
/// Manual retry goes through [runNow], which bypasses the queue and the
/// started set so the engine answers the user immediately (its own busy
/// error) instead of queueing silently.
class DeferredFileJobs<C> {
  /// Private named initializing formals: callers spell the arguments without
  /// the underscore (`canStart: …`).
  DeferredFileJobs({
    required this._canStart,
    required this._engine,
    required this._accept,
    required this._run,
  });

  final bool Function() _canStart;
  final Object Function(C) _engine;
  final Future<bool> Function(String, String, C) _accept;
  final Future<bool> Function(
    String,
    C, {
    bool prepareLanguages,
    bool fromQueue,
  })
  _run;
  final Map<(Object, String), ({String path, C config})> _pending = {};
  final Set<(Object, String)> _started = {};
  bool _pumping = false;
  bool _disposed = false;

  /// Whether the pump is executing a queued job right now.
  bool get busy => _pumping;

  /// A job sits queued for [recordingKey] under [engine] but has not run.
  bool queuedFor(Object engine, String recordingKey) =>
      _pending.containsKey((engine, recordingKey));

  /// Automatic path after a take stops. A recording key that already ran once
  /// for this engine, or that a persistent adapter accepted, is skipped.
  Future<void> enqueue(String recordingKey, String path, C config) async {
    if (_disposed) return;
    final tag = (_engine(config), recordingKey);
    if (_started.contains(tag)) return;
    if (await _accept(recordingKey, path, config)) {
      _started.add(tag);
      return;
    }
    if (_disposed) return;
    _pending[tag] = (path: path, config: config);
    unawaited(pump());
  }

  /// Manual retry from the detail screen: the engine's own busy handling
  /// answers immediately; the queue and the started set are not consulted.
  Future<bool> runNow(String path, C config, {bool prepareLanguages = false}) =>
      _run(path, config, prepareLanguages: prepareLanguages, fromQueue: false);

  /// Runs the next queued job when the start gate allows it. The pump is
  /// single-flight; a busy engine (run reporting false) keeps its entry.
  Future<void> pump() async {
    if (_pumping || _disposed || _pending.isEmpty) return;
    if (!_canStart()) return;
    final entry = _pending.entries.first;
    _pumping = true;
    var accepted = false;
    try {
      accepted = await _run(
        entry.value.path,
        entry.value.config,
        prepareLanguages: false,
        fromQueue: true,
      );
    } finally {
      if (accepted) {
        _pending.remove(entry.key);
        _started.add(entry.key);
      }
      _pumping = false;
      if (accepted && _pending.isNotEmpty) unawaited(pump());
    }
  }

  void discard(String recordingKey) {
    _pending.removeWhere((tag, _) => tag.$2 == recordingKey);
    _started.removeWhere((tag) => tag.$2 == recordingKey);
  }

  /// Drops every queued job; later enqueues and pumps are ignored.
  void dispose() {
    _disposed = true;
    _pending.clear();
  }
}
