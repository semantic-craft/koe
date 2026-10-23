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
  SpeakerDiarizer get _effectiveSpeakerDiarizer;
  bool _isRecordingAudioLocked(int? id, String? path);
  Future<void> _maybeAutoGenerateTopicNoteForKey(
    String key, {
    String? pathHint,
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
    final languageChanged =
        sourceLanguage != null && sourceLanguage != metadata?.sourceLanguage;
    final textChanged = manual == null && previous != t;
    final visibleChanged = textChanged || languageChanged;
    if (textChanged) {
      // Speaker display names belong to the material, not to one provider run.
      // Keep them when a manual transcript already protects the visible text.
      _clearSpeakerAliases(path);
      _transcriptSegments.remove(key);
      _speakerUndo.remove(key);
      _speakerHintDismissed.remove(key);
    }
    // Segment speaker fixes are indexed into the stored segment list; they do
    // not carry over to a different list from another provider run.
    if (textChanged ||
        (segments != null &&
            !listEquals(segments, _transcriptSegments[key] ?? const []))) {
      _segmentSpeakers.remove(key);
    }
    if (manual != null && t != manual) {
      _incomingTranscripts[key] = t;
    }
    if (manual != null && t == manual) _incomingTranscripts.remove(key);
    _transcriptMetadata[key] = TranscriptMetadata(
      provider: provider ?? metadata?.provider ?? speechProvider,
      sourceLanguage: sourceLanguage ?? metadata?.sourceLanguage,
      revision: (metadata?.revision ?? 0) + (visibleChanged ? 1 : 0),
    );
    transcriptsByPath[path] = t;
    _transcriptPathsByKey[key] = path;
    if (segments == null) {
      // Callers that only revise text or metadata keep existing sentence times.
    } else if (segments.isEmpty) {
      _transcriptSegments.remove(key);
    } else {
      _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(segments);
    }
    // Also index by file id when known.
    final id = fileIdFromPath(path);
    if (id != null) transcriptsByFileId[id] = t;
    unawaited(_persistTranscripts());
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
    if (manual != null) _pinTranslationSource(key, manual);
    _manualTranscripts.remove(key);
    notifyListeners();
    await _persistTranscripts(strict: true);
  }

  Future<void> adoptIncomingTranscript(String path) async {
    final key = _recordingKey(path: path);
    final incoming = _incomingTranscripts.remove(key);
    if (incoming == null) return;
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
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      _incomingTranscripts[key] = incoming;
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
    final previousOverrides = _segmentSpeakers[key] == null
        ? null
        : Map<int, String>.of(_segmentSpeakers[key]!);
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
    notifyListeners();
    try {
      await _persistTranscripts(strict: true);
    } catch (_) {
      if (previousOverrides == null) {
        _segmentSpeakers.remove(key);
      } else {
        _segmentSpeakers[key] = previousOverrides;
      }
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
    if (count == null || count <= 0) {
      _expectedSpeakers.remove(key);
    } else {
      _expectedSpeakers[key] = count;
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
  /// has not dismissed the hint, and the user has not already pinned an
  /// explicit [expectedSpeakersForPath].
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

  void _saveSpeakerUndoSnapshot(String path, {required String label}) {
    final key = _recordingKey(path: path);
    final segments = _transcriptSegments[key] ?? const <TranscriptSegment>[];
    final overrides = _segmentSpeakers[key] ?? const <int, String>{};
    final aliases = _speakerAliasesForPath(path);
    _speakerUndo[key] = SpeakerEditSnapshot(
      label: label,
      segments: List<TranscriptSegment>.unmodifiable(segments),
      segmentSpeakers: Map<int, String>.unmodifiable(
        Map<int, String>.of(overrides),
      ),
      aliases: Map<String, String>.unmodifiable(Map<String, String>.of(aliases)),
      rawTranscript: transcriptsByPath[path],
      expectedSpeakers: _expectedSpeakers[key],
      quality: _diarizationQuality[key],
      hintDismissed: _speakerHintDismissed.contains(key),
    );
  }

  /// Merges all segments of [fromSpeakerId] into [intoSpeakerId] for [path]
  /// (S23).
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
    final knownIds = {
      for (final s in transcriptSpeakersForPath(path)) s.id,
    };
    if (!knownIds.contains(from) || !knownIds.contains(into)) {
      throw ArgumentError('说话人不存在');
    }

    final key = _recordingKey(path: path);
    _saveSpeakerUndoSnapshot(path, label: '复原合并发言人');

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
      _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(updated);
    }

    final overrides = _segmentSpeakers[key];
    if (overrides != null && overrides.isNotEmpty) {
      for (final index in overrides.keys.toList()) {
        if (overrides[index] == from) {
          overrides[index] = into;
        }
      }
    }

    final rawText = transcriptsByPath[path];
    if (rawText != null && rawText.isNotEmpty) {
      final prefixRegex = RegExp(
        '^(\\s*)说话人\\s+${RegExp.escape(from)}：',
        multiLine: true,
      );
      final replaced = rawText.replaceAllMapped(
        prefixRegex,
        (m) => '${m.group(1) ?? ''}说话人 $into：',
      );
      transcriptsByPath[path] = replaced;
      final fileId = fileIdFromPath(path);
      if (fileId != null && transcriptsByFileId.containsKey(fileId)) {
        transcriptsByFileId[fileId] = replaced;
      }
    }

    final currentAliases = Map<String, String>.of(_speakerAliasesForPath(path));
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
        speakerAliasesByFileId[fileId] = Map<String, String>.of(currentAliases);
      }
    }

    notifyListeners();
    await _persistTranscripts(strict: true);
  }

  /// Re-runs speaker diarization on [path] with optional [expectedSpeakers]
  /// (`大约几个人`, null = auto) while keeping the transcript text unchanged
  /// and preserving all manually edited segment speakers in [_segmentSpeakers]
  /// (S10, S22).
  Future<void> rediarizeSpeakers(
    String path, {
    int? expectedSpeakers,
    List<DiarizationTurn>? turnsOverride,
    DiarizationQuality? qualityOverride,
  }) async {
    final key = _recordingKey(path: path);
    final currentSegments = _transcriptSegments[key];
    if (currentSegments == null || currentSegments.isEmpty) {
      throw StateError('当前录音没有可区分发言人的时间分段');
    }

    final List<DiarizationTurn> turns;
    final DiarizationQuality? quality;
    if (turnsOverride != null) {
      turns = turnsOverride;
      quality = qualityOverride;
    } else {
      final wavPath = await _convertExportToWav(path);
      final diarized = await _effectiveSpeakerDiarizer.diarize(
        wavPath,
        expectedSpeakers: expectedSpeakers,
      );
      turns = diarized.turns;
      quality = qualityOverride ?? diarized.quality;
    }

    _saveSpeakerUndoSnapshot(path, label: '复原重新区分发言人');
    if (expectedSpeakers == null || expectedSpeakers <= 0) {
      _expectedSpeakers.remove(key);
    } else {
      _expectedSpeakers[key] = expectedSpeakers;
    }

    final assigned = assignSpeakersToSegments(turns, currentSegments);
    // Manual per-segment speaker edits in _segmentSpeakers[key] are intentionally
    // preserved so transcriptSegmentsForPath(path) keeps user corrections.
    final overrides = _segmentSpeakers[key] ?? const <int, String>{};
    _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(
      keepSpeakerIds(
        currentSegments,
        assigned.segments,
        corrected: overrides.keys.toSet(),
        reserved: {..._speakerAliasesForPath(path).keys, ...overrides.values},
      ),
    );
    _recordDiarizationQuality(path, quality);

    notifyListeners();
    await _persistTranscripts(strict: true);
  }

  /// Restores the state saved before the most recent [mergeTranscriptSpeakers]
  /// or [rediarizeSpeakers] on [path] (S23).
  Future<bool> undoSpeakerEdit(String path) async {
    final key = _recordingKey(path: path);
    final snapshot = _speakerUndo.remove(key);
    if (snapshot == null) return false;

    if (snapshot.segments.isEmpty) {
      _transcriptSegments.remove(key);
    } else {
      _transcriptSegments[key] = List<TranscriptSegment>.unmodifiable(
        snapshot.segments,
      );
    }

    if (snapshot.segmentSpeakers.isEmpty) {
      _segmentSpeakers.remove(key);
    } else {
      _segmentSpeakers[key] = Map<int, String>.of(snapshot.segmentSpeakers);
    }

    if (snapshot.aliases.isEmpty) {
      speakerAliasesByPath.remove(path);
    } else {
      speakerAliasesByPath[path] = Map<String, String>.of(snapshot.aliases);
    }
    final fileId = fileIdFromPath(path);
    if (fileId != null) {
      if (snapshot.aliases.isEmpty) {
        speakerAliasesByFileId.remove(fileId);
      } else {
        speakerAliasesByFileId[fileId] = Map<String, String>.of(
          snapshot.aliases,
        );
      }
    }

    if (snapshot.rawTranscript != null) {
      transcriptsByPath[path] = snapshot.rawTranscript!;
      if (fileId != null && transcriptsByFileId.containsKey(fileId)) {
        transcriptsByFileId[fileId] = snapshot.rawTranscript!;
      }
    }

    if (snapshot.expectedSpeakers == null) {
      _expectedSpeakers.remove(key);
    } else {
      _expectedSpeakers[key] = snapshot.expectedSpeakers!;
    }

    if (snapshot.quality == null) {
      _diarizationQuality.remove(key);
    } else {
      _diarizationQuality[key] = snapshot.quality!;
    }

    if (snapshot.hintDismissed) {
      _speakerHintDismissed.add(key);
    } else {
      _speakerHintDismissed.remove(key);
    }

    notifyListeners();
    await _persistTranscripts(strict: true);
    return true;
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
