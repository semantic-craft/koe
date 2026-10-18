import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';

void main() {
  late Directory temp;
  late File historyFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-playback-');
    historyFile = File('${temp.path}/playback_history.json');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  PlaybackPoint point(
    String path, {
    int? fileId,
    int seconds = 20,
    int total = 120,
    bool completed = false,
    DateTime? updatedAt,
  }) => PlaybackPoint(
    path: path,
    fileId: fileId,
    position: Duration(seconds: seconds),
    duration: Duration(seconds: total),
    completed: completed,
    updatedAt: updatedAt ?? DateTime(2026, 10, 18, 9),
  );

  test('两段资料的进度分开保存，重启后最近收听与倍速仍在', () async {
    final first = PlaybackHistoryStore(file: historyFile);
    await first.load();
    await first.record(point('/tmp/100.wav', fileId: 100, seconds: 32));
    await first.record(
      point('/tmp/178.wav', fileId: 178, seconds: 95, completed: true),
    );
    await first.setSpeed(1.5);

    final restarted = PlaybackHistoryStore(file: historyFile);
    await restarted.load();

    expect(restarted.speed, 1.5);
    expect(restarted.latest?.fileId, 178);
    expect(restarted.latest?.completed, isTrue);
    expect(
      restarted.forRecording(fileId: 100, path: '/tmp/100.wav')?.position,
      const Duration(seconds: 32),
    );
    expect(
      restarted.forRecording(fileId: 178, path: '/tmp/178.wav')?.completed,
      isTrue,
    );
  });

  test('断点只应用到对应资料，已听完与接近结尾都从头开始', () async {
    final store = PlaybackHistoryStore(inMemory: true);
    await store.record(point('/tmp/100.wav', fileId: 100, seconds: 30));
    await store.record(
      point('/tmp/178.wav', fileId: 178, seconds: 60, completed: true),
    );
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: store,
    );
    addTearDown(controller.dispose);
    await controller.waitForPlaybackHistory();

    expect(
      controller.resumePositionFor(
        '/tmp/100.wav',
        fileId: 100,
        total: const Duration(seconds: 120),
      ),
      const Duration(seconds: 30),
    );
    expect(
      controller.resumePositionFor(
        '/tmp/178.wav',
        fileId: 178,
        total: const Duration(seconds: 120),
      ),
      Duration.zero,
    );
    expect(
      controller.resumePositionFor(
        '/tmp/100.wav',
        fileId: 100,
        total: const Duration(seconds: 30, milliseconds: 500),
      ),
      Duration.zero,
    );
    expect(
      controller.resumePositionFor(
        '/tmp/999.wav',
        fileId: 999,
        total: const Duration(seconds: 120),
      ),
      Duration.zero,
    );
  });

  test('显式 0:00 从头播放，播放 Future 未结束也会保存断点', () async {
    final audio = File('${temp.path}/178.wav');
    await audio.writeAsBytes(List<int>.filled(100, 0));
    final store = PlaybackHistoryStore(inMemory: true);
    await store.load();
    await store.record(point(audio.path, fileId: 178, seconds: 30));
    final player = _FakePlayer();
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: store,
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForPlaybackHistory();

    await controller
        .playExported(audio.path, fileId: 178, startAt: Duration.zero)
        .timeout(const Duration(seconds: 1));

    expect(controller.position, Duration.zero);
    expect(player.seeks, isEmpty, reason: '显式 0:00 不能跳到旧断点 0:30');

    player.emitPosition(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      store.forRecording(fileId: 178, path: audio.path)?.position,
      const Duration(seconds: 10),
      reason: '播放 Future 尚未结束时也必须保存位置',
    );
  });

  test('回听进度写入失败会抛出并向用户提示，不静默成功', () async {
    final blocker = File('${temp.path}/blocked');
    await blocker.writeAsString('not a directory');
    final store = PlaybackHistoryStore(
      file: File('${blocker.path}/history.json'),
    );
    await expectLater(
      store.record(point('/tmp/178.wav', fileId: 178)),
      throwsA(isA<FileSystemException>()),
    );
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: store,
      player: _FakePlayer(),
    );
    addTearDown(controller.dispose);
    await controller.waitForPlaybackHistory();

    await controller.setPlaybackSpeed(1.5);

    expect(controller.statusMessage, contains('无法保存'));
  });

  test('未播放时的零位置事件不会覆盖已保存断点', () async {
    final audio = File('${temp.path}/178.wav');
    await audio.writeAsBytes(List<int>.filled(100, 0));
    final store = PlaybackHistoryStore(inMemory: true);
    await store.load();
    await store.record(point(audio.path, fileId: 178, seconds: 30));
    final player = _FakePlayer();
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: store,
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForPlaybackHistory();

    await controller.playExported(
      audio.path,
      fileId: 178,
      startAt: const Duration(seconds: 30),
    );
    player.emitPosition(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      store.forRecording(fileId: 178, path: audio.path)?.position,
      const Duration(seconds: 30),
    );
  });

  test('系统回退到已结束音频的中段时清除完成状态', () async {
    final audio = File('${temp.path}/178.wav');
    await audio.writeAsBytes(List<int>.filled(100, 0));
    final store = PlaybackHistoryStore(inMemory: true);
    await store.load();
    final player = _FakePlayer();
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: store,
      player: player,
    );
    addTearDown(controller.dispose);
    await controller.waitForPlaybackHistory();

    await controller.playExported(audio.path, fileId: 178);
    player.emitCompleted();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.playbackCompleted, isTrue);

    player.emitPosition(const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.playbackCompleted, isFalse);
    expect(controller.position, const Duration(seconds: 60));
  });

  test('播放进度写失败不把已完成的删除报成失败', () async {
    final blocker = File('${temp.path}/blocked-delete');
    await blocker.writeAsString('not a directory');
    final store = PlaybackHistoryStore(
      file: File('${blocker.path}/history.json'),
    );
    final audio = File('${temp.path}/178.wav');
    await audio.writeAsBytes([1, 2, 3, 4]);
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: store,
    );
    addTearDown(controller.dispose);
    await controller.waitForPlaybackHistory();
    controller.exportedPaths.add(audio.path);

    final result = await controller.deleteLocalExports([audio.path]);

    expect(result.deleted, 1);
    expect(result.failed, isEmpty);
    expect(await audio.exists(), isFalse);
    expect(controller.exportedPaths, isNot(contains(audio.path)));
    expect(controller.errorMessage, contains('播放进度记录未能清理'));
  });

  testWidgets('重启后今日页从持久化记录显示继续回听并调用真实播放入口', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final audio = File('${temp.path}/178.wav');
    late _PlaybackProbeController controller;
    await tester.runAsync(() async {
      await audio.writeAsBytes([1, 2, 3, 4]);
      final store = PlaybackHistoryStore(file: historyFile);
      await store.load();
      await store.record(point(audio.path, seconds: 42, total: 300));
      controller = _PlaybackProbeController(store);
      await controller.waitForPlaybackHistory();
    });
    addTearDown(controller.dispose);
    controller.exportedPaths.add(audio.path);

    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    expect(find.byKey(const ValueKey('continue-listening')), findsOneWidget);
    expect(find.textContaining('已听 0:42 / 5:00'), findsOneWidget);
    await tester.tap(find.byTooltip('继续播放').first);
    await tester.pump();
    expect(controller.played, [audio.path]);
  });
}

class _PlaybackProbeController extends RecorderController {
  _PlaybackProbeController(PlaybackHistoryStore store)
    : super(loadPersistedState: false, playbackHistoryStore: store);

  final played = <String>[];

  @override
  Future<void> playExported(
    String path, {
    int? fileId,
    Duration? startAt,
  }) async {
    played.add(path);
    notifyListeners();
  }
}

class _FakePlayer extends AudioPlayer {
  final _states = StreamController<PlayerState>.broadcast();
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration?>.broadcast();
  final _processing = StreamController<ProcessingState>.broadcast();
  final _play = Completer<void>();
  final seeks = <Duration?>[];

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
  Duration? get duration => const Duration(seconds: 120);

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async => const Duration(seconds: 120);

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seeks.add(position);
  }

  @override
  Future<void> play() => _play.future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  void emitPosition(Duration value) => _positions.add(value);
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
