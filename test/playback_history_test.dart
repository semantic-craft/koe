import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('显式指定 0:00 时不恢复断点，只有未指定起点才续听', () async {
    final store = PlaybackHistoryStore(inMemory: true);
    await store.record(point('/tmp/100.wav', fileId: 100, seconds: 30));
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: store,
    );
    addTearDown(controller.dispose);
    await controller.waitForPlaybackHistory();

    expect(
      controller.resolvePlaybackStart(
        path: '/tmp/100.wav',
        fileId: 100,
        total: const Duration(seconds: 120),
        requested: Duration.zero,
      ),
      Duration.zero,
    );
    expect(
      controller.resolvePlaybackStart(
        path: '/tmp/100.wav',
        fileId: 100,
        total: const Duration(seconds: 120),
      ),
      const Duration(seconds: 30),
    );
    expect(
      controller.resolvePlaybackStart(
        path: '/tmp/100.wav',
        fileId: 100,
        total: const Duration(seconds: 10),
        requested: const Duration(seconds: 30),
      ),
      const Duration(seconds: 10),
    );
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
