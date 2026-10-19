import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/widgets/inline_player.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('播放进度只刷新进度条和时间，不通知整个控制器', (tester) async {
    const path = '/tmp/178.wav';
    final player = _PositionPlayer();
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: player,
    );
    addTearDown(controller.dispose);
    controller.playingPath = path;
    controller.duration = const Duration(minutes: 2);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          home: Scaffold(body: InlinePlayer(path: path)),
        ),
      ),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    for (final seconds in [1, 2, 3, 65]) {
      player.emitPosition(Duration(seconds: seconds));
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(notifications, 0);
    expect(find.text('01:05'), findsOneWidget);
  });
}

class _PositionPlayer extends AudioPlayer {
  final _positions = StreamController<Duration>.broadcast();

  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<ProcessingState> get processingStateStream => const Stream.empty();

  void emitPosition(Duration value) => _positions.add(value);

  @override
  Future<void> dispose() async {
    await _positions.close();
    await super.dispose();
  }
}
