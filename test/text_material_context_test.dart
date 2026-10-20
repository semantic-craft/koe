import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/context_source.dart';
import 'package:koe/ui/widgets/context_timeline.dart';
import 'package:provider/provider.dart';

class _Assistant implements AnalysisService {
  String Function(String source) reply = (_) => '';

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => reply(source);

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-text-context-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  RecorderController controller(_Assistant assistant) => RecorderController(
    loadPersistedState: false,
    analysisController: RecordingAnalysis(inMemory: true),
    qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
    contextAnalysisService: assistant,
    transcriptPersister: ({bool strict = false}) async {},
    libraryDirectory: Directory('${directory.path}/imports'),
  );

  test('text materials join the day, Ask cites their sentences, and todos '
      'point back to the text instead of an audio offset', () async {
    final assistant = _Assistant();
    final c = controller(assistant);
    addTearDown(c.dispose);
    await c.contextItems.load();

    final note = await c.saveTextNote('今天先聊别的。\n房东说月底前把押金退给我。');
    final imported = (await c.importMinutesText(
      '周会.txt',
      '预算控制在二十万以内。',
    )).document;

    final today = c.contextItemsForDay(note.capturedAt!);
    final noteItem = today.firstWhere((i) => i.title == note.title);
    expect(noteItem.start, note.capturedAt);
    expect(c.contextItemHasText(noteItem), isTrue);
    expect(c.contextReference(noteItem), isNull);
    // An import without its own time sits on the import day, time unknown.
    final importedItem = today.firstWhere((i) => i.title == imported.title);
    expect(importedItem.timeKnown, isFalse);

    // Ask finds the typed sentence and cites the text, not a playback spot.
    assistant.reply = (source) {
      final label = RegExp(r'\[(S\d+)\][^\n]*押金').firstMatch(source)!.group(1);
      return '房东会在月底前退押金 [$label]。';
    };
    final session = await c.newAskSession();
    await c.ask(session.id, '押金什么时候退？');
    final cited = c.asks.sessionById(session.id)!.messages.last.sources.single;
    expect(cited.text, '房东说月底前把押金退给我。');
    expect(cited.source.documentId, note.id);
    expect(cited.source.line, 1);

    // Todo extraction reads the note and cites its sentence.
    assistant.reply = (_) =>
        '{"items":[{"type":"others","title":"退押金","owner":"房东",'
        '"due":null,"segment":2}],"updates":[]}';
    expect(await c.extractTodosForItem(noteItem), 1);
    final todo = c.todos.todos.single;
    expect(todo.quote, '房东说月底前把押金退给我。');
    expect(todo.source.documentId, note.id);
    expect(todo.source.line, 1);
    expect(await c.extractTodosForItem(noteItem), 0);
    expect(c.todos.todos, hasLength(1));

    // Yesterday's key points and the diary read the same day's text.
    final material = c.diaryMaterial(DiaryPeriod.day(note.capturedAt!));
    expect(
      material.sources.map((line) => line.text),
      containsAll(['房东说月底前把押金退给我。', '预算控制在二十万以内。']),
    );
  });

  testWidgets('opening a text item or its citation shows the text', (
    tester,
  ) async {
    late RecorderController c;
    late MinutesDocument note;
    await tester.runAsync(() async {
      c = controller(_Assistant());
      await c.contextItems.load();
      note = await c.saveTextNote('房东说月底前把押金退给我。');
    });
    addTearDown(c.dispose);
    final item = c.contextItemsForDay(note.capturedAt!).single;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: c,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  ContextTimelineRow(item: item),
                  TextButton(
                    onPressed: () => openContextSource(
                      context,
                      ContextSource(
                        recordingKey: ContextSource.documentKey(note.id),
                        line: 0,
                      ),
                    ),
                    child: const Text('出处'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text(note.title));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('minutes-document-${note.id}')), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('出处'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('minutes-document-${note.id}')), findsOneWidget);
    expect(find.text('原录音已不在资料里（可能在回收站）'), findsNothing);
  });
}
