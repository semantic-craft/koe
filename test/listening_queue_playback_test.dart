import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:koe/state/recorder_controller.dart';

import 'support/wav_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-queue-playback-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  ListeningQueueEntry entry(File file, {int? fileId, String? title}) =>
      ListeningQueueEntry(
        path: file.path,
        fileId: fileId,
        title: title ?? file.uri.pathSegments.last,
        addedAt: DateTime(2026, 10, 18, 9),
      );

  Future<File> audio(String name) async {
    final file = File('${temp.path}/$name');
    await file.writeAsBytes(wavBytes(List<int>.filled(256, 0)));
    return file;
  }

  Future<void> settleQueue(RecorderController controller) async {
    await Future<void>.delayed(Duration.zero);
    await controller.waitForQueueIdle();
    await Future<void>.delayed(Duration.zero);
    await controller.waitForQueueIdle();
  }

  test('连续播放按各自断点切到下一项，两个资料的断点互不覆盖', () async {
    final first = await audio('100.wav');
    final second = await audio('178.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(second, fileId: 178, title: '第二段'));

    final history = PlaybackHistoryStore(inMemory: true);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: first.path,
        fileId: 100,
        position: const Duration(seconds: 12),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );
    await history.record(
      PlaybackPoint(
        path: second.path,
        fileId: 178,
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );

    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      second.path: const Duration(minutes: 5),
    });
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: history,
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    await controller.waitForPlaybackHistory();

    await controller.playQueueEntry('id:100');
    await settleQueue(controller);
    expect(
      controller.playingPath,
      first.path,
      reason:
          'error=${controller.errorMessage} notice=${controller.queueNotice} '
          'availability=${controller.queueAvailabilityFor(queue.entries.first).reason}',
    );
    expect(player.seeks.last, const Duration(seconds: 12));

    player.emitCompleted();
    await settleQueue(controller);

    expect(controller.playingPath, second.path, reason: '第一段结束后应连续播放第二段');
    expect(player.sources, [first.path, second.path]);
    expect(
      player.seeks.last,
      const Duration(seconds: 40),
      reason: '第二段使用自己的断点',
    );
    expect(queue.currentKey, 'id:178');
    expect(
      history.forRecording(fileId: 100, path: first.path)?.completed,
      isTrue,
    );
    expect(
      history.forRecording(fileId: 178, path: second.path)?.position,
      const Duration(seconds: 40),
      reason: '切换不能把第一段的位置写到第二段',
    );
    expect(
      history.forRecording(fileId: 178, path: second.path)?.completed,
      isFalse,
    );
  });

  test('下一项音频缺失时暂停并说明真实状态，不冒充播完；补齐后重试继续', () async {
    final first = await audio('100.wav');
    final missing = File('${temp.path}/178.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(missing, fileId: 178, title: '第二段'));

    final history = PlaybackHistoryStore(inMemory: true);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: missing.path,
        fileId: 178,
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );
    final player = _QueuePlayer({first.path: const Duration(minutes: 5)});
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: history,
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    await controller.waitForPlaybackHistory();

    await controller.playQueueEntry('id:100');
    await settleQueue(controller);
    player.emitCompleted();
    await settleQueue(controller);

    expect(player.sources, [first.path], reason: '缺失的音频不能被当成已播放');
    expect(controller.playingPath, first.path);
    expect(queue.currentKey, 'id:178');
    expect(controller.queueNotice, contains('缺失'));
    expect(controller.queueNotice, isNot(contains('播完')));
    expect(controller.playbackCompleted, isTrue, reason: '第一段确实播放结束');

    await missing.writeAsBytes(wavBytes(List<int>.filled(256, 0)));
    player.durations[missing.path] = const Duration(minutes: 5);
    await controller.retryQueueEntry('id:178');
    await settleQueue(controller);

    expect(controller.playingPath, missing.path);
    expect(player.sources.last, missing.path);
    expect(player.seeks.last, const Duration(seconds: 40));
    expect(controller.queueNotice, isNull);
  });

  test('移除当前项先暂停且不自动跳播；选择继续下一项才切换', () async {
    final first = await audio('100.wav');
    final second = await audio('178.wav');
    final third = await audio('200.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(second, fileId: 178, title: '第二段'));
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      second.path: const Duration(minutes: 5),
      third.path: const Duration(minutes: 5),
    });
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    await controller.waitForPlaybackHistory();

    await controller.playQueueEntry('id:100');
    await settleQueue(controller);
    player.emitState(playing: true);
    await settleQueue(controller);

    await controller.removeFromListeningQueue('id:100');
    await settleQueue(controller);

    expect(player.sources, [first.path], reason: '移除当前项不能擅自播放下一项');
    expect(player.pauses, greaterThan(0));
    expect(queue.currentKey, isNull);
    expect(queue.entries.map((item) => item.fileId), [178]);

    await queue.add(entry(third, fileId: 200, title: '第三段'));
    await controller.playQueueEntry('id:178');
    await settleQueue(controller);
    player.emitState(playing: true);
    await settleQueue(controller);

    await controller.removeFromListeningQueue('id:178', playNext: true);
    await settleQueue(controller);

    expect(queue.entries.map((item) => item.fileId), [200]);
    expect(queue.currentKey, 'id:200');
    expect(controller.playingPath, third.path);
    expect(player.sources.last, third.path);
  });

  test('手动切项保存上一项断点，并从目标项自己的断点继续', () async {
    final first = await audio('100.wav');
    final second = await audio('178.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(second, fileId: 178, title: '第二段'));
    final history = PlaybackHistoryStore(inMemory: true);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: second.path,
        fileId: 178,
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      second.path: const Duration(minutes: 5),
    });
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: history,
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    await controller.waitForPlaybackHistory();

    await controller.playQueueEntry('id:100');
    await settleQueue(controller);
    player.emitState(playing: true);
    player.emitPosition(const Duration(seconds: 25));
    await settleQueue(controller);

    await controller.playQueueEntry('id:178');
    await settleQueue(controller);

    expect(controller.playingPath, second.path);
    expect(controller.queueCurrentKey, 'id:178');
    expect(player.seeks.last, const Duration(seconds: 40));
    expect(
      history.forRecording(fileId: 100, path: first.path)?.position,
      const Duration(seconds: 25),
      reason: '切到第二项前必须保存第一项的真实位置',
    );
  });

  test('重排与删除非当前项不打断当前播放，下一项按新顺序', () async {
    final first = await audio('100.wav');
    final second = await audio('178.wav');
    final third = await audio('200.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(second, fileId: 178, title: '第二段'));
    await queue.add(entry(third, fileId: 200, title: '第三段'));
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      second.path: const Duration(minutes: 5),
      third.path: const Duration(minutes: 5),
    });
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    await controller.waitForPlaybackHistory();

    await controller.playQueueEntry('id:100');
    await settleQueue(controller);
    player.emitState(playing: true);
    await settleQueue(controller);

    await controller.moveQueueEntry(2, 1);
    await controller.removeFromListeningQueue('id:178');
    await settleQueue(controller);

    expect(queue.entries.map((item) => item.fileId), [100, 200]);
    expect(controller.queueCurrentKey, 'id:100');
    expect(controller.playingPath, first.path);
    expect(controller.isPlaying, isTrue);

    player.emitCompleted();
    await settleQueue(controller);

    expect(controller.queueCurrentKey, 'id:200');
    expect(controller.playingPath, third.path, reason: '下一项应按重排后的顺序');
    expect(player.sources, [first.path, third.path]);
  });

  test('跳过缺失的当前项只前进一项，不把缺失当播完', () async {
    final first = await audio('100.wav');
    final missing = File('${temp.path}/178.wav');
    final third = await audio('200.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(missing, fileId: 178, title: '缺失'));
    await queue.add(entry(third, fileId: 200, title: '第三段'));
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      third.path: const Duration(minutes: 5),
    });
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    await controller.waitForPlaybackHistory();

    await controller.playQueueEntry('id:100');
    await settleQueue(controller);
    player.emitCompleted();
    await settleQueue(controller);
    expect(controller.queueCurrentKey, 'id:178');
    expect(controller.queueNotice, contains('缺失'));

    await controller.skipQueueEntry('id:178');
    await settleQueue(controller);

    expect(controller.queueCurrentKey, 'id:200');
    expect(controller.playingPath, third.path);
    expect(player.sources, [first.path, third.path]);
    expect(queue.entries.map((item) => item.fileId), [100, 178, 200]);
    expect(controller.queueNotice, isNull);
  });

  test('重试非当前缺失项会先暂停上一段，不留下仍在播放的旧音频', () async {
    final first = await audio('100.wav');
    final missing = File('${temp.path}/178.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(missing, fileId: 178, title: '缺失'));
    final player = _QueuePlayer({first.path: const Duration(minutes: 5)});
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    await controller.waitForPlaybackHistory();

    await controller.playQueueEntry('id:100');
    await settleQueue(controller);
    player.emitState(playing: true);
    await settleQueue(controller);
    expect(controller.isPlaying, isTrue);

    await controller.retryQueueEntry('id:178');
    await settleQueue(controller);

    expect(controller.isPlaying, isFalse);
    expect(player.pauses, greaterThan(0));
    expect(player.sources, [first.path], reason: '缺失项不能替换成别的音频');
    expect(controller.queueCurrentKey, 'id:178');
    expect(controller.queueNotice, contains('缺失'));
  });

  test('重启后队列当前资料与断点仍正确，继续从该资料位置收听', () async {
    final first = await audio('100.wav');
    final second = await audio('178.wav');
    final queueFile = File('${temp.path}/listening_queue.json');
    final historyFile = File('${temp.path}/playback_history.json');

    final queue = ListeningQueueStore(file: queueFile);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(second, fileId: 178, title: '第二段'));
    final history = PlaybackHistoryStore(file: historyFile);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: second.path,
        fileId: 178,
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );

    final firstPlayer = _QueuePlayer({first.path: const Duration(minutes: 5)});
    final firstRun = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: history,
      player: firstPlayer,
    );
    await firstRun.waitForListeningQueue();
    await firstRun.waitForPlaybackHistory();
    await firstRun.playQueueEntry('id:100');
    await settleQueue(firstRun);
    firstPlayer.emitCompleted();
    await settleQueue(firstRun);
    expect(queue.currentKey, 'id:178');
    firstPlayer.emitState(playing: true);
    await settleQueue(firstRun);
    await firstRun.pauseForInterruption();
    await settleQueue(firstRun);
    firstRun.dispose();

    final secondPlayer = _QueuePlayer({
      second.path: const Duration(minutes: 5),
    });
    final restarted = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: ListeningQueueStore(file: queueFile),
      playbackHistoryStore: PlaybackHistoryStore(file: historyFile),
      player: secondPlayer,
    );
    addTearDown(restarted.dispose);
    await restarted.waitForListeningQueue();
    await restarted.waitForPlaybackHistory();

    expect(restarted.queueCurrentKey, 'id:178');
    expect(restarted.queueCurrent?.title, '第二段');
    expect(restarted.queueEntries.map((item) => item.fileId), [100, 178]);

    await restarted.playQueueEntry('id:178');
    await settleQueue(restarted);
    expect(restarted.playingPath, second.path);
    expect(secondPlayer.seeks.last, const Duration(seconds: 40));
  });

  test('已删、回收站与缺失音频说明实际状态，不当作可播放', () async {
    final missing = File('${temp.path}/100.wav');
    final trashed = await audio('178.wav');
    final deleted = await audio('200.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(missing, fileId: 100, title: '缺失'));
    await queue.add(entry(trashed, fileId: 178, title: '回收站'));
    await queue.add(entry(deleted, fileId: 200, title: '已删除'));
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: _QueuePlayer(const {}),
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();
    final now = DateTime(2026, 10, 18, 9);
    await controller.library.upsert(
      RecordingAsset(
        path: trashed.path,
        displayName: '回收站',
        source: RecordingSource.device,
        importedAt: now,
        deletedAt: now,
      ),
    );
    await controller.library.upsert(
      RecordingAsset(
        path: deleted.path,
        displayName: '已删除',
        source: RecordingSource.device,
        importedAt: now,
        deletedAt: now,
        permanentlyDeleted: true,
      ),
    );

    final missingStatus = controller.queueAvailabilityFor(queue.entries[0]);
    final trashedStatus = controller.queueAvailabilityFor(queue.entries[1]);
    final deletedStatus = controller.queueAvailabilityFor(queue.entries[2]);

    expect(missingStatus.playable, isFalse);
    expect(missingStatus.reason, contains('缺失'));
    expect(trashedStatus.playable, isFalse);
    expect(trashedStatus.reason, contains('回收站'));
    expect(deletedStatus.playable, isFalse);
    expect(deletedStatus.reason, contains('删除'));
  });

  test('章节只复用可靠的转写时间，不可靠时保持整段播放', () async {
    final reliable = await audio('100.wav');
    final unreliable = await audio('178.wav');
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(reliable, fileId: 100, title: '可靠'));
    await queue.add(entry(unreliable, fileId: 178, title: '不可靠'));
    final controller = RecorderController(
      loadPersistedState: false,
      listeningQueueStore: queue,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: _QueuePlayer(const {}),
    );
    addTearDown(controller.dispose);
    await controller.waitForListeningQueue();

    controller.rememberTranscript(
      reliable.path,
      '第一句。第二句。',
      segments: const [
        TranscriptSegment(
          text: '第一句。',
          start: Duration.zero,
          end: Duration(seconds: 4),
        ),
        TranscriptSegment(
          text: '第二句。',
          start: Duration(seconds: 10),
          end: Duration(seconds: 14),
        ),
      ],
    );
    controller.rememberTranscript(
      unreliable.path,
      '甲。乙。',
      segments: const [
        TranscriptSegment(text: '甲。', start: Duration.zero),
        TranscriptSegment(text: '乙。', start: Duration.zero),
      ],
    );

    final chapters = controller.queueChaptersFor(queue.entries[0]);
    expect(chapters.map((chapter) => chapter.start), [
      Duration.zero,
      const Duration(seconds: 10),
    ]);
    expect(chapters.last.label, contains('第二句'));
    expect(controller.queueChaptersFor(queue.entries[1]), isEmpty);
  });
}

class _QueuePlayer extends AudioPlayer {
  _QueuePlayer(Map<String, Duration> sourceDurations)
    : durations = Map.of(sourceDurations);

  final Map<String, Duration> durations;
  final sources = <String>[];
  final seeks = <Duration?>[];
  final _states = StreamController<PlayerState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _processing = StreamController<ProcessingState>.broadcast();
  final _play = Completer<void>();
  var pauses = 0;
  Duration _duration = const Duration(minutes: 5);

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Stream<ProcessingState> get processingStateStream => _processing.stream;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Duration? get duration => _duration;

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    final path = (audioSource as UriAudioSource).uri.path;
    sources.add(path);
    _duration = durations[path] ?? const Duration(minutes: 5);
    return _duration;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks.add(position);
  }

  @override
  Future<void> play() => _play.future;

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> stop() async {}

  void emitPosition(Duration value) => _positions.add(value);
  void emitState({required bool playing}) =>
      _states.add(PlayerState(playing, ProcessingState.ready));
  void emitCompleted() => _processing.add(ProcessingState.completed);

  @override
  Future<void> dispose() async {
    await _states.close();
    await _positions.close();
    await _durations.close();
    await _processing.close();
    await super.dispose();
  }
}
