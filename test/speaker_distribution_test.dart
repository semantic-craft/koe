import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/speaker_distribution_screen.dart';
import 'package:koe/ui/transcript_jump.dart';
import 'package:provider/provider.dart';

/// #143: the speaker view counts from the segments the reader shows, opens
/// the matching sentence, follows speaker corrections and survives restart.
void main() {
  late Directory temp;
  late String path;
  late RecordingReference reference;

  TranscriptSegment segment(String text, int start, int end, String? who) =>
      TranscriptSegment(
        text: text,
        start: Duration(seconds: start),
        end: Duration(seconds: end),
        speaker: who,
        speakerChanged: who != null,
      );

  // Speaker 1 and 2 talk over each other for 2 s; one sentence has no
  // speaker. Voiced 30 s of a 40 s recording.
  final segments = [
    segment('甲先说。', 0, 10, '1'),
    segment('乙接话。', 8, 20, '2'),
    segment('没人认领。', 24, 28, null),
    segment('甲收尾。', 30, 36, '1'),
  ];
  const text = '说话人 1：甲先说。\n说话人 2：乙接话。\n没人认领。\n说话人 1：甲收尾。';

  setUp(() {
    // A tap that lands off the chip would make "nothing happened" pass.
    WidgetController.hitTestWarningShouldBeFatal = true;
    temp = Directory.systemTemp.createTempSync('koe-speakers-');
    path = '${temp.path}/143100.wav';
    reference = RecordingReference(fileId: 143100, path: path);
  });

  tearDown(() {
    WidgetController.hitTestWarningShouldBeFatal = false;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Controller and its stores load in the real zone, not on the fake clock.
  Future<_SpeakerController> start(WidgetTester tester) async {
    final controller = (await tester.runAsync(() async {
      final created = _SpeakerController();
      await created.settleTopicNoteWork();
      return created;
    }))!;
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> showDetail(WidgetTester tester, RecorderController c) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          theme: AppTheme.light,
          home: RecordingDetailScreen(reference: reference),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发言人'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('speaker-distribution')), findsOneWidget);
  }

  Finder shareOf(String group) => find.byKey(ValueKey('speaker-share-$group'));

  void expectShare(String group, String value) => expect(
    find.descendant(of: shareOf(group), matching: find.text(value)),
    findsOneWidget,
    reason: '$group 应显示 $value',
  );

  void expectMetric(String key, String value) => expect(
    find.descendant(
      of: find.byKey(ValueKey('speaker-$key')),
      matching: find.text(value),
    ),
    findsOneWidget,
    reason: '$key 应显示 $value',
  );

  testWidgets('点片段进入原句并回听，改归属后统计更新，重启后保持', (tester) async {
    // The store is one shared file: empty it again, letting the queued real
    // write finish while the test clock is pumped.
    addTearDown(() async {
      var done = false;
      unawaited(
        TranscriptStore.save(
          byPath: const {},
          byFileId: const {},
          aliasesByPath: const {},
          aliasesByFileId: const {},
        ).whenComplete(() => done = true),
      );
      for (var i = 0; i < 300 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
    });
    await tester.runAsync(() async {
      await File(path).writeAsBytes(List.filled(64, 0));
      await TranscriptStore.save(
        byPath: {path: text},
        byFileId: const {},
        aliasesByPath: const {},
        aliasesByFileId: const {},
        segments: {'file:143100': segments},
        strict: true,
      );
    });
    final c = await start(tester);
    await showDetail(tester, c);

    expect(
      find.text('有人声 00:30，录音 00:40'),
      findsOneWidget,
      reason: '分母写明是有人声总时长，并给出录音总时长',
    );
    expectShare('1', '00:16  53%');
    expectShare('2', '00:12  40%');
    expectShare('unlabeled', '00:04  13%');
    expectMetric('overlap', '00:02');
    expectMetric('silence', '00:10');
    expect(find.text('未标注发言人'), findsWidgets);

    // Speaker 2's sentence opens in the text at that sentence and plays.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('speaker-segment-1')),
      200,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('speaker-segment-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('speaker-segment-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('highlighted-segment-1')), findsOneWidget);
    expect(c.playbackRequests, [(path, const Duration(seconds: 8), 143100)]);

    // Correct that sentence to speaker 1 in the text, as #128 allows.
    await tester.tap(find.byKey(const ValueKey('segment-speaker-1')));
    await tester.pumpAndSettle();
    expect(find.text('这段是谁说的？'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '说话人 1'));
    await tester.pumpAndSettle();
    // The save runs on real I/O; pump between real-time waits so its
    // continuations on the test clock run too.
    var saved = false;
    for (var i = 0; i < 300 && !saved; i++) {
      await tester.runAsync(() async {
        final stored = await TranscriptStore.load();
        saved = stored.segmentSpeakersByKey['file:143100']?[1] == '1';
        if (!saved) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
    }
    expect(saved, isTrue, reason: '发言人改正应写入存储');
    expect(find.text('无法保存发言人归属，请重试'), findsNothing);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('返回发言人'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('speaker-distribution')), findsOneWidget);
    expect(shareOf('2'), findsNothing, reason: '说话人 2 已没有任何片段');
    expectShare('1', '00:26  87%');
    expectMetric('overlap', '00:00');

    // Restart: a fresh controller reads the saved correction back.
    await tester.pumpWidget(const SizedBox.shrink());
    final restarted = await start(tester);
    await showDetail(tester, restarted);
    expect(shareOf('2'), findsNothing);
    expectShare('1', '00:26  87%');
    expectShare('unlabeled', '00:04  13%');
    expectMetric('overlap', '00:00');
  });

  testWidgets('缺原音频仍显示文字统计，但片段时间不假装能回听', (tester) async {
    final c = _SpeakerController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.views[reference.key] = RecordingViewData(
      reference: reference,
      title: '缺音频',
      path: path,
      text: text,
      segments: segments,
      originalPresent: false,
    );
    final opened = <TranscriptJump>[];
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          theme: AppTheme.light,
          home: SpeakerDistributionScreen(
            reference: reference,
            onOpenSource: opened.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('speaker-audio-missing')), findsOneWidget);
    expect(find.text('有人声 00:30，录音 时长未知'), findsOneWidget);
    expectShare('1', '00:16  53%');
    expectMetric('silence', '未知');

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('speaker-segment-1')),
      200,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('speaker-segment-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('speaker-segment-1')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(c.playbackRequests, isEmpty);
  });

  testWidgets('没有分段、处理中、失败各自提示，不显示人数或占比', (tester) async {
    final c = _SpeakerController(loadPersistedState: false);
    addTearDown(c.dispose);
    Future<void> show(RecordingViewData view) async {
      c.views[reference.key] = view;
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: c,
          child: MaterialApp(
            theme: AppTheme.light,
            home: SpeakerDistributionScreen(
              key: UniqueKey(),
              reference: reference,
              onOpenSource: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('%'), findsNothing);
      expect(find.byKey(const ValueKey('speaker-denominator')), findsNothing);
    }

    await show(
      RecordingViewData(
        reference: reference,
        title: '无分段',
        path: path,
        text: '一整段没有时码的文字。',
      ),
    );
    expect(find.byKey(const ValueKey('speaker-no-segments')), findsOneWidget);

    await show(
      RecordingViewData(
        reference: reference,
        title: '处理中',
        path: path,
        text: '',
        processing: true,
      ),
    );
    expect(find.byKey(const ValueKey('speaker-processing')), findsOneWidget);

    await show(
      RecordingViewData(
        reference: reference,
        title: '失败',
        path: path,
        text: '',
        error: '网络中断',
      ),
    );
    expect(find.byKey(const ValueKey('speaker-error')), findsOneWidget);
    expect(find.textContaining('网络中断'), findsOneWidget);
  });
}

class _SpeakerController extends RecorderController {
  _SpeakerController({super.loadPersistedState = true});

  final views = <String, RecordingViewData>{};
  final playbackRequests = <(String, Duration, int?)>[];

  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      views[reference.key] ?? super.recordingView(reference);

  @override
  Duration? localDurationForPath(String path) => const Duration(seconds: 40);

  @override
  Future<void> playFrom(String path, Duration start, {int? fileId}) async {
    playbackRequests.add((path, start, fileId));
  }
}
