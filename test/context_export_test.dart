import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a project, a topic and a day export as Markdown with resolvable '
      'sources and nothing outside the scope', () async {
    final directory = await Directory.systemTemp.createTemp('koe-export-');
    addTearDown(() => directory.delete(recursive: true));
    final topics = TopicStore(inMemory: true);
    addTearDown(topics.dispose);
    final c = RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: topics,
      analysisController: RecordingAnalysis(inMemory: true),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
    );
    addTearDown(c.dispose);
    final monday = DateTime(2026, 10, 19, 9);
    final tuesday = DateTime(2026, 10, 20, 14);
    Future<String> add(DateTime at, String text, {Duration? second}) async {
      final id = at.millisecondsSinceEpoch ~/ 1000;
      final path = '${directory.path}/$id.wav';
      await File(path).writeAsBytes([1, 2, 3, 4]);
      c.exportedPaths.add(path);
      c.rememberTranscript(
        path,
        text,
        segments: [
          TranscriptSegment(text: text, start: Duration.zero),
          if (second != null) TranscriptSegment(text: '第二句。', start: second),
        ],
      );
      return 'file:$id';
    }

    final a = await add(
      monday,
      '和师傅约好周五量房。',
      second: const Duration(seconds: 7),
    );
    final b = await add(tuesday, '预算先按二十万算。');
    await add(DateTime(2026, 10, 20, 18), '晚上和朋友吃饭。');
    await c.contextItems.load();
    final move = await c.createProject('搬家', goal: '月底前搬完');
    final renovation = await topics.createTopic(
      kind: TopicKind.general,
      title: '装修',
    );
    await topics.moveRecording(a, renovation.id);
    c.contextItemsForDay(monday);
    await c.setContextItemProjects('recording:$a', [move.id]);
    await c.setContextItemProjects('recording:$b', [move.id]);
    await c.setContextItemTopics('recording:$b', [renovation.id]);
    final now = DateTime.now();
    await c.todos.put(
      Todo(
        id: 't1',
        kind: TodoKind.mine,
        title: '周五量房',
        source: ContextSource(recordingKey: a),
        quote: '和师傅约好周五量房。',
        projectIds: [move.id],
        createdAt: now,
        updatedAt: now,
      ),
    );

    final (project, count) = c.exportContextMarkdown(ProjectExport(move.id));
    expect(count, 2);
    expect(project, contains('# Koe 项目：搬家'));
    expect(project, contains('目标：月底前搬完'));
    expect(project, isNot(contains('晚上和朋友吃饭')));
    expect(project.indexOf('和师傅约好周五量房'), lessThan(project.indexOf('预算先按二十万算')));
    expect(project, contains('- [S2] 00:07 第二句。'));
    expect(
      project,
      matches(RegExp(r'- \[S2\] .* · 2026-10-19 09:00 · 录音位置 00:07 · ' + a)),
    );
    expect(project, contains('原话：「和师傅约好周五量房。」'));

    // Topic export follows the corrected links, not only the topic store.
    final (topic, _) = c.exportContextMarkdown(TopicExport(renovation.id));
    expect(topic, contains('和师傅约好周五量房'));
    expect(topic, contains('预算先按二十万算'));
    expect(topic, isNot(contains('晚上和朋友吃饭')));

    // A day's diary keeps pointing at the same sentences after relabelling.
    await c.diary.put(
      DiaryEntry(
        key: DiaryPeriod.day(tuesday).key,
        current: DiaryDraft(
          text: '【整理】定了预算 [S9]',
          sources: [
            SourceLine(
              label: 'S9',
              title: 't',
              text: '预算先按二十万算。',
              source: ContextSource(recordingKey: b),
            ),
          ],
          fingerprint: 'f',
          generatedAt: now,
        ),
      ),
    );
    final (day, dayCount) = c.exportContextMarkdown(DayExport(tuesday));
    expect(dayCount, 2);
    expect(day, contains('- [S1] 00:00 预算先按二十万算。'));
    expect(day, contains('【整理】定了预算 [S1]'));
    expect(day, isNot(contains('和师傅约好周五量房')));
  });

  test('after the user corrects a timed transcript, exports, diary and Ask '
      'quote the corrected text instead of the old segments', () async {
    final directory = await Directory.systemTemp.createTemp('koe-export-');
    addTearDown(() => directory.delete(recursive: true));
    final c = RecorderController(
      loadPersistedState: false,
      analysisController: RecordingAnalysis(inMemory: true),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
    );
    addTearDown(c.dispose);
    final at = DateTime(2026, 10, 19, 9);
    final path = '${directory.path}/${at.millisecondsSinceEpoch ~/ 1000}.wav';
    await File(path).writeAsBytes([1, 2, 3, 4]);
    c.exportedPaths.add(path);
    c.rememberTranscript(
      path,
      '说话人 1：录音豆今天到了。\n说话人 2：明天试一下。',
      segments: const [
        TranscriptSegment(text: '录音豆今天到了。', start: Duration.zero, speaker: '1'),
        TranscriptSegment(
          text: '明天试一下。',
          start: Duration(seconds: 5),
          speaker: '2',
        ),
      ],
    );
    await c.contextItems.load();
    await c.saveManualTranscript(path, '说话人 1：录音笔今天到了。\n说话人 2：明天试一下（校）。');
    await c.renameTranscriptSpeaker(path, '1', '老王');

    final lines = c.contextSourceLines(c.contextItemsForDay(at));
    expect(
      [for (final line in lines) line.text],
      ['老王：录音笔今天到了。', '说话人 2：明天试一下（校）。'],
    );
    expect(lines.every((line) => line.source.start == Duration.zero), isTrue);

    final (day, _) = c.exportContextMarkdown(DayExport(at));
    expect(day, contains('老王：录音笔今天到了。'));
    expect(day, contains('明天试一下（校）。'));
    expect(day, isNot(contains('录音豆')));
  });
}
