import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/audio/audio_version.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/widgets/topic_note_panel.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('一本书模板解析摘录（含口述页码）、配对/独立评论、疑问、联想、待查并校验原文引用与段落定位', () {
    final bookTopic = Topic(
      id: 'topic-book-1',
      title: '《思考，快与慢》',
      author: '丹尼尔·卡尼曼',
      kind: TopicKind.book,
      createdAt: DateTime(2026, 4, 20),
    );
    final instruction = topicNoteInstruction(bookTopic);
    expect(instruction, contains('《思考，快与慢》'));
    expect(instruction, contains('excerpts'));
    expect(instruction, contains('page'));

    final raw = jsonEncode({
      'overview': '梳理系统1与系统2的分工及锚定效应。',
      'excerpts': [
        {
          'text': '系统1的运行是无意识且快速的，不怎么费脑力。',
          'page': '第24页',
          'sources': ['S1'],
        },
        {
          'text': '锚定效应会在人们做数量估计时悄悄拉偏起点。',
          'sources': ['S2'],
        },
      ],
      'comments': [
        {
          'text': '日常开会拍脑袋定价很容易掉进这个坑。',
          'excerpt': '锚定效应会在人们做数量估计时悄悄拉偏起点。',
          'sources': ['S2'],
        },
        {
          'text': '全书前半部分例子很扎实，适合做团队内部分享。',
          'sources': ['S1', 'S2'],
        },
      ],
      'questions': [
        {
          'text': '团队评审时怎么设计流程来规避第一报价锚定？',
          'sources': ['S2'],
        },
      ],
      'associations': [
        {
          'text': '联想到上季度预算讨论里先报高价再砍价的场景。',
          'sources': ['S2'],
        },
      ],
      'toCheck': [
        {
          'text': '查一下卡尼曼关于锚定效应原始实验的样本量。',
          'sources': ['S2'],
        },
      ],
    });

    final validated = validateTopicNote(bookTopic)(raw, const ['p1', 'p2']);
    final note = TopicNote.parse(validated, 2);
    expect(note.kind, TopicKind.book);
    expect(note.topicId, 'topic-book-1');
    expect(note.overview, '梳理系统1与系统2的分工及锚定效应。');
    expect(note.excerpts, hasLength(2));
    expect(note.excerpts.first.page, '第24页');
    expect(note.excerpts.first.sources, ['S1']);
    expect(note.excerpts.last.page, isNull);
    expect(note.comments, hasLength(2));
    expect(note.comments.first.excerpt, '锚定效应会在人们做数量估计时悄悄拉偏起点。');
    expect(note.comments.last.excerpt, isNull);
    expect(note.questions.single.text, contains('规避第一报价锚定'));
    expect(note.associations.single.text, contains('上季度预算讨论'));
    expect(note.toCheck.single.text, contains('原始实验的样本量'));

    final exported = note.export(
      AnalysisResult(
        text: validated,
        sourceHash: 'h',
        model: 'qwen3.8-flash',
        instruction: instruction,
        sources: const ['p1', 'p2'],
        createdAt: DateTime(2026, 4, 20),
      ),
      topic: bookTopic,
    );
    expect(exported, contains('《思考，快与慢》'));
    expect(exported, contains('第24页'));
    expect(exported, contains('[S2]'));

    expect(
      () => TopicNote.parse(
        jsonEncode({
          'overview': '越界引用',
          'excerpts': [
            {
              'text': '某段摘录',
              'sources': ['S3'],
            },
          ],
        }),
        2,
        fallbackKind: TopicKind.book,
        fallbackTopicId: 'topic-book-1',
      ),
      throwsFormatException,
    );

    const transcript =
        '第一段：第24页提到系统1的运行是无意识且快速的。\n\n'
        '第二段：后面讲到锚定效应会在人们做数量估计时悄悄拉偏起点，我觉得开会定价常掉进这个坑。\n\n'
        '第三段：最后记一下待查卡尼曼原始实验。';
    final paragraphs = splitTranscriptParagraphs(transcript);
    expect(paragraphs, hasLength(3));
    final paragraphIndex = locateTranscriptParagraph(transcript, const [
      'S2',
    ], itemText: '锚定效应会在人们做数量估计时悄悄拉偏起点。');
    expect(paragraphIndex, 1);
  });

  test('定位不到原文时返回 null，不回退到第一段或首个候选', () {
    expect(
      locateTranscriptParagraph('第一段无关内容。\n\n第二段也无关。', const [
        'S1',
      ], itemText: '完全不存在的句子xyz'),
      isNull,
    );
    expect(
      locateTranscriptParagraph(
        '第一段无关内容。\n\n第二段也无关。',
        const ['S1'],
        itemText: '完全不存在的句子xyz',
        sourceBlocks: const ['第一段无关内容。'],
      ),
      isNull,
    );
  });

  test('解析模型输出时主题编号和音频版本只用调用方传入的值', () {
    const raw = '''
{
  "topicId": "model-topic",
  "audioSignature": "model-sig",
  "overview": "调用方才是这份笔记的主题。",
  "ideas": [
    {"text": "想法", "reason": "理由", "sources": ["S1"]}
  ],
  "changes": [],
  "questions": [],
  "associations": [],
  "todos": []
}''';
    final note = TopicNote.parse(
      raw,
      1,
      fallbackKind: TopicKind.general,
      forcedTopicId: 'caller-topic',
      forcedAudioSignature: 'caller-sig',
      forceAudioSignature: true,
    );
    expect(note.topicId, 'caller-topic');
    expect(note.audioSignature, 'caller-sig');

    final cleared = TopicNote.parse(
      raw,
      1,
      fallbackKind: TopicKind.general,
      forcedTopicId: 'caller-topic',
      forcedAudioSignature: null,
      forceAudioSignature: true,
    );
    expect(cleared.topicId, 'caller-topic');
    expect(cleared.audioSignature, isNull);

    final stored = TopicNote.parse(note.encode(), 1);
    expect(stored.topicId, 'caller-topic');
    expect(stored.audioSignature, 'caller-sig');
  });

  test('读取已存笔记时 fallbackTopicId 不覆盖 JSON 里的主题编号', () {
    final stored = jsonEncode({
      'kind': 'general',
      'topicId': 'topic-old',
      'audioSignature': 'sig-old',
      'overview': '迁移前写下的概要',
      'ideas': [
        {
          'text': '旧想法',
          'reason': '旧理由',
          'sources': ['S1'],
        },
      ],
    });

    final parsed = TopicNote.parse(
      stored,
      1,
      fallbackKind: TopicKind.general,
      fallbackTopicId: 'topic-new',
    );
    expect(parsed.topicId, 'topic-old');
    expect(parsed.audioSignature, 'sig-old');
  });

  test('一般主题模板解析主要想法、与此前笔记的变化、疑问、联想、待办与仅明确表达的结论', () {
    final generalTopic = Topic(
      id: 'topic-gen-1',
      title: '产品定价策略',
      kind: TopicKind.general,
      createdAt: DateTime(2026, 4, 20),
    );

    final firstRaw = jsonEncode({
      'overview': '初次梳理订阅制与买断制的取舍。',
      'ideas': [
        {
          'text': '优先采用按年订阅制',
          'reason': '持续提供云端转写与摘要服务，有固定边际成本',
          'sources': ['S1'],
        },
      ],
      'changes': [
        {
          'text': '首条笔记不应保留虚构的变化',
          'sources': ['S1'],
        },
      ],
      'questions': [
        {
          'text': '老用户迁移要不要给首年折扣？',
          'sources': ['S1'],
        },
      ],
      'associations': [
        {
          'text': '参考同类效率工具的双档位设计。',
          'sources': ['S1'],
        },
      ],
      'todos': [
        {
          'text': '测算月均调用成本与免费额度上限',
          'sources': ['S1'],
        },
      ],
    });

    final firstValidated = validateTopicNote(
      generalTopic,
      hasPriorNotes: false,
    )(firstRaw, const ['s1']);
    final firstNote = TopicNote.parse(firstValidated, 1);
    expect(firstNote.kind, TopicKind.general);
    expect(firstNote.ideas.single.text, '优先采用按年订阅制');
    expect(firstNote.ideas.single.reason, contains('固定边际成本'));
    expect(firstNote.changes, isEmpty);
    expect(firstNote.conclusion, isNull);

    final secondInstruction = topicNoteInstruction(
      generalTopic,
      priorNotes: [firstNote],
    );
    expect(secondInstruction, contains('初次梳理订阅制与买断制的取舍'));
    expect(secondInstruction, contains('优先采用按年订阅制'));

    final secondRaw = jsonEncode({
      'overview': '补充免费试用与年付锚定方案。',
      'ideas': [
        {
          'text': '提供 14 天全功能试用后转年付',
          'reason': '降低首次付费门槛并保留年付现金流',
          'sources': ['S1'],
        },
      ],
      'changes': [
        {
          'text': '从单纯讨论年付改为“14天试用 + 年付”组合',
          'sources': ['S1'],
        },
      ],
      'questions': [],
      'associations': [],
      'todos': [
        {
          'text': '上线试用倒计时提示',
          'sources': ['S1'],
        },
      ],
      'conclusion': {
        'text': '确定首版采用 14 天试用加按年订阅方案。',
        'sources': ['S1'],
      },
    });

    final secondValidated = validateTopicNote(
      generalTopic,
      hasPriorNotes: true,
    )(secondRaw, const ['s1']);
    final secondNote = TopicNote.parse(secondValidated, 1);
    expect(secondNote.changes.single.text, contains('14天试用 + 年付'));
    expect(secondNote.conclusion?.text, '确定首版采用 14 天试用加按年订阅方案。');
    expect(secondNote.conclusion?.sources, ['S1']);
  });

  test('归到主题且转写完成后自动用 qwen3.8-flash 生成一次笔记；待归类、未归类及主题间移动不自动触发', () async {
    final dir = await Directory.systemTemp.createTemp('koe-topic-notes-auto-');
    addTearDown(() => dir.delete(recursive: true));
    final fileA = File('${dir.path}/1760001001.wav')
      ..writeAsBytesSync(wavBytes([1, 2, 3, 4]));
    final fileB = File('${dir.path}/1760001002.wav')
      ..writeAsBytesSync(wavBytes([5, 6, 7, 8]));
    final fileC = File('${dir.path}/1760001003.wav')
      ..writeAsBytesSync(wavBytes([9, 10, 11, 12]));

    final calls = <({String model, String instruction, String source})>[];
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      calls.add((model: model, instruction: instruction, source: source));
      if (instruction.contains('《思考，快与慢》')) {
        return jsonEncode({
          'overview': '读书笔记自动生成',
          'excerpts': [
            {
              'text': '第18页讲到直觉偏差。',
              'page': '第18页',
              'sources': ['S1'],
            },
          ],
          'comments': [],
          'questions': [],
          'associations': [],
          'toCheck': [],
        });
      }
      return jsonEncode({
        'overview': '一般主题笔记自动生成',
        'ideas': [
          {
            'text': '核心观点A',
            'reason': '理由A',
            'sources': ['S1'],
          },
        ],
        'changes': [],
        'questions': [],
        'associations': [],
        'todos': [],
      });
    });

    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: store,
      analysisController: analysis,
      fileJobJournal: FileJobJournal(inMemory: true),
      retrievedAudioSettleTime: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.setQwenConfig(const EngineConfig(apiKey: 'sk-test'));

    final bookTopic = await store.createTopic(
      title: '《思考，快与慢》',
      kind: TopicKind.book,
    );
    final generalTopic = await store.createTopic(
      title: '产品思考',
      kind: TopicKind.general,
    );

    final refA = RecordingReference(fileId: 1760001001, path: fileA.path);
    final refB = RecordingReference(fileId: 1760001002, path: fileB.path);
    final refC = RecordingReference(fileId: 1760001003, path: fileC.path);
    final keyA = controller.analysisKey(refA);
    final keyB = controller.analysisKey(refB);
    final keyC = controller.analysisKey(refC);

    // 1. 待归类录音完成转写：不自动触发
    await store.placeRetrieved(keyB);
    expect(store.isPending(keyB), isTrue);
    controller.rememberTranscript(fileB.path, '待归类录音的转写内容，讨论产品核心观点A与理由A。');
    await controller.settleTopicNoteWork();
    expect(calls, isEmpty);

    // 2. 不归主题录音完成转写：不自动触发
    await store.removeFromTopic(keyC);
    controller.rememberTranscript(fileC.path, '不归主题的普通录音转写。');
    await controller.settleTopicNoteWork();
    expect(calls, isEmpty);

    // 3. 已归入主题的录音完成转写：自动用 qwen3.8-flash 生成一次笔记
    await store.moveRecording(keyA, bookTopic.id);
    controller.rememberTranscript(fileA.path, '今天读到第18页讲到直觉偏差。');
    await controller.settleTopicNoteWork();
    expect(calls, hasLength(1));
    expect(calls.single.model, 'qwen3.8-flash');
    final noteResultA = analysis.results[TopicNote.slotKey(keyA)];
    expect(noteResultA, isNotNull);
    final parsedA = TopicNote.parse(noteResultA!.text, 1);
    expect(parsedA.kind, TopicKind.book);
    expect(parsedA.excerpts.single.page, '第18页');
    expect(controller.isTopicNoteStale(refA), isFalse);

    // 4. 待归类且已有转写的录音被归入主题：自动触发一次生成
    await store.moveRecording(keyB, generalTopic.id);
    await controller.settleTopicNoteWork();
    expect(calls, hasLength(2));
    final noteResultB = analysis.results[TopicNote.slotKey(keyB)];
    expect(noteResultB, isNotNull);
    expect(TopicNote.parse(noteResultB!.text, 1).kind, TopicKind.general);

    // 5. 从主题 A 移到主题 B：只标过期，不自动重跑计费
    await store.moveRecording(keyA, generalTopic.id);
    await controller.settleTopicNoteWork();
    expect(calls, hasLength(2));
    expect(controller.isTopicNoteStale(refA), isTrue);
  });

  test('重复完成通知、重启恢复、长转写分段断点续跑与音频变更后不重复计费', () async {
    final dir = await Directory.systemTemp.createTemp('koe-topic-notes-dedup-');
    addTearDown(() => dir.delete(recursive: true));
    final audioFile = File('${dir.path}/1760002001.wav')
      ..writeAsBytesSync(wavBytes([1, 2, 3, 4]));
    final topicsFile = File('${dir.path}/topics.json');
    final analysisFile = File('${dir.path}/analysis.json');
    final ref = RecordingReference(fileId: 1760002001, path: audioFile.path);

    var calls = 0;
    var failChunk2 = false;
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      calls++;
      if (failChunk2 && source.startsWith('[S2] ')) {
        throw const HttpException('网络波动');
      }
      return jsonEncode({
        'overview': '第 $calls 次调用结果',
        'ideas': [
          {
            'text': '想法 $calls',
            'reason': '理由 $calls',
            'sources': ['S1'],
          },
        ],
        'changes': [],
        'questions': [],
        'associations': [],
        'todos': [],
      });
    });

    final store = TopicStore(
      file: topicsFile,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(file: analysisFile, service: service);
    final controller = RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: store,
      analysisController: analysis,
      fileJobJournal: FileJobJournal(inMemory: true),
      retrievedAudioSettleTime: Duration.zero,
    );
    await controller.setQwenConfig(const EngineConfig(apiKey: 'sk-test'));

    final key = controller.analysisKey(ref);
    final topic = await store.createTopic(
      title: '长期研究',
      kind: TopicKind.general,
    );
    await store.moveRecording(key, topic.id);
    controller.rememberTranscript(audioFile.path, '第一版研究录音转写内容。');
    await controller.settleTopicNoteWork();
    expect(calls, 1);

    // 重复收到相同转写完成通知或再次 assign 同一主题：不重复计费
    controller.rememberTranscript(audioFile.path, '第一版研究录音转写内容。');
    await store.moveRecording(key, topic.id);
    await controller.settleTopicNoteWork();
    expect(calls, 1);

    // 模拟应用重启恢复：已有最新笔记时启动不重跑
    controller.dispose();
    final storeRestarted = TopicStore(
      file: topicsFile,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await storeRestarted.load();
    final analysisRestarted = RecordingAnalysis(
      file: analysisFile,
      service: service,
    );
    await analysisRestarted.load();
    final controllerRestarted = RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: storeRestarted,
      analysisController: analysisRestarted,
      fileJobJournal: FileJobJournal(inMemory: true),
      retrievedAudioSettleTime: Duration.zero,
    );
    addTearDown(controllerRestarted.dispose);
    await controllerRestarted.setQwenConfig(
      const EngineConfig(apiKey: 'sk-test'),
    );
    controllerRestarted.rememberTranscript(audioFile.path, '第一版研究录音转写内容。');
    await controllerRestarted.settleTopicNoteWork();
    expect(calls, 1);

    // 录音音频变化后：仅标过期，不自动重跑
    audioFile.writeAsBytesSync(wavBytes([1, 2, 3, 4, 5, 6, 7, 8, 9]));
    await controllerRestarted.refreshCachedAudioVersion(ref, force: true);
    expect(controllerRestarted.isTopicNoteStale(ref), isTrue);
    await controllerRestarted.settleTopicNoteWork();
    expect(calls, 1);

    // 长转写分段断点续跑：第 2 段失败后重试复用第 1 段结果
    final longText =
        '${List.filled(350, '甲段内容讨论研究假设。').join()}\n\n'
        '${List.filled(350, '乙段内容讨论验证路径。').join()}';
    failChunk2 = true;
    controllerRestarted.rememberTranscript(audioFile.path, longText);
    await controllerRestarted.settleTopicNoteWork();
    // chunk 1 成功 (calls=2)，chunk 2 失败 (calls=3)
    expect(calls, 3);
    expect(analysisRestarted.errors[TopicNote.slotKey(key)], isNotNull);

    failChunk2 = false;
    await controllerRestarted.generateTopicNote(ref);
    // 仅重跑 chunk 2 (calls=4) + merge (calls=5)，不重跑 chunk 1
    expect(calls, 5);
    expect(analysisRestarted.errors[TopicNote.slotKey(key)], isNull);
  });

  test('启动时加载已有主题归属不会把迁移笔记或尚无笔记的录音重新生成', () async {
    final dir = await Directory.systemTemp.createTemp('koe-topic-notes-cold-');
    addTearDown(() => dir.delete(recursive: true));
    final topicsFile = File('${dir.path}/topics.json');
    const migratedId = 1760004101;
    const plainId = 1760004102;
    const migratedKey = 'file:$migratedId';
    const plainKey = 'file:$plainId';
    const textMigrated = '迁移前已经归入旧主题的录音转写。';
    const textPlain = '已经归入主题但还没有笔记的录音转写。';

    final bootstrap = TopicStore(
      file: topicsFile,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await bootstrap.load();
    final oldTopic = await bootstrap.createTopic(
      title: '旧主题',
      kind: TopicKind.general,
    );
    final newTopic = await bootstrap.createTopic(
      title: '新主题',
      kind: TopicKind.general,
    );
    final plainTopic = await bootstrap.createTopic(
      title: '已归主题',
      kind: TopicKind.general,
    );
    await bootstrap.moveRecording(migratedKey, oldTopic.id);
    await bootstrap.moveRecording(migratedKey, newTopic.id);
    await bootstrap.moveRecording(plainKey, plainTopic.id);
    bootstrap.dispose();

    var calls = 0;
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      calls++;
      return _generalNoteJson('不应在启动时生成');
    });
    final migratedNote = TopicNote(
      kind: TopicKind.general,
      topicId: oldTopic.id,
      overview: '迁移前写下的笔记',
      ideas: const [
        TopicIdea(text: '旧想法', reason: '旧理由', sources: ['S1']),
      ],
    );
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    analysis.results[TopicNote.slotKey(migratedKey)] = AnalysisResult(
      text: migratedNote.encode(),
      sourceHash: analysisFingerprint(textMigrated),
      model: TopicNote.defaultModel,
      instruction: '已保存',
      sources: const ['s1'],
      createdAt: DateTime(2026, 10, 16),
    );

    final coldStore = TopicStore(
      file: topicsFile,
      now: () => DateTime(2026, 10, 16, 10),
    );
    final controller = _InMemoryUiController(
      topicStore: coldStore,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    controller.transcriptsByFileId[migratedId] = textMigrated;
    controller.transcriptsByFileId[plainId] = textPlain;
    await controller.settleTopicNoteWork();
    expect(calls, 0);
    expect(
      TopicNote.parse(
        analysis.results[TopicNote.slotKey(migratedKey)]!.text,
        1,
      ).topicId,
      oldTopic.id,
    );
    expect(analysis.results[TopicNote.slotKey(plainKey)], isNull);
  });

  test('生成主题笔记时写入的音频版本等于 audioVersion', () async {
    final dir = await Directory.systemTemp.createTemp('koe-topic-notes-ver-');
    addTearDown(() => dir.delete(recursive: true));
    final audioFile = File('${dir.path}/1760004201.wav')
      ..writeAsBytesSync(wavBytes([1, 2, 3, 4]));
    final ref = RecordingReference(fileId: 1760004201, path: audioFile.path);
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      return _generalNoteJson('带音频版本的笔记');
    });
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = _InMemoryUiController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    final topic = await store.createTopic(title: '版本', kind: TopicKind.general);
    await store.moveRecording(controller.analysisKey(ref), topic.id);
    controller.rememberTranscript(audioFile.path, '这段转写用来生成带音频版本的笔记。');
    await controller.settleTopicNoteWork();
    final parsed = TopicNote.parse(
      analysis.results[TopicNote.slotKey(controller.analysisKey(ref))]!.text,
      1,
    );
    expect(parsed.audioSignature, await audioVersion(audioFile.path));
  });

  testWidgets('重建主题笔记面板不读取音频文件，版本变化后才标过期', (tester) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('koe-topic-notes-stale-'),
    ))!;
    addTearDown(() => dir.delete(recursive: true));
    final audioFile = File('${dir.path}/1760004202.wav')
      ..writeAsBytesSync(wavBytes([1, 2, 3, 4]));
    final ref = RecordingReference(fileId: 1760004202, path: audioFile.path);
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      return _generalNoteJson('面板里的笔记');
    });
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = _InMemoryUiController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    final topic = await store.createTopic(title: '面板', kind: TopicKind.general);
    const transcript = '这段转写显示在主题笔记面板里。';
    final version = (await tester.runAsync(() => audioVersion(audioFile.path)))!;
    controller.transcriptsByPath[audioFile.path] = transcript;
    controller.transcriptsByFileId[ref.fileId!] = transcript;
    controller.localPathsByFileId[ref.fileId!] = audioFile.path;
    final note = TopicNote(
      kind: TopicKind.general,
      topicId: topic.id,
      overview: '面板里的笔记',
      audioSignature: version,
      ideas: const [
        TopicIdea(text: '核心观点', reason: '因为如此', sources: ['S1']),
      ],
    );
    analysis.results[TopicNote.slotKey(controller.analysisKey(ref))] =
        AnalysisResult(
          text: note.encode(),
          sourceHash: analysisFingerprint(transcript),
          model: TopicNote.defaultModel,
          instruction: '已保存',
          sources: const ['s1'],
          createdAt: DateTime(2026, 10, 16),
        );
    await tester.runAsync(
      () => controller.refreshCachedAudioVersion(ref, force: true),
    );

    Future<void> showPanel() {
      return tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            home: Scaffold(
              body: TopicNotePanel(controller: controller, reference: ref),
            ),
          ),
        ),
      );
    }

    await showPanel();
    await tester.pump();
    expect(find.textContaining('可能已过期'), findsNothing);

    audioFile.writeAsBytesSync(wavBytes([9, 8, 7, 6, 5]));
    await showPanel();
    await tester.pump();
    expect(find.textContaining('可能已过期'), findsNothing);

    await tester.runAsync(
      () => controller.refreshCachedAudioVersion(ref, force: true),
    );
    await tester.pump();
    expect(find.textContaining('原文或所属主题已变化，当前笔记可能已过期'), findsOneWidget);
  });

  testWidgets('迁移后编辑概要仍保留原主题编号，过期标记不消失', (tester) async {
    const ref = RecordingReference(fileId: 1760008101, path: '/1760008101.wav');
    const transcript = '迁移前写下的录音转写，讨论旧主题里的想法。';
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      return _generalNoteJson('不应在编辑概要时重新生成');
    });
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = _InMemoryUiController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);

    final oldTopic = await store.createTopic(
      title: '旧主题',
      kind: TopicKind.general,
    );
    final newTopic = await store.createTopic(
      title: '新主题',
      kind: TopicKind.general,
    );
    final key = controller.analysisKey(ref);
    await store.moveRecording(key, oldTopic.id);
    await controller.settleTopicNoteWork();

    controller.transcriptsByPath[ref.path!] = transcript;
    controller.transcriptsByFileId[ref.fileId!] = transcript;
    final note = TopicNote(
      kind: TopicKind.general,
      topicId: oldTopic.id,
      overview: '迁移前写下的概要',
      audioSignature: 'sig-before-move',
      ideas: const [
        TopicIdea(text: '旧想法', reason: '旧理由', sources: ['S1']),
      ],
    );
    analysis.results[TopicNote.slotKey(key)] = AnalysisResult(
      text: note.encode(),
      sourceHash: analysisFingerprint(transcript),
      model: TopicNote.defaultModel,
      instruction: '已保存',
      sources: const ['s1'],
      createdAt: DateTime(2026, 10, 16),
    );
    await store.moveRecording(key, newTopic.id);
    await controller.settleTopicNoteWork();
    expect(controller.isTopicNoteStale(ref), isTrue);
    expect(
      jsonDecode(analysis.results[TopicNote.slotKey(key)]!.text)['topicId'],
      oldTopic.id,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: TopicNotePanel(controller: controller, reference: ref),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('可能已过期'), findsOneWidget);

    await tester.tap(find.text('编辑'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('topic-note-edit-overview')),
      '迁到新主题后修订的概要',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();

    final saved = jsonDecode(analysis.results[TopicNote.slotKey(key)]!.text)
        as Map<String, dynamic>;
    expect(saved['overview'], '迁到新主题后修订的概要');
    expect(saved['topicId'], oldTopic.id);
    expect(saved['audioSignature'], 'sig-before-move');
    expect(controller.isTopicNoteStale(ref), isTrue);
    expect(find.textContaining('可能已过期'), findsOneWidget);
  });

  testWidgets('已有笔记且出错时重试会先确认覆盖，取消则不生成', (tester) async {
    const ref = RecordingReference(fileId: 1760006101, path: '/1760006101.wav');
    var calls = 0;
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      calls++;
      return _generalNoteJson('重试生成的笔记');
    });
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = _InMemoryUiController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    final key = controller.analysisKey(ref);
    final topic = await store.createTopic(
      title: '产品思考',
      kind: TopicKind.general,
    );
    await store.moveRecording(key, topic.id);
    await _pumpUntilTopicNotesIdle(tester, controller);
    const transcript = '已有笔记的录音转写，讨论定价策略。';
    controller.transcriptsByPath[ref.path!] = transcript;
    controller.transcriptsByFileId[ref.fileId!] = transcript;
    final note = TopicNote(
      kind: TopicKind.general,
      topicId: topic.id,
      overview: '用户改过的概要',
      ideas: const [
        TopicIdea(text: '保留这条', reason: '手动留下的', sources: ['S1']),
      ],
    );
    analysis.results[TopicNote.slotKey(key)] = AnalysisResult(
      text: note.encode(),
      sourceHash: analysisFingerprint(transcript),
      model: TopicNote.defaultModel,
      instruction: '已保存',
      sources: const ['s1'],
      createdAt: DateTime(2026, 10, 16),
    );
    analysis.errors[TopicNote.slotKey(key)] = '生成失败';

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: TopicNotePanel(controller: controller, reference: ref),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('用户改过的概要'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.text('重新生成会覆盖当前内容（包括手动修改）。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _pumpUntilTopicNotesIdle(tester, controller);
    expect(calls, 0);
    expect(find.text('用户改过的概要'), findsOneWidget);
  });

  testWidgets('引用匹配不到原文时不跳转并提示未能定位原文', (tester) async {
    const ref = RecordingReference(fileId: 1760005101, path: '/1760005101.wav');
    var jumps = 0;
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: _CallbackAnalysisService((model, instruction, source) async {
        return _generalNoteJson('不会用到');
      }),
    );
    final controller = _InMemoryUiController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    const transcript = '第一段无关内容。\n\n第二段也无关。';
    controller.transcriptsByPath[ref.path!] = transcript;
    controller.transcriptsByFileId[ref.fileId!] = transcript;
    final note = TopicNote(
      kind: TopicKind.general,
      topicId: 'topic-missing',
      overview: '无法对上原文的笔记',
      ideas: const [
        TopicIdea(text: '完全不存在的句子xyz', reason: '对不上', sources: ['S1']),
      ],
    );
    analysis.results[TopicNote.slotKey(
      controller.analysisKey(ref),
    )] = AnalysisResult(
      text: note.encode(),
      sourceHash: analysisFingerprint(transcript),
      model: TopicNote.defaultModel,
      instruction: '已保存',
      sources: const ['s1'],
      createdAt: DateTime(2026, 10, 16),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: TopicNotePanel(
              controller: controller,
              reference: ref,
              onSelectParagraph: (_) => jumps++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('topic-note-source-S1')));
    await tester.pump();
    expect(jumps, 0);
    expect(find.text('未能定位原文'), findsOneWidget);
    expect(find.byKey(const ValueKey('highlighted-paragraph-0')), findsNothing);
  });

  test('生成是否写完要等在途任务空闲，而不是固定等待几十毫秒', () async {
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    var calls = 0;
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      calls++;
      await release.future;
      return _generalNoteJson('慢生成');
    });
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = _InMemoryUiController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);
    const ref = RecordingReference(fileId: 1760007101, path: '/1760007101.wav');
    final topic = await store.createTopic(title: '慢', kind: TopicKind.general);
    await store.moveRecording(controller.analysisKey(ref), topic.id);
    controller.rememberTranscript(ref.path!, '慢生成用的转写内容。');
    expect(
      analysis.results[TopicNote.slotKey(controller.analysisKey(ref))],
      isNull,
    );
    release.complete();
    await controller.settleTopicNoteWork();
    expect(calls, 1);
    expect(
      analysis.results[TopicNote.slotKey(controller.analysisKey(ref))],
      isNotNull,
    );
  });

  testWidgets('笔记面板支持编辑、重生成覆盖确认，并可点击引用跳回录音详情对应原段高亮', (tester) async {
    const ref = RecordingReference(fileId: 1760003001, path: '/1760003001.wav');

    const transcript =
        '第一段：今天开始读《思考，快与慢》第一章，先看系统1和系统2。\n\n'
        '第二段：书里第42页写到锚定效应会显著影响谈判中的第一报价，我觉得我们采购谈判也常遇到。\n\n'
        '第三段：后面还要再去查一下原书附录里的实验数据。';

    var completionCalls = 0;
    final service = _CallbackAnalysisService((
      model,
      instruction,
      source,
    ) async {
      completionCalls++;
      return jsonEncode({
        'overview': '第 $completionCalls 次生成的读书笔记',
        'excerpts': [
          {
            'text': '锚定效应会显著影响谈判中的第一报价。',
            'page': '第42页',
            'sources': ['S1'],
          },
        ],
        'comments': [
          {
            'text': '采购谈判也常遇到第一报价锚定。',
            'excerpt': '锚定效应会显著影响谈判中的第一报价。',
            'sources': ['S1'],
          },
        ],
        'questions': [],
        'associations': [],
        'toCheck': [
          {
            'text': '查原书附录里的实验数据。',
            'sources': ['S1'],
          },
        ],
      });
    });

    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final analysis = RecordingAnalysis(inMemory: true, service: service);
    final controller = _InMemoryUiController(
      topicStore: store,
      analysisController: analysis,
    );
    addTearDown(controller.dispose);

    final key = controller.analysisKey(ref);
    final bookTopic = await store.createTopic(
      title: '《思考，快与慢》',
      kind: TopicKind.book,
    );
    await store.moveRecording(key, bookTopic.id);
    controller.rememberTranscript(ref.path!, transcript);
    await _pumpUntilTopicNotesIdle(tester, controller);
    expect(completionCalls, 1);

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(
          home: Scaffold(
            body: TopicNotePanel(controller: controller, reference: ref),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('第 1 次生成的读书笔记'), findsOneWidget);
    expect(find.textContaining('第42页'), findsOneWidget);
    expect(find.textContaining('采购谈判也常遇到第一报价锚定'), findsOneWidget);

    // 编辑并保存笔记
    await tester.tap(find.text('编辑'));
    await tester.pump();
    final overviewField = find.byKey(
      const ValueKey('topic-note-edit-overview'),
    );
    expect(overviewField, findsOneWidget);
    await tester.enterText(overviewField, '手动修订后的读书笔记概要');
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('手动修订后的读书笔记概要'), findsOneWidget);
    expect(analysis.results[TopicNote.slotKey(key)]!.editedAt, isNotNull);

    // 点击重生成：弹出覆盖确认，取消不调用，确认才重新生成
    await tester.tap(find.text('重生成'));
    await tester.pump();
    expect(find.text('重新生成会覆盖当前内容（包括手动修改）。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(completionCalls, 1);

    await tester.tap(find.text('重生成'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '重生成'));
    await _pumpUntilTopicNotesIdle(tester, controller);
    expect(completionCalls, 2);
    expect(find.textContaining('第 2 次生成的读书笔记'), findsOneWidget);

    // 在录音详情页中打开主题笔记并点击引用跳回对应原段高亮
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: const MaterialApp(home: RecordingDetailScreen(reference: ref)),
      ),
    );
    await tester.pump();

    expect(find.text('主题笔记'), findsWidgets);
    await tester.tap(find.text('主题笔记').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 点击摘录上的 S1 引用标签，跳回原录音第 2 段（index 1，匹配摘录文本“锚定效应会显著影响谈判中的第一报价。”）并高亮
    final sourceChip = find.byKey(const ValueKey('topic-note-source-S1')).first;
    await tester.tap(sourceChip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('highlighted-paragraph-1')),
      findsOneWidget,
    );
  });
}

Future<void> _pumpUntilTopicNotesIdle(
  WidgetTester tester,
  RecorderController controller,
) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump();
    if (!controller.topicNoteWorkPending) return;
  }
  expect(controller.topicNoteWorkPending, isFalse);
}

String _generalNoteJson(String overview) => jsonEncode({
  'overview': overview,
  'ideas': [
    {
      'text': '核心观点',
      'reason': '因为如此',
      'sources': ['S1'],
    },
  ],
  'changes': [],
  'questions': [],
  'associations': [],
  'todos': [],
});

class _InMemoryUiController extends RecorderController {
  _InMemoryUiController({
    required super.topicStore,
    required super.analysisController,
  }) : super(
         loadPersistedState: false,
         topicsEnabled: true,
         fileJobJournal: FileJobJournal(inMemory: true),
       );

  @override
  String get analysisApiKey => 'sk-test';
}

class _CallbackAnalysisService implements AnalysisService {
  _CallbackAnalysisService(this._handler);

  final Future<String> Function(String model, String instruction, String source)
  _handler;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) => _handler(model, instruction, source);

  @override
  void dispose() {}
}
