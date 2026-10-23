part of '../recorder_controller.dart';

/// Playback of local recordings: the audio player wiring, resume history,
/// the listening queue and bookmarks.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderPlayback on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  abstract bool _disposed;
  bool _isRecordingAudioLocked(int? id, String? path);
  abstract final AudioPlayer _player;
  String _referenceKey(RecordingReference ref);
  abstract final List<StreamSubscription> _subs;
  abstract final Map<String, TranscriptMetadata> _transcriptMetadata;
  abstract String? errorMessage;
  abstract String? expandedLocalPath;
  int? fileIdFromPath(String path);
  abstract final RecordingLibraryStore library;
  Duration? localDurationForPath(String path);
  abstract final Map<int, String> localPathsByFileId;
  RecordingViewData recordingView(RecordingReference ref);
  Map<String, String> speakerAliasesForPath(String path);
  abstract String? statusMessage;
  // END DEPS

  late final PlaybackHistoryStore playbackHistory;
  late final Future<void> _playbackHistoryLoaded;
  late final RecordingBookmarkStore bookmarks;
  late final Future<void> _bookmarksLoaded;
  late final ListeningQueueStore listeningQueue;
  late final Future<void> _listeningQueueLoaded;
  Future<void> _queueActions = Future<void>.value();
  String? queueNotice;

  DateTime _lastHistoryPersist = DateTime.fromMillisecondsSinceEpoch(0);
  int _audioSwitchDepth = 0;
  bool get _switchingAudio => _audioSwitchDepth > 0;

  /// Monotonic playback intent. Every explicit play/stop/seek request bumps it;
  /// a queued auto-advance checks it across async boundaries and abandons when
  /// the user has chosen something newer.
  int _playbackIntent = 0;

  /// Queue entry that asked for the next real audio load; consumed by
  /// [playExported]. Null means the load was started outside the queue.
  String? _pendingQueuePlaybackKey;

  /// Queue entry that owns the audio loaded now, or null when the user started
  /// it outside the queue. A missing current item can leave the previous queue
  /// entry's paused audio loaded, which is not an external playback intent.
  String? _playbackQueueEntryKey;
  bool _pausePersistArmed = false;
  Duration _confirmedPosition = Duration.zero;
  bool _playbackStartedSinceSource = false;

  void _wirePlayer() {
    _subs.add(
      _player.playerStateStream.listen((s) {
        isPlaying = s.playing;
        // Clear sticky "正在播放" header once audio is no longer playing.
        if (!s.playing) {
          _clearPlayingStatus();
          // Stop/loading events during a source switch still carry the old
          // path but may already expose the new source's zero position.
          if (_pausePersistArmed &&
              !_switchingAudio &&
              _player.processingState == ProcessingState.ready) {
            _pausePersistArmed = false;
            unawaited(_persistPlayback(at: _confirmedPosition));
          }
        } else if (!_switchingAudio) {
          _playbackStartedSinceSource = true;
          _pausePersistArmed = true;
        }
        notifyListeners();
      }),
    );
    // Position ticks only reach [positionListenable] (progress bar, time
    // text, active sentence); the controller itself is not notified, so the
    // rest of the tree does not rebuild while audio plays.
    _subs.add(
      _player.positionStream.listen((pos) {
        position = pos;
        final now = DateTime.now();
        if (_switchingAudio) return;
        final paused = !isPlaying && !playbackCompleted;
        final changed = pos != _confirmedPosition;
        final resumedAfterCompletion =
            playbackCompleted &&
            duration > Duration.zero &&
            pos < duration - const Duration(milliseconds: 500);
        if (resumedAfterCompletion) {
          // A lock-screen or notification seek bypasses seekTo.
          playbackCompleted = false;
          _confirmedPosition = pos;
          unawaited(_persistPlayback(at: pos));
          notifyListeners();
        } else if (isPlaying ||
            pos > Duration.zero ||
            paused && changed && _playbackStartedSinceSource) {
          // Position events before the player reports "playing" still carry
          // real progress. A paused seek must persist immediately, including
          // a seek back to zero; source-initialization zero events are ignored
          // until that source has actually started playing.
          _confirmedPosition = pos;
          if (paused ||
              now.difference(_lastHistoryPersist) >=
                  const Duration(seconds: 2)) {
            _lastHistoryPersist = now;
            unawaited(_persistPlayback(at: _confirmedPosition));
          }
        }
      }),
    );
    _subs.add(
      _player.durationStream.listen((d) {
        duration = d ?? Duration.zero;
        notifyListeners();
      }),
    );
    _subs.add(
      _player.processingStateStream.listen((state) {
        if (state == ProcessingState.completed) {
          if (_switchingAudio) return;
          final completedPath = playingPath;
          final completedId = playingFileId;
          final completedIntent = _playbackIntent;
          isPlaying = false;
          // Keep the final position and mark completion so the UI never looks
          // like it is still playing or silently restarts at zero.
          playbackCompleted = true;
          if (duration > Duration.zero) position = duration;
          _confirmedPosition = position;
          _clearPlayingStatus();
          unawaited(_player.pause());
          _pausePersistArmed = false;
          unawaited(_persistPlayback(completed: true));
          if (completedPath != null) {
            unawaited(
              _enqueueQueueAction(
                () => _advanceQueueAfterCompletion(
                  path: completedPath,
                  fileId: completedId,
                  intent: completedIntent,
                ),
              ),
            );
          }
          notifyListeners();
        }
      }),
    );
  }

  /// Drop playback-only status so Home header does not stick on "正在播放".
  void _clearPlayingStatus() {
    final m = statusMessage;
    if (m == null) return;
    if (m.startsWith('正在播放') || m.startsWith('正在准备播放')) {
      statusMessage = null;
    }
  }

  String? playingPath;

  /// File id of the currently loaded local track (if parseable from path).
  int? playingFileId;
  bool isPlaying = false;
  bool playbackCompleted = false;

  /// Current playback position. Frequent; listen to [positionListenable]
  /// instead of the controller to follow it.
  final ValueNotifier<Duration> _position = ValueNotifier(Duration.zero);
  ValueListenable<Duration> get positionListenable => _position;
  Duration get position => _position.value;
  set position(Duration value) => _position.value = value;
  Duration duration = Duration.zero;
  double playbackSpeed = 1.0;

  bool get hasLoadedTrack => playingPath != null;

  String get playingTitle {
    final path = playingPath;
    if (path == null) return '';
    return path.split('/').last;
  }

  double get playbackProgress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  bool isFilePlaying(int fileId) => playingFileId == fileId && isPlaying;

  bool isFileLoaded(int fileId) => playingFileId == fileId;

  PlaybackPoint? get latestPlayback {
    final point = playbackHistory.latest;
    if (point == null) return null;
    final path = point.fileId == null
        ? point.path
        : localPathsByFileId[point.fileId];
    if (path == null || !File(path).existsSync()) return null;
    return point.path == path ? point : point.copyWith(path: path);
  }

  String? get continuePath => playingPath ?? latestPlayback?.path;

  bool get continueCompleted =>
      continuePath != null &&
      playingPath == null &&
      (latestPlayback?.completed ?? false);

  String get continueDetail {
    final point = latestPlayback;
    if (point == null || playingPath != null) return '原声保存在手机';
    if (point.completed) return '已听完 · 可重新回听';
    if (point.duration > Duration.zero) {
      return '已听 ${_clock(point.position)} / ${_clock(point.duration)}';
    }
    return '原声保存在手机';
  }

  Duration resumePositionFor(String path, {int? fileId, Duration? total}) {
    final point = playbackHistory.forRecording(fileId: fileId, path: path);
    if (point == null || point.completed) return Duration.zero;
    if (total != null &&
        total > Duration.zero &&
        point.position >= total - const Duration(seconds: 1)) {
      return Duration.zero;
    }
    return point.position;
  }

  @visibleForTesting
  Future<void> waitForPlaybackHistory() => _playbackHistoryLoaded;

  List<ListeningQueueEntry> get queueEntries => listeningQueue.entries;
  String? get queueCurrentKey => listeningQueue.currentKey;
  ListeningQueueEntry? get queueCurrent => listeningQueue.current;

  ListeningQueueEntry? queueEntryFor(RecordingReference ref) {
    final view = recordingView(ref);
    return listeningQueue.entryFor(
      fileId: view.reference.fileId,
      path: view.path,
    );
  }

  bool queueContainsRecording(RecordingReference ref) =>
      queueEntryFor(ref) != null;

  @visibleForTesting
  Future<void> waitForListeningQueue() => _listeningQueueLoaded;

  /// Adds one original-audio material. A save failure leaves the queue as it
  /// was and reports the real error instead of showing an unsaved item.
  Future<bool> addToListeningQueue(RecordingReference ref) async {
    await _listeningQueueLoaded;
    final view = recordingView(ref);
    final path = view.path;
    if (path == null) {
      errorMessage = '音频不在本机，先下载后才能加入收听队列';
      notifyListeners();
      return false;
    }
    if (view.audioLocked) {
      errorMessage = '录音保存后即可加入收听队列';
      notifyListeners();
      return false;
    }
    if (!view.originalPresent) {
      errorMessage = '音频不在本机，先下载后才能加入收听队列';
      notifyListeners();
      return false;
    }
    final entry = ListeningQueueEntry(
      path: path,
      fileId: view.reference.fileId ?? fileIdFromPath(path),
      title: _playbackTitle(path),
      addedAt: DateTime.now(),
    );
    try {
      final added = await listeningQueue.add(entry);
      statusMessage = added ? '已加入收听队列' : '已在收听队列中';
      errorMessage = null;
      if (added) queueNotice = null;
      notifyListeners();
      return added;
    } catch (error) {
      debugPrint('[ListeningQueue] add failed: $error');
      errorMessage = '未能加入收听队列：无法写入本机存储';
      notifyListeners();
      return false;
    }
  }

  /// Removes [key]. Removing the current item pauses real audio first; when
  /// [playNext] is chosen the next queue item starts, otherwise nothing plays.
  Future<bool> removeFromListeningQueue(
    String key, {
    bool playNext = false,
  }) async {
    var removed = false;
    await _enqueueQueueAction(() async {
      await _listeningQueueLoaded;
      final index = listeningQueue.indexOf(key);
      if (index < 0) return;
      final entry = _queueEntry(key);
      if (entry == null) return;
      final intent = _playbackIntent;
      final wasCurrent = listeningQueue.currentKey == key;
      // The stored current can lag behind a just-started outside material
      // while its clear write is still queued. Only audio that really belongs
      // to the removed entry may be paused.
      final playsRemoved = _queueEntryIsPlaying(entry);
      final externalPlayback =
          playingPath != null && _playbackQueueEntryKey == null;
      final nextKey = index + 1 < listeningQueue.entries.length
          ? listeningQueue.entries[index + 1].key
          : null;
      // A missing current item can leave the previous queue entry paused at
      // its end. That is still queue audio, so "play next" is allowed; a
      // genuinely new outside selection must never be replaced.
      final canAdvance =
          wasCurrent && playNext && (playsRemoved || !externalPlayback);
      final paused = playsRemoved
          ? await _pauseQueueAudio(expectedIntent: intent, onlyFor: entry)
          : false;
      final intentBeforeRemove = _playbackIntent;
      final mayAdvance = canAdvance && intentBeforeRemove == intent;
      removed = await listeningQueue.remove(
        key,
        nextCurrentKey: mayAdvance ? nextKey : null,
      );
      if (!removed) return;
      if (intentBeforeRemove != _playbackIntent || intent != _playbackIntent) {
        await _reconcileQueueCurrent();
        queueNotice = '已移出该队列项；新的播放未被中断。';
        notifyListeners();
        return;
      }
      if (canAdvance) {
        if (nextKey == null) {
          queueNotice = '已移除当前项，收听队列没有下一项。';
        } else {
          await _playQueueKey(nextKey);
        }
      } else if (wasCurrent && externalPlayback) {
        queueNotice = '已移出该队列项；正在播放的是其他资料，未中断。';
      } else if (wasCurrent && paused) {
        queueNotice = '已移除当前项，播放已暂停。';
      } else if (wasCurrent) {
        queueNotice = '已移除当前项。';
      } else if (paused) {
        queueNotice = '已移出该队列项，播放已暂停。';
      }
      notifyListeners();
    });
    return removed;
  }

  Future<bool> moveQueueEntry(int from, int to) async {
    var moved = false;
    await _enqueueQueueAction(() async {
      await _listeningQueueLoaded;
      moved = await listeningQueue.move(from, to);
      if (moved) notifyListeners();
    });
    return moved;
  }

  Future<void> playQueueEntry(String key) => _enqueueQueueAction(() async {
    await _listeningQueueLoaded;
    await _playQueueKey(key);
  });

  /// Skips the current item, attempting exactly the next one. A missing next
  /// item stays visible instead of being silently treated as the end.
  Future<void> skipQueueEntry(String key) => _enqueueQueueAction(() async {
    await _listeningQueueLoaded;
    if (listeningQueue.currentKey != key) return;
    final index = listeningQueue.indexOf(key);
    if (index < 0) return;
    final intent = _playbackIntent;
    final nextKey = index + 1 < listeningQueue.entries.length
        ? listeningQueue.entries[index + 1].key
        : null;
    await _pauseQueueAudio(expectedIntent: intent);
    if (intent != _playbackIntent) {
      await _reconcileQueueCurrent();
      return;
    }
    queueNotice = null;
    if (nextKey == null) {
      await listeningQueue.setCurrent(null);
      queueNotice = '已到收听队列末尾。';
      notifyListeners();
      return;
    }
    await listeningQueue.setCurrent(nextKey);
    await _playQueueKey(nextKey);
  });

  Future<void> retryQueueEntry(String key) => playQueueEntry(key);

  @visibleForTesting
  Future<void> waitForQueueIdle() async {
    await _listeningQueueLoaded;
    for (var spin = 0; spin < 50; spin++) {
      final pending = _queueActions;
      await pending.catchError((Object _) {});
      if (identical(pending, _queueActions)) return;
    }
  }

  ListeningQueueAvailability queueAvailabilityFor(ListeningQueueEntry entry) {
    final view = recordingView(_queueReference(entry));
    final asset = view.path == null ? null : library.assetForPath(view.path!);
    final path = view.path ?? entry.path;
    final fileId = view.reference.fileId ?? entry.fileId;
    ListeningQueueAvailability unavailable(String reason) =>
        ListeningQueueAvailability(
          playable: false,
          reason: reason,
          path: path,
          fileId: fileId,
        );
    if (asset?.permanentlyDeleted == true) {
      return unavailable('资料已删除，无法播放；可移除或跳过。');
    }
    if (asset?.trashed == true) {
      return unavailable('已移到回收站，恢复后可继续收听。');
    }
    if (view.audioLocked) {
      return unavailable('录音仍在保存，保存完成后再收听。');
    }
    if (path.isEmpty) {
      return unavailable('音频未下载，先在设备端取回后再收听。');
    }
    final file = File(path);
    if (!file.existsSync()) {
      return unavailable('音频缺失，可重试或跳过。');
    }
    try {
      if (file.lengthSync() == 0) {
        return unavailable('音频为空，无法播放；可重试或跳过。');
      }
    } catch (_) {
      return unavailable('音频无法读取，可重试或跳过。');
    }
    return ListeningQueueAvailability(
      playable: true,
      reason: '可以播放',
      path: path,
      fileId: fileId,
    );
  }

  Future<void> _enqueueQueueAction(Future<void> Function() action) {
    final operation = _queueActions.then((_) async {
      queueNotice = null;
      await action();
    });
    final guarded = operation.catchError((Object error, StackTrace stack) {
      if (_disposed) return;
      debugPrint('[ListeningQueue] action failed: $error');
      queueNotice = '队列操作失败，请重试。';
      notifyListeners();
    });
    _queueActions = guarded;
    return guarded;
  }

  ListeningQueueEntry? _queueEntry(String key) {
    for (final entry in listeningQueue.entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  RecordingReference _queueReference(ListeningQueueEntry entry) =>
      RecordingReference(
        fileId: entry.fileId ?? fileIdFromPath(entry.path),
        path: entry.path,
      );

  /// Whether the audio loaded right now is really [entry], not another track
  /// the queue's stored current has not caught up with yet.
  bool _queueEntryIsPlaying(ListeningQueueEntry entry) {
    final path = playingPath;
    if (path == null) return false;
    if (path == entry.path) return true;
    if (recordingView(_queueReference(entry)).path == path) return true;
    final id = entry.fileId ?? fileIdFromPath(entry.path);
    return id != null && playingFileId == id;
  }

  String _queueTitle(ListeningQueueEntry entry) {
    final view = recordingView(_queueReference(entry));
    final title = view.title.trim();
    if (title.isEmpty || title == '当前录音') return entry.title;
    return title;
  }

  String _queueUnavailableNotice(
    ListeningQueueEntry entry,
    ListeningQueueAvailability availability,
  ) => '「${_queueTitle(entry)}」${availability.reason}';

  /// Loads [key], resuming that material's own history point. A missing item
  /// becomes current and stays paused; it is never replaced by another file.
  Future<void> _playQueueKey(String key) async {
    final entry = _queueEntry(key);
    if (entry == null) return;
    final intent = _playbackIntent;
    final availability = queueAvailabilityFor(entry);
    if (!availability.playable) {
      if (intent != _playbackIntent) {
        await _reconcileQueueCurrent();
        return;
      }
      // Selecting a broken item must not leave the previous track playing as
      // if it were still the queue's current material.
      await _pauseQueueAudio(expectedIntent: intent);
      if (intent != _playbackIntent) {
        await _reconcileQueueCurrent();
        return;
      }
      await listeningQueue.setCurrent(key);
      if (intent != _playbackIntent) {
        await _reconcileQueueCurrent();
        return;
      }
      queueNotice = _queueUnavailableNotice(entry, availability);
      notifyListeners();
      return;
    }
    await listeningQueue.setCurrent(key);
    // The write above can take a while; a newer manual selection must win.
    if (intent != _playbackIntent) {
      await _reconcileQueueCurrent();
      return;
    }
    queueNotice = null;
    _pendingQueuePlaybackKey = key;
    final play = playExported(availability.path!, fileId: availability.fileId);
    final ownIntent = _playbackIntent;
    await play;
    if (ownIntent != _playbackIntent) {
      await _reconcileQueueCurrent();
      return;
    }
    if (playingPath != availability.path) {
      queueNotice = '「${_queueTitle(entry)}」无法播放，请重新下载后重试。';
    }
    notifyListeners();
  }

  Future<void> _advanceQueueAfterCompletion({
    required String path,
    int? fileId,
    required int intent,
  }) async {
    await _listeningQueueLoaded;
    if (_disposed) return;
    // The completion event was captured before this action reached the front
    // of the queue chain. A restart or seek of the same finished track bumps
    // the intent without changing path/id/current, so compare the captured
    // value, not the current one.
    if (intent != _playbackIntent) return;
    final current = listeningQueue.current;
    if (current == null) return;
    // The user or the system may have started another track before this queued
    // advance runs; never override it.
    if (playingPath != path ||
        (fileId != null && playingFileId != fileId) ||
        !current.matches(fileId: fileId, path: path)) {
      return;
    }
    final index = listeningQueue.indexOf(current.key);
    if (index < 0) return;
    final nextKey = index + 1 < listeningQueue.entries.length
        ? listeningQueue.entries[index + 1].key
        : null;
    if (nextKey == null) {
      if (intent != _playbackIntent) return;
      queueNotice = '收听队列已播完。';
      notifyListeners();
      return;
    }
    if (intent != _playbackIntent) return;
    await _playQueueKey(nextKey);
  }

  /// Persists the real point, then pauses the audio that was loaded when this
  /// started. If the user starts something newer during the write, or the
  /// loaded track is no longer [onlyFor], nothing is paused.
  Future<bool> _pauseQueueAudio({
    int? expectedIntent,
    ListeningQueueEntry? onlyFor,
  }) async {
    final path = playingPath;
    if (path == null) return false;
    final fileId = playingFileId;
    await _persistPlayback(at: _confirmedPosition);
    if (expectedIntent != null && expectedIntent != _playbackIntent) {
      return false;
    }
    if (onlyFor != null && !_queueEntryIsPlaying(onlyFor)) return false;
    if (playingPath != path || playingFileId != fileId) return false;
    try {
      await _player.pause();
    } catch (_) {
      return false;
    }
    _pausePersistArmed = false;
    isPlaying = false;
    _clearPlayingStatus();
    return true;
  }

  /// Makes the persisted queue current match the material actually playing.
  /// A member becomes current; anything outside the queue clears the stale
  /// current so the queue page never points at a track that was superseded.
  Future<void> _syncQueueForPlayback({
    required String path,
    int? fileId,
  }) async {
    await _listeningQueueLoaded;
    if (_disposed) return;
    final entry = listeningQueue.entryFor(fileId: fileId, path: path);
    if (entry == null) {
      if (listeningQueue.currentKey == null) return;
      try {
        await listeningQueue.setCurrent(null);
        if (!_disposed) notifyListeners();
      } catch (error) {
        debugPrint('[ListeningQueue] current clear failed: $error');
        if (_disposed) return;
        queueNotice = '队列状态未能保存，重启后可能不准确。';
        notifyListeners();
      }
      return;
    }
    if (listeningQueue.currentKey == entry.key) return;
    try {
      await listeningQueue.setCurrent(entry.key);
      if (!_disposed) notifyListeners();
    } catch (error) {
      debugPrint('[ListeningQueue] current save failed: $error');
      if (_disposed) return;
      queueNotice = '队列状态未能保存，重启后可能不准确。';
      notifyListeners();
    }
  }

  /// Re-anchors the persisted current item to whatever is actually playing
  /// after a superseded queue action.
  Future<void> _reconcileQueueCurrent() async {
    final path = playingPath;
    if (path == null) {
      if (listeningQueue.currentKey == null) return;
      try {
        await listeningQueue.setCurrent(null);
        if (!_disposed) notifyListeners();
      } catch (error) {
        debugPrint('[ListeningQueue] current clear failed: $error');
      }
      return;
    }
    await _syncQueueForPlayback(path: path, fileId: playingFileId);
  }

  @visibleForTesting
  Future<void> waitForBookmarks() => _bookmarksLoaded;

  bool get showBookmarkMarkers => bookmarks.showMarkers;
  String? get bookmarkRecoveryNotice => bookmarks.recoveryNotice;

  @visibleForTesting
  bool get bookmarkAudioReading => _bookmarkAudioReads.isNotEmpty;

  final Map<String, ({int size, DateTime modified, String? version})>
  _bookmarkAudio = {};
  final Map<String, Future<String?>> _bookmarkAudioReads = {};

  /// Digest of the audio now at [path] for bookmark checks, reusing the
  /// `audioVersion` content identity. `known` is false while it is being read;
  /// a changed size or modification time triggers a fresh read.
  ({bool known, String? version}) bookmarkAudioVersion(String path) {
    FileStat stat;
    try {
      stat = File(path).statSync();
    } catch (_) {
      return (known: true, version: null);
    }
    if (stat.type != FileSystemEntityType.file) {
      return (known: true, version: null);
    }
    final cached = _bookmarkAudio[path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == stat.modified) {
      return (known: true, version: cached.version);
    }
    unawaited(_readBookmarkAudio(path));
    return (known: false, version: null);
  }

  /// Content identity used for bookmarks; overridable to simulate a read
  /// that cannot establish it.
  @visibleForTesting
  Future<String?> readBookmarkAudioVersion(String path) => audioVersion(path);

  /// Re-reads the audio content now (not the stat-keyed cache), so a replay
  /// is never allowed by a cached digest of a file replaced in place.
  Future<String?> verifyBookmarkAudio(String path) => _readBookmarkAudio(path);

  final Map<String, int> _bookmarkGenerations = {};

  Future<String?> _readBookmarkAudio(String path) =>
      _bookmarkAudioReads[path] ??= () async {
        try {
          final before = await File(path).stat();
          String? version;
          try {
            version = await readBookmarkAudioVersion(path);
          } catch (_) {
            version = null;
          }
          _bookmarkAudio[path] = (
            size: before.size,
            modified: before.modified,
            version: version,
          );
          if (!_disposed) notifyListeners();
          return version;
        } catch (_) {
          return null;
        } finally {
          _bookmarkAudioReads.remove(path);
        }
      }();

  /// Bookmarks of exactly this material, ordered by position.
  List<RecordingBookmark> bookmarksFor(RecordingReference ref) =>
      bookmarks.forRecording(_referenceKey(ref));

  /// The calendar meeting of this material (#407) and its bookmarks (#400)
  /// written out for the model that summarizes it; empty without either. A
  /// highlight quotes the sentence at its time only when the transcript's
  /// times can be trusted.
  String analysisNotesFor(RecordingReference ref) {
    final view = recordingView(ref);
    final path = view.path;
    final meeting = path == null ? null : library.assetForPath(path)?.meeting;
    final bookmarks = _bookmarkNotesFor(ref, view);
    return [
      ?meeting?.analysisNotes,
      if (bookmarks.isNotEmpty) bookmarks,
    ].join('\n\n');
  }

  String _bookmarkNotesFor(RecordingReference ref, RecordingViewData view) {
    final saved = bookmarksFor(ref);
    if (saved.isEmpty) return '';
    final path = view.path;
    final segments = view.segments;
    final locatable =
        transcriptSegmentsMatchText(
          segments,
          normalizeSttText(view.text),
          aliases: path == null ? const {} : speakerAliasesForPath(path),
        ) &&
        transcriptSegmentsLocatable(
          segments,
          duration: path == null ? null : localDurationForPath(path),
        );
    return bookmarkNotesForAnalysis(
      saved,
      segments: locatable ? segments : const [],
    );
  }

  /// Saves a bookmark at [position]; [segment] anchors it to the sentence the
  /// reader shows so a later transcript change cannot redirect it. Throws when
  /// the store cannot be written, leaving nothing saved.
  Future<RecordingBookmark> addBookmark(
    RecordingReference ref, {
    required Duration position,
    TranscriptSegment? segment,
    String note = '',
  }) async {
    await _bookmarksLoaded;
    final key = _referenceKey(ref);
    final generation = _bookmarkGenerations[key] ?? 0;
    final path = recordingView(ref).path;
    final version = path == null ? null : await _readBookmarkAudio(path);
    if (version == null) {
      throw const BookmarkSaveException('未保存：无法读取原音频以确认书签来源。草稿已保留，可稍后重试。');
    }
    // A permanent delete may have finished while the digest was read; the
    // check and the queued add below run without an await in between.
    if ((_bookmarkGenerations[key] ?? 0) != generation) {
      throw const BookmarkSaveException('未保存：这份资料已被删除。');
    }
    final now = DateTime.now();
    final bookmark = RecordingBookmark(
      id: bookmarks.newId(now),
      recordingKey: key,
      position: position < Duration.zero ? Duration.zero : position,
      note: note.trim(),
      segmentText: segment?.text.trim(),
      segmentStart: segment?.start,
      segmentEnd: segment?.end,
      transcriptRevision: segment == null
          ? null
          : _transcriptMetadata[key]?.revision ?? 0,
      audioVersion: version,
      createdAt: now,
      updatedAt: now,
    );
    await bookmarks.add(bookmark);
    if (!_disposed) notifyListeners();
    return bookmark;
  }

  Future<void> updateBookmarkNote(String id, String note) async {
    await _bookmarksLoaded;
    await bookmarks.updateNote(id, note.trim(), now: DateTime.now());
    if (!_disposed) notifyListeners();
  }

  Future<void> removeBookmark(String id) async {
    await _bookmarksLoaded;
    await bookmarks.remove(id);
    if (!_disposed) notifyListeners();
  }

  /// Display only: hiding markers never deletes bookmarks.
  Future<void> setShowBookmarkMarkers(bool value) async {
    await _bookmarksLoaded;
    await bookmarks.setShowMarkers(value);
    if (!_disposed) notifyListeners();
  }

  Future<void> _persistPlayback({bool? completed, Duration? at}) async {
    final path = playingPath;
    if (path == null || _disposed) return;
    final fileId = playingFileId;
    final total = duration;
    final point = at ?? position;
    final finished =
        completed ??
        (total > Duration.zero &&
            point >= total - const Duration(milliseconds: 500));
    await _playbackHistoryLoaded;
    if (_disposed) return;
    try {
      await playbackHistory.record(
        PlaybackPoint(
          path: path,
          fileId: fileId,
          position: finished && total > Duration.zero ? total : point,
          duration: total,
          completed: finished,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (_) {
      if (_disposed) return;
      statusMessage = '回听进度保存失败，重启后可能丢失';
      notifyListeners();
    }
  }

  String _playbackTitle(String path) {
    final label = library.assetForPath(path)?.displayName.trim();
    if (label != null && label.isNotEmpty) return label;
    final edited = ExportCatalog.editableLabelFromPath(path).trim();
    return edited.isEmpty ? p.basename(path) : edited;
  }

  Future<void> toggleLatestPlayback() async {
    final path = latestPlayback?.path;
    if (path == null) return;
    await playExported(path, fileId: fileIdFromPath(path));
  }

  /// Load local [path] and start playback. Tapping the same track pauses.
  ///
  /// Completed exports are standard WAV. Legacy raw Opus files are still muxed
  /// to Ogg on demand for playback compatibility.
  Future<void> playExported(
    String path, {
    int? fileId,
    Duration? startAt,
  }) async {
    final generation = ++_playbackIntent;
    final queueKey = _pendingQueuePlaybackKey;
    _pendingQueuePlaybackKey = null;
    if (_isRecordingAudioLocked(fileId ?? fileIdFromPath(path), path)) {
      errorMessage = '录音保存后即可播放';
      notifyListeners();
      return;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        if (generation != _playbackIntent) return;
        errorMessage = '找不到录音，请重新下载';
        statusMessage = '无法播放';
        notifyListeners();
        return;
      }
      if (await file.length() == 0) {
        if (generation != _playbackIntent) return;
        errorMessage = '文件为空，无法播放';
        statusMessage = '无法播放';
        notifyListeners();
        return;
      }
      if (generation != _playbackIntent) return;

      // Keep the local row expanded so transport controls stay visible.
      expandedLocalPath = path;

      // Same logical track (raw .opus or its .ogg sidecar).
      final logicalId = fileId ?? _fileIdFromPath(path);
      if (playingPath != null &&
          (playingPath == path ||
              playingFileId == logicalId && logicalId != null)) {
        await _applyPlayPause();
        if (generation != _playbackIntent) return;
        _playbackQueueEntryKey = queueKey;
        await _syncQueueForPlayback(path: path, fileId: logicalId);
        return;
      }
      if (playingPath != null) {
        await _persistPlayback(at: _confirmedPosition);
      }
      errorMessage = null;
      statusMessage = '正在准备播放 ${path.split('/').last}…';
      notifyListeners();

      final playPath = await OggOpus.ensurePlayable(path);
      if (generation != _playbackIntent) return;
      final len = await File(playPath).length();
      if (generation != _playbackIntent) return;
      if (len < 64) {
        throw StateError('封装后的音频无效（${len}B）');
      }

      _audioSwitchDepth++;
      _playbackStartedSinceSource = false;
      try {
        await _player.stop();
        if (generation != _playbackIntent) return;
        await _playbackHistoryLoaded;
        if (generation != _playbackIntent) return;
        final title = _playbackTitle(path);
        final durationFromFile = await _player.setAudioSource(
          AudioSource.uri(
            Uri.file(playPath),
            tag: MediaItem(
              id: logicalId == null ? 'koe:$path' : 'koe:id:$logicalId',
              title: title,
              album: 'Koe 资料',
            ),
          ),
        );
        if (generation != _playbackIntent) return;
        await _player.setSpeed(playbackSpeed);
        if (generation != _playbackIntent) return;
        playingPath = path; // keep UI key on original export path
        playingFileId = logicalId;
        _playbackQueueEntryKey = queueKey;
        duration = durationFromFile ?? _player.duration ?? Duration.zero;
        // Duration may arrive async on some platforms.
        if (duration <= Duration.zero) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (generation != _playbackIntent) return;
          duration = _player.duration ?? Duration.zero;
        }
        final resume = _resolvePlaybackStart(
          path: path,
          fileId: logicalId,
          total: duration,
          requested: startAt,
        );
        position = resume;
        _confirmedPosition = resume;
        if (resume > Duration.zero) {
          await _player.seek(resume);
          if (generation != _playbackIntent) return;
        }
        playbackCompleted = false;
        final sec = duration.inMilliseconds / 1000.0;
        statusMessage = resume > Duration.zero
            ? '已从 ${_clock(resume)} 继续回听'
            : duration > Duration.zero
            ? '正在播放 · ${sec.toStringAsFixed(1)}s'
            : '正在播放 ${path.split('/').last}';
        if (generation != _playbackIntent) return;
        _startPlayback();
      } finally {
        _audioSwitchDepth--;
      }
      if (generation == _playbackIntent) {
        await _syncQueueForPlayback(path: path, fileId: logicalId);
      }
      notifyListeners();
    } catch (e, stack) {
      if (generation != _playbackIntent) return;
      debugPrint('[Playback] play failed: $e\n$stack');
      errorMessage = '无法播放录音，请重新下载后重试';
      statusMessage = '无法播放';
      playingPath = null;
      playingFileId = null;
      _playbackQueueEntryKey = null;
      isPlaying = false;
      playbackCompleted = false;
      _playbackStartedSinceSource = false;
      _confirmedPosition = Duration.zero;
      duration = Duration.zero;
      notifyListeners();
    }
  }

  String _clock(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// Load [path] when needed, jump to [start] and play.
  Future<void> playFrom(String path, Duration start, {int? fileId}) async {
    _playbackIntent++;
    final logicalId = fileId ?? _fileIdFromPath(path);
    final sameTrack =
        playingPath == path ||
        (logicalId != null && playingFileId == logicalId);
    if (sameTrack) {
      await seekTo(start);
      if (playingPath == null) return;
      if (!isPlaying) {
        playbackCompleted = false;
        _startPlayback();
        notifyListeners();
      }
      return;
    }
    await playExported(path, fileId: fileId, startAt: start);
  }

  int? _fileIdFromPath(String path) => ExportCatalog.fileIdFromPath(path);

  Duration _resolvePlaybackStart({
    required String path,
    required Duration total,
    int? fileId,
    Duration? requested,
  }) {
    if (requested == null) {
      return resumePositionFor(path, fileId: fileId, total: total);
    }
    return total > Duration.zero && requested > total ? total : requested;
  }

  void _startPlayback() {
    unawaited(
      _player.play().catchError((Object error, StackTrace stack) {
        if (_disposed) return;
        errorMessage = '无法播放录音，请重新下载后重试';
        statusMessage = '无法播放';
        isPlaying = false;
        notifyListeners();
      }),
    );
  }

  Future<void> togglePlayPause() async {
    _playbackIntent++;
    await _applyPlayPause();
  }

  Future<void> _applyPlayPause() async {
    if (playingPath == null) return;
    try {
      if (isPlaying) {
        await _player.pause();
        await _persistPlayback(at: _confirmedPosition);
        _pausePersistArmed = false;
        _clearPlayingStatus();
      } else {
        if (playbackCompleted) {
          await _player.seek(Duration.zero);
          position = Duration.zero;
          _confirmedPosition = Duration.zero;
          playbackCompleted = false;
        }
        _startPlayback();
        final sec = duration.inMilliseconds / 1000.0;
        statusMessage = duration > Duration.zero
            ? '正在播放 · ${sec.toStringAsFixed(1)}s'
            : '正在播放';
      }
      notifyListeners();
    } catch (e) {
      errorMessage = '无法控制播放，请重新打开录音';
      notifyListeners();
    }
  }

  /// System interruptions and route changes must stop real audio, not only
  /// move the progress bar.
  Future<void> pauseForInterruption({String? message}) async {
    _playbackIntent++;
    if (playingPath == null || !isPlaying) return;
    try {
      await _player.pause();
      await _persistPlayback(at: _confirmedPosition);
      _clearPlayingStatus();
      statusMessage = message ?? '播放已暂停，可手动继续';
      notifyListeners();
    } catch (error) {
      errorMessage = '播放状态已中断，请手动继续';
      notifyListeners();
    }
  }

  Future<void> seekBy(Duration delta) async {
    if (playingPath == null) return;
    final total = duration > Duration.zero ? duration : position + delta;
    var target = position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    await seekTo(target);
  }

  Future<void> seekTo(Duration target) async {
    _playbackIntent++;
    if (playingPath == null) return;
    try {
      await _player.seek(target);
      position = target;
      _confirmedPosition = target;
      playbackCompleted = duration > Duration.zero && target >= duration;
      notifyListeners();
    } catch (e) {
      errorMessage = '无法跳转，请重试';
      notifyListeners();
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    playbackSpeed = speed;
    try {
      await _player.setSpeed(speed);
    } catch (e) {
      errorMessage = '无法更改播放速度，请重试';
      notifyListeners();
      return;
    }
    try {
      await _playbackHistoryLoaded;
      await playbackHistory.setSpeed(speed);
    } catch (_) {
      statusMessage = '倍速已更改，但无法保存到本机';
    }
    notifyListeners();
  }

  Future<void> stopPlayback() async {
    _playbackIntent++;
    await _persistPlayback(at: _confirmedPosition);
    try {
      await _player.stop();
    } catch (_) {}
    playingPath = null;
    playingFileId = null;
    _playbackQueueEntryKey = null;
    isPlaying = false;
    playbackCompleted = false;
    _confirmedPosition = Duration.zero;
    position = Duration.zero;
    duration = Duration.zero;
    _clearPlayingStatus();
    notifyListeners();
  }
}
