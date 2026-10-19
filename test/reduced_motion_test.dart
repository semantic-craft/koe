import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

/// An assistant whose answer never arrives, so Ask Koe stays "thinking".
class _SlowAssistant implements AnalysisService {
  final hold = Completer<String>();

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) => hold.future;

  @override
  void dispose() {}
}

void main() {
  late Directory directory;
  late RecorderController c;
  late _SlowAssistant assistant;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-motion-');
    assistant = _SlowAssistant();
    c = RecorderController(
      loadPersistedState: false,
      analysisController: RecordingAnalysis(inMemory: true),
      qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
      contextAnalysisService: assistant,
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
    );
    addTearDown(() async {
      c.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  // iOS「减弱动态效果」only sets `reduceMotion`; Android「移除动画」sets
  // `disableAnimations`. Both must quiet Koe's motion.
  const platforms = {
    'iOS Reduce Motion': FakeAccessibilityFeatures(reduceMotion: true),
    'Android remove animations': FakeAccessibilityFeatures(
      disableAnimations: true,
    ),
  };

  for (final MapEntry(key: platform, value: features) in platforms.entries) {
    group(platform, () {
      void reduceMotion(WidgetTester tester) {
        tester.platformDispatcher.accessibilityFeaturesTestValue = features;
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }

      testWidgets('with Reduce Motion on, waiting for Ask Koe shows a still '
          'indicator instead of a spinning one', (tester) async {
        reduceMotion(tester);
        await tester.runAsync(() async {
          final path = '${directory.path}/1760850000.wav';
          await File(path).writeAsBytes([1, 2, 3, 4]);
          c.exportedPaths.add(path);
          c.rememberTranscript(
            path,
            '装修师傅说下周一开工。',
            segments: const [
              TranscriptSegment(text: '装修师傅说下周一开工。', start: Duration.zero),
            ],
          );
          await c.contextItems.load();
        });
        await tester.pumpWidget(KoeApp(controller: c));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('ask-koe')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ask-input')),
          '什么时候开工',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('ask-send')));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        expect(find.text('正在查你的资料…'), findsOneWidget);
        // Let the tap ripple and the caret go quiet; only the waiting indicator
        // could still be animating after that.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('正在查你的资料…'), findsOneWidget);
        expect(tester.hasRunningAnimations, isFalse);
      });

      testWidgets(
        'with Reduce Motion on, the new record sheet appears at once',
        (tester) async {
          reduceMotion(tester);
          await tester.pumpWidget(KoeApp(controller: c));
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const ValueKey('new-recording')));
          await tester.pump();
          await tester.pump();

          final hint = find.text('原件先保存到手机，再决定是否转写或整理。');
          final first = tester.getRect(hint);
          await tester.pump(const Duration(seconds: 1));
          expect(tester.getRect(hint), first);
        },
      );
    });
  }
}
