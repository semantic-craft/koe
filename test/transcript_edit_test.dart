import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

void main() {
  const path = '/tmp/128100.wav';
  const key = 'file:128100';

  TranscriptSegment segment(
    String text,
    int start, {
    String? speaker = '1',
  }) => TranscriptSegment(
    text: text,
    start: Duration(seconds: start),
    speaker: speaker,
    speakerChanged: speaker != null,
  );

  tearDown(() async {
    await TranscriptStore.save(
      byPath: const {},
      byFileId: const {},
      aliasesByPath: const {},
      aliasesByFileId: const {},
    );
  });

  test('人工校订正文、重启后仍显示，旧时码明确不再对应', () async {
    final original = [segment('第一句', 0), segment('第二句', 10)];
    await TranscriptStore.save(
      byPath: const {path: '第一句第二句'},
      byFileId: const {},
      aliasesByPath: const {},
      aliasesByFileId: const {},
      segments: {key: original},
      manualByKey: const {key: '校订后的第一句。校订后的第二句。'},
    );

    final c = RecorderController(loadPersistedState: true);
    addTearDown(c.dispose);
    await c.settleTopicNoteWork();

    final view = c.recordingView(const RecordingReference(path: path));
    expect(view.text, '校订后的第一句。校订后的第二句。');
    expect(view.manuallyEdited, isTrue);
    expect(view.segments, hasLength(2));
    expect(
      transcriptSegmentsMatchText(view.segments, view.text),
      isFalse,
      reason: '校订后的正文不能继续绑定旧时码',
    );
  });

  test('重转写不覆盖手改，新版本可查看后再采用', () async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.rememberTranscript(path, '原始正文', segments: [segment('原始正文', 0)]);
    await c.saveManualTranscript(path, '人工校订正文');
    expect(c.transcriptForPath(path), '人工校订正文');

    c.rememberTranscript(
      path,
      '新服务转写',
      segments: [segment('新服务转写', 0)],
    );

    expect(c.transcriptForPath(path), '人工校订正文');
    expect(c.hasPendingTranscript(path), isTrue);
    expect(c.incomingTranscriptForPath(path), '新服务转写');

    await c.adoptIncomingTranscript(path);
    expect(c.transcriptForPath(path), '新服务转写');
    expect(c.hasPendingTranscript(path), isFalse);
  });

  test('改正片段归属会落到显示分段并持久化', () async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '说话人 1：甲\n说话人 2：乙',
      segments: [
        segment('甲', 0, speaker: '1'),
        segment('乙', 10, speaker: '2'),
      ],
    );

    await c.setSegmentSpeaker(path, 0, '2');

    expect(c.transcriptSegmentsForPath(path).first.speaker, '2');
    expect(
      c.transcriptSegmentsForPath(path).first.speakerChanged,
      isTrue,
    );
    final saved = await TranscriptStore.load();
    expect(saved.segmentSpeakersByKey[key]?[0], '2');
  });

  testWidgets('保存失败保留编辑草稿，成功后关闭并保存校订', (tester) async {
    const reference = RecordingReference(fileId: 128100, path: path);
    final c = _EditProbeController();
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '校订测试',
      path: path,
      text: '原始正文',
      segments: [],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: const MaterialApp(
          home: RecordingDetailScreen(reference: reference),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑正文'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transcript-edit-input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('transcript-edit-input')),
      '失败时保留的草稿',
    );
    c.failSave = true;
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transcript-edit-error')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('transcript-edit-input')),
          )
          .controller
          ?.text,
      '失败时保留的草稿',
    );

    c.failSave = false;
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('transcript-edit-input')), findsNothing);
    expect(c.saved, ['失败时保留的草稿']);
  });
}

class _EditProbeController extends RecorderController {
  _EditProbeController() : super(loadPersistedState: false);

  final views = <String, RecordingViewData>{};
  final saved = <String>[];
  bool failSave = false;

  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      views[reference.key] ?? super.recordingView(reference);

  @override
  Future<bool> saveManualTranscript(String path, String text) async {
    if (failSave) throw StateError('保存失败');
    saved.add(text);
    final reference = views.keys.single;
    final current = views[reference]!;
    views[reference] = RecordingViewData(
      reference: current.reference,
      title: current.title,
      path: current.path,
      text: text,
      manuallyEdited: true,
    );
    notifyListeners();
    return true;
  }
}
