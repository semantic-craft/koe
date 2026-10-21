import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/tts_answer_speaker.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

/// Answer read-aloud on Android (#342): the system TextToSpeech reads Ask
/// Koe answers, off by default and labeled synthetic, as on iPhone.
void main() {
  const engine = MethodChannel('flutter_tts');
  late Directory directory;
  late List<MethodCall> calls;
  late Completer<void> utterance;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-tts-');
    calls = [];
    utterance = Completer<void>();
    // The plugin's Android side: speak completes when the utterance ends,
    // and stop ends it early.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(engine, (call) async {
          calls.add(call);
          if (call.method == 'speak') await utterance.future;
          if (call.method == 'stop' && !utterance.isCompleted) {
            utterance.complete();
          }
          return 1;
        });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engine, null);
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  // flutter_tts picks the argument shape by dart:io's platform, which is
  // the host's in tests rather than the overridden target.
  List<String> spoken() => [
    for (final call in calls)
      if (call.method == 'speak')
        switch (call.arguments) {
          final Map<Object?, Object?> args => args['text']! as String,
          final Object? text => text! as String,
        },
  ];

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue);
  }

  testWidgets(
    'Ask Koe offers read-aloud, off until turned on, and then the system '
    'voice reads new answers in Chinese until stopped',
    (tester) async {
      final assistant = _Assistant()..reply = '师傅说下周一开工 [S1]。';
      final c = (await tester.runAsync(() async {
        final c = RecorderController(
          loadPersistedState: false,
          analysisController: RecordingAnalysis(inMemory: true),
          qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
          contextAnalysisService: assistant,
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${directory.path}/imports'),
          askStore: AskStore(file: File('${directory.path}/ask.json')),
        );
        final source = '${directory.path}/1760850000.wav';
        await File(source).writeAsBytes([1, 2, 3, 4]);
        c.exportedPaths.add(source);
        c.rememberTranscript(source, '装修师傅说下周一开工。');
        await c.contextItems.load();
        await c.asks.load();
        return c;
      }))!;
      addTearDown(c.dispose);
      await tester.pumpWidget(KoeApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ask-koe')));
      await tester.pumpAndSettle();
      await settle(tester, () => c.asks.sessions.isNotEmpty);

      final toggle = find.byKey(const ValueKey('ask-read-aloud'));
      expect(toggle, findsOneWidget);
      expect(find.byTooltip('朗读回答：关'), findsOneWidget);

      await tester.tap(toggle);
      final notice = find.text('新回答会用合成语音朗读，不是录音原声');
      await settle(tester, () => notice.evaluate().isNotEmpty);
      expect(c.asks.readAloud, isTrue);
      expect(find.byTooltip('朗读回答：开（合成语音）'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('ask-input')),
        '师傅什么时候开工？',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ask-send')));
      await settle(tester, () => spoken().isNotEmpty);
      await tester.pump();
      expect(spoken(), ['师傅说下周一开工。']);
      expect(
        calls.any((c) => c.method == 'setLanguage' && c.arguments == 'zh-CN'),
        isTrue,
      );
      expect(find.text('合成语音朗读中，不是录音原声'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ask-stop-speaking')));
      await settle(tester, () => utterance.isCompleted);
      await tester.pump();
      expect(find.text('合成语音朗读中，不是录音原声'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test('a long answer is read in parts Android accepts, and stop ends it '
      'before the next part', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final speaker = TtsAnswerSpeaker();
    final sentence = '${'很' * 99}长。';
    final answer = List.filled(100, sentence).join();

    final reading = speaker.speak(answer);
    await pumpEventQueue();
    expect(spoken(), hasLength(1));
    expect(spoken().single.length, lessThanOrEqualTo(3900));
    expect(spoken().single, endsWith('。'));

    utterance.complete();
    utterance = Completer<void>();
    await pumpEventQueue();
    expect(spoken(), hasLength(2));
    await speaker.stop();
    await reading;
    expect(spoken(), hasLength(2));
    expect(answer, startsWith(spoken().join()));
  });
}

class _Assistant implements AnalysisService {
  String reply = '';

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => reply;

  @override
  void dispose() {}
}
