import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/topics_screen.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TopicNote generalNote(String topicId, String overview) => TopicNote(
    kind: TopicKind.general,
    topicId: topicId,
    overview: overview,
    ideas: const [
      TopicIdea(text: '想法', reason: '理由', sources: ['S1']),
    ],
  );

  AnalysisResult noteResult(TopicNote note) => AnalysisResult(
    text: note.encode(),
    sourceHash: 'synthetic-note-hash',
    model: TopicNote.defaultModel,
    instruction: 'synthetic note',
    sources: const ['synthetic source block'],
    createdAt: DateTime(2026, 10, 16),
  );

  test('书籍按口述页码排序，无页码按录音时间；普通主题全按时间', () {
    final book = Topic(
      id: 'book',
      kind: TopicKind.book,
      title: '虚构书',
      author: '甲',
      createdAt: DateTime(2026, 10, 16),
    );
    TopicSummaryNote bookNote(String key, int time, String? page) {
      final note = TopicNote(
        kind: TopicKind.book,
        topicId: book.id,
        overview: '关于$key 的评论',
        excerpts: page == null
            ? const []
            : [
                TopicExcerpt(text: '虚构摘录', page: page, sources: const ['S1']),
              ],
      );
      return TopicSummaryNote(
        recordingKey: key,
        title: key,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(time * 1000),
        note: note,
      );
    }

    final notes = [
      bookNote('late-no-page', 40, null),
      bookNote('page-30', 10, '第30页'),
      bookNote('early-no-page', 20, null),
      bookNote('page-8', 30, '第八页'),
    ];
    final ordered = buildTopicSummaryInput(book, notes);
    expect(ordered.sources.map((s) => s.recordingKey), [
      'page-8',
      'page-30',
      'early-no-page',
      'late-no-page',
    ]);
    expect(ordered.source, contains('[N1] page-8'));
    final general = Topic(
      id: 'general',
      kind: TopicKind.general,
      title: '想法',
      createdAt: DateTime(2026, 10, 16),
    );
    final generalNotes = notes.map((item) {
      final note = generalNote(general.id, item.recordingKey);
      return TopicSummaryNote(
        recordingKey: item.recordingKey,
        title: item.title,
        recordedAt: item.recordedAt,
        note: note,
      );
    });
    expect(
      buildTopicSummaryInput(
        general,
        generalNotes,
      ).sources.map((s) => s.recordingKey),
      ['page-30', 'early-no-page', 'page-8', 'late-no-page'],
    );
  });

  test('手动调用只发送笔记；编辑、新增、迁出使汇总过期，归档隐藏过期后重开恢复', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(kind: TopicKind.general, title: '规划');
    final other = await store.createTopic(kind: TopicKind.general, title: '其他');
    final sent = <String>[];
    final service = _SummaryService((source, instruction) async {
      sent.add(source);
      return _generalSummaryJson();
    });
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    for (final key in [
      'file:1760000001',
      'file:1760000002',
      'file:1760000003',
    ]) {
      await store.moveRecording(key, topic.id);
      analysis.results[TopicNote.slotKey(key)] = noteResult(
        generalNote(topic.id, '笔记$key'),
      );
    }
    await controller.settleTopicNoteWork();
    expect(sent, isEmpty); // Neither opening nor assignment creates a summary.
    await controller.generateTopicSummary(topic.id);
    expect(sent, hasLength(1));
    expect(sent.single, contains('笔记file:1760000001'));
    expect(sent.single, contains('笔记file:1760000002'));
    expect(sent.single, contains('笔记file:1760000003'));
    final slot = TopicSummary.slotKey(topic.id);
    expect(analysis.results[slot], isNotNull);
    expect(controller.isTopicSummaryStale(topic.id), isFalse);

    final firstKey = 'file:1760000001';
    final oldNote = analysis.results[TopicNote.slotKey(firstKey)]!;
    await analysis.editResult(
      TopicNote.slotKey(firstKey),
      oldNote,
      generalNote(topic.id, '用户修订的笔记').encode(),
    );
    expect(controller.isTopicSummaryStale(topic.id), isTrue);
    await store.closeTopic(topic.id);
    expect(controller.isTopicSummaryStale(topic.id), isFalse);
    await store.reopenTopic(topic.id);
    expect(controller.isTopicSummaryStale(topic.id), isTrue);

    await controller.generateTopicSummary(
      topic.id,
      retry: TopicSummaryRetry.overwrite,
    );
    expect(controller.isTopicSummaryStale(topic.id), isFalse);
    await store.moveRecording('file:1760000002', other.id);
    expect(controller.isTopicSummaryStale(topic.id), isTrue);
    expect(controller.topicSummaryInput(other.id).invalidKeys, [
      'file:1760000002',
    ]);
    await expectLater(
      controller.generateTopicSummary(other.id),
      throwsStateError,
    );
    await controller.generateTopicSummary(
      topic.id,
      retry: TopicSummaryRetry.overwrite,
    );
    expect(controller.isTopicSummaryStale(topic.id), isFalse);
    await store.moveRecording('file:1760000004', topic.id);
    analysis.results[TopicNote.slotKey('file:1760000004')] = noteResult(
      generalNote(topic.id, '新增笔记'),
    );
    expect(controller.isTopicSummaryStale(topic.id), isTrue);
  });

  test('长主题用 N 引用分段汇总；已保存片段在重启后继续复用', () async {
    final dir = await Directory.systemTemp.createTemp('topic-summary-resume-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/analysis.json');
    final topic = Topic(
      id: 'long',
      kind: TopicKind.general,
      title: '长期思考',
      createdAt: DateTime(2026, 10, 16),
    );
    final sources = [
      for (var i = 1; i <= 2; i++)
        TopicSummarySource(
          id: 'N$i',
          recordingKey: 'file:$i',
          title: '录音$i',
          recordedAt: DateTime(2026, 10, 16),
        ),
    ];
    final instruction = topicSummaryInstruction(topic);
    var calls = 0;
    final sent = <String>[];
    final service = _SummaryService((source, instruction) async {
      calls++;
      sent.add(source);
      if (instruction.contains('依据这些覆盖原文')) {
        expect(instruction, contains('保留笔记 [N数字]'));
        expect(source, contains('[N1]'));
        expect(source, contains('[N2]'));
        return jsonEncode({
          'thoughtTimeline': [
            {
              'text': '覆盖两条笔记',
              'sources': ['N1', 'N2'],
            },
          ],
          'currentConclusions': <Object>[],
          'openQuestions': <Object>[],
          'nextSteps': <Object>[],
        });
      }
      return '${source.contains('[N1]') ? '[N1]' : '[N2]'} 片段笔记';
    });
    var checkCount = 0;
    final first = RecordingAnalysis(file: file, service: service);
    await first.run(
      recording: 'topic:long',
      source: 'two notes',
      sourceBlocks: const ['[N1] 笔记一', '[N2] 笔记二'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: instruction,
      validateResult: validateTopicSummary(topic, sources),
      avoidDuplicateCharges: true,
      preserveInputCitations: true,
      currentSource: () => ++checkCount >= 2 ? 'changed' : 'two notes',
    );
    expect(calls, 1);
    expect(sent.single, startsWith('[N1]'));
    expect(first.results[TopicSummary.slotKey('long')], isNull);
    first.dispose();

    final resumed = RecordingAnalysis(file: file, service: service);
    addTearDown(resumed.dispose);
    resumed.clearUnconfirmedNode(TopicSummary.slotKey('long'));
    await resumed.run(
      recording: 'topic:long',
      source: 'two notes',
      sourceBlocks: const ['[N1] 笔记一', '[N2] 笔记二'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: instruction,
      validateResult: validateTopicSummary(topic, sources),
      avoidDuplicateCharges: true,
      preserveInputCitations: true,
      currentSource: () => 'two notes',
    );
    expect(calls, 3); // second chunk + merge; first chunk was not billed twice.
    final summary = TopicSummary.parse(
      resumed.results[TopicSummary.slotKey('long')]!.text,
    );
    expect(summary.sections['thoughtTimeline']!.single.sources, ['N1', 'N2']);
  });

  test('失败请求的结果未确认时，重启和普通重试都不再次调用模型', () async {
    final dir = await Directory.systemTemp.createTemp(
      'topic-summary-uncertain-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/analysis.json');
    var calls = 0;
    final service = _SummaryService((source, instruction) async {
      calls++;
      throw const HttpException('模拟回复丢失');
    });
    Future<void> run(RecordingAnalysis analysis) => analysis.run(
      recording: 'topic:uncertain',
      source: 'note snapshot',
      sourceBlocks: const ['[N1] note snapshot'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      avoidDuplicateCharges: true,
      currentSource: () => 'note snapshot',
    );
    final first = RecordingAnalysis(file: file, service: service);
    await run(first);
    expect(calls, 1);
    first.dispose();
    final restarted = RecordingAnalysis(file: file, service: service);
    addTearDown(restarted.dispose);
    await run(restarted);
    await run(restarted);
    expect(calls, 1);
    expect(
      restarted.errors[TopicSummary.slotKey('uncertain')],
      contains('不能自动重试'),
    );
    await restarted.run(
      recording: 'topic:uncertain',
      source: 'edited note snapshot',
      sourceBlocks: const ['[N1] edited note snapshot'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      avoidDuplicateCharges: true,
      currentSource: () => 'edited note snapshot',
    );
    expect(calls, 1);
    expect(
      restarted.errors[TopicSummary.slotKey('uncertain')],
      contains('旧检查点不能复用'),
    );
  });

  test('确认重试只补失败片段，已完成片段不再发送给模型', () async {
    final dir = await Directory.systemTemp.createTemp('topic-summary-retry-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/analysis.json');
    final sent = <String>[];
    final service = _SummaryService((source, instruction) async {
      sent.add(source);
      if (source.contains('[N2]')) throw const HttpException('第二段失败');
      return '[N1] 第一段笔记';
    });
    final topic = Topic(
      id: 'retry',
      kind: TopicKind.general,
      title: '重试',
      createdAt: DateTime(2026, 10, 17),
    );
    final retrySources = [
      for (var i = 1; i <= 2; i++)
        TopicSummarySource(
          id: 'N$i',
          recordingKey: 'file:$i',
          title: '录音$i',
          recordedAt: DateTime(2026, 10, 17),
        ),
    ];
    final first = RecordingAnalysis(file: file, service: service);
    await first.run(
      recording: 'topic:retry',
      source: 'two notes',
      sourceBlocks: const ['[N1] 第一段笔记', '[N2] 第二段笔记'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      validateResult: validateTopicSummary(topic, retrySources),
      avoidDuplicateCharges: true,
      preserveInputCitations: true,
      currentSource: () => 'two notes',
    );
    expect(sent, hasLength(2));
    expect(sent.first, startsWith('[N1]'));
    expect(sent.last, startsWith('[N2]'));
    expect(first.errors[TopicSummary.slotKey('retry')], contains('结果未确认'));

    final resumedSent = <String>[];
    final resumedService = _SummaryService((source, instruction) async {
      resumedSent.add(source);
      return jsonEncode({
        'thoughtTimeline': [
          {
            'text': '合并两条笔记',
            'sources': ['N1', 'N2'],
          },
        ],
        'currentConclusions': <Object>[],
        'openQuestions': <Object>[],
        'nextSteps': <Object>[],
      });
    });
    final resumed = RecordingAnalysis(file: file, service: resumedService);
    addTearDown(resumed.dispose);
    await resumed.load();
    expect(File(file.path).existsSync(), isTrue, reason: '失败前应先落盘检查点');
    final resumedSlot = TopicSummary.slotKey('retry');
    expect(resumed.hasPendingClaim(resumedSlot), isFalse);
    expect(resumed.busy(resumedSlot), isFalse);
    expect(resumed.hasCheckpoint(resumedSlot), isTrue);
    expect(resumed.hasUnconfirmedNode(resumedSlot), isTrue);
    expect(resumed.errors[resumedSlot], contains('结果未确认'));
    expect(resumed.errors[TopicSummary.slotKey('retry')], contains('结果未确认'));
    // The controller clears this guard only after the user confirms retry.
    resumed.clearUnconfirmedNode(resumedSlot);
    await resumed.run(
      recording: 'topic:retry',
      source: 'two notes',
      sourceBlocks: const ['[N1] 第一段笔记', '[N2] 第二段笔记'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      validateResult: validateTopicSummary(topic, retrySources),
      avoidDuplicateCharges: true,
      preserveInputCitations: true,
      currentSource: () => 'two notes',
    );
    expect(resumedSent, hasLength(2));
    expect(
      resumedSent.where((source) => source.startsWith('[N1]')),
      hasLength(1),
      reason: '合并节点复用已保存片段，但不重发原始 N1 请求',
    );
    expect(
      resumedSent.where((source) => source.startsWith('[N2]')),
      hasLength(1),
      reason: '只重发失败片段一次，合并节点复用它',
    );
    expect(
      resumedSent
          .where((source) => source.startsWith('[N1]'))
          .single
          .contains('{"thoughtTimeline"'),
      isTrue,
      reason: 'N1 只作为合并输入复用检查点',
    );
  });

  test('并发触发同一主题只执行一次模型任务', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(kind: TopicKind.general, title: '并发');
    final key = 'file:1760000201';
    await store.moveRecording(key, topic.id);
    final service = _SummaryService((source, instruction) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return _generalSummaryJson();
    });
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    analysis.results[TopicNote.slotKey(key)] = noteResult(
      generalNote(topic.id, '某个笔记'),
    );
    final RecorderController controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    await controller.settleTopicNoteWork();
    await Future.wait([
      controller.generateTopicSummary(topic.id),
      controller.generateTopicSummary(topic.id),
    ]);
    expect(service.calls, 1);
  });

  test('模型汇总只能引用存在的笔记；存储的来源指向录音键', () {
    final topic = Topic(
      id: 'book',
      kind: TopicKind.book,
      title: '虚构书',
      createdAt: DateTime(2026, 10, 16),
    );
    final sources = [
      TopicSummarySource(
        id: 'N1',
        recordingKey: 'file:1760000001',
        title: '录音一',
        recordedAt: DateTime(2026, 10, 16),
        page: 3,
      ),
    ];
    final valid = jsonEncode({
      for (final key in TopicSummary.sectionKeys(topic.kind))
        key: [
          {
            'text': '有依据的段落',
            'sources': ['N1'],
          },
        ],
    });
    final parsed = TopicSummary.parse(
      validateTopicSummary(topic, sources)(valid, const []),
    );
    expect(parsed.sources.single.recordingKey, 'file:1760000001');
    expect(parsed.sections['reviewDraft']!.single.sources, ['N1']);
    expect(
      () => validateTopicSummary(topic, sources)(
        valid.replaceAll('N1', 'N2'),
        const [],
      ),
      throwsFormatException,
    );
  });

  testWidgets('主题详情手动生成、覆盖确认与逐条编辑', (tester) async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '产品想法',
    );
    const key = 'file:1760000101';
    await store.moveRecording(key, topic.id);
    var calls = 0;
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: _SummaryService((source, instruction) async {
        calls++;
        return _generalSummaryJson();
      }),
    );
    analysis.results[TopicNote.slotKey(key)] = noteResult(
      generalNote(topic.id, '某个笔记'),
    );
    final RecorderController controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    await controller.settleTopicNoteWork();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: AppTheme.light,
          home: TopicDetailScreen(topicId: topic.id),
        ),
      ),
    );
    await tester.pump();
    expect(calls, 0);
    await tester.ensureVisible(
      find.byKey(const ValueKey('topic-summary-generate')),
    );
    await tester.tap(find.byKey(const ValueKey('topic-summary-generate')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('一条思路'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('编辑条目').first);
    await tester.tap(find.byTooltip('编辑条目').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('topic-summary-edit-text')),
      '用户修改的思路',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(find.text('用户修改的思路'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('topic-summary-generate')),
    );
    await tester.tap(find.byKey(const ValueKey('topic-summary-generate')));
    await tester.pumpAndSettle();
    expect(find.textContaining('覆盖当前汇总'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('用户修改的思路'), findsOneWidget);
  });
}

String _generalSummaryJson() => jsonEncode({
  'thoughtTimeline': [
    {
      'text': '一条思路',
      'sources': ['N1'],
    },
  ],
  'currentConclusions': <Object>[],
  'openQuestions': <Object>[],
  'nextSteps': <Object>[],
});

class _SummaryController extends RecorderController {
  _SummaryController({
    required super.topicStore,
    required super.analysisController,
  }) : super(
         loadPersistedState: false,
         topicsEnabled: true,
         fileJobJournal: FileJobJournal(inMemory: true),
       );

  @override
  String get analysisApiKey => 'synthetic-test-key';
}

class _SummaryService implements AnalysisService {
  _SummaryService(this.handler);
  final Future<String> Function(String source, String instruction) handler;
  int calls = 0;

  @override
  void dispose() {}

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    await Future<void>.delayed(Duration.zero);
    return handler(source, instruction);
  }
}
