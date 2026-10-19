import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

class _Assistant implements AnalysisService {
  final List<String> instructions = [];
  final List<String> sources = [];
  String Function(String source) reply = (_) => '';
  Object? failure;
  Completer<String>? hold;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    instructions.add(instruction);
    sources.add(source);
    if (failure != null) throw failure!;
    if (hold != null) return hold!.future;
    return reply(source);
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-ask-');
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

  Future<void> add(
    RecorderController c,
    int id,
    List<TranscriptSegment>? segments,
  ) async {
    final path = '${directory.path}/$id.wav';
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

  test('answers cite the matching sentences, follow-ups keep the thread, '
      'and nothing found is said plainly', () async {
    final assistant = _Assistant();
    final c = controller(assistant);
    addTearDown(c.dispose);
    await add(c, 1760850000, const [
      TranscriptSegment(text: '今天先聊别的事情。', start: Duration.zero),
      TranscriptSegment(text: '装修师傅说下周一开工。', start: Duration(seconds: 12)),
    ]);
    await add(c, 1760936400, const [
      TranscriptSegment(text: '预算控制在二十万以内。', start: Duration(seconds: 3)),
    ]);
    await add(c, 1761022800, null);
    await c.contextItems.load();
    final session = await c.newAskSession();
    expect(c.askScope().withText, 2);
    expect(c.askScope().withoutText, 1);

    assistant.reply = (source) {
      final label = RegExp(r'\[(S\d+)\][^\n]*开工').firstMatch(source)!.group(1);
      return '师傅说下周一开工 [$label]。';
    };
    await c.ask(session.id, '装修师傅说什么时候开工？');
    var answer = c.asks.sessionById(session.id)!.messages.last;
    expect(answer.status, AskStatus.done);
    expect(answer.sources.single.text, '装修师傅说下周一开工。');
    expect(answer.sources.single.source.start, const Duration(seconds: 12));
    expect(assistant.instructions.last, contains('1 条录音还没有文字'));

    assistant.reply = (source) {
      final label = RegExp(r'\[(S\d+)\][^\n]*预算').firstMatch(source)!.group(1);
      return '预算在二十万以内 [$label]。';
    };
    await c.ask(session.id, '那预算呢？');
    answer = c.asks.sessionById(session.id)!.messages.last;
    expect(answer.sources.single.text, '预算控制在二十万以内。');
    expect(assistant.instructions.last, contains('装修师傅说什么时候开工？'));

    final asked = assistant.instructions.length;
    await c.ask(session.id, '火星基地的进度');
    answer = c.asks.sessionById(session.id)!.messages.last;
    expect(answer.grounded, isFalse);
    expect(answer.text, contains('没有找到相关内容'));
    expect(assistant.instructions, hasLength(asked));

    assistant.failure = StateError('分析请求失败');
    await c.ask(session.id, '开工时间定了吗');
    answer = c.asks.sessionById(session.id)!.messages.last;
    expect(answer.status, AskStatus.failed);
    expect(
      c.asks.sessionById(session.id)!.messages.reversed.skip(1).first.text,
      '开工时间定了吗',
    );
    assistant
      ..failure = null
      ..reply = (_) => '下周一 [S1]。';
    await c.retryAsk(session.id);
    final messages = c.asks.sessionById(session.id)!.messages;
    expect(messages.last.status, AskStatus.done);
    expect(messages.where((m) => m.text == '开工时间定了吗'), hasLength(1));
  });

  testWidgets('a second tap while waiting sends nothing, and the draft '
      'survives leaving the page', (tester) async {
    final assistant = _Assistant()..hold = Completer<String>();
    late RecorderController c;
    await tester.runAsync(() async {
      c = controller(assistant);
      await add(c, 1760850000, const [
        TranscriptSegment(text: '装修师傅说下周一开工。', start: Duration.zero),
      ]);
      await c.contextItems.load();
    });
    addTearDown(c.dispose);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ask-koe')));
    await tester.pumpAndSettle();
    expect(find.text('连续问答尚未开放'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('ask-input')), '什么时候开工');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-send')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('ask-input')), '什么时候开工');
    await tester.tap(find.byKey(const ValueKey('ask-send')));
    await tester.pump();
    expect(find.text('正在查你的资料…'), findsOneWidget);
    final session = c.asks.sessions.first;
    expect(session.messages.where((m) => m.role == AskRole.user), hasLength(1));

    await tester.runAsync(() async {
      assistant.hold!.complete('下周一开工 [S1]。');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('下周一开工'), findsWidgets);

    await tester.enterText(find.byKey(const ValueKey('ask-input')), '还没问完');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ask-koe')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没问完'), findsOneWidget);
  });
}
