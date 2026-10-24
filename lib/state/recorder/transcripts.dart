part of '../recorder_controller.dart';

/// Saved transcripts: loading and persisting them, the canonical text for a
/// recording, manual corrections, incoming re-transcriptions waiting for
/// review, and speaker names.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderTranscripts on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  Future<String> _convertExportToWav(
    String path, {
    // ignore: unused_element_parameter
    bool register = true,
    // ignore: unused_element_parameter
    List<String>? conversionFailures,
  });
  _RecordingSession? get _currentRecording;
  abstract bool _disposed;
  SpeakerDiarizer get _effectiveSpeakerDiarizer;
  bool _isRecordingAudioLocked(int? id, String? path);
  bool get _labelsSpeakersAutomatically;
  Future<void> _maybeAutoGenerateTopicNoteForKey(
    String key, {
    String? pathHint,
  });
  Future<void> upgradeDraftMinutesIfNeeded(
    RecordingReference ref, {
    String? templateId,
    String language = 'zh',
  });
  String _recordingKey({int? fileId, String? path});
  abstract final Map<String, RecordingTranslation> _recordingTranslations;
  Future<void> _scheduleTopicAssist(String recordingKey, String transcript);
  abstract final Map<String, TranscriptMetadata> _transcriptMetadata;
  abstract final TranscriptPersister? _transcriptPersister;
  int? fileIdFromPath(String path);
  bool get isLiveSession;
  abstract SttProvider speechProvider;
  abstract final bool topicsEnabled;
  abstract String transcript;
  abstract String? transcriptPartial;
  // END DEPS

  final Map<String, String> _transcriptPathsByKey = {};

  Future<void> _loadPersistedTranscripts() async {
    final saved = await TranscriptStore.load();
    // Merge so a transcript completed during startup is never overwritten.
    for (final entry in saved.byPath.entries) {
      transcriptsByPath.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.byFileId.entries) {
      transcriptsByFileId.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.aliasesByPath.entries) {
      speakerAliasesByPath.putIfAbsent(
        entry.key,
        () => Map<String, String>.from(entry.value),
      );
    }
    for (final entry in saved.aliasesByFileId.entries) {
      speakerAliasesByFileId.putIfAbsent(
        entry.key,
        () => Map<String, String>.from(entry.value),
      );
    }
    for (final entry in saved.metadata.entries) {
      _transcriptMetadata.putIfAbsent(entry.key, () => entry.value);
    }
    // Translations of an older source are kept and shown as out of date.
    for (final entry in saved.translations.entries) {
      _recordingTranslations.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.segments.entries) {
      _transcriptSegments.putIfAbsent(
        entry.key,
        () => List<TranscriptSegment>.unmodifiable(entry.value),
      );
    }
    for (final entry in saved.manualByKey.entries) {
      _manualTranscripts.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.incomingByKey.entries) {
      _incomingTranscripts.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.segmentSpeakersByKey.entries) {
      _segmentSpeakers.putIfAbsent(
        entry.key,
        () => Map<int, String>.from(entry.value),
      );
    }
    for (final entry in saved.expectedSpeakersByKey.entries) {
      _expectedSpeakers.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in saved.diarizationQualityByKey.entries) {
      _diarizationQuality.putIfAbsent(entry.key, () => entry.value);
    }
    _speakerHintDismissed.addAll(saved.speakerHintDismissedKeys);
    for (final entry in saved.speakerUndoByKey.entries) {
      _speakerUndo.putIfAbsent(entry.key, () => entry.value);
    }
    notifyListeners();
  }

  Future<void> _persistTranscripts({bool strict = false}) async {
    await _transcriptsLoaded;
    final override = _transcriptPersister;
    if (override != null) {
      await override(strict: strict);
      return;
    }
    await TranscriptStore.save(
      byPath: transcriptsByPath,
      byFileId: transcriptsByFileId,
      aliasesByPath: speakerAliasesByPath,
      aliasesByFileId: speakerAliasesByFileId,
      metadata: _transcriptMetadata,
      translations: _recordingTranslations,
      segments: _transcriptSegments,
      manualByKey: _manualTranscripts,
      incomingByKey: _incomingTranscripts,
      segmentSpeakersByKey: _segmentSpeakers,
      expectedSpeakersByKey: _expectedSpeakers,
      diarizationQualityByKey: _diarizationQuality,
      speakerHintDismissedKeys: _speakerHintDismissed,
      speakerUndoByKey: _speakerUndo,
      strict: strict,
    );
  }

  /// Store per-file transcript so Home list can show text (not just a button).
  void rememberTranscript(
    String path,
    String text, {
    SttProvider? provider,
    String? sourceLanguage,
    List<TranscriptSegment>? segments,
  }) {
    final t = normalizeSttText(text);
    if (path.isEmpty || t.isEmpty) return;
    final key = _recordingKey(path: path);
    final previous = _rawTranscriptForPath(path);
    final metadata = _transcriptMetadata[key];
    final manual = _manualTranscripts[key];
    final stored = _transcriptSegments[key];
    final languageChanged =
        sourceLanguage != null && sourceLanguage != metadata?.sourceLanguage;
    final textChanged = manual == null && previous != t;
    final visibleChanged = textChanged || languageChanged;
    // A local run returns passages without speakers; when they say what the
    // saved ones say, the people already labelled on them stay. Callers that
    // only revise text or metadata pass no segments and keep sentence times.
    final fresh =
        segments != null &&
            !textChanged &&
            stored != null &&
            _samePassages(segments, stored)
        ? null
        : segments;
    final segmentsReplaced =
        textChanged ||
        (fresh != null && !listEquals(fresh, stored ?? const []));
    if (textChanged) {
      // A provider run numbers its speakers afresh, so names go with the old
      // text, unless a manual transcript still protects the visible text.
      // Passages without speakers are labelled next on this device, which
      // finds the same people by time, so the names wait for them.
      final labelledByTime =
          fresh != null &&
          fresh.isNotEmpty &&
          fresh.every((segment) => segment.speaker == null) &&
          transcriptSegmentsForPath(
            path,
          ).any((segment) => segment.speaker != null);
      if (!labelledByTime) _clearSpeakerAliases(path);
    }
    if (segmentsReplaced) {
      if (fresh == null || fresh.isEmpty) {
        _transcriptSegments.remove(key);
      } else {
        _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(fresh);
      }
      // Speaker fixes are indexed into the old list, and its diarization
      // quality and undo describe it; none of them carries over.
      _segmentSpeakers.remove(key);
      _diarizationQuality.remove(key);
      _speakerHintDismissed.remove(key);
      _speakerUndo.remove(key);
    }
    final incoming = _incomingTranscripts[key];
    if (manual != null && t != manual) {
      _incomingTranscripts[key] = t;
    }
    if (manual != null && t == manual) _incomingTranscripts.remove(key);
    // Undo would bring back the provider text this one replaces.
    if (_incomingTranscripts[key] != incoming) _speakerUndo.remove(key);
    _transcriptMetadata[key] = TranscriptMetadata(
      provider: provider ?? metadata?.provider ?? speechProvider,
      sourceLanguage: sourceLanguage ?? metadata?.sourceLanguage,
      revision: (metadata?.revision ?? 0) + (visibleChanged ? 1 : 0),
    );
    transcriptsByPath[path] = t;
    _transcriptPathsByKey[key] = path;
    // Also index by file id when known.
    final id = fileIdFromPath(path);
    if (id != null) transcriptsByFileId[id] = t;
    unawaited(_persistTranscripts());
    if (textChanged && !_isRecordingAudioLocked(id, path)) {
      unawaited(
        upgradeDraftMinutesIfNeeded(
          RecordingReference(fileId: id, path: path),
        ),
      );
    }
    if (visibleChanged && topicsEnabled) {
      unawaited(_maybeAutoGenerateTopicNoteForKey(key, pathHint: path));
    }
    if (topicsEnabled && !_isRecordingAudioLocked(id, path)) {
      unawaited(_scheduleTopicAssist(key, t));
    }
  }

  String? transcriptForPath(String path) {
    final raw = manualTranscriptForPath(path) ?? _rawTranscriptForPath(path);
    if (raw == null) return null;
    return applyTranscriptSpeakerAliases(
      normalizeSttText(raw),
      _speakerAliasesForPath(path),
    );
  }

  /// Provider-timed segments for [path], scoped to its transcript key.
  List<TranscriptSegment> transcriptSegmentsForPath(String path) {
    final key = _recordingKey(path: path);
    final segments = _transcriptSegments[key];
    if (segments == null) return const [];
    final overrides = _segmentSpeakers[key];
    final effective = <TranscriptSegment>[];
    String? previousSpeaker;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final speaker = overrides?[index] ?? segment.speaker;
      final effectiveSpeaker = speaker == null || speaker.isEmpty
          ? null
          : speaker;
      final changed =
          effectiveSpeaker != null && effectiveSpeaker != previousSpeaker;
      effective.add(
        segment.copyWith(
          speaker: effectiveSpeaker,
          clearSpeaker: effectiveSpeaker == null,
          speakerChanged: changed,
        ),
      );
      previousSpeaker = effectiveSpeaker;
    }
    return effective;
  }

  /// Whether [fresh] says what [path]'s passages already say. Passages
  /// without speakers match whoever the saved ones were given to.
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  bool _sameSegments(String path, List<TranscriptSegment> fresh) =>
      _samePassages(
        fresh,
        _transcriptSegments[_recordingKey(path: path)] ?? const [],
      ) ||
      listEquals(transcriptSegmentsForPath(path), fresh);

  /// Whether [fresh], with no speakers on it, has the words and times of
  /// [stored].
  static bool _samePassages(
    List<TranscriptSegment> fresh,
    List<TranscriptSegment> stored,
  ) {
    if (fresh.length != stored.length) return false;
    for (var i = 0; i < fresh.length; i++) {
      final next = fresh[i];
      final saved = stored[i];
      if (next.speaker != null ||
          next.text != saved.text ||
          next.start != saved.start ||
          next.end != saved.end) {
        return false;
      }
    }
    return true;
  }

  /// The pieces of [path]'s text that other features quote and cite.
  ///
  /// Provider-timed segments while they still match the visible text. Once
  /// the user corrects the transcript the old segments no longer say what the
  /// text says, so the corrected text is quoted paragraph by paragraph from
  /// the start of the recording instead; the same holds for untimed text.
  List<TranscriptSegment> quotableSegmentsForPath(String path) {
    final edited = _manualTranscripts.containsKey(_recordingKey(path: path));
    final timed = edited
        ? const <TranscriptSegment>[]
        : transcriptSegmentsForPath(path);
    if (timed.isNotEmpty) return timed;
    final text = transcriptForPath(path)?.trim() ?? '';
    return [
      for (final paragraph in text.split('\n'))
        if (paragraph.trim().isNotEmpty)
          TranscriptSegment(text: paragraph.trim(), start: Duration.zero),
    ];
  }

  /// Manual text last saved by the user, before display aliases are applied.
  String? manualTranscriptForPath(String path) =>
      _manualTranscripts[_recordingKey(path: path)];

  /// Visible source text without display aliases, for editing.
  String? canonicalTranscriptForPath(String path) {
    final raw = manualTranscriptForPath(path) ?? _rawTranscriptForPath(path);
    return raw == null ? null : normalizeSttText(raw);
  }

  /// Provider text that arrived after a manual edit, still unadopted.
  String? incomingTranscriptForPath(String path) =>
      _incomingTranscripts[_recordingKey(path: path)];

  bool hasPendingTranscript(String path) =>
      _incomingTranscripts.containsKey(_recordingKey(path: path));

  /// Saves a human-corrected transcript. Returns false when the text equals
  /// the provider version and the manual override was removed.
  Future<bool> saveManualTranscript(String path, String text) async {
    final key = _recordingKey(path: path);
    final normalized = normalizeSttText(text);
    if (normalized.isEmpty) throw ArgumentError('正文不能为空');
    final provider = _rawTranscriptForPath(path);
    final previousManual = _manualTranscripts[key];
    final previousIncoming = _incomingTranscripts[key];
    final previousVisible = previousManual ?? provider ?? '';
    final visibleChanged = normalized != previousVisible;
    final adoptsProvider = provider == normalized && visibleChanged;
    if (visibleChanged) _pinTranslationSource(key, previousVisible);
    final previousAliasesPath = speakerAliasesByPath[path];
    final fileId = fileIdFromPath(path);
    final previousAliasesId = fileId == null
        ? null
        : speakerAliasesByFileId[fileId];
    // Undo would bring back the text before this edit.
    final undo = visibleChanged ? _speakerUndo.remove(key) : null;
    if (provider == normalized) {
      _manualTranscripts.remove(key);
      _incomingTranscripts.remove(key);
      // The provider version may reuse speaker ids for different people.
      if (adoptsProvider) _clearSpeakerAliases(path);
    } else {
      _manualTranscripts[key] = normalized;
    }
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      // Keep the editor draft by rolling the in-memory state back.
      if (previousManual == null) {
        _manualTranscripts.remove(key);
      } else {
        _manualTranscripts[key] = previousManual;
      }
      if (previousIncoming == null) {
        _incomingTranscripts.remove(key);
      } else {
        _incomingTranscripts[key] = previousIncoming;
      }
      if (adoptsProvider) {
        if (previousAliasesPath != null) {
          speakerAliasesByPath[path] = previousAliasesPath;
        }
        if (fileId != null && previousAliasesId != null) {
          speakerAliasesByFileId[fileId] = previousAliasesId;
        }
      }
      if (undo != null) _speakerUndo[key] = undo;
      notifyListeners();
      rethrow;
    }
    if (topicsEnabled && !_isRecordingAudioLocked(fileIdFromPath(path), path)) {
      if (adoptsProvider) {
        unawaited(_maybeAutoGenerateTopicNoteForKey(key, pathHint: path));
      }
      // Recommendations follow the visible text, but never overwrite notes.
      unawaited(_scheduleTopicAssist(key, normalized));
    }
    return _manualTranscripts.containsKey(key);
  }

  /// Manual edits keep the revision, so a translation saved before source
  /// fingerprints existed is pinned to the text it was made from before that
  /// text changes; it then reads as out of date instead of current.
  void _pinTranslationSource(String key, String visibleText) {
    final translation = _recordingTranslations[key];
    if (translation == null || translation.sourceDigest != null) return;
    _recordingTranslations[key] = RecordingTranslation(
      text: translation.text,
      sourceLanguage: translation.sourceLanguage,
      targetLanguage: translation.targetLanguage,
      provider: translation.provider,
      sourceRevision: translation.sourceRevision,
      sourceDigest: transcriptSourceDigest(visibleText),
      segments: translation.segments,
    );
  }

  Future<void> discardManualTranscript(String path) async {
    final key = _recordingKey(path: path);
    final manual = _manualTranscripts[key];
    if (manual != null) {
      _pinTranslationSource(key, manual);
      _speakerUndo.remove(key);
    }
    _manualTranscripts.remove(key);
    notifyListeners();
    await _persistTranscripts(strict: true);
  }

  Future<void> adoptIncomingTranscript(String path) async {
    final key = _recordingKey(path: path);
    final incoming = _incomingTranscripts.remove(key);
    if (incoming == null) return;
    final undo = _speakerUndo.remove(key);
    final previousText = transcriptsByPath[path];
    _pinTranslationSource(key, _manualTranscripts[key] ?? previousText ?? '');
    final previousManual = _manualTranscripts.remove(key);
    final id = fileIdFromPath(path);
    final previousAliasesPath = speakerAliasesByPath.remove(path);
    final previousAliasesId = id == null
        ? null
        : speakerAliasesByFileId.remove(id);
    // Adopting a provider version makes it the new base text, so later
    // re-transcriptions and the edit notice compare against that version.
    transcriptsByPath[path] = incoming;
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      _incomingTranscripts[key] = incoming;
      if (previousManual != null) _manualTranscripts[key] = previousManual;
      if (previousText == null) {
        transcriptsByPath.remove(path);
      } else {
        transcriptsByPath[path] = previousText;
      }
      if (previousAliasesPath != null) {
        speakerAliasesByPath[path] = previousAliasesPath;
      }
      if (id != null && previousAliasesId != null) {
        speakerAliasesByFileId[id] = previousAliasesId;
      }
      if (undo != null) _speakerUndo[key] = undo;
      notifyListeners();
      rethrow;
    }
    final visible = normalizeSttText(incoming);
    if (topicsEnabled &&
        visible.isNotEmpty &&
        !_isRecordingAudioLocked(id, path)) {
      unawaited(_maybeAutoGenerateTopicNoteForKey(key, pathHint: path));
      unawaited(_scheduleTopicAssist(key, visible));
    }
  }

  Future<void> dismissIncomingTranscript(String path) async {
    final key = _recordingKey(path: path);
    final incoming = _incomingTranscripts.remove(key);
    if (incoming == null) return;
    final undo = _speakerUndo.remove(key);
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      _incomingTranscripts[key] = incoming;
      if (undo != null) _speakerUndo[key] = undo;
      notifyListeners();
      rethrow;
    }
  }

  /// Corrects which speaker owns one timed segment. An empty [speakerId]
  /// removes the label instead of guessing another speaker.
  Future<void> setSegmentSpeaker(
    String path,
    int index,
    String speakerId,
  ) async {
    final key = _recordingKey(path: path);
    final segments = _transcriptSegments[key];
    if (segments == null || index < 0 || index >= segments.length) {
      throw ArgumentError('片段不存在');
    }
    final snapshot = _speakerSnapshot(path, label: '手改发言人');
    final shown = transcriptSegmentsForPath(path);
    final previousOverrides = _segmentSpeakers[key] == null
        ? null
        : Map<int, String>.of(_segmentSpeakers[key]!);
    // Undo would take this correction back along with the earlier change.
    final undo = _speakerUndo.remove(key);
    final speaker = speakerId.trim();
    final overrides = _segmentSpeakers.putIfAbsent(key, () => <int, String>{});
    final original = segments[index].speaker;
    final clearsOriginal = speaker.isEmpty && original != null;
    if ((speaker == original && !clearsOriginal) ||
        (speaker.isEmpty && original == null)) {
      overrides.remove(index);
    } else {
      overrides[index] = speaker;
    }
    if (overrides.isEmpty) _segmentSpeakers.remove(key);
    _relabelSpeakerText(path, segments, shown);
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      _restoreSpeakerSnapshot(path, snapshot);
      if (previousOverrides == null) {
        _segmentSpeakers.remove(key);
      } else {
        _segmentSpeakers[key] = previousOverrides;
      }
      if (undo != null) _speakerUndo[key] = undo;
      notifyListeners();
      rethrow;
    }
  }

  Map<String, String> speakerAliasesForPath(String path) =>
      Map<String, String>.unmodifiable(_speakerAliasesForPath(path));

  String? _rawTranscriptForPath(String path) {
    final direct = transcriptsByPath[path];
    if (direct != null && direct.isNotEmpty) return direct;
    final id = fileIdFromPath(path);
    if (id != null) {
      final byId = transcriptsByFileId[id];
      if (byId != null && byId.isNotEmpty) return byId;
    }
    // Only mirror *live* draft onto the newest export while a session is active.
    // Avoids showing a previous take's text on the file list after a new start.
    if (isLiveSession &&
        _currentRecording != null &&
        (fileIdFromPath(path) == _currentRecording!.fileId ||
            path == _currentRecording!.path)) {
      final live = transcript.trim();
      if (live.isNotEmpty) return live;
      final partial = transcriptPartial?.trim();
      if (partial != null && partial.isNotEmpty) return partial;
    }
    return null;
  }

  String? transcriptForFileId(int fileId) {
    final raw =
        _manualTranscripts[_recordingKey(fileId: fileId)] ??
        transcriptsByFileId[fileId];
    if (raw == null) return null;
    return applyTranscriptSpeakerAliases(
      normalizeSttText(raw),
      speakerAliasesByFileId[fileId] ?? const {},
    );
  }

  List<TranscriptSpeaker> transcriptSpeakersForPath(String path) {
    final raw = manualTranscriptForPath(path) ?? _rawTranscriptForPath(path);
    final aliases = _speakerAliasesForPath(path);
    final speakers = raw == null
        ? <TranscriptSpeaker>[]
        : extractTranscriptSpeakers(normalizeSttText(raw), aliases: aliases);
    final seen = {for (final speaker in speakers) speaker.id};
    for (final segment in transcriptSegmentsForPath(path)) {
      final id = segment.speaker;
      if (id == null || !seen.add(id)) continue;
      final alias = aliases[id]?.trim();
      speakers.add(
        TranscriptSpeaker(
          id: id,
          defaultLabel: '说话人 $id',
          displayLabel: alias == null || alias.isEmpty ? '说话人 $id' : alias,
        ),
      );
    }
    return speakers;
  }

  Future<void> renameTranscriptSpeaker(
    String path,
    String speakerId,
    String value,
  ) async {
    final id = speakerId.trim();
    final raw = canonicalTranscriptForPath(path);
    final known =
        raw != null &&
        extractTranscriptSpeakers(
          normalizeSttText(raw),
        ).any((speaker) => speaker.id == id);
    final knownFromSegments = transcriptSegmentsForPath(
      path,
    ).any((segment) => segment.speaker == id);
    if (id.isEmpty || (!known && !knownFromSegments)) {
      throw ArgumentError('说话人不存在');
    }

    var alias = value.trim();
    alias = alias.replaceFirst(RegExp(r'[:：]\s*$'), '').trimRight();
    if (alias.isEmpty) throw ArgumentError('请输入说话人姓名');
    if (alias.runes.length > 40) throw ArgumentError('说话人姓名不能超过 40 个字符');

    final defaultLabel = '说话人 $id';
    // Undo would take the new name back along with the earlier change.
    _speakerUndo.remove(_recordingKey(path: path));
    _setSpeakerAlias(speakerAliasesByPath, path, id, alias, defaultLabel);
    final fileId = fileIdFromPath(path);
    if (fileId != null) {
      _setSpeakerAlias(speakerAliasesByFileId, fileId, id, alias, defaultLabel);
    }
    notifyListeners();
    await _persistTranscripts();
  }

  Map<String, String> _speakerAliasesForPath(String path) {
    final direct = speakerAliasesByPath[path];
    if (direct != null) return direct;
    final id = fileIdFromPath(path);
    return id == null ? const {} : speakerAliasesByFileId[id] ?? const {};
  }

  void _setSpeakerAlias<K>(
    Map<K, Map<String, String>> aliasesByRecording,
    K recording,
    String speakerId,
    String alias,
    String defaultLabel,
  ) {
    if (alias == defaultLabel) {
      final aliases = aliasesByRecording[recording];
      aliases?.remove(speakerId);
      if (aliases?.isEmpty ?? false) aliasesByRecording.remove(recording);
      return;
    }
    aliasesByRecording.putIfAbsent(
      recording,
      () => <String, String>{},
    )[speakerId] = alias;
  }

  void _clearSpeakerAliases(String path) {
    speakerAliasesByPath.remove(path);
    final id = fileIdFromPath(path);
    if (id != null) speakerAliasesByFileId.remove(id);
  }

  int? expectedSpeakersForPath(String path) =>
      _expectedSpeakers[_recordingKey(path: path)];

  Future<void> setExpectedSpeakers(String path, int? count) async {
    final key = _recordingKey(path: path);
    final next = count == null || count <= 0 ? null : count;
    if (_expectedSpeakers[key] == next) return;
    _speakerUndo.remove(key);
    if (next == null) {
      _expectedSpeakers.remove(key);
    } else {
      _expectedSpeakers[key] = next;
    }
    notifyListeners();
    await _persistTranscripts();
  }

  DiarizationQuality? diarizationQualityForPath(String path) =>
      _diarizationQuality[_recordingKey(path: path)];

  void _recordDiarizationQuality(String path, DiarizationQuality? quality) {
    final key = _recordingKey(path: path);
    if (quality == null) {
      _diarizationQuality.remove(key);
    } else {
      _diarizationQuality[key] = quality;
    }
    _speakerHintDismissed.remove(key);
  }

  Future<void> setDiarizationQualityForPath(
    String path,
    DiarizationQuality? quality,
  ) async {
    _recordDiarizationQuality(path, quality);
    notifyListeners();
    await _persistTranscripts();
  }

  bool speakerHintDismissed(String path) =>
      _speakerHintDismissed.contains(_recordingKey(path: path));

  /// Whether the merge-risk hint banner should be shown above the transcript
  /// for [path] (S24).
  ///
  /// Shown when [DiarizationQuality.shouldSuggestRediarize] is true, the user
  /// has not dismissed the hint, and the user has not given
  /// [expectedSpeakersForPath]: whether chosen on recording or importing
  /// (R24.2) or on redoing the speakers, the hint would only ask for it again.
  bool shouldShowSpeakerMergeHint(String path) {
    final key = _recordingKey(path: path);
    if (_speakerHintDismissed.contains(key)) return false;
    if (_expectedSpeakers.containsKey(key)) return false;
    final quality = _diarizationQuality[key];
    return quality != null && quality.shouldSuggestRediarize;
  }

  Future<void> dismissSpeakerMergeHint(String path) async {
    final key = _recordingKey(path: path);
    _speakerHintDismissed.add(key);
    notifyListeners();
    await _persistTranscripts();
  }

  bool canUndoSpeakerEdit(String path) =>
      _speakerUndo.containsKey(_recordingKey(path: path));

  String? speakerUndoLabel(String path) =>
      _speakerUndo[_recordingKey(path: path)]?.label;

  /// Everything a speaker edit on [path] can change, for undo and for a
  /// failed save.
  SpeakerEditSnapshot _speakerSnapshot(String path, {required String label}) {
    final key = _recordingKey(path: path);
    final id = fileIdFromPath(path);
    return SpeakerEditSnapshot(
      label: label,
      segments: List<TranscriptSegment>.unmodifiable(
        _transcriptSegments[key] ?? const <TranscriptSegment>[],
      ),
      segmentSpeakers: Map<int, String>.unmodifiable(
        _segmentSpeakers[key] ?? const <int, String>{},
      ),
      aliases: Map<String, String>.unmodifiable(_speakerAliasesForPath(path)),
      rawTranscript:
          transcriptsByPath[path] ??
          (id == null ? null : transcriptsByFileId[id]),
      manualTranscript: _manualTranscripts[key],
      incomingTranscript: _incomingTranscripts[key],
      expectedSpeakers: _expectedSpeakers[key],
      quality: _diarizationQuality[key],
      hintDismissed: _speakerHintDismissed.contains(key),
    );
  }

  void _restoreSpeakerSnapshot(String path, SpeakerEditSnapshot snapshot) {
    final key = _recordingKey(path: path);
    _setOrRemove(
      _transcriptSegments,
      key,
      snapshot.segments.isEmpty
          ? null
          : List<TranscriptSegment>.unmodifiable(snapshot.segments),
    );
    _setOrRemove(
      _segmentSpeakers,
      key,
      snapshot.segmentSpeakers.isEmpty
          ? null
          : Map<int, String>.of(snapshot.segmentSpeakers),
    );
    Map<String, String>? aliases() =>
        snapshot.aliases.isEmpty ? null : Map.of(snapshot.aliases);
    _setOrRemove(speakerAliasesByPath, path, aliases());
    final id = fileIdFromPath(path);
    if (id != null) _setOrRemove(speakerAliasesByFileId, id, aliases());
    if (snapshot.rawTranscript case final raw?) {
      _rewriteRawTranscript(path, (_) => raw);
    }
    _setOrRemove(_manualTranscripts, key, snapshot.manualTranscript);
    _setOrRemove(_incomingTranscripts, key, snapshot.incomingTranscript);
    _setOrRemove(_expectedSpeakers, key, snapshot.expectedSpeakers);
    _setOrRemove(_diarizationQuality, key, snapshot.quality);
    if (snapshot.hintDismissed) {
      _speakerHintDismissed.add(key);
    } else {
      _speakerHintDismissed.remove(key);
    }
  }

  /// Applies [edit] to [path] as a speaker edit that undo takes back as
  /// [label]. A failed save puts the recording and its earlier undo back.
  Future<void> _editSpeakers(
    String path, {
    required String label,
    required void Function() edit,
  }) async {
    final key = _recordingKey(path: path);
    final previousUndo = _speakerUndo[key];
    final before = _speakerSnapshot(path, label: label);
    edit();
    _speakerUndo[key] = before;
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      _restoreSpeakerSnapshot(path, before);
      _setOrRemove(_speakerUndo, key, previousUndo);
      notifyListeners();
      rethrow;
    }
  }

  /// Rewrites the provider text of [path], under its path and its file id.
  void _rewriteRawTranscript(String path, String Function(String) rewrite) {
    final byPath = transcriptsByPath[path];
    if (byPath != null && byPath.isNotEmpty) {
      transcriptsByPath[path] = rewrite(byPath);
    }
    final id = fileIdFromPath(path);
    final byId = id == null ? null : transcriptsByFileId[id];
    if (id != null && byId != null && byId.isNotEmpty) {
      transcriptsByFileId[id] = rewrite(byId);
    }
  }

  /// Relabels the lines of [path]'s provider text after its passages changed
  /// speakers, where that text was labelled from the passages as saved
  /// ([base]) or as shown ([shown]).
  void _relabelSpeakerText(
    String path,
    List<TranscriptSegment> base,
    List<TranscriptSegment> shown,
  ) {
    final labelled = {
      for (final segments in [base, shown])
        // Clearing the last speaker leaves plain text. It must still match
        // when a later correction assigns that passage a speaker again.
        _speakerText(segments),
    };
    if (labelled.isEmpty) return;
    final relabelled = _speakerText(transcriptSegmentsForPath(path));
    _rewriteRawTranscript(
      path,
      (text) => labelled.contains(normalizeSttText(text)) ? relabelled : text,
    );
  }

  /// The text a provider writes for [segments]: one line per passage, with
  /// `说话人 N：` where the speaker changes.
  static String _speakerText(List<TranscriptSegment> segments) =>
      normalizeSttText(segments.map(transcriptSegmentLabel).join('\n'));

  /// Merges all segments of [fromSpeakerId] into [intoSpeakerId] for [path]
  /// (S23), in the passages and in every text that labels its lines.
  ///
  /// Alias rule: if [intoSpeakerId] already has a custom alias, it keeps its
  /// own alias; otherwise, if [fromSpeakerId] had a custom alias,
  /// [intoSpeakerId] inherits it. [fromSpeakerId]'s alias is removed.
  Future<void> mergeTranscriptSpeakers(
    String path, {
    required String fromSpeakerId,
    required String intoSpeakerId,
  }) async {
    final from = fromSpeakerId.trim();
    final into = intoSpeakerId.trim();
    if (from.isEmpty || into.isEmpty || from == into) {
      throw ArgumentError('请选择两位不同的发言人进行合并');
    }
    final knownIds = {for (final s in transcriptSpeakersForPath(path)) s.id};
    if (!knownIds.contains(from) || !knownIds.contains(into)) {
      throw ArgumentError('说话人不存在');
    }

    final key = _recordingKey(path: path);
    await _editSpeakers(
      path,
      label: '复原合并发言人',
      edit: () {
        final existingSegments = _transcriptSegments[key];
        if (existingSegments != null && existingSegments.isNotEmpty) {
          final updated = <TranscriptSegment>[];
          String? prevSpeaker;
          for (final seg in existingSegments) {
            final nextSpeaker = seg.speaker == from ? into : seg.speaker;
            final changed = nextSpeaker != null && nextSpeaker != prevSpeaker;
            updated.add(
              seg.copyWith(
                speaker: nextSpeaker,
                clearSpeaker: nextSpeaker == null,
                speakerChanged: changed,
              ),
            );
            prevSpeaker = nextSpeaker;
          }
          _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(
            updated,
          );
        }

        final overrides = _segmentSpeakers[key];
        if (overrides != null && overrides.isNotEmpty) {
          for (final index in overrides.keys.toList()) {
            if (overrides[index] == from) {
              overrides[index] = into;
            }
          }
        }

        // The provider text, the user's edit of it and a newer provider text
        // waiting under that edit all label their lines.
        final prefix = RegExp(
          '^(\\s*)说话人\\s+${RegExp.escape(from)}：',
          multiLine: true,
        );
        String relabel(String text) => text.replaceAllMapped(
          prefix,
          (m) => '${m.group(1) ?? ''}说话人 $into：',
        );
        _rewriteRawTranscript(path, relabel);
        if (_manualTranscripts[key] case final manual?) {
          _manualTranscripts[key] = relabel(manual);
        }
        if (_incomingTranscripts[key] case final incoming?) {
          _incomingTranscripts[key] = relabel(incoming);
        }

        final currentAliases = Map<String, String>.of(
          _speakerAliasesForPath(path),
        );
        final intoAlias = currentAliases[into]?.trim();
        final fromAlias = currentAliases.remove(from)?.trim();
        if ((intoAlias == null || intoAlias.isEmpty) &&
            fromAlias != null &&
            fromAlias.isNotEmpty &&
            fromAlias != '说话人 $into') {
          currentAliases[into] = fromAlias;
        }
        if (currentAliases.isEmpty) {
          speakerAliasesByPath.remove(path);
        } else {
          speakerAliasesByPath[path] = currentAliases;
        }
        final fileId = fileIdFromPath(path);
        if (fileId != null) {
          if (currentAliases.isEmpty) {
            speakerAliasesByFileId.remove(fileId);
          } else {
            speakerAliasesByFileId[fileId] = Map<String, String>.of(
              currentAliases,
            );
          }
        }
      },
    );
  }

  // Speaker passes run one at a time: each loads both models and the whole
  // recording. The last pass queued, until it ends.
  Future<void>? _lastSpeakerPass;

  /// Recording key → speaker passes queued or running for it.
  final Map<String, int> _speakerPasses = {};

  /// Whether the speakers of [path] are being labelled.
  bool labellingSpeakers(String path) =>
      _speakerPasses.containsKey(_recordingKey(path: path));

  Future<T> _runSpeakerPass<T>(String key, Future<T> Function() pass) async {
    _speakerPasses.update(key, (count) => count + 1, ifAbsent: () => 1);
    if (!_disposed) notifyListeners();
    final previous = _lastSpeakerPass;
    final ended = Completer<void>();
    _lastSpeakerPass = ended.future;
    try {
      if (previous != null) await previous;
      return await pass();
    } finally {
      ended.complete();
      if (identical(_lastSpeakerPass, ended.future)) _lastSpeakerPass = null;
      final left = _speakerPasses[key]! - 1;
      if (left == 0) {
        _speakerPasses.remove(key);
      } else {
        _speakerPasses[key] = left;
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<DiarizationResult> _diarize(
    String path, {
    int? expectedSpeakers,
  }) async => _effectiveSpeakerDiarizer.diarize(
    await _convertExportToWav(path),
    expectedSpeakers: expectedSpeakers,
  );

  /// Labels the speakers of [path]'s saved passages, outside the
  /// transcription job that saved them. Speakers keep the ids, and so the
  /// names, of the people in [previous] they match by time (R22.2).
  ///
  /// Does nothing when the passages already have speakers, and drops the
  /// result when they change before the pass ends.
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  Future<void> _labelSpeakersLater(
    String path,
    List<TranscriptSegment> previous,
  ) async {
    if (_disposed || !_labelsSpeakersAutomatically) return;
    final key = _recordingKey(path: path);
    final base = _transcriptSegments[key];
    if (base == null ||
        base.isEmpty ||
        base.any((segment) => segment.speaker != null)) {
      return;
    }
    bool current() => !_disposed && identical(_transcriptSegments[key], base);
    try {
      await _runSpeakerPass(key, () async {
        if (!current()) return;
        final diarized = await _diarize(
          path,
          expectedSpeakers: _expectedSpeakers[key],
        );
        if (!current() || diarized.turns.isEmpty) return;
        final overrides = _segmentSpeakers[key] ?? const <int, String>{};
        _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(
          keepSpeakerIds(
            previous,
            assignSpeakersToSegments(diarized.turns, base).segments,
            reserved: {
              ..._speakerAliasesForPath(path).keys,
              ...overrides.values,
            },
          ),
        );
        _recordDiarizationQuality(path, diarized.quality);
        notifyListeners();
        await _persistTranscripts();
      });
    } catch (error) {
      debugPrint('[Diarization] speakers not labelled: $error');
    }
  }

  /// Groups the passages of [path] by speaker again, as about
  /// [expectedSpeakers] people (`大约几个人`, null = automatic), keeping the
  /// words and the passages the user corrected (S10, S22). Speakers keep
  /// their ids, and so their names, where the new grouping matches the old
  /// one by time (R22.2); a provider text labelled from these passages is
  /// relabelled.
  ///
  /// Throws a [StateError], changing nothing, while the speakers of [path]
  /// are being labelled, when its passages change before the pass ends, or
  /// when no speaker is found.
  Future<void> rediarizeSpeakers(
    String path, {
    int? expectedSpeakers,
    List<DiarizationTurn>? turnsOverride,
    DiarizationQuality? qualityOverride,
  }) async {
    final key = _recordingKey(path: path);
    final base = _transcriptSegments[key];
    if (base == null || base.isEmpty) {
      throw StateError('当前录音没有可区分发言人的时间分段');
    }
    if (_speakerPasses.containsKey(key)) {
      throw StateError('正在区分发言人，请稍候');
    }
    await _runSpeakerPass(key, () async {
      final diarized = turnsOverride != null
          ? DiarizationResult(turns: turnsOverride, quality: qualityOverride)
          : await _diarize(path, expectedSpeakers: expectedSpeakers);
      if (_disposed) return;
      if (!identical(_transcriptSegments[key], base)) {
        throw StateError('录音内容已更新，请重新区分发言人');
      }
      if (diarized.turns.isEmpty) {
        throw StateError('没能从录音里分出发言人，原来的发言人没有改动');
      }
      await _editSpeakers(
        path,
        label: '复原重新区分发言人',
        edit: () {
          _setOrRemove(
            _expectedSpeakers,
            key,
            expectedSpeakers == null || expectedSpeakers <= 0
                ? null
                : expectedSpeakers,
          );
          final shown = transcriptSegmentsForPath(path);
          final overrides = _segmentSpeakers[key] ?? const <int, String>{};
          _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(
            keepSpeakerIds(
              base,
              assignSpeakersToSegments(diarized.turns, base).segments,
              corrected: overrides.keys.toSet(),
              reserved: {
                ..._speakerAliasesForPath(path).keys,
                ...overrides.values,
              },
            ),
          );
          _relabelSpeakerText(path, base, shown);
          _recordDiarizationQuality(path, qualityOverride ?? diarized.quality);
        },
      );
    });
  }

  /// Restores the state saved before the most recent [mergeTranscriptSpeakers]
  /// or [rediarizeSpeakers] on [path] (S23). A failed save leaves the edit
  /// and its undo in place.
  Future<bool> undoSpeakerEdit(String path) async {
    final key = _recordingKey(path: path);
    final snapshot = _speakerUndo.remove(key);
    if (snapshot == null) return false;
    final current = _speakerSnapshot(path, label: snapshot.label);
    _restoreSpeakerSnapshot(path, snapshot);
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      _restoreSpeakerSnapshot(path, current);
      _speakerUndo[key] = snapshot;
      notifyListeners();
      rethrow;
    }
    return true;
  }

  /// Replaces all occurrences of [fromTerm] with [toTerm] across [path]'s
  /// transcript text and timed segments while preserving segment timecodes
  /// (#493 / S34).
  Future<bool> replaceTermInTranscript(
    String path,
    String fromTerm,
    String toTerm,
  ) async {
    final from = fromTerm.trim();
    final to = toTerm.trim();
    if (from.isEmpty || from == to) return false;
    final key = _recordingKey(path: path);
    final prevByPath = transcriptsByPath[path];
    final fileId = fileIdFromPath(path);
    final prevById = fileId == null ? null : transcriptsByFileId[fileId];
    final prevManual = _manualTranscripts[key];
    final prevIncoming = _incomingTranscripts[key];
    final prevSegments = _transcriptSegments[key];
    final prevSpeakerUndo = _speakerUndo[key];

    var changed = false;
    if (prevByPath != null && prevByPath.contains(from)) {
      transcriptsByPath[path] = prevByPath.replaceAll(from, to);
      changed = true;
    }
    if (fileId != null && prevById != null && prevById.contains(from)) {
      transcriptsByFileId[fileId] = prevById.replaceAll(from, to);
      changed = true;
    }
    if (prevManual != null && prevManual.contains(from)) {
      _manualTranscripts[key] = prevManual.replaceAll(from, to);
      changed = true;
    }
    if (prevIncoming != null && prevIncoming.contains(from)) {
      _incomingTranscripts[key] = prevIncoming.replaceAll(from, to);
      changed = true;
    }
    if (prevSegments != null &&
        prevSegments.any((seg) => seg.text.contains(from))) {
      _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable([
        for (final seg in prevSegments)
          seg.text.contains(from)
              ? seg.copyWith(text: seg.text.replaceAll(from, to))
              : seg,
      ]);
      changed = true;
    }
    if (!changed) return false;
    _speakerUndo.remove(key);
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      _setOrRemove(transcriptsByPath, path, prevByPath);
      if (fileId != null) {
        _setOrRemove(transcriptsByFileId, fileId, prevById);
      }
      _setOrRemove(_manualTranscripts, key, prevManual);
      _setOrRemove(_incomingTranscripts, key, prevIncoming);
      _setOrRemove(_transcriptSegments, key, prevSegments);
      _setOrRemove(_speakerUndo, key, prevSpeakerUndo);
      notifyListeners();
      rethrow;
    }
    return true;
  }

  /// Every map holding a recording's transcript state under its key.
  List<Map<String, Object>> get _transcriptStateByKey => [
    _transcriptMetadata,
    _recordingTranslations,
    _transcriptSegments,
    _manualTranscripts,
    _incomingTranscripts,
    _segmentSpeakers,
    _expectedSpeakers,
    _diarizationQuality,
    _speakerUndo,
  ];

  /// Drops the transcript state of a deleted recording.
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  void _forgetTranscriptState(String key) {
    for (final state in _transcriptStateByKey) {
      state.remove(key);
    }
    _speakerHintDismissed.remove(key);
  }

  /// Moves the transcript state of a renamed recording to its new key.
  // Used by other parts through their abstract declarations.
  // ignore: unused_element
  void _moveTranscriptState(String from, String to) {
    if (from == to) return;
    for (final state in _transcriptStateByKey) {
      final value = state.remove(from);
      if (value != null) state[to] = value;
    }
    if (_speakerHintDismissed.remove(from)) _speakerHintDismissed.add(to);
  }

  /// path → last STT text for that local export.
  final Map<String, String> transcriptsByPath = {};

  /// fileId → STT text (device list + local).
  final Map<int, String> transcriptsByFileId = {};

  /// Recording key → provider-timed transcript segments.
  final Map<String, List<TranscriptSegment>> _transcriptSegments = {};

  /// Local recording path → provider speaker id → custom display name.
  final Map<String, Map<String, String>> speakerAliasesByPath = {};

  /// Device file id → provider speaker id → custom display name.
  final Map<int, Map<String, String>> speakerAliasesByFileId = {};

  /// Recording key → manual transcript text that must survive re-transcription.
  final Map<String, String> _manualTranscripts = {};

  /// Recording key → provider text that arrived after a manual edit.
  final Map<String, String> _incomingTranscripts = {};

  /// Recording key → segment index → corrected speaker id.
  final Map<String, Map<int, String>> _segmentSpeakers = {};
  final Map<String, int> _expectedSpeakers = {};
  final Map<String, DiarizationQuality> _diarizationQuality = {};
  final Set<String> _speakerHintDismissed = {};
  final Map<String, SpeakerEditSnapshot> _speakerUndo = {};
  // Used by other parts through their abstract declarations.
  // ignore: prefer_final_fields
  Future<void> _transcriptsLoaded = Future<void>.value();

  @visibleForTesting
  Future<void> waitForTranscripts() => _transcriptsLoaded;
}

void _setOrRemove<K, V extends Object>(Map<K, V> map, K key, V? value) {
  if (value == null) {
    map.remove(key);
  } else {
    map[key] = value;
  }
}
