import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/widgets/inline_player.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('系统回退后结束状态立即从播放器界面消失', (tester) async {
    const path = '/tmp/178.wav';
    final player = _ProbePlayer();
    final controller = RecorderController(
      loadPersistedState: false,
      playbackHistoryStore: PlaybackHistoryStore(inMemory: true),
      player: player,
    );
    addTearDown(controller.dispose);
    controller.playingPath = path;
    controller.duration = const Duration(seconds: 120);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          home: Scaffold(body: InlinePlayer(path: path)),
        ),
      ),
    );
    player.emitCompleted();
    await tester.pump();
    expect(find.text('已结束'), findsOneWidget);

    player.emitPosition(const Duration(seconds: 60));
    await tester.pump();
    await tester.pump();
    expect(find.text('已结束'), findsNothing);
  });
}

class _ProbePlayer extends AudioPlayer {
  final _positions = StreamController<Duration>.broadcast();
  final _processing = StreamController<ProcessingState>.broadcast();

  @override
  Stream<PlayerState> get playerStateStream => const Stream.empty();

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<Duration?> get durationStream => const Stream.empty();

  @override
  Stream<ProcessingState> get processingStateStream => _processing.stream;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Duration? get duration => const Duration(seconds: 120);

  @override
  Future<void> pause() async {}

  void emitCompleted() => _processing.add(ProcessingState.completed);

  void emitPosition(Duration value) => _positions.add(value);

  @override
  Future<void> dispose() async {
    await _positions.close();
    await _processing.close();
    await super.dispose();
  }
}
