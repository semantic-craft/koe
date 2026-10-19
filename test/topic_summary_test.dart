import 'dart:async';
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

  AnalysisResult noteResult(TopicNote note) {
    final template = builtInTemplateById(
      note.kind == TopicKind.book ? bookNoteTemplateId : thinkingNoteTemplateId,
    )!;
    return AnalysisResult(
      text: note.encode(),
      sourceHash: 'synthetic-note-hash',
      model: TopicNote.defaultModel,
      instruction: 'synthetic note',
      sources: const ['synthetic source block'],
      createdAt: DateTime(2026, 10, 16),
      templateId: template.id,
      templateVersion: template.version,
      templateFingerprint: template.fingerprint,
    );
  }

  AnalysisResult noteResultForSource(String source, TopicNote note) {
    final template = builtInTemplateById(
      note.kind == TopicKind.book ? bookNoteTemplateId : thinkingNoteTemplateId,
    )!;
    return AnalysisResult(
      text: note.encode(),
      sourceHash: analysisFingerprint(source),
      model: TopicNote.defaultModel,
      instruction: 'synthetic note',
      sources: [source],
      createdAt: DateTime(2026, 10, 16),
      templateId: template.id,
      templateVersion: template.version,
      templateFingerprint: template.fingerprint,
    );
  }

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

  test('控制器确认重试只重发失败片段，已完成片段不再发送给模型', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '确认重试',
    );
    final sent = <String>[];
    var failSecond = true;
    final service = _SummaryService((source, instruction) async {
      sent.add(source);
      if (source.startsWith('[N2]') && failSecond) {
        failSecond = false;
        throw const HttpException('第二段失败');
      }
      if (instruction.contains('依据这些覆盖原文')) {
        return _generalSummaryJson();
      }
      return source.startsWith('[N1]') ? '[N1] 第一段笔记' : '[N2] 第二段笔记';
    });
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    TopicNote longNote(String label) =>
        generalNote(topic.id, '$label ${'长' * 3000}');
    for (final key in ['file:1760000251', 'file:1760000252']) {
      await store.moveRecording(key, topic.id);
      analysis.results[TopicNote.slotKey(key)] = noteResult(longNote('笔记$key'));
    }
    final controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    await controller.settleTopicNoteWork();
    final slot = TopicSummary.slotKey(topic.id);

    await controller.generateTopicSummary(topic.id);
    expect(sent, hasLength(2), reason: '两个片段，第二段失败');
    expect(sent.first, startsWith('[N1]'));
    expect(sent.last, startsWith('[N2]'));
    expect(analysis.results[slot], isNull);
    expect(analysis.errors[slot], contains('结果未确认'));

    await controller.generateTopicSummary(
      topic.id,
      retry: TopicSummaryRetry.confirmedRetry,
    );
    expect(sent, hasLength(4), reason: '确认后只重发 N2 与合并节点');
    expect(sent[2], startsWith('[N2]'));
    expect(sent[3], contains('[N1] 第一段笔记'));
    expect(sent[3], contains('[N2] 第二段笔记'));
    expect(
      sent.take(3).where((source) => source.startsWith('[N1]')),
      hasLength(1),
      reason: '合并节点复用已保存片段，但不重发原始 N1 请求',
    );
    expect(
      sent.take(3).where((source) => source.startsWith('[N2]')),
      hasLength(2),
      reason: 'N2 首次失败后只重试一次，合并节点复用它',
    );
    expect(TopicSummary.tryParse(analysis.results[slot]!.text), isNotNull);
  });

  test('运行中撞上的确认重试不会清除第一条请求的未确认保护', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '保护标记',
    );
    final key = 'file:1760000261';
    await store.moveRecording(key, topic.id);
    final service = _GatedFailingSummaryService();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    analysis.results[TopicNote.slotKey(key)] = noteResult(
      generalNote(topic.id, '一条笔记'),
    );
    final RecorderController controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    await controller.settleTopicNoteWork();
    final slot = TopicSummary.slotKey(topic.id);

    final first = controller.generateTopicSummary(topic.id);
    await service.started.future;
    final collided = controller.generateTopicSummary(
      topic.id,
      retry: TopicSummaryRetry.confirmedRetry,
    );
    await collided;
    service.release.complete();
    await first;
    expect(analysis.busy(slot), isFalse);
    expect(analysis.errors[slot], contains('不能自动重试'));

    await controller.generateTopicSummary(topic.id);
    expect(service.calls, 1, reason: '第一条请求失败后普通重试仍须被拦截');
    expect(analysis.errors[slot], contains('不能自动重试'));
  });

  test('确认重试只重跑校验失败的合并节点，成功片段不重发', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '重试汇总',
    );
    final sent = <String>[];
    var mergeCalls = 0;
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: _SummaryService((source, instruction) async {
        sent.add(source);
        if (instruction.contains('依据这些覆盖原文')) {
          mergeCalls++;
          return mergeCalls == 1 ? '不是 JSON' : _generalSummaryJson();
        }
        return source.startsWith('[N1]') ? '[N1] 第一段笔记' : '[N2] 第二段笔记';
      }),
    );
    TopicNote longNote(String label) =>
        generalNote(topic.id, '$label ${'长' * 3000}');
    for (final key in ['file:1760000301', 'file:1760000302']) {
      await store.moveRecording(key, topic.id);
      analysis.results[TopicNote.slotKey(key)] = noteResult(longNote('笔记$key'));
    }
    final controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    await controller.settleTopicNoteWork();
    await controller.generateTopicSummary(topic.id);
    final slot = TopicSummary.slotKey(topic.id);
    expect(analysis.results[slot], isNull);
    expect(analysis.errors[slot], contains('校验失败'));
    expect(sent, hasLength(3), reason: '两段笔记加一次合并');

    await controller.generateTopicSummary(
      topic.id,
      retry: TopicSummaryRetry.confirmedRetry,
    );
    expect(sent, hasLength(4), reason: '确认后只重跑被拒的合并节点');
    expect(sent.last, contains('[N1] 第一段笔记'));
    expect(sent.last, contains('[N2] 第二段笔记'));
    expect(TopicSummary.tryParse(analysis.results[slot]!.text), isNotNull);
  });

  test('来源变化需明确重新开始，确认后使用新笔记并清除旧检查点', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '来源变化',
    );
    final keys = ['file:1760000311', 'file:1760000312'];
    final sent = <String>[];
    var failSecond = true;
    TopicNote longNote(String label) =>
        generalNote(topic.id, '$label ${'长' * 3000}');
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: _SummaryService((source, instruction) async {
        sent.add(source);
        if (source.startsWith('[N2]') && failSecond) {
          failSecond = false;
          throw const HttpException('第二段失败');
        }
        if (instruction.contains('依据这些覆盖原文')) {
          return _generalSummaryJson();
        }
        return source.startsWith('[N1]') ? '[N1] 一' : '[N2] 二';
      }),
    );
    for (final key in keys) {
      await store.moveRecording(key, topic.id);
      analysis.results[TopicNote.slotKey(key)] = noteResult(longNote('笔记$key'));
    }
    final controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    await controller.settleTopicNoteWork();
    await controller.generateTopicSummary(topic.id);
    final slot = TopicSummary.slotKey(topic.id);
    expect(analysis.results[slot], isNull);

    analysis.results[TopicNote.slotKey(keys.first)] = noteResult(
      longNote('变更后的笔记'),
    );
    await controller.generateTopicSummary(topic.id);
    expect(analysis.errors[slot], contains('旧检查点不能复用'));
    final callsBeforeConfirm = sent.length;
    expect(callsBeforeConfirm, 2);

    await controller.generateTopicSummary(
      topic.id,
      retry: TopicSummaryRetry.overwrite,
    );
    expect(sent.length, greaterThan(callsBeforeConfirm));
    expect(sent, anyElement(contains('变更后的笔记')));
    expect(TopicSummary.tryParse(analysis.results[slot]!.text), isNotNull);
  });

  test('并发触发同一主题只执行一次模型任务', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(kind: TopicKind.general, title: '并发');
    final key = 'file:1760000201';
    await store.moveRecording(key, topic.id);
    final service = _SummaryService((source, instruction) async {
      return _generalSummaryJson();
    });
    final analysis = _RunLoadGatedAnalysis(service: service);
    analysis.results[TopicNote.slotKey(key)] = noteResult(
      generalNote(topic.id, '某个笔记'),
    );
    final RecorderController controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    await controller.settleTopicNoteWork();
    analysis.arm(skip: 1);
    final first = controller.generateTopicSummary(topic.id);
    await analysis.runLoadStarted.future;
    final second = controller.generateTopicSummary(topic.id);
    await second;
    expect(service.calls, 0, reason: '首个请求仍在加载，第二次触发必须被拒绝');
    analysis.releaseRunLoad.complete();
    await first;
    expect(service.calls, 1);
  });

  test('加载阶段第二次 run 不进入模型请求', () async {
    final service = _SummaryService((source, instruction) async => '结果');
    final analysis = _LoadGatedAnalysis(service: service);
    addTearDown(analysis.dispose);
    Future<void> run() => analysis.run(
      recording: 'topic:loading',
      source: 'note snapshot',
      sourceBlocks: const ['[N1] note snapshot'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      currentSource: () => 'note snapshot',
    );

    final first = run();
    await analysis.loadStarted.future;
    final second = run();
    await pumpEventQueue();
    expect(service.calls, 0, reason: '首个请求仍在加载，第二次触发必须被拒绝');
    await second;
    analysis.releaseLoad.complete();
    await first;
    expect(service.calls, 1);
  });

  test('模型请求阶段第二次 run 不重复调用', () async {
    final service = _GatedSummaryService();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    addTearDown(analysis.dispose);
    Future<void> run() => analysis.run(
      recording: 'topic:request',
      source: 'note snapshot',
      sourceBlocks: const ['[N1] note snapshot'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      currentSource: () => 'note snapshot',
    );

    final first = run();
    await service.started.future;
    final second = run();
    await pumpEventQueue();
    expect(service.calls, 1, reason: '请求进行中不得再次调用模型');
    service.release.complete();
    await Future.wait([first, second]);
    expect(service.calls, 1);
  });

  test('首次保存任务状态失败后释放忙碌并允许重试', () async {
    final dir = await Directory.systemTemp.createTemp('analysis-save-fail-');
    addTearDown(() => dir.delete(recursive: true));
    final blocker = File('${dir.path}/blocked');
    await blocker.writeAsString('not a directory');
    final service = _SummaryService((source, instruction) async => '结果');
    final analysis = RecordingAnalysis(
      file: File('${blocker.path}/analysis.json'),
      service: service,
    );
    addTearDown(analysis.dispose);
    Future<void> run() => analysis.run(
      recording: 'topic:save-fail',
      source: 'note snapshot',
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      avoidDuplicateCharges: true,
      currentSource: () => 'note snapshot',
    );

    await run();
    final slot = TopicSummary.slotKey('save-fail');
    expect(analysis.busy(slot), isFalse);
    expect(analysis.errors[slot], contains('无法保存任务状态'));
    expect(service.calls, 0);

    await blocker.delete();
    await Directory(blocker.path).create();
    await run();
    expect(analysis.busy(slot), isFalse);
    expect(analysis.results[slot], isNotNull);
    expect(service.calls, 1);
  });

  test('恢复检查点时保存失败会释放占位并保留保护标记', () async {
    final root = await Directory.systemTemp.createTemp(
      'analysis-recovery-save-',
    );
    addTearDown(() => root.delete(recursive: true));
    final dir = Directory('${root.path}/data');
    await dir.create();
    final file = File('${dir.path}/analysis.json');
    final slot = TopicSummary.slotKey('recovery-save');
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'model': 'qwen3.8-flash',
        'results': <String, Object>{},
        'customInstructions': <String, Object>{},
        'customTemplates': <Object>[],
        'checkpoints': {
          slot: {'final': '恢复的结果'},
        },
        'jobHashes': <String, Object>{},
        'unconfirmedNodes': {slot: 'final'},
        'pending': <String>[],
        'errors': <String, Object>{},
      }),
    );
    final service = _SummaryService((source, instruction) async => '新结果');
    final analysis = RecordingAnalysis(file: file, service: service);
    addTearDown(analysis.dispose);
    await analysis.load();
    await file.delete();
    await dir.delete();
    await File(dir.path).writeAsString('not a directory');
    Future<void> run() => analysis.run(
      recording: 'topic:recovery-save',
      source: 'note snapshot',
      sourceBlocks: const ['[N1] note snapshot'],
      apiKey: 'synthetic-test-key',
      custom: true,
      resultSlot: TopicSummary.slot,
      instruction: 'synthetic instruction',
      avoidDuplicateCharges: true,
      currentSource: () => 'note snapshot',
    );

    await expectLater(run(), throwsA(isA<FileSystemException>()));
    expect(analysis.busy(slot), isFalse, reason: '保存失败后必须释放占位');
    expect(
      analysis.hasUnconfirmedNode(slot),
      isTrue,
      reason: '恢复失败不得丢失未确认保护标记',
    );
    expect(analysis.results[slot], isNull);
    expect(service.calls, 0);

    await File(dir.path).delete();
    await dir.create();
    await run();
    expect(analysis.busy(slot), isFalse);
    expect(analysis.hasUnconfirmedNode(slot), isFalse);
    expect(analysis.results[slot]?.text, '恢复的结果');
    expect(service.calls, 0);
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

  testWidgets('加载期立即显示忙碌并隐藏生成按钮', (tester) async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '加载反馈',
    );
    const key = 'file:1760000401';
    await store.moveRecording(key, topic.id);
    final analysis = _RunLoadGatedAnalysis(
      service: _SummaryService((source, instruction) async {
        return _generalSummaryJson();
      }),
    );
    analysis.results[TopicNote.slotKey(key)] = noteResult(
      generalNote(topic.id, '一条笔记'),
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
    final generate = find.byKey(const ValueKey('topic-summary-generate'));
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
    analysis.arm(skip: 1);
    await tester.tap(generate);
    await tester.pump();
    await analysis.runLoadStarted.future;
    await tester.pump();
    expect(analysis.busy(TopicSummary.slotKey(topic.id)), isTrue);
    expect(generate, findsNothing, reason: '加载期不得再显示生成按钮');
    expect(find.text('正在生成…'), findsOneWidget);
    analysis.releaseRunLoad.complete();
    await tester.pumpAndSettle();
    expect(find.text('一条思路'), findsOneWidget);
  });

  testWidgets('控制器预加载期立即显示忙碌并隐藏生成按钮', (tester) async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '预加载反馈',
    );
    const key = 'file:1760000402';
    await store.moveRecording(key, topic.id);
    final analysis = _RunLoadGatedAnalysis(
      service: _SummaryService((source, instruction) async {
        return _generalSummaryJson();
      }),
    );
    analysis.results[TopicNote.slotKey(key)] = noteResult(
      generalNote(topic.id, '一条笔记'),
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
    final generate = find.byKey(const ValueKey('topic-summary-generate'));
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
    analysis.arm(skip: 0);
    await tester.tap(generate);
    await tester.pump();
    await analysis.runLoadStarted.future;
    await tester.pump();
    expect(
      analysis.busy(TopicSummary.slotKey(topic.id)),
      isTrue,
      reason: '控制器预加载期间也必须显示忙碌',
    );
    expect(generate, findsNothing, reason: '预加载期不得再显示生成按钮');
    expect(find.text('正在生成…'), findsOneWidget);
    analysis.releaseRunLoad.complete();
    await tester.pumpAndSettle();
    expect(find.text('一条思路'), findsOneWidget);
  });

  testWidgets('转写变化使笔记过期时禁止生成汇总，重生成笔记后恢复', (tester) async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '过期笔记',
    );
    const path = '/tmp/koe-stale-note-source.wav';
    const key = 'path:$path';
    await store.moveRecording(key, topic.id);
    var calls = 0;
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: _SummaryService((source, instruction) async {
        calls++;
        return _generalSummaryJson();
      }),
    );
    final RecorderController controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    controller.transcriptsByPath[path] = '旧转写';
    analysis.results[TopicNote.slotKey(key)] = noteResultForSource(
      '旧转写',
      generalNote(topic.id, '旧笔记'),
    );
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
    final generate = find.byKey(const ValueKey('topic-summary-generate'));
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);

    controller.transcriptsByPath[path] = '新转写';
    analysis.notifyListeners();
    await tester.pump();
    expect(find.textContaining('请先打开对应录音重新生成笔记'), findsOneWidget);
    expect(tester.widget<FilledButton>(generate).onPressed, isNull);
    expect(calls, 0);

    analysis.results[TopicNote.slotKey(key)] = noteResultForSource(
      '新转写',
      generalNote(topic.id, '更新后的笔记'),
    );
    analysis.notifyListeners();
    await tester.pump();
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('一条思路'), findsOneWidget);
  });

  test('音频版本变化使笔记过期时阻止汇总请求', () async {
    final dir = await Directory.systemTemp.createTemp('stale-audio-');
    addTearDown(() => dir.delete(recursive: true));
    final audio = File('${dir.path}/note.wav');
    await audio.writeAsBytes([1, 2, 3, 4]);
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '音频过期',
    );
    final key = 'path:${audio.path}';
    await store.moveRecording(key, topic.id);
    var calls = 0;
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: _SummaryService((source, instruction) async {
        calls++;
        return _generalSummaryJson();
      }),
    );
    final controller = _SummaryController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    controller.transcriptsByPath[audio.path] = '转写';
    analysis.results[TopicNote.slotKey(key)] = noteResultForSource(
      '转写',
      TopicNote(
        kind: TopicKind.general,
        topicId: topic.id,
        overview: '音频变化前的笔记',
        audioSignature: 'stale-audio-version',
        ideas: const [
          TopicIdea(text: '想法', reason: '理由', sources: ['S1']),
        ],
      ),
    );
    await controller.settleTopicNoteWork();
    expect(controller.topicSummaryInput(topic.id).invalidKeys, isEmpty);
    await controller.refreshCachedAudioVersion(
      RecordingReference(path: audio.path),
      force: true,
    );
    expect(controller.topicSummaryInput(topic.id).invalidKeys, [key]);
    await expectLater(
      controller.generateTopicSummary(topic.id),
      throwsStateError,
    );
    expect(calls, 0);
  });

  testWidgets('导入录音的读书笔记尚无汇总时，书籍主题页显示可汇总与生成按钮', (tester) async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.book,
      title: '验收书',
      author: '验收',
    );
    // Imported originals use a microsecond timestamp as their file id.
    const key = 'file:1760850000123456';
    await store.moveRecording(key, topic.id);
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: _SummaryService((source, instruction) async => '{}'),
    );
    analysis.results[TopicNote.slotKey(key)] = noteResult(
      TopicNote(
        kind: TopicKind.book,
        topicId: topic.id,
        overview: '读书概要',
        excerpts: const [
          TopicExcerpt(text: '摘录', page: 'p.12', sources: ['S1']),
        ],
      ),
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
    expect(find.text('已有 1 条笔记可汇总'), findsOneWidget);
    final generate = find.byKey(const ValueKey('topic-summary-generate'));
    expect(tester.widget<FilledButton>(generate).onPressed, isNotNull);
    expect(find.text('添加录音'), findsOneWidget);
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

class _GatedSummaryService implements AnalysisService {
  final started = Completer<void>();
  final release = Completer<void>();
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
    if (!started.isCompleted) started.complete();
    await release.future;
    return _generalSummaryJson();
  }
}

