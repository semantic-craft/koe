import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

class _Assistant implements AnalysisService {
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => '【整理】昨天定了装修预算 [S1]';

  @override
  void dispose() {}
}

void main() {
  testWidgets('the morning brief lists open and due items and writes '
      "yesterday's key points only when asked", (tester) async {
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 10);
    late Directory directory;
    late RecorderController c;
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('koe-brief-');
      c = RecorderController(
        loadPersistedState: false,
        analysisController: RecordingAnalysis(inMemory: true),
        qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
        contextAnalysisService: _Assistant(),
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${directory.path}/imports'),
      );
      final id = yesterday.millisecondsSinceEpoch ~/ 1000;
      final path = '${directory.path}/$id.wav';
      await File(path).writeAsBytes([1, 2, 3, 4]);
      c.exportedPaths.add(path);
      c.rememberTranscript(
        path,
        '预算定在二十万。',
        segments: const [
          TranscriptSegment(text: '预算定在二十万。', start: Duration.zero),
        ],
      );
      await c.contextItems.load();
      final source = ContextSource(recordingKey: 'file:$id', path: path);
      Todo todo(String id, TodoKind kind, String title, DateTime due) => Todo(
        id: id,
        kind: kind,
        title: title,
        owner: kind == TodoKind.others ? '小王' : null,
        due: due,
        source: source,
        quote: title,
        createdAt: yesterday,
        updatedAt: yesterday,
      );
      await c.todos.put(
        todo(
          'm1',
          TodoKind.mine,
          '订材料',
          DateTime(now.year, now.month, now.day),
        ),
      );
      await c.todos.put(todo('o1', TodoKind.others, '发报价', yesterday));
      await c.todos.put(
        todo(
          'o2',
          TodoKind.others,
          '下月复查',
          DateTime(now.year, now.month + 1, 1),
        ),
      );
    });
    addTearDown(() async {
      c.dispose();
      await directory.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();

    expect(find.text('1 条待办未完成'), findsOneWidget);
    expect(find.byKey(const ValueKey('brief-follow-o1')), findsOneWidget);
    expect(find.byKey(const ValueKey('brief-follow-o2')), findsNothing);
    expect(find.textContaining('昨天定了装修预算'), findsNothing);
    expect(c.diary.entryFor(MorningBrief.briefKey(now)), isNull);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('brief-generate')));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('昨天定了装修预算'), findsOneWidget);
    expect(
      c.diary
          .entryFor(MorningBrief.briefKey(now))
          ?.current
          ?.sources
          .single
          .text,
      '预算定在二十万。',
    );
  });
}
