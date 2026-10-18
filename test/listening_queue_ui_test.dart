import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/listening_queue_screen.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('koe-queue-ui-');
  });
  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  /// Store, controller and their loads all run in the real zone: a load queue
  /// created under the fake test clock would never finish.
  Future<({RecorderController controller, _UiPlayer player})> start(
    WidgetTester tester,
  ) async {
    final result = (await tester.runAsync(() async {
      final player = _UiPlayer();
      final controller = RecorderController(
        loadPersistedState: false,
        listeningQueueStore: ListeningQueueStore(inMemory: true),
        player: player,
        libraryDirectory: Directory('${directory.path}/imports'),
      );
      await controller.waitForListeningQueue();
      await controller.waitForPlaybackHistory();
      return (controller: controller, player: player);
    }))!;
    addTearDown(result.controller.dispose);
    return result;
  }

  File audio(String name) {
    final file = File('${directory.path}/$name');
    file.writeAsBytesSync(wavBytes(List<int>.filled(256, 0)));
    return file;
  }

  /// Real file reads finish outside the fake clock; pump until the visible
  /// result appears instead of guessing a delay.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: '等待的结果没有出现');
  }

  testWidgets('资料页进入空队列，详情加入后队列保存并显示', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (:controller, :player) = await start(tester);
    final file = audio('访谈一.wav');
    controller.exportedPaths.add(file.path);

    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('library-queue')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-queue')));
    await tester.pumpAndSettle();
    expect(find.byType(ListeningQueueScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-empty')), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('recording-row-${file.path}')));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingDetailScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('add-to-queue')));
    await until(tester, () => controller.queueEntries.isNotEmpty);

    expect(controller.queueEntries.single.path, file.path);
    expect(find.text('已加入收听队列'), findsOneWidget);
  });

  testWidgets('队列页在窄屏大字号下不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final (:controller, :player) = await start(tester);
    final first = audio('第一段.wav');
    final second = audio('第二段.wav');
    controller.exportedPaths.addAll([first.path, second.path]);
    await tester.runAsync(() async {
      await controller.addToListeningQueue(
        RecordingReference(path: first.path),
      );
      await controller.addToListeningQueue(
        RecordingReference(path: second.path),
      );
    });

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: ListeningQueueScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        ValueKey('queue-row-${ListeningQueueEntry.keyFor(path: first.path)}'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('队列页移除当前项按选择继续下一项，并能回到详情', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (:controller, :player) = await start(tester);
    final first = audio('第一段.wav');
    final second = audio('第二段.wav');
    controller.exportedPaths.addAll([first.path, second.path]);

    await tester.runAsync(() async {
      await controller.addToListeningQueue(
        RecordingReference(path: first.path),
      );
      await controller.addToListeningQueue(
        RecordingReference(path: second.path),
      );
      await controller.playQueueEntry(
        ListeningQueueEntry.keyFor(path: first.path),
      );
      await controller.waitForQueueIdle();
    });
    player.emitState(playing: true);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: ListeningQueueScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final firstKey = ListeningQueueEntry.keyFor(path: first.path);
    final secondKey = ListeningQueueEntry.keyFor(path: second.path);
    expect(find.byKey(ValueKey('queue-row-$firstKey')), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('queue-remove-$firstKey')));
    await tester.pump();
    expect(find.text('移除并播放下一项'), findsOneWidget);
    await tester.tap(find.text('移除并播放下一项'));
    await until(tester, () => controller.playingPath == second.path);
    await tester.pumpAndSettle();

    expect(controller.queueEntries.single.path, second.path);
    expect(controller.queueCurrentKey, secondKey);
    expect(controller.playingPath, second.path);

    await tester.tap(find.byKey(ValueKey('queue-open-$secondKey')));
    await tester.pumpAndSettle();
    expect(find.byType(RecordingDetailScreen), findsOneWidget);
  });
}

class _UiPlayer extends AudioPlayer {
  final _states = StreamController<PlayerState>.broadcast();
  final _play = Completer<void>();

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<Duration> get positionStream => const Stream.empty();

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Duration? get duration => const Duration(minutes: 5);

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async => const Duration(minutes: 5);

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> seek(Duration? position, {int? index}) async {}

  @override
  Future<void> play() => _play.future;

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  void emitState({required bool playing}) =>
      _states.add(PlayerState(playing, ProcessingState.ready));

  @override
  Future<void> dispose() async {
    await _states.close();
    await super.dispose();
  }
}
