import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

void main() {
  const path = '/tmp/128100.wav';
  const key = 'file:128100';

  TranscriptSegment segment(String text, int start, {String? speaker = '1'}) =>
      TranscriptSegment(
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

    c.rememberTranscript(path, '新服务转写', segments: [segment('新服务转写', 0)]);

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
    expect(c.transcriptSegmentsForPath(path).first.speakerChanged, isTrue);
    final saved = await TranscriptStore.load();
    expect(saved.segmentSpeakersByKey[key]?[0], '2');
  });

  test('重新转写换了分段后，旧的片段归属不套到新句子上', () async {
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

    c.rememberTranscript(
      path,
      '说话人 1：丙丁',
      segments: [
        segment('丙', 0, speaker: '1'),
        segment('丁', 10, speaker: '1'),
      ],
    );

    expect(c.transcriptSegmentsForPath(path).map((s) => s.speaker), ['1', '1']);
    await pumpEventQueue();
    final saved = await TranscriptStore.load();
    expect(saved.segmentSpeakersByKey[key], isNull);
  });

  test('清除发言人标签并在相邻片段重算显示边界', () async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '说话人 1：甲\n说话人 1：乙',
      segments: [
        segment('甲', 0, speaker: '1'),
        segment('乙', 10, speaker: '1'),
      ],
    );

    await c.setSegmentSpeaker(path, 0, '2');
    var shown = c.transcriptSegmentsForPath(path);
    expect(shown[0].speaker, '2');
    expect(shown[0].speakerChanged, isTrue);
    expect(shown[1].speaker, '1');
    expect(shown[1].speakerChanged, isTrue);

    await c.setSegmentSpeaker(path, 0, '');
    shown = c.transcriptSegmentsForPath(path);
    expect(shown[0].speaker, isNull);
    expect(shown[0].speakerChanged, isFalse);
    expect(shown[1].speaker, '1');
    expect(shown[1].speakerChanged, isTrue);
  });

  test('人工改字后旧译文失效，重转写与手改一致时清掉旧待采用稿', () async {
    const reference = RecordingReference(fileId: 128100, path: path);
    await TranscriptStore.save(
      byPath: const {path: '原始正文'},
      byFileId: const {},
      aliasesByPath: const {},
      aliasesByFileId: const {},
      metadata: const {
        key: TranscriptMetadata(provider: SttProvider.qwen, revision: 1),
      },
      translations: const {
        key: RecordingTranslation(
          text: 'Old translation',
          sourceLanguage: 'zh',
          targetLanguage: 'en',
          provider: SttProvider.qwen,
          sourceRevision: 1,
        ),
      },
    );
    final c = RecorderController(loadPersistedState: true);
    addTearDown(c.dispose);
    await c.settleTopicNoteWork();
    expect(c.recordingView(reference).translation, isNotNull);

    await c.saveManualTranscript(path, '人工正文');
    expect(c.recordingView(reference).translation, isNull);

    c.rememberTranscript(path, '另一版转写');
    expect(c.incomingTranscriptForPath(path), '另一版转写');
    c.rememberTranscript(path, '人工正文');
    expect(c.hasPendingTranscript(path), isFalse);
  });

  test('手改正文后的译文不会被未采用的转写版本作废', () async {
    await TranscriptStore.save(
      byPath: const {path: '人工正文'},
      byFileId: const {},
      aliasesByPath: const {},
      aliasesByFileId: const {},
      metadata: const {
        key: TranscriptMetadata(provider: SttProvider.qwen, revision: 1),
      },
      translations: const {
        key: RecordingTranslation(
          text: 'Manual translation',
          sourceLanguage: 'zh',
          targetLanguage: 'en',
          provider: SttProvider.qwen,
          sourceRevision: 1,
        ),
      },
      manualByKey: const {key: '人工正文'},
    );
    final c = RecorderController(loadPersistedState: true);
    addTearDown(c.dispose);
    await c.settleTopicNoteWork();

    c.rememberTranscript(path, '另一版转写');

    expect(c.incomingTranscriptForPath(path), '另一版转写');
    expect(
      c
          .recordingView(const RecordingReference(fileId: 128100, path: path))
          .translation
          ?.text,
      'Manual translation',
    );
  });

  test('手改正文后转写语言变化仍会作废旧译文', () async {
    await TranscriptStore.save(
      byPath: const {path: '人工正文'},
      byFileId: const {},
      aliasesByPath: const {},
      aliasesByFileId: const {},
      metadata: const {
        key: TranscriptMetadata(provider: SttProvider.qwen, revision: 1),
      },
      translations: const {
        key: RecordingTranslation(
          text: 'Manual translation',
          sourceLanguage: 'zh',
          targetLanguage: 'en',
          provider: SttProvider.qwen,
          sourceRevision: 1,
        ),
      },
      manualByKey: const {key: '人工正文'},
    );
    final c = RecorderController(loadPersistedState: true);
    addTearDown(c.dispose);
    await c.settleTopicNoteWork();

    c.rememberTranscript(path, '人工正文', sourceLanguage: 'ja');

    expect(
      c
          .recordingView(const RecordingReference(fileId: 128100, path: path))
          .translation,
      isNull,
    );
  });

  test('保存与现有手改相同的正文不会作废译文', () async {
    await TranscriptStore.save(
      byPath: const {path: '人工正文'},
      byFileId: const {},
      aliasesByPath: const {},
      aliasesByFileId: const {},
      metadata: const {
        key: TranscriptMetadata(provider: SttProvider.qwen, revision: 1),
      },
      translations: const {
        key: RecordingTranslation(
          text: 'Manual translation',
          sourceLanguage: 'zh',
          targetLanguage: 'en',
          provider: SttProvider.qwen,
          sourceRevision: 1,
        ),
      },
      manualByKey: const {key: '人工正文'},
    );
    final c = RecorderController(loadPersistedState: true);
    addTearDown(c.dispose);
    await c.settleTopicNoteWork();
    const reference = RecordingReference(fileId: 128100, path: path);
    expect(c.recordingView(reference).translation, isNotNull);

    await c.saveManualTranscript(path, '人工正文');

    expect(c.recordingView(reference).translation?.text, 'Manual translation');
  });

  test('关闭待采用稿保存失败时恢复提示', () async {
    var failStrictSave = false;
    final c = RecorderController(
      loadPersistedState: false,
      transcriptPersister: ({bool strict = false}) async {
        if (strict && failStrictSave) throw StateError('磁盘不可写');
      },
    );
    addTearDown(c.dispose);
    c.rememberTranscript(path, '原始正文');
    await c.saveManualTranscript(path, '人工正文');
    c.rememberTranscript(path, '新版本正文');
    expect(c.hasPendingTranscript(path), isTrue);

    failStrictSave = true;
    await expectLater(
      c.dismissIncomingTranscript(path),
      throwsA(isA<StateError>()),
    );

    expect(c.hasPendingTranscript(path), isTrue);
    expect(c.incomingTranscriptForPath(path), '新版本正文');
  });

  test('发言人改正保存失败时回滚内存状态', () async {
    var failStrictSave = false;
    final c = RecorderController(
      loadPersistedState: false,
      transcriptPersister: ({bool strict = false}) async {
        if (strict && failStrictSave) throw StateError('磁盘不可写');
      },
    );
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '甲\n乙',
      segments: [
        segment('甲', 0, speaker: '1'),
        segment('乙', 10, speaker: '2'),
      ],
    );
    await c.setSegmentSpeaker(path, 0, '2');

    failStrictSave = true;
    await expectLater(
      c.setSegmentSpeaker(path, 1, '1'),
      throwsA(isA<StateError>()),
    );

    final shown = c.transcriptSegmentsForPath(path);
    expect(shown[0].speaker, '2');
    expect(shown[1].speaker, '2');
    expect(shown[1].speakerChanged, isFalse);
  });

  test('无文字标签但有时码分段的发言人也能改名', () async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.rememberTranscript(
      path,
      '甲\n乙',
      segments: [
        segment('甲', 0, speaker: '1'),
        segment('乙', 10, speaker: '2'),
      ],
    );

    await c.renameTranscriptSpeaker(path, '2', '张三');

    expect(
      c.transcriptSpeakersForPath(path).map((speaker) => speaker.displayLabel),
      contains('张三'),
    );
  });

  test('采用新转写时清掉旧发言人姓名', () async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.rememberTranscript(path, '旧正文', segments: [segment('旧正文', 0)]);
    c.speakerAliasesByPath[path] = {'1': '张三'};
    c.speakerAliasesByFileId[128100] = {'1': '张三'};
    await c.saveManualTranscript(path, '人工正文');
    c.rememberTranscript(path, '新版本正文');

    await c.adoptIncomingTranscript(path);

    expect(c.speakerAliasesByPath[path], isNull);
    expect(c.speakerAliasesByFileId[128100], isNull);
  });

  test('采用新转写保存失败时恢复旧发言人姓名', () async {
    var failStrictSave = false;
    final c = RecorderController(
      loadPersistedState: false,
      transcriptPersister: ({bool strict = false}) async {
        if (strict && failStrictSave) throw StateError('磁盘不可写');
      },
    );
    addTearDown(c.dispose);
    c.rememberTranscript(path, '旧正文', segments: [segment('旧正文', 0)]);
    c.speakerAliasesByPath[path] = {'1': '张三'};
    c.speakerAliasesByFileId[128100] = {'1': '张三'};
    await c.saveManualTranscript(path, '人工正文');
    c.rememberTranscript(path, '新版本正文');

    failStrictSave = true;
    await expectLater(
      c.adoptIncomingTranscript(path),
      throwsA(isA<StateError>()),
    );

    expect(c.speakerAliasesByPath[path], {'1': '张三'});
    expect(c.speakerAliasesByFileId[128100], {'1': '张三'});
  });

  test('手工保存为服务版本时清掉旧发言人姓名', () async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.rememberTranscript(path, '原始正文', segments: [segment('原始正文', 0)]);
    c.speakerAliasesByPath[path] = {'1': '张三'};
    c.speakerAliasesByFileId[128100] = {'1': '张三'};
    await c.saveManualTranscript(path, '人工正文');
    c.rememberTranscript(path, '新服务版本');

    await c.saveManualTranscript(path, '新服务版本');

    expect(c.speakerAliasesByPath[path], isNull);
    expect(c.speakerAliasesByFileId[128100], isNull);
  });

  test('手工保存为服务版本失败时恢复旧发言人姓名', () async {
    var failStrictSave = false;
    final c = RecorderController(
      loadPersistedState: false,
      transcriptPersister: ({bool strict = false}) async {
        if (strict && failStrictSave) throw StateError('磁盘不可写');
      },
    );
    addTearDown(c.dispose);
    c.rememberTranscript(path, '原始正文', segments: [segment('原始正文', 0)]);
    c.speakerAliasesByPath[path] = {'1': '张三'};
    c.speakerAliasesByFileId[128100] = {'1': '张三'};
    await c.saveManualTranscript(path, '人工正文');
    c.rememberTranscript(path, '新服务版本');

    failStrictSave = true;
    await expectLater(
      c.saveManualTranscript(path, '新服务版本'),
      throwsA(isA<StateError>()),
    );

    expect(c.speakerAliasesByPath[path], {'1': '张三'});
    expect(c.speakerAliasesByFileId[128100], {'1': '张三'});
    expect(c.manualTranscriptForPath(path), '人工正文');
  });

  test('人工正文引入的发言人也能改名', () async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    c.rememberTranscript(path, '原始正文', segments: [segment('原始正文', 0)]);
    await c.saveManualTranscript(path, '说话人 3：人工补充');
    expect(
      c.transcriptSpeakersForPath(path).map((speaker) => speaker.id),
      contains('3'),
    );

    await c.renameTranscriptSpeaker(path, '3', '李四');

    expect(
      c.transcriptSpeakersForPath(path).map((speaker) => speaker.displayLabel),
      contains('李四'),
    );
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

  testWidgets('编辑正文时使用无别名的原始正文', (tester) async {
    const reference = RecordingReference(fileId: 128100, path: path);
    final c = _EditProbeController();
    c.canonicalText = '说话人 1：原始正文';
    c.views[reference.key] = const RecordingViewData(
      reference: reference,
      title: '别名测试',
      path: path,
      text: '张三：原始正文',
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

    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('transcript-edit-input')),
          )
          .controller
          ?.text,
      '说话人 1：原始正文',
    );
  });
}

class _EditProbeController extends RecorderController {
  _EditProbeController() : super(loadPersistedState: false);

  final views = <String, RecordingViewData>{};
  final saved = <String>[];
  bool failSave = false;
  String? canonicalText;

  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      views[reference.key] ?? super.recordingView(reference);

  @override
  String? canonicalTranscriptForPath(String path) =>
      canonicalText ?? super.canonicalTranscriptForPath(path);

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
