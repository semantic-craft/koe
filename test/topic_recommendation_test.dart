import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/topics_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeTempDir() =>
      Directory.systemTemp.createTemp('topics-52-');

  Future<String> recording(Directory dir, int id) async {
    final path = '${dir.path}/$id.wav';
    await File(path).writeAsBytes(wavBytes([1, 2, 3, 4]));
    return path;
  }

  RecorderController buildController(
    TopicStore store, {
    _FakeQwenStt? qwen,
    AnalysisService? recommender,
    RecordingAnalysis? analysis,
  }) {
    final c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      topicsEnabled: true,
      topicStore: store,
      qwenSpeech: qwen ?? _FakeQwenStt(),
      topicRecommendationService: recommender ?? _FakeRecommendService(),
      fileJobJournal: FileJobJournal(inMemory: true),
      analysisController: analysis,
      retrievedAudioSettleTime: Duration.zero,
    );
    addTearDown(c.dispose);
    return c;
  }

  test(
    'pending recordings get an existing-topic or new-topic recommendation '
    'after transcription; recommendation itself triggers no note/analysis '
    'call, and confirm/change/dismiss update placement as expected',
    () async {
      final dir = await makeTempDir();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = TopicStore(
        inMemory: true,
        now: () => DateTime(2026, 10, 16, 10),
      );
      await store.load();
      final book = await store.createTopic(
        kind: TopicKind.book,
        title: '法学方法论',
        author: '拉伦茨',
      );
      final career = await store.createTopic(
        kind: TopicKind.general,
        title: '职业规划',
      );

      final qwen = _FakeQwenStt();
      final recommender = _FakeRecommendService();
      final analysisService = _FakeAnalysisService();
      final analysis = RecordingAnalysis(
        inMemory: true,
        service: analysisService,
      );
      final c = buildController(
        store,
        qwen: qwen,
        recommender: recommender,
        analysis: analysis,
      );
      await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
      c.setSpeechProvider(SttProvider.qwen);
      c.setAutoTranscribe(true);

      // 1. Existing topic recommendation -> confirm
      recommender.nextOutput = '{"action":"existing","topicId":"${book.id}"}';
      qwen.nextText = '今天读到法学方法论第三章关于法律解释的讨论';
      final path1 = await recording(dir, 1760000101);
      await c.processRetrievedRecording(path1);
      await c.waitForTopicAssist();

      const key1 = 'file:1760000101';
      expect(store.isPending(key1), isTrue);
      expect(store.topicOf(key1), isNull);
      expect(analysisService.calls, 0);
      final rec1 = store.recommendationFor(key1);
      expect(rec1, isNotNull);
      expect(rec1!.kind, TopicRecommendationKind.existingTopic);
      expect(rec1.topicId, book.id);

      final confirmed1 = await store.confirmRecommendation(key1);
      expect(confirmed1?.id, book.id);
      expect(store.isPending(key1), isFalse);
      expect(store.topicOf(key1)?.id, book.id);
      expect(store.recommendationFor(key1), isNull);

      // 2. Existing topic recommendation -> change (改选) to another topic
      recommender.nextOutput = '{"action":"existing","topicId":"${book.id}"}';
      qwen.nextText = '关于未来三年工作方向的思考';
      final path2 = await recording(dir, 1760000102);
      await c.processRetrievedRecording(path2);
      await c.waitForTopicAssist();

      const key2 = 'file:1760000102';
      expect(store.recommendationFor(key2)?.topicId, book.id);
      await store.moveRecording(key2, career.id);
      expect(store.topicOf(key2)?.id, career.id);
      expect(store.recommendationFor(key2), isNull);

      // 3. New topic recommendation -> confirm creates topic and moves recording
      recommender.nextOutput =
          '{"action":"new","kind":"book","title":"正义论","author":"罗尔斯"}';
      qwen.nextText = '罗尔斯在正义论里提到无知之幕的假定';
      final path3 = await recording(dir, 1760000103);
      await c.processRetrievedRecording(path3);
      await c.waitForTopicAssist();

      const key3 = 'file:1760000103';
      final rec3 = store.recommendationFor(key3);
      expect(rec3, isNotNull);
      expect(rec3!.kind, TopicRecommendationKind.newTopic);
      expect(rec3.suggestedTitle, '正义论');
      expect(rec3.suggestedKind, TopicKind.book);
      expect(rec3.suggestedAuthor, '罗尔斯');

      final created = await store.confirmRecommendation(key3);
      expect(created, isNotNull);
      expect(created!.title, '正义论');
      expect(created.kind, TopicKind.book);
      expect(created.author, '罗尔斯');
      expect(store.topicOf(key3)?.id, created.id);
      expect(store.recommendationFor(key3), isNull);

      // 4. New topic recommendation -> dismiss (忽略) keeps recording in 待归类
      recommender.nextOutput =
          '{"action":"new","kind":"general","title":"健身计划"}';
      qwen.nextText = '下周开始每周三次有氧训练';
      final path4 = await recording(dir, 1760000104);
      await c.processRetrievedRecording(path4);
      await c.waitForTopicAssist();

      const key4 = 'file:1760000104';
      expect(store.recommendationFor(key4)?.suggestedTitle, '健身计划');
      await store.dismissRecommendation(key4);
      expect(store.isPending(key4), isTrue);
      expect(store.recommendationFor(key4), isNull);
    },
  );

  test('采用服务新版本后按新正文重跑待归类建议', () async {
    final dir = await makeTempDir();
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final recommender = _FakeRecommendService();
    final c = buildController(store, recommender: recommender);
    await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
    c.setSpeechProvider(SttProvider.qwen);

    final path = await recording(dir, 1760000199);
    const key = 'file:1760000199';
    await store.placeRetrieved(key);
    c.rememberTranscript(path, '旧正文');
    await c.waitForTopicAssist();
    await c.saveManualTranscript(path, '人工正文');
    await c.waitForTopicAssist();
    c.rememberTranscript(path, '新版本正文提到法学方法论');
    await c.waitForTopicAssist();
    recommender.sources.clear();

    await c.adoptIncomingTranscript(path);
    await c.waitForTopicAssist();

    expect(recommender.sources, isNotEmpty);
    expect(recommender.sources.last, contains('新版本正文提到法学方法论'));
  });

  testWidgets(
    'PendingRecordingsScreen and TopicDetailScreen render recommendation and '
    'drift actions (确认/改选/忽略 and 移到…/保留) without auto-migrating',
    (tester) async {
      final store = TopicStore(
        inMemory: true,
        now: () => DateTime(2026, 10, 16, 10),
      );
      await store.load();
      final book = await store.createTopic(
        kind: TopicKind.book,
        title: '法学方法论',
        author: '拉伦茨',
      );
      final career = await store.createTopic(
        kind: TopicKind.general,
        title: '职业规划',
      );
      await store.setCurrentTopic(book.id);

      const p1 = '/tmp/1760000111.wav';
      const p2 = '/tmp/1760000112.wav';
      const p3 = '/tmp/1760000113.wav';
      const p4 = '/tmp/1760000114.wav';
      const k1 = 'file:1760000111';
      const k2 = 'file:1760000112';
      const k3 = 'file:1760000113';
      const k4 = 'file:1760000114';

      // Place k3 and k4 into current topic (book), and k1 and k2 into 待归类
      await store.placeRetrieved(k3);
      await store.placeRetrieved(k4);
      await store.setCurrentTopic(null);
      await store.placeRetrieved(k1);
      await store.placeRetrieved(k2);

      await store.setRecommendation(
        k1,
        TopicRecommendation.existing(topicId: book.id),
      );
      await store.setRecommendation(
        k2,
        const TopicRecommendation.newTopic(
          suggestedKind: TopicKind.book,
          suggestedTitle: '正义论',
          suggestedAuthor: '罗尔斯',
        ),
      );
      await store.setDriftHint(k3, TopicDriftHint(topicId: book.id));
      await store.setDriftHint(
        k4,
        TopicDriftHint(topicId: book.id, suggestedTopicId: career.id),
      );

      final c = buildController(store);
      c.exportedPaths = [p1, p2, p3, p4];

      // PendingRecordingsScreen: confirm k2 (new topic) and change k1 (改选)
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: c,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const PendingRecordingsScreen(),
          ),
        ),
      );
      expect(find.text('推荐归入《法学方法论》'), findsOneWidget);
      expect(find.text('建议新建主题《正义论》 · 罗尔斯'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('change-recommend-$k1')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '法学方法论')).selected,
        isTrue,
      );
      await tester.tap(find.text('职业规划'));
      await tester.pumpAndSettle();
      expect(store.topicOf(k1)?.id, career.id);

      await tester.tap(find.byKey(const ValueKey('confirm-recommend-$k2')));
      await tester.pumpAndSettle();
      expect(store.topicOf(k2)?.title, '正义论');
      expect(store.topicOf(k2)?.author, '罗尔斯');

      // TopicDetailScreen: drift prompt "这条好像不属于《法学方法论》" with 移到… / 保留
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: c,
          child: MaterialApp(
            theme: AppTheme.light,
            home: TopicDetailScreen(topicId: book.id),
          ),
        ),
      );
      expect(find.text('这条好像不属于《法学方法论》'), findsNWidgets(2));

      // Keep k3 in book
      await tester.tap(find.byKey(const ValueKey('drift-keep-$k3')));
      await tester.pumpAndSettle();
      expect(store.topicOf(k3)?.id, book.id);
      expect(store.driftHintFor(k3), isNull);
      expect(find.text('这条好像不属于《法学方法论》'), findsOneWidget);

      // Move k4 to career (with suggestedTopicId pre-selected in picker)
      await tester.tap(find.byKey(const ValueKey('drift-move-$k4')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '职业规划')).selected,
        isTrue,
      );
      await tester.tap(find.text('职业规划'));
      await tester.pumpAndSettle();
      expect(store.topicOf(k4)?.id, career.id);
      expect(store.driftHintFor(k4), isNull);
      expect(find.text('这条好像不属于《法学方法论》'), findsNothing);
    },
  );

  test(
    'recordings in current topic that obviously drift record a drift hint '
    'without migrating automatically',
    () async {
      final dir = await makeTempDir();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = TopicStore(
        inMemory: true,
        now: () => DateTime(2026, 10, 16, 10),
      );
      await store.load();
      final book = await store.createTopic(
        kind: TopicKind.book,
        title: '法学方法论',
      );
      final career = await store.createTopic(
        kind: TopicKind.general,
        title: '职业规划',
      );
      await store.setCurrentTopic(book.id);

      final qwen = _FakeQwenStt();
      final recommender = _FakeRecommendService();
      final c = buildController(store, qwen: qwen, recommender: recommender);
      await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
      c.setSpeechProvider(SttProvider.qwen);
      c.setAutoTranscribe(true);

      recommender.nextOutput =
          '{"drift":true,"suggestedTopicId":"${career.id}"}';
      qwen.nextText = '聊聊明年换城市工作的打算';
      final path1 = await recording(dir, 1760000201);
      await c.processRetrievedRecording(path1);
      await c.waitForTopicAssist();

      const key1 = 'file:1760000201';
      // Never auto-migrates
      expect(store.topicOf(key1)?.id, book.id);
      expect(store.recordingsIn(book.id), [key1]);
      expect(store.driftHintFor(key1)?.topicId, book.id);
      expect(store.driftHintFor(key1)?.suggestedTopicId, career.id);
      expect(store.driftPromptFor(key1), '这条好像不属于《法学方法论》');
    },
  );

  test(
    'only unarchived topics are recommended; closed or deleted topics are '
    'rejected or invalidated, and single-speaker is passed only as a hint',
    () async {
      final dir = await makeTempDir();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/topics.json');
      final store = TopicStore(
        file: file,
        now: () => DateTime(2026, 10, 16, 10),
      );
      await store.load();
      final open = await store.createTopic(
        kind: TopicKind.general,
        title: '开放主题',
      );
      final closedBook = await store.createTopic(
        kind: TopicKind.book,
        title: '已读完的书',
      );
      final closedGeneral = await store.createTopic(
        kind: TopicKind.general,
        title: '已归档主题',
      );
      await store.closeTopic(closedBook.id);
      await store.closeTopic(closedGeneral.id);

      final qwen = _FakeQwenStt();
      final recommender = _FakeRecommendService();
      final c = buildController(store, qwen: qwen, recommender: recommender);
      await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
      c.setSpeechProvider(SttProvider.qwen);
      c.setAutoTranscribe(true);

      // Model tries to return a closed topic id -> rejected
      recommender.nextOutput =
          '{"action":"existing","topicId":"${closedBook.id}"}';
      qwen.nextText = '说话人 1：这段是单人独白';
      final path1 = await recording(dir, 1760000301);
      await c.processRetrievedRecording(path1);
      await c.waitForTopicAssist();

      expect(recommender.lastInstruction, contains('开放主题'));
      expect(recommender.lastInstruction, isNot(contains('已读完的书')));
      expect(recommender.lastInstruction, isNot(contains('已归档主题')));
      expect(recommender.lastInstruction, contains('单说话人'));
      expect(store.recommendationFor('file:1760000301'), isNull);

      // Multi-speaker recording still gets evaluated with multi-speaker hint
      recommender.nextOutput = '{"action":"existing","topicId":"${open.id}"}';
      qwen.nextText = '说话人 1：第一句\n说话人 2：第二句';
      final path2 = await recording(dir, 1760000302);
      await c.processRetrievedRecording(path2);
      await c.waitForTopicAssist();

      expect(recommender.lastInstruction, contains('多说话人'));
      expect(store.recommendationFor('file:1760000302')?.topicId, open.id);

      // Archiving the recommended topic before confirm invalidates it
      await store.closeTopic(open.id);
      expect(store.recommendationFor('file:1760000302'), isNull);
      expect(await store.confirmRecommendation('file:1760000302'), isNull);
      expect(store.isPending('file:1760000302'), isTrue);

      // If a persisted recommendation points to a deleted topic on reload,
      // it is dropped and the recording remains safely in 待归类.
      final active2 = await store.createTopic(
        kind: TopicKind.general,
        title: '临时主题',
      );
      recommender.nextOutput =
          '{"action":"existing","topicId":"${active2.id}"}';
      qwen.nextText = '另一段待归类思考';
      final path3 = await recording(dir, 1760000303);
      await c.processRetrievedRecording(path3);
      await c.waitForTopicAssist();
      expect(store.recommendationFor('file:1760000303')?.topicId, active2.id);

      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      (decoded['topics'] as List<Object?>).removeWhere(
        (t) => (t as Map<String, Object?>)['id'] == active2.id,
      );
      await file.writeAsString(jsonEncode(decoded));
      final reloaded = TopicStore(
        file: file,
        now: () => DateTime(2026, 10, 16, 10),
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.recommendationFor('file:1760000303'), isNull);
      expect(reloaded.isPending('file:1760000303'), isTrue);
    },
  );

  test(
    'recommendation reads only a short transcript excerpt (no history), '
    'deduplicates after success, and silently falls back on failure/offline '
    'while allowing retry on a later trigger',
    () async {
      final dir = await makeTempDir();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/topics.json');
      final store = TopicStore(
        file: file,
        now: () => DateTime(2026, 10, 16, 10),
      );
      await store.load();
      final topic = await store.createTopic(
        kind: TopicKind.general,
        title: '日常思考',
      );
      await store.setCurrentTopic(topic.id);

      final qwen = _FakeQwenStt();
      final recommender = _FakeRecommendService();
      final c = buildController(store, qwen: qwen, recommender: recommender);
      await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
      c.setSpeechProvider(SttProvider.qwen);
      c.setAutoTranscribe(true);

      // Historical recording in a topic
      recommender.nextOutput = '{"drift":false}';
      qwen.nextText = '历史录音独有标记_不应出现在后续推荐请求中';
      final historyPath = await recording(dir, 1760000400);
      await c.processRetrievedRecording(historyPath);
      await c.waitForTopicAssist();
      expect(recommender.calls, 1);

      // Switch to no current topic so next recording goes to 待归类
      await store.setCurrentTopic(null);
      recommender.nextOutput = '{"action":"existing","topicId":"${topic.id}"}';
      final longText = '${'这是一段关于日常思考的冗长录音内容。' * 60}超出摘要窗口尾部标记';
      qwen.nextText = longText;
      final path1 = await recording(dir, 1760000401);
      await c.processRetrievedRecording(path1);
      await c.waitForTopicAssist();

      expect(recommender.calls, 2);
      expect(
        recommender.lastSource!.runes.length,
        lessThanOrEqualTo(maxTopicExcerptRunes + 1),
      );
      expect(recommender.lastSource, isNot(contains('超出摘要窗口尾部标记')));
      expect(recommender.lastSource, isNot(contains('历史录音独有标记')));
      expect(recommender.lastInstruction, isNot(contains('历史录音独有标记')));

      // Duplicate triggers after success: re-retrieving, re-saving same
      // transcript, or dismissing and re-triggering must not call the model again.
      await c.processRetrievedRecording(path1);
      c.rememberTranscript(path1, longText, provider: SttProvider.qwen);
      await c.waitForTopicAssist();
      expect(recommender.calls, 2);

      await store.dismissRecommendation('file:1760000401');
      c.rememberTranscript(path1, longText, provider: SttProvider.qwen);
      await c.waitForTopicAssist();
      expect(recommender.calls, 2);

      // Offline failure (SocketException) -> silent fallback to manual,
      // NOT marked evaluated yet so a later trigger can retry.
      recommender.nextError = const SocketException('Network is unreachable');
      qwen.nextText = '离线时的转写内容';
      final offlinePath = await recording(dir, 1760000402);
      await c.processRetrievedRecording(offlinePath);
      await c.waitForTopicAssist();

      const offlineKey = 'file:1760000402';
      expect(recommender.calls, 3);
      expect(store.isPending(offlineKey), isTrue);
      expect(store.recommendationFor(offlineKey), isNull);
      expect(
        c
            .recordingView(
              RecordingReference(fileId: 1760000402, path: offlinePath),
            )
            .error,
        isNull,
      );
      expect(c.errorMessage, isNull);
      expect(store.saveError, isNull);

      // When network recovers, a later trigger retries and succeeds, and only
      // then marks the recording evaluated.
      recommender.nextError = null;
      recommender.nextOutput = '{"action":"existing","topicId":"${topic.id}"}';
      c.rememberTranscript(offlinePath, '离线时的转写内容', provider: SttProvider.qwen);
      await c.waitForTopicAssist();
      expect(recommender.calls, 4);
      expect(store.recommendationFor(offlineKey)?.topicId, topic.id);

      // Manual classification still works
      await store.moveRecording(offlineKey, topic.id);
      expect(store.topicOf(offlineKey)?.id, topic.id);

      // Malformed model output -> silent fallback to manual, then retryable
      recommender.nextError = null;
      recommender.nextOutput = 'not valid json';
      qwen.nextText = '模型返回格式异常时的转写内容';
      final badOutputPath = await recording(dir, 1760000403);
      await c.processRetrievedRecording(badOutputPath);
      await c.waitForTopicAssist();

      const badOutputKey = 'file:1760000403';
      expect(recommender.calls, 5);
      expect(store.isPending(badOutputKey), isTrue);
      expect(store.recommendationFor(badOutputKey), isNull);
      expect(
        c
            .recordingView(
              RecordingReference(fileId: 1760000403, path: badOutputPath),
            )
            .error,
        isNull,
      );

      // Subsequent trigger retries after malformed output and succeeds
      recommender.nextOutput =
          '{"action":"new","kind":"general","title":"恢复后的新主题"}';
      c.rememberTranscript(
        badOutputPath,
        '模型返回格式异常时的转写内容',
        provider: SttProvider.qwen,
      );
      await c.waitForTopicAssist();
      expect(recommender.calls, 6);
      expect(store.recommendationFor(badOutputKey)?.suggestedTitle, '恢复后的新主题');
    },
  );

  test(
    'real QwenAnalysisService request wrapper uses dedicated topic-assist '
    'prompt (not note-taking [S1] wrapper) and extracts the first JSON object '
    'when the model wraps JSON in prose or code fences',
    () async {
      final dir = await makeTempDir();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = TopicStore(
        inMemory: true,
        now: () => DateTime(2026, 10, 16, 10),
      );
      await store.load();
      final book = await store.createTopic(
        kind: TopicKind.book,
        title: '法学方法论',
        author: '拉伦茨',
      );
      final career = await store.createTopic(
        kind: TopicKind.general,
        title: '职业规划',
      );

      final capturedMessages = <List<Map<String, Object?>>>[];
      var nextContent = '';
      final realService = QwenAnalysisService(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          final msgs = (body['messages'] as List)
              .map((m) => Map<String, Object?>.from(m as Map))
              .toList();
          capturedMessages.add(msgs);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {'content': nextContent},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final qwen = _FakeQwenStt();
      final c = buildController(store, qwen: qwen, recommender: realService);
      await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
      c.setSpeechProvider(SttProvider.qwen);
      c.setAutoTranscribe(true);

      // 1. Pending recommendation: model replies with prose + fenced JSON + trailing JSON
      nextContent =
          '根据转写片段 [S1]，推荐归入现有主题：\n'
          '```json\n'
          '{"action":"existing","topicId":"${book.id}"}\n'
          '```\n'
          '备选：{"action":"new","kind":"general","title":"干扰主题"}';
      qwen.nextText = '今天读拉伦茨关于法律解释与法的续造的章节';
      final path1 = await recording(dir, 1760000501);
      await c.processRetrievedRecording(path1);
      await c.waitForTopicAssist();

      expect(capturedMessages, hasLength(1));
      final sysPrompt1 = capturedMessages.first[0]['content'] as String;
      final userPrompt1 = capturedMessages.first[1]['content'] as String;
      expect(sysPrompt1, isNot(contains('你是录音整理助手')));
      expect(sysPrompt1, isNot(contains('[S1]')));
      expect(sysPrompt1, contains('JSON'));
      expect(userPrompt1, isNot(contains('原文或分段笔记')));

      final rec = store.recommendationFor('file:1760000501');
      expect(rec, isNotNull);
      expect(rec!.kind, TopicRecommendationKind.existingTopic);
      expect(rec.topicId, book.id);

      // 2. Drift check in current topic: model replies with prose around JSON
      await store.setCurrentTopic(book.id);
      nextContent =
          '分析说明：这段内容在谈换工作，明显偏离《法学方法论》 '
          '{"drift":true,"suggestedTopicId":"${career.id}"} 建议移入职业规划。';
      qwen.nextText = '下周准备投递简历并约面试';
      final path2 = await recording(dir, 1760000502);
      await c.processRetrievedRecording(path2);
      await c.waitForTopicAssist();

      expect(capturedMessages, hasLength(2));
      final hint = store.driftHintFor('file:1760000502');
      expect(hint, isNotNull);
      expect(hint!.topicId, book.id);
      expect(hint.suggestedTopicId, career.id);
    },
  );

  test(
    'a newer transcript supersedes an in-flight assist, and leaving 待归类 '
    'does not stick a mark that blocks retrying the same text',
    () async {
      final dir = await makeTempDir();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = TopicStore(
        inMemory: true,
        now: () => DateTime(2026, 10, 16, 10),
      );
      await store.load();
      final book = await store.createTopic(
        kind: TopicKind.book,
        title: '法学方法论',
        author: '拉伦茨',
      );
      final career = await store.createTopic(
        kind: TopicKind.general,
        title: '职业规划',
      );

      final qwen = _FakeQwenStt();
      final recommender = _FakeRecommendService();
      final c = buildController(store, qwen: qwen, recommender: recommender);
      await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
      c.setSpeechProvider(SttProvider.qwen);
      c.setAutoTranscribe(true);

      Future<void> until(bool Function() done) async {
        final started = DateTime.now();
        while (!done()) {
          expect(
            DateTime.now().difference(started),
            lessThan(const Duration(seconds: 5)),
            reason: 'timed out waiting for topic assist',
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      // A is in flight when a clearly different transcript B arrives.
      // A's model result must not remain as the recommendation, and B must
      // be evaluated.
      final stallA = Completer<void>();
      addTearDown(() {
        if (!stallA.isCompleted) stallA.complete();
      });
      recommender.stall = stallA;
      recommender.nextOutput = '{"action":"existing","topicId":"${book.id}"}';
      const textA = '转写A独有：法学方法论里关于法律解释的讨论';
      qwen.nextText = textA;
      final pathA = await recording(dir, 1760000701);
      await c.processRetrievedRecording(pathA);
      await until(() => recommender.calls == 1);

      const textB = '转写B独有：明年换城市并重新规划职业方向';
      recommender.nextOutput =
          '{"action":"existing","topicId":"${career.id}"}';
      c.rememberTranscript(pathA, textB, provider: SttProvider.qwen);
      stallA.complete();
      await c.waitForTopicAssist();

      const keyA = 'file:1760000701';
      final hashB = analysisFingerprint(topicTranscriptExcerpt(textB));
      expect(recommender.sources, contains(contains('转写B独有')));
      expect(store.recommendationFor(keyA)?.topicId, career.id);
      expect(store.recommendationFor(keyA)?.sourceHash, hashB);
      expect(store.topicOf(keyA), isNull);
      expect(store.isPending(keyA), isTrue);

      // Leaving 待归类 while assist is in flight must not stick a mark that
      // blocks evaluating the same text after the recording is pending again.
      final stallC = Completer<void>();
      addTearDown(() {
        if (!stallC.isCompleted) stallC.complete();
      });
      recommender.stall = stallC;
      recommender.nextOutput = '{"action":"existing","topicId":"${book.id}"}';
      const textC = '移出待归类期间保持不变的同一段转写';
      final callsBeforeC = recommender.calls;
      qwen.nextText = textC;
      final pathC = await recording(dir, 1760000702);
      await c.processRetrievedRecording(pathC);
      await until(() => recommender.calls == callsBeforeC + 1);

      const keyC = 'file:1760000702';
      await store.removeFromTopic(keyC);
      stallC.complete();
      await c.waitForTopicAssist();

      final tokenC =
          'pending:${analysisFingerprint(topicTranscriptExcerpt(textC))}';
      expect(store.isPending(keyC), isFalse);
      expect(store.recommendationFor(keyC), isNull);
      expect(store.hasEvaluatedAssist(keyC, tokenC), isFalse);

      final snapshot = store.toJson();
      final placements = Map<String, Object?>.from(
        snapshot['placements']! as Map,
      );
      placements[keyC] = 'pending';
      snapshot['placements'] = placements;
      final reopenFile = File('${dir.path}/reopen-topics.json');
      await reopenFile.writeAsString(jsonEncode(snapshot));
      final reloaded = TopicStore(
        file: reopenFile,
        now: () => DateTime(2026, 10, 16, 10),
      );
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.isPending(keyC), isTrue);
      expect(reloaded.hasEvaluatedAssist(keyC, tokenC), isFalse);

      final recommender2 = _FakeRecommendService();
      recommender2.nextOutput = '{"action":"existing","topicId":"${book.id}"}';
      final c2 = buildController(reloaded, recommender: recommender2);
      await c2.setQwenConfig(const EngineConfig(apiKey: 'key'));
      c2.rememberTranscript(pathC, textC, provider: SttProvider.qwen);
      await c2.waitForTopicAssist();

      expect(recommender2.calls, 1);
      expect(reloaded.recommendationFor(keyC)?.topicId, book.id);
      expect(reloaded.isPending(keyC), isTrue);
      expect(reloaded.topicOf(keyC), isNull);
    },
  );
}

class _FakeQwenStt extends QwenSttService {
  String nextText = '转写文本';

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    return SttResult(text: nextText, sourcePath: path, language: 'zh');
  }
}

class _FakeRecommendService implements AnalysisService {
  int calls = 0;
  String nextOutput = '{}';
  Object? nextError;
  String? lastSource;
  String? lastInstruction;
  final List<String> sources = [];

  /// When set, the next generate call waits until this completer finishes,
  /// using the output captured at the start of that call.
  Completer<void>? stall;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    lastSource = source;
    lastInstruction = instruction;
    sources.add(source);
    final output = nextOutput;
    final error = nextError;
    final gate = stall;
    stall = null;
    if (gate != null) await gate.future;
    if (error != null) throw error;
    return output;
  }

  @override
  void dispose() {}
}

class _FakeAnalysisService implements AnalysisService {
  int calls = 0;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    return '{}';
  }

  @override
  void dispose() {}
}