class _GatedFailingSummaryService implements AnalysisService {
  final started = Completer<void>();
  final release = Completer<void>();
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
    if (!started.isCompleted) started.complete();
    await release.future;
    throw const HttpException('模拟回复丢失');
  }
}

class _LoadGatedAnalysis extends RecordingAnalysis {
  _LoadGatedAnalysis({super.service}) : super(inMemory: true);

  final loadStarted = Completer<void>();
  final releaseLoad = Completer<void>();
  bool _blocked = false;

  @override
  Future<void> load() async {
    if (!_blocked) {
      _blocked = true;
      loadStarted.complete();
      await releaseLoad.future;
    }
    await super.load();
  }
}

class _RunLoadGatedAnalysis extends RecordingAnalysis {
  _RunLoadGatedAnalysis({super.service}) : super(inMemory: true);

  final runLoadStarted = Completer<void>();
  final releaseRunLoad = Completer<void>();
  bool _armed = false;
  int _skip = 0;

  void arm({required int skip}) {
    _armed = true;
    _skip = skip;
  }

  @override
  Future<void> load() async {
    if (_armed) {
      if (_skip > 0) {
        _skip--;
      } else {
        _armed = false;
        if (!runLoadStarted.isCompleted) runLoadStarted.complete();
        await releaseRunLoad.future;
      }
    }
    await super.load();
  }
}
