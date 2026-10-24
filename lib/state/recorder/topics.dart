part of '../recorder_controller.dart';

/// Topics (#49/#50): placement observation, per-recording topic notes,
/// topic summaries and the topic-assist recommendation runs.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderTopics on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract Completer<void>? _activeFileJobCompleter;
  String? _audioPathFor(RecordingReference ref);
  abstract final Map<String, String> _audioVersions;
  abstract final DeferredFileJobs<SpeechConfiguration> _deferredJobs;
  abstract bool _disposed;
  abstract final QwenSttService _qwenStt;
  abstract AnalysisBackendKind analysisBackend;
  abstract EngineConfig analysisOpenAiConfig;
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  RecordingReference _referenceFromKey(String key, {String? pathHint});
  String _referenceKey(RecordingReference ref);
  abstract final Future<void> _settingsLoaded;
  AnalysisService _keptAlive(AnalysisService service);
  abstract final AnalysisService? _topicRecommendationOverride;
  abstract Future<void> _transcriptsLoaded;
  abstract final RecordingAnalysis analysis;
  String get analysisApiKey;
  abstract String? errorMessage;
  int? fileIdFromPath(String path);
  abstract final RecordingLibraryStore library;
  bool recordingAudioChanged(RecordingReference ref);
  DateTime? _recordedAtFromFileId(int? id);
  RecordingViewData recordingView(RecordingReference ref);
  abstract String? statusMessage;
  abstract final bool topicsEnabled;
  String? transcriptForPath(String path);
  abstract final Map<int, String> transcriptsByFileId;
  abstract final Map<String, String> transcriptsByPath;
  // END DEPS

  Map<String, TopicPlacement> _observedPlacements = const {};
  bool _topicsObserved = false;

  late final AnalysisService _topicRecommender = _keptAlive(
    switch (_topicRecommendationOverride) {
      final QwenAnalysisService qwen when !qwen.isTopicAssist =>
        qwen.asTopicAssist(),
      final OpenAiCompatibleAnalysisService openAi when !openAi.isTopicAssist =>
        openAi.asTopicAssist(),
      final AnalysisService service => service,
      null => RoutingAnalysisService(
        backend: () => analysisBackend,
        qwen: QwenAnalysisService.topicAssist(origin: () => _qwenStt.baseUrl),
        openAiCompatible: OpenAiCompatibleAnalysisService.topicAssist(
          baseUrl: () =>
              analysisOpenAiConfig.baseUrl ?? 'http://localhost:11434/v1',
        ),
      ),
    },
  );

  final Map<String, Future<void>> _topicAssistTasks = {};
  final Map<String, _TopicAssistLatest> _topicAssistLatest = {};
  final Set<Future<void>> _topicNoteInflight = <Future<void>>{};

  /// Chunked #13 digest. Missing files return null without reading bytes.
  Future<String?> _topicNoteAudioVersion(String? path) async {
    if (path == null || path.isEmpty) return null;
    if (!File(path).existsSync()) return null;
    try {
      return await audioVersion(path);
    } on AudioVersionException {
      return null;
    }
  }

  List<TopicNote> _priorTopicNotes(String topicId, String excludeRecordingKey) {
    final notes = <TopicNote>[];
    for (final otherKey in topics.recordingsIn(topicId)) {
      if (otherKey == excludeRecordingKey) continue;
      final res = analysis.results[TopicNote.slotKey(otherKey)];
      if (res == null) continue;
      final parsed = TopicNote.tryParse(
        res.text,
        res.sources.isEmpty ? 1 : res.sources.length,
        fallbackTopicId: topicId,
      );
      if (parsed != null) notes.add(parsed);
    }
    return notes;
  }

  bool isTopicNoteStale(RecordingReference ref) {
    final key = _referenceKey(ref);
    final slotKey = TopicNote.slotKey(key);
    final result = analysis.results[slotKey];
    if (result == null) return false;
    if (recordingAudioChanged(ref)) return true;
    final view = recordingView(ref);
    final source = view.text.trim();
    if (source.isNotEmpty && result.staleFor(source)) return true;
    final parsed = TopicNote.tryParse(
      result.text,
      result.sources.isEmpty ? 1 : result.sources.length,
    );
    if (parsed == null) return true;
    final topic = topics.topicOf(key);
    final noteKind = topic?.kind ?? parsed.kind;
    final expectedTemplateId = noteKind == TopicKind.book
        ? bookNoteTemplateId
        : thinkingNoteTemplateId;
    if (result.templateId != expectedTemplateId) return true;
    if (topic != null &&
        parsed.topicId.isNotEmpty &&
        parsed.topicId != topic.id) {
      return true;
    }
    final cachedVersion = _audioVersions[key];
    if (parsed.audioSignature != null &&
        cachedVersion != null &&
        cachedVersion != parsed.audioSignature) {
      return true;
    }
    return analysis.isTemplateStale(result);
  }

  TopicSummaryInput topicSummaryInput(String topicId) {
    final topic = topics.topicById(topicId);
    if (topic == null) throw StateError('主题不存在');
    final notes = <TopicSummaryNote>[];
    final noteKeys = <String>[];
    final invalidKeys = <String>[];
    for (final key in topics.recordingsIn(topicId)) {
      final result = analysis.results[TopicNote.slotKey(key)];
      if (result == null) continue;
      noteKeys.add(key);
      final ref = _referenceFromKey(key);
      if (isTopicNoteStale(ref)) {
        invalidKeys.add(key);
        continue;
      }
      final note = TopicNote.tryParse(
        result.text,
        result.sources.isEmpty ? 1 : result.sources.length,
        fallbackTopicId: topicId,
      );
      if (note == null ||
          note.kind != topic.kind ||
          (note.topicId.isNotEmpty && note.topicId != topicId)) {
        invalidKeys.add(key);
        continue;
      }
      // Imported ids are microsecond stamps, not recording seconds.
      final recordedAt = key.startsWith('file:')
          ? _recordedAtFromFileId(int.tryParse(key.substring(5)))
          : null;
      notes.add(
        TopicSummaryNote(
          recordingKey: key,
          title: recordingView(ref).title,
          recordedAt: recordedAt ?? result.createdAt,
          note: note,
        ),
      );
    }
    return buildTopicSummaryInput(
      topic,
      notes,
      recordingKeys: noteKeys,
      invalidKeys: invalidKeys,
    );
  }

  bool isTopicSummaryStale(String topicId) {
    final topic = topics.topicById(topicId);
    if (topic == null || topic.closed) return false;
    final result = analysis.results[TopicSummary.slotKey(topicId)];
    if (result == null) return false;
    return result.staleFor(topicSummaryInput(topicId).source);
  }

  Future<void> generateTopicSummary(
    String topicId, {
    TopicSummaryRetry retry = TopicSummaryRetry.auto,
  }) async {
    if (!topicsEnabled) return;
    final slotKey = TopicSummary.slotKey(topicId);
    if (!analysis.claim(slotKey)) return;
    try {
      await Future.wait([
        _settingsLoaded,
        _transcriptsLoaded,
        _topicsLoaded,
        analysis.load(),
      ]);
      if (_disposed || !topicsEnabled) return;
      final topic = topics.topicById(topicId);
      if (topic == null) return;
      final input = topicSummaryInput(topicId);
      if (input.invalidKeys.isNotEmpty) {
        throw StateError('有 ${input.invalidKeys.length} 条笔记已过期或无法解析，请先重生成对应笔记');
      }
      if (input.sources.isEmpty) {
        throw StateError('这个主题还没有可汇总的笔记');
      }
      if (analysis.results.containsKey(slotKey) &&
          retry == TopicSummaryRetry.auto) {
        throw StateError('重新生成会覆盖已有汇总，请先确认');
      }
      final confirmedRestart = retry != TopicSummaryRetry.auto;
      if (retry == TopicSummaryRetry.confirmedRetry &&
          !analysis.hasUnconfirmedNode(slotKey)) {
        retry = TopicSummaryRetry.overwrite;
      }
      // run() clears the unconfirmed marker only after it owns the slot, so a
      // confirmed retry that collides with an active request cannot erase the
      // first request's protection marker.
      await analysis.run(
        recording: 'topic:$topicId',
        source: input.source,
        sourceBlocks: input.blocks,
        apiKey: analysisApiKey,
        custom: true,
        resultSlot: TopicSummary.slot,
        modelOverride: TopicSummary.model,
        instruction: topicSummaryInstruction(topic),
        validateResult: validateTopicSummary(topic, input.sources),
        avoidDuplicateCharges: true,
        preserveInputCitations: true,
        confirmedRestart: confirmedRestart,
        slotClaimed: true,
        currentSource: () => topicSummaryInput(topicId).source,
      );
    } finally {
      analysis.releaseClaim(slotKey);
    }
  }

  Future<void> generateTopicNote(RecordingReference ref) {
    final task = _runGenerateTopicNote(ref);
    _trackTopicNote(task);
    return task;
  }

  /// Recomputes the cached #13 audio version. Build paths must not call this.
  /// When [force] is false, a version already stored for this recording is kept.
  Future<void> refreshCachedAudioVersion(
    RecordingReference ref, {
    bool force = false,
  }) {
    final task = _refreshCachedAudioVersion(ref, force: force);
    _trackTopicNote(task);
    return task;
  }

  Future<void> _refreshCachedAudioVersion(
    RecordingReference ref, {
    required bool force,
  }) async {
    final key = _referenceKey(ref);
    if (!force && _audioVersions.containsKey(key)) return;
    final version = await _topicNoteAudioVersion(_audioPathFor(ref));
    if (version == null || _audioVersions[key] == version) return;
    _audioVersions[key] = version;
    if (!_disposed) notifyListeners();
  }

  void _trackTopicNote(Future<void> task) {
    _topicNoteInflight.add(task);
    task.whenComplete(() => _topicNoteInflight.remove(task));
  }

  /// True while a topic-note generation or refresh started by the controller
  /// is still running. Widget tests pump until this is false.
  @visibleForTesting
  bool get topicNoteWorkPending => _topicNoteInflight.isNotEmpty;

  /// Waits until startup loads and every in-flight topic-note task has
  /// finished. "Must not call" assertions have to use this, not a fixed delay.
  @visibleForTesting
  Future<void> settleTopicNoteWork() async {
    await Future.wait([_settingsLoaded, _transcriptsLoaded, _topicsLoaded]);
    await Future<void>.value();
    var spins = 0;
    while (_topicNoteInflight.isNotEmpty) {
      if (++spins > 30) {
        throw StateError('主题笔记任务没有结束');
      }
      final pending = List<Future<void>>.of(_topicNoteInflight);
      try {
        await Future.wait(pending);
      } finally {
        _topicNoteInflight.removeAll(pending);
      }
    }
  }

  Future<void> _runGenerateTopicNote(RecordingReference ref) async {
    if (!topicsEnabled) return;
    await Future.wait([
      _settingsLoaded,
      _transcriptsLoaded,
      _topicsLoaded,
      analysis.load(),
    ]);
    final key = _referenceKey(ref);
    if (_disposed || !topicsEnabled || _isTrashedRecordingKey(key)) return;
    final topic = topics.topicOf(key);
    if (topic == null) return;
    final view = recordingView(ref);
    final source = view.text.trim();
    if (source.isEmpty) return;
    final priorNotes = _priorTopicNotes(topic.id, key);
    final audioSig = await _topicNoteAudioVersion(_audioPathFor(ref));
    if (audioSig != null) _audioVersions[key] = audioSig;
    final template = analysis.requireTemplate(
      topic.kind == TopicKind.book
          ? bookNoteTemplateId
          : thinkingNoteTemplateId,
    );
    await analysis.run(
      recording: key,
      source: source,
      apiKey: analysisApiKey,
      custom: true,
      templateId: template.id,
      resultSlot: TopicNote.slot,
      modelOverride: TopicNote.defaultModel,
      instruction: topicNoteInstruction(
        topic,
        priorNotes: priorNotes,
        template: template,
      ),
      validateResult: validateTopicNote(
        topic,
        hasPriorNotes: priorNotes.isNotEmpty,
        audioSignature: audioSig,
      ),
      currentSource: () =>
          _isTrashedRecordingKey(key) ? '' : recordingView(ref).text,
    );
  }

  Future<void> _maybeAutoGenerateTopicNoteForKey(
    String key, {
    String? pathHint,
  }) {
    final task = _runMaybeAutoGenerateTopicNote(key, pathHint: pathHint);
    _trackTopicNote(task);
    return task;
  }

  Future<void> _runMaybeAutoGenerateTopicNote(
    String key, {
    String? pathHint,
  }) async {
    if (!topicsEnabled) return;
    await Future.wait([
      _settingsLoaded,
      _transcriptsLoaded,
      _topicsLoaded,
      analysis.load(),
    ]);
    if (_disposed || !topicsEnabled || _isTrashedRecordingKey(key)) return;
    final topic = topics.topicOf(key);
    if (topic == null) return;
    final ref = _referenceFromKey(key, pathHint: pathHint);
    if (recordingAudioChanged(ref)) return;
    final view = recordingView(ref);
    final source = view.text.trim();
    if (source.isEmpty || analysisApiKey.trim().isEmpty) return;
    final slotKey = TopicNote.slotKey(key);
    if (analysis.busy(slotKey)) return;
    // 已有笔记（包括原文、主题或模板变化后的旧笔记）只标过期，等用户确认后
    // 手动重生成，自动路径不重复收费。
    if (analysis.results[slotKey] != null) return;
    await generateTopicNote(ref);
  }

  void _onTopicsChanged() {
    if (_disposed || !topicsEnabled || !_topicsObserved) return;
    final current = topics.placements;
    final keys = <String>{..._observedPlacements.keys, ...current.keys};
    final newlyAssigned = <String>[];
    for (final key in keys) {
      final prev = _observedPlacements[key];
      final next = current[key];
      if (prev is! InTopicPlacement && next is InTopicPlacement) {
        newlyAssigned.add(key);
      }
    }
    _observedPlacements = Map<String, TopicPlacement>.from(current);
    for (final key in newlyAssigned) {
      unawaited(_maybeAutoGenerateTopicNoteForKey(key));
    }
    notifyListeners();
  }

  late final TopicStore topics;
  late final Future<void> _topicsLoaded;
  AppLifecycleListener? _lifecycle;
  late final bool _ownsTopics;

  @visibleForTesting
  Future<void> waitForTopicAssist() async {
    await _deferredJobs.pump();
    while (_deferredJobs.busy ||
        _activeFileJobCompleter != null ||
        _topicAssistTasks.isNotEmpty) {
      final inflight = <Future<void>>[
        if (_activeFileJobCompleter != null) _activeFileJobCompleter!.future,
        ..._topicAssistTasks.values,
      ];
      if (inflight.isEmpty) {
        // The pump can be waiting between queue acceptance and registering its
        // completer; yield so the test observes that progress instead of
        // returning before the job has actually run.
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      await Future.wait(inflight);
    }
  }

  // Only called from other parts, through their abstract declarations.
  // ignore: unused_element
  Future<void> _scheduleTopicAssist(String recordingKey, String transcript) {
    if (!topicsEnabled || _disposed) return Future<void>.value();
    final excerpt = topicTranscriptExcerpt(transcript);
    if (excerpt.isEmpty) return Future<void>.value();
    final latest = _topicAssistLatest.putIfAbsent(
      recordingKey,
      () => _TopicAssistLatest(transcript),
    );
    latest.transcript = transcript;
    final existing = _topicAssistTasks[recordingKey];
    if (existing != null) {
      latest.dirty = true;
      return existing;
    }
    latest.dirty = false;
    final scheduledHash = analysisFingerprint(excerpt);
    late final Future<void> task;
    task = _runTopicAssist(recordingKey, transcript, excerpt).whenComplete(() {
      if (!identical(_topicAssistTasks[recordingKey], task)) return;
      _topicAssistTasks.remove(recordingKey);
      if (_disposed || !topicsEnabled) return;
      final pending = _topicAssistLatest[recordingKey];
      if (pending == null) return;
      final pendingExcerpt = topicTranscriptExcerpt(pending.transcript);
      if (pendingExcerpt.isEmpty) {
        pending.dirty = false;
        return;
      }
      final pendingHash = analysisFingerprint(pendingExcerpt);
      if (!pending.dirty && pendingHash == scheduledHash) return;
      _scheduleTopicAssist(recordingKey, pending.transcript);
    });
    _topicAssistTasks[recordingKey] = task;
    return task;
  }

  String? _pathForRecordingKey(String recordingKey) {
    if (recordingKey.startsWith('path:')) {
      final path = recordingKey.substring('path:'.length);
      return path.isEmpty ? null : path;
    }
    if (!recordingKey.startsWith('file:')) return null;
    final id = int.tryParse(recordingKey.substring('file:'.length));
    if (id == null) return null;
    for (final path in transcriptsByPath.keys) {
      if (fileIdFromPath(path) == id) return path;
    }
    return null;
  }

  bool _isTrashedRecordingKey(String recordingKey) {
    final int? fileId;
    final String? path;
    if (recordingKey.startsWith('file:')) {
      fileId = int.tryParse(recordingKey.substring('file:'.length));
      path = null;
    } else if (recordingKey.startsWith('path:')) {
      fileId = null;
      path = recordingKey.substring('path:'.length);
    } else {
      return false;
    }
    for (final asset in library.assets) {
      if (!asset.trashed) continue;
      if (path != null && asset.path == path) return true;
      if (fileId != null &&
          ExportCatalog.fileIdFromPath(asset.path) == fileId) {
        return true;
      }
    }
    return false;
  }

  /// Transcript currently stored for [recordingKey], via [transcriptForPath]
  /// when the path is known.
  String? _transcriptForTopicAssist(String recordingKey) {
    final path = _pathForRecordingKey(recordingKey);
    if (path != null) {
      final fromPath = transcriptForPath(path);
      if (fromPath != null && fromPath.trim().isNotEmpty) return fromPath;
    }
    if (recordingKey.startsWith('file:')) {
      final id = int.tryParse(recordingKey.substring('file:'.length));
      final byId = id == null ? null : transcriptsByFileId[id];
      if (byId != null && byId.isNotEmpty) return byId;
    }
    return null;
  }

  String? _currentTopicExcerptHash(String recordingKey) {
    final text = _transcriptForTopicAssist(recordingKey);
    if (text == null || text.trim().isEmpty) return null;
    final excerpt = topicTranscriptExcerpt(text);
    if (excerpt.isEmpty) return null;
    return analysisFingerprint(excerpt);
  }

  bool _topicExcerptStill(String recordingKey, String excerptHash) =>
      !_isTrashedRecordingKey(recordingKey) &&
      _currentTopicExcerptHash(recordingKey) == excerptHash;

  bool _pendingAssistCurrent(String recordingKey, String excerptHash) =>
      !_disposed &&
      topics.isPending(recordingKey) &&
      _topicExcerptStill(recordingKey, excerptHash);

  bool _driftAssistCurrent(
    String recordingKey,
    String excerptHash,
    String topicId,
  ) {
    if (_disposed || !_topicExcerptStill(recordingKey, excerptHash)) {
      return false;
    }
    if (topics.topicOf(recordingKey)?.id != topicId) return false;
    final topic = topics.topicById(topicId);
    return topic != null && !topic.closed;
  }

  /// Drops a recommendation, drift hint, or evaluated-assist mark that belongs
  /// to an excerpt the recording no longer has, or to a placement it has left.
  Future<void> _rollbackSupersededTopicAssist(
    String recordingKey,
    String excerptHash,
    String token, {
    required bool pending,
  }) async {
    if (pending) {
      final rec = topics.recommendationFor(recordingKey);
      if (rec != null && rec.sourceHash == excerptHash) {
        await topics.dismissRecommendation(recordingKey);
      }
    } else {
      final hint = topics.driftHintFor(recordingKey);
      if (hint != null && hint.sourceHash == excerptHash) {
        await topics.dismissDriftHint(recordingKey);
      }
    }
    if (topics.hasEvaluatedAssist(recordingKey, token)) {
      await topics.clearAssistEvaluated(recordingKey, token);
    }
  }

  Future<void> _runTopicAssist(
    String recordingKey,
    String transcript,
    String excerpt,
  ) async {
    try {
      await Future.wait([_settingsLoaded, _topicsLoaded]);
      await topics.load();
      if (_disposed || !topicsEnabled) return;
      final apiKey = analysisApiKey.trim();
      if (apiKey.isEmpty) return;
      final model = (analysis.model ?? 'qwen3.8-flash').trim();
      if (model.isEmpty) return;
      final excerptHash = analysisFingerprint(excerpt);
      if (!_topicExcerptStill(recordingKey, excerptHash)) return;

      if (topics.isPending(recordingKey)) {
        final token = 'pending:$excerptHash';
        if (topics.hasEvaluatedAssist(recordingKey, token)) return;
        final instruction = buildTopicRecommendationInstruction(
          openTopics: topics.openTopics,
          transcript: transcript,
        );
        final raw = await _topicRecommender.generate(
          model: model,
          apiKey: apiKey,
          source: excerpt,
          instruction: instruction,
          abort: Completer<void>().future,
        );
        if (!_pendingAssistCurrent(recordingKey, excerptHash)) return;
        final rec = parseTopicRecommendation(
          raw,
          topics.openTopics,
          sourceHash: excerptHash,
        );
        // Unparseable output is not a finished "no recommendation" decision:
        // leave the excerpt unmarked so a later trigger can retry (#52).
        if (rec == null) return;
        await topics.setRecommendation(recordingKey, rec);
        if (!_pendingAssistCurrent(recordingKey, excerptHash)) {
          await _rollbackSupersededTopicAssist(
            recordingKey,
            excerptHash,
            token,
            pending: true,
          );
          return;
        }
        await topics.markAssistEvaluated(recordingKey, token);
        if (!_pendingAssistCurrent(recordingKey, excerptHash)) {
          await _rollbackSupersededTopicAssist(
            recordingKey,
            excerptHash,
            token,
            pending: true,
          );
        }
        return;
      }

      final assigned = topics.topicOf(recordingKey);
      if (assigned != null && !assigned.closed) {
        final token = 'drift:${assigned.id}:$excerptHash';
        if (topics.hasEvaluatedAssist(recordingKey, token)) return;
        if (!_topicExcerptStill(recordingKey, excerptHash)) return;
        final instruction = buildTopicDriftInstruction(
          currentTopic: assigned,
          openTopics: topics.openTopics,
          transcript: transcript,
        );
        final raw = await _topicRecommender.generate(
          model: model,
          apiKey: apiKey,
          source: excerpt,
          instruction: instruction,
          abort: Completer<void>().future,
        );
        if (!_driftAssistCurrent(recordingKey, excerptHash, assigned.id)) {
          return;
        }
        final decision = parseTopicDriftDecision(
          raw,
          currentTopic: topics.topicById(assigned.id)!,
          openTopics: topics.openTopics,
          sourceHash: excerptHash,
        );
        if (decision == null) return;
        if (decision.hint != null) {
          if (!_driftAssistCurrent(recordingKey, excerptHash, assigned.id)) {
            return;
          }
          await topics.setDriftHint(recordingKey, decision.hint!);
        }
        if (!_driftAssistCurrent(recordingKey, excerptHash, assigned.id)) {
          await _rollbackSupersededTopicAssist(
            recordingKey,
            excerptHash,
            token,
            pending: false,
          );
          return;
        }
        await topics.markAssistEvaluated(recordingKey, token);
        if (!_driftAssistCurrent(recordingKey, excerptHash, assigned.id)) {
          await _rollbackSupersededTopicAssist(
            recordingKey,
            excerptHash,
            token,
            pending: false,
          );
        }
      }
    } catch (_) {
      // Silent fallback. Do not mark: a later trigger may retry the same
      // excerpt, and a superseded excerpt must not block the latest text.
    }
  }

  /// Unassigns one material from its project/topic without deleting notes.
  Future<void> removeRecordingFromTopics(String path) async {
    final key = _recordingKey(path: path);
    await topics.removeFromTopic(key);
    _observedPlacements = Map<String, TopicPlacement>.from(topics.placements);
    statusMessage = '已移出项目/主题，资料与笔记仍保留';
    errorMessage = null;
    notifyListeners();
  }
}
