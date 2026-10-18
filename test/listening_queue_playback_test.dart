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
    final history = PlaybackHistoryStore(inMemory: true);
    await history.load();
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
    player.emitState(playing: true);
    player.emitPosition(const Duration(seconds: 20));
    await settleQueue(controller);
    expect(controller.isPlaying, isTrue);

    await controller.retryQueueEntry('id:178');
    await settleQueue(controller);

    expect(controller.isPlaying, isFalse);
    expect(player.pauses, greaterThan(0));
    expect(player.sources, [first.path], reason: '缺失项不能替换成别的音频');
    expect(
      history.forRecording(fileId: 100, path: first.path)?.position,
      const Duration(seconds: 20),
      reason: '暂停时保留上一段真实断点',
    );
    expect(controller.queueCurrentKey, 'id:178');
    expect(controller.queueNotice, contains('缺失'));
  });

  test('移除暂停写盘期间用户改播队列外资料，不会误停或替换新播放', () async {
    final first = await audio('100.wav');
    final next = await audio('178.wav');
    final outside = await audio('200.wav');
    final historyFile = File('${temp.path}/playback_history.json');
    final history = _BlockingHistoryStore(file: historyFile);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: outside.path,
        fileId: 200,
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );
    final queue = ListeningQueueStore(inMemory: true);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(next, fileId: 178, title: '第二段'));
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      next.path: const Duration(minutes: 5),
      outside.path: const Duration(minutes: 5),
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
    player.emitPosition(const Duration(seconds: 10));
    await settleQueue(controller);

    history.gateNextRecord();
    final remove = controller.removeFromListeningQueue('id:100');
    await history.entered.timeout(const Duration(seconds: 5));

    final outsidePlay = controller.playExported(outside.path, fileId: 200);
    for (var i = 0; i < 200 && controller.playingPath != outside.path; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(controller.playingPath, outside.path);
    player.emitState(playing: true);
    history.release();
    await remove;
    await outsidePlay;
    await controller.waitForQueueIdle();
    await controller.waitForQueueIdle();

    expect(controller.playingPath, outside.path);
    expect(controller.isPlaying, isTrue);
    expect(player.sources, [first.path, outside.path]);
    expect(queue.entries.map((item) => item.fileId), [178]);
    expect(controller.queueCurrentKey, isNull);

    player.emitPosition(const Duration(seconds: 45));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.pauseForInterruption();
    expect(
      history.forRecording(fileId: 200, path: outside.path)?.position,
      const Duration(seconds: 45),
      reason: '移除不能污染新播放的断点',
    );
  });

  test('移除写盘期间用户改播队列外资料，旧playNext不能替换新播放', () async {
    final first = await audio('100.wav');
    final next = await audio('178.wav');
    final outside = await audio('200.wav');
    final queueFile = File('${temp.path}/listening_queue.json');
    final queue = _GatedQueueStore(file: queueFile);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(next, fileId: 178, title: '第二段'));
    final history = PlaybackHistoryStore(inMemory: true);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: outside.path,
        fileId: 200,
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      next.path: const Duration(minutes: 5),
      outside.path: const Duration(minutes: 5),
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

    queue.gateNextWrite();
    final remove = controller.removeFromListeningQueue(
      'id:100',
      playNext: true,
    );
    await queue.entered.timeout(const Duration(seconds: 5));

    final outsidePlay = controller.playExported(outside.path, fileId: 200);
    for (var i = 0; i < 200 && controller.playingPath != outside.path; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(controller.playingPath, outside.path);
    player.emitState(playing: true);
    queue.release();

    await remove;
    await outsidePlay;
    await controller.waitForQueueIdle();
    await controller.waitForQueueIdle();

    expect(controller.playingPath, outside.path, reason: '旧移除动作不能播放下一项');
    expect(controller.isPlaying, isTrue);
    expect(player.sources, [first.path, outside.path]);
    expect(queue.entries.map((item) => item.fileId), [178]);
    expect(controller.queueCurrentKey, isNull);

    player.emitPosition(const Duration(seconds: 45));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.pauseForInterruption();
    expect(
      history.forRecording(fileId: 200, path: outside.path)?.position,
      const Duration(seconds: 45),
      reason: '移除不能污染新播放的断点',
    );
  });

  test('自动续播等待队列动作时重播同一段，不再跳到下一项', () async {
    final first = await audio('100.wav');
    final next = await audio('178.wav');
    final third = await audio('200.wav');
    final queueFile = File('${temp.path}/listening_queue.json');
    final queue = _GatedQueueStore(file: queueFile);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(next, fileId: 178, title: '第二段'));
    await queue.add(entry(third, fileId: 200, title: '第三段'));
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      next.path: const Duration(minutes: 5),
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

    // Hold the queue action chain with a non-current removal, so the
    // completion event has to wait before its auto-advance runs.
    queue.gateNextWrite();
    final removingThird = controller.removeFromListeningQueue('id:200');
    await queue.entered.timeout(const Duration(seconds: 5));
    player.emitCompleted();
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    await controller.playFrom(first.path, Duration.zero, fileId: 100);
    player.emitState(playing: true);
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.playingPath, first.path);
    expect(controller.isPlaying, isTrue);

    queue.release();
    await removingThird;
    await controller.waitForQueueIdle();
    await controller.waitForQueueIdle();

    expect(controller.playingPath, first.path, reason: '重播的同一段不能被自动续播覆盖');
    expect(controller.isPlaying, isTrue);
    expect(player.sources, [first.path]);
    expect(controller.queueCurrentKey, 'id:100');
    expect(queue.entries.map((item) => item.fileId), [100, 178]);
  });

  test('上一段播完后移除缺失的当前项并选下一项，仍会播放下一项', () async {
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
    expect(controller.playingPath, first.path, reason: 'A 仍暂停在结尾');

    await controller.removeFromListeningQueue('id:178', playNext: true);
    await settleQueue(controller);

    expect(queue.entries.map((item) => item.fileId), [100, 200]);
    expect(queue.currentKey, 'id:200');
    expect(controller.playingPath, third.path);
    expect(player.sources, [first.path, third.path]);
    expect(controller.queueNotice, isNull);
  });

  test('自动续播写当前项时用户改播队列外资料，最新选择胜出', () async {
    final first = await audio('100.wav');
    final next = await audio('178.wav');
    final outside = await audio('200.wav');
    final queueFile = File('${temp.path}/listening_queue.json');
    final queue = _GatedQueueStore(file: queueFile);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(next, fileId: 178, title: '第二段'));
    final history = PlaybackHistoryStore(inMemory: true);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: outside.path,
        fileId: 200,
        position: const Duration(seconds: 50),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      next.path: const Duration(minutes: 5),
      outside.path: const Duration(minutes: 5),
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
    queue.gateNextWrite();
    player.emitCompleted();
    await queue.entered.timeout(const Duration(seconds: 5));

    // The auto-advance is now suspended inside the current-item write. The
    // user starts a material outside the queue; that intent must win.
    final outsidePlay = controller.playExported(outside.path, fileId: 200);
    for (var i = 0; i < 200 && controller.playingPath != outside.path; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(controller.playingPath, outside.path);
    player.emitState(playing: true);
    player.emitPosition(const Duration(seconds: 55));

    queue.release();
    await outsidePlay;
    await controller.waitForQueueIdle();
    await controller.waitForQueueIdle();

    expect(controller.playingPath, outside.path, reason: '旧的自动续播不能覆盖新选择');
    expect(player.sources, [first.path, outside.path]);
    expect(controller.queueCurrentKey, isNull);
    expect(queue.entries.map((item) => item.fileId), [100, 178]);

    // The new material keeps playing; pausing it persists its later position
    // instead of letting the abandoned queue action own the breakpoint.
    player.emitPosition(const Duration(seconds: 56));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.pauseForInterruption();
    expect(
      history.forRecording(fileId: 200, path: outside.path)?.position,
      const Duration(seconds: 56),
      reason: '旧动作不能把队列外资料的新断点覆写掉',
    );
  });

  test('播放队列外资料时移除旧current不暂停也不替换实际音频', () async {
    final first = await audio('100.wav');
    final next = await audio('178.wav');
    final outside = await audio('200.wav');
    final queueFile = File('${temp.path}/listening_queue.json');
    final queue = _GatedQueueStore(file: queueFile);
    await queue.load();
    await queue.add(entry(first, fileId: 100, title: '第一段'));
    await queue.add(entry(next, fileId: 178, title: '第二段'));
    final history = PlaybackHistoryStore(inMemory: true);
    await history.load();
    await history.record(
      PlaybackPoint(
        path: outside.path,
        fileId: 200,
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 5),
        completed: false,
        updatedAt: DateTime(2026, 10, 18, 9),
      ),
    );
    final player = _QueuePlayer({
      first.path: const Duration(minutes: 5),
      next.path: const Duration(minutes: 5),
      outside.path: const Duration(minutes: 5),
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
    player.emitPosition(const Duration(seconds: 10));
    await settleQueue(controller);

    queue.gateNextWrite();
    final outsidePlay = controller.playExported(outside.path, fileId: 200);
    for (var i = 0; i < 200 && controller.playingPath != outside.path; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(controller.playingPath, outside.path);
    player.emitState(playing: true);
    await queue.entered.timeout(const Duration(seconds: 5));

    // The queue current is still A because its clear write is blocked. Removing
    // A must only touch audio that really belongs to A; X keeps playing.
    final pausesBefore = player.pauses;
    final remove = controller.removeFromListeningQueue('id:100');
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.isPlaying, isTrue, reason: '移除旧current不能暂停队列外资料');
    expect(player.pauses, pausesBefore);
    expect(player.sources, [first.path, outside.path]);

    queue.release();
    await remove;
    await outsidePlay;
    await controller.waitForQueueIdle();
    await controller.waitForQueueIdle();

    expect(controller.playingPath, outside.path);
    expect(controller.isPlaying, isTrue);
    expect(queue.entries.map((item) => item.fileId), [178]);
    expect(controller.queueCurrentKey, isNull);

    player.emitPosition(const Duration(seconds: 35));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.pauseForInterruption();
    expect(
      history.forRecording(fileId: 200, path: outside.path)?.position,
      const Duration(seconds: 35),
      reason: '移除旧current不能覆盖队列外资料的真实断点',
    );
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
}

class _BlockingHistoryStore extends PlaybackHistoryStore {
  _BlockingHistoryStore({super.file});

  Completer<void>? _entered;
  Completer<void>? _release;
  bool _gateNext = false;

  void gateNextRecord() {
    _gateNext = true;
    _entered = Completer<void>();
    _release = Completer<void>();
  }

  Future<void> get entered => _entered!.future;
  void release() => _release!.complete();

  @override
  Future<void> record(PlaybackPoint point, {bool makeLatest = true}) async {
    if (_gateNext) {
      _gateNext = false;
      _entered!.complete();
      await _release!.future;
    }
    await super.record(point, makeLatest: makeLatest);
  }
}

class _GatedQueueStore extends ListeningQueueStore {
  _GatedQueueStore({super.file});

  Completer<void>? _entered;
  Completer<void>? _release;
  bool _gateNext = false;

  void gateNextWrite() {
    _gateNext = true;
    _entered = Completer<void>();
    _release = Completer<void>();
  }

  Future<void> get entered => _entered!.future;
  void release() => _release!.complete();

  @override
  Future<void> writeSnapshot(String json) async {
    if (_gateNext) {
      _gateNext = false;
      _entered!.complete();
      await _release!.future;
    }
    await super.writeSnapshot(json);
  }
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
