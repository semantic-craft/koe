import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

class _Assistant implements AnalysisService {
  String reply = '';
  Object? failure;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    if (failure != null) throw failure!;
    return reply;
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-diary-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  test('the diary cites its sentences, keeps the user edit when new material '
      'arrives, and keeps one summary per week', () async {
    final assistant = _Assistant();
    final c = RecorderController(
      loadPersistedState: false,
      analysisController: RecordingAnalysis(inMemory: true),
      qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
      contextAnalysisService: assistant,
      // Transcripts stay in memory; nothing races the temp-dir cleanup.
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
    );
    addTearDown(c.dispose);
    // Wednesday 2026-10-21, 09:00 and 15:00 local time.
    final morning = DateTime(2026, 10, 21, 9);
    final afternoon = DateTime(2026, 10, 21, 15);
    Future<void> add(DateTime at, List<TranscriptSegment>? segments) async {
      final path = '${directory.path}/${at.millisecondsSinceEpoch ~/ 1000}.wav';
      await File(path).writeAsBytes([1, 2, 3, 4]);
      c.exportedPaths.add(path);
      if (segments != null) {
        c.rememberTranscript(
          path,
          segments.map((s) => s.text).join(),
          segments: segments,
        );
      }
    }

    await add(morning, const [
      TranscriptSegment(text: '今天开会讨论预算。', start: Duration.zero),
      TranscriptSegment(text: '我下周交方案。', start: Duration(seconds: 8)),
    ]);
    await add(DateTime(2026, 10, 21, 12), null);
    await c.contextItems.load();
    final day = DiaryPeriod.day(morning);

    final material = c.diaryMaterial(day);
    expect(material.items, hasLength(2));
    expect(material.withoutText, 1);

    assistant.reply = '【整理】上午开会讨论了预算 [S1]\n【原话】我下周交方案。 [S2]\n【建议】提前准备方案';
    await c.generateDiary(day);
    final first = c.diary.entryFor(day.key)!.current!;
    expect(first.text, assistant.reply);
    expect(first.sources.map((line) => line.label), ['S1', 'S2']);
    expect(first.sources.last.source.start, const Duration(seconds: 8));
    expect(first.sources.last.text, '我下周交方案。');

    // Same material: nothing is regenerated.
    assistant.reply = '不该出现';
    await c.generateDiary(day);
    expect(c.diary.entryFor(day.key)!.current!.text, first.text);

    await c.editDiary(day.key, '【整理】我自己的说法 [S1]');

    // A failed run keeps the last good version.
    await add(afternoon, const [
      TranscriptSegment(text: '下午去看了房子。', start: Duration.zero),
    ]);
    assistant.failure = StateError('分析请求失败');
    await expectLater(c.generateDiary(day), throwsStateError);
    expect(c.diary.entryFor(day.key)!.current!.text, '【整理】我自己的说法 [S1]');
    expect(c.diary.entryFor(day.key)!.pendingFingerprint, isNull);

    assistant
      ..failure = null
      ..reply = '【整理】上午开会 [S1]，下午看房 [S3]';
    await c.generateDiary(day);
    final edited = c.diary.entryFor(day.key)!;
    expect(edited.current!.text, '【整理】我自己的说法 [S1]');
    expect(edited.newer?.text, '【整理】上午开会 [S1]，下午看房 [S3]');

    await c.keepEditedDiary(day.key);
    assistant.reply = '不该出现';
    await c.generateDiary(day);
    expect(c.diary.entryFor(day.key)!.newer, isNull);
    expect(c.diary.entryFor(day.key)!.current!.text, '【整理】我自己的说法 [S1]');

    assistant.reply = '【整理】本周主要在谈预算 [S1]';
    await c.generateDiary(DiaryPeriod.week(morning));
    await c.generateDiary(DiaryPeriod.week(DateTime(2026, 10, 25)));
    expect(
      c.diary.entries.where((entry) => entry.key.startsWith('week:')),
      hasLength(1),
    );
    expect(DiaryPeriod.week(DateTime(2026, 10, 25)).key, 'week:2026-10-19');
  });
}
