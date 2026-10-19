import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

/// #147: a translated sentence plays its source sentence's original audio,
/// survives restart, and is only offered when the mapping is reliable.
void main() {
  late Directory temp;
  late String path;
  late RecordingReference reference;
  const key = 'file:147100';

  // Forty timed sentences, four seconds apart, so both readers scroll.
  final segments = [
    for (var i = 0; i < 40; i++)
      TranscriptSegment(
        text: 'Sentence $i is spoken here.',
        start: Duration(seconds: i * 4),
        end: Duration(seconds: i * 4 + 3),
      ),
  ];
  final text = segments.map((s) => s.text).join('\n');

  setUp(() {
    // A tap that misses the sentence would make "nothing played" pass.
    WidgetController.hitTestWarningShouldBeFatal = true;
    temp = Directory.systemTemp.createTempSync('koe-translation-');
    path = '${temp.path}/147100.wav';
    reference = RecordingReference(fileId: 147100, path: path);
  });

  tearDown(() {
    WidgetController.hitTestWarningShouldBeFatal = false;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Waits in real time, pumping the test clock between waits so queued
  /// writes and their continuations finish.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> emptyStore(WidgetTester tester) async {
    var done = false;
    unawaited(
      TranscriptStore.save(
        byPath: const {},
        byFileId: const {},
        aliasesByPath: const {},
        aliasesByFileId: const {},
      ).whenComplete(() => done = true),
    );
    await settle(tester, () => done);
  }

  Future<void> seed(
    WidgetTester tester, {
    Map<String, RecordingTranslation> translations = const {},
  }) async {
    await tester.runAsync(() async {
      await File(path).writeAsBytes(List.filled(64, 0));
      await TranscriptStore.save(
        byPath: {path: text},
        byFileId: const {},
        aliasesByPath: const {},
        aliasesByFileId: const {},
        metadata: const {
          key: TranscriptMetadata(
            provider: SttProvider.apple,
            sourceLanguage: 'en-US',
            revision: 1,
          ),
        },
        translations: translations,
        segments: {key: segments},
        strict: true,
      );
    });
  }

  Future<_TranslationController> start(
    WidgetTester tester,
    _Apple apple,
  ) async {
    final controller = (await tester.runAsync(() async {
      final created = _TranslationController(apple);
      await created.settleTopicNoteWork();
      // Saved settings load in the background; pin the languages after.
      created
        ..speechProvider = SttProvider.apple
        ..appleSourceLanguage = 'en-US'
        ..translationTargetLanguage = 'zh-Hans';
      return created;
    }))!;
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> showDetail(WidgetTester tester, RecorderController c) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          theme: AppTheme.light,
          home: RecordingDetailScreen(reference: reference),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inReader(String reader, Finder matching) =>
      find.descendant(of: find.byKey(ValueKey(reader)), matching: matching);

  ScrollPosition readerScroll(WidgetTester tester, String reader) => tester
      .state<ScrollableState>(inReader(reader, find.byType(Scrollable)).first)
      .position;

  /// The translation dialog's confirm button, whatever its label says.
  Future<void> confirmTranslation(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    // The translation and its save run on real I/O; the progress indicator
    // keeps animating until they finish, so wait for the job instead.
    await tester.pump();
    await tester.pump();
    await settle(
      tester,
      () =>
          find
              .byKey(const ValueKey('translation-progress-notice'))
              .evaluate()
              .isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapTranslated(WidgetTester tester, int index) async {
    final sentence = inReader(
      'translation-reader',
      find.byKey(ValueKey('segment-$index')),
    );
    await tester.ensureVisible(sentence);
    await tester.pumpAndSettle();
    await tester.tap(sentence);
    await tester.pumpAndSettle();
  }

  testWidgets('翻译后点译文回听对应原声，原文译文各自保留位置，重启后仍可定位', (tester) async {
    addTearDown(() => emptyStore(tester));
    await seed(tester);
    final apple = _Apple();
    final c = await start(tester, apple);
    await showDetail(tester, c);
    await tester.drag(
      find.byKey(const ValueKey('source-reader')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    final sourcePosition = readerScroll(tester, 'source-reader').pixels;
    expect(sourcePosition, greaterThan(0));

    await tester.tap(find.widgetWithText(TextButton, '翻译'));
    await tester.pumpAndSettle();
    await confirmTranslation(tester);
    var saved = false;
    for (var i = 0; i < 300 && !saved; i++) {
      await tester.runAsync(() async {
        final stored = await TranscriptStore.load();
        saved = stored.translations[key]?.segments?.length == 40;
        if (!saved) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
    }
    expect(saved, isTrue, reason: '逐句译文与原句映射应写入存储');
    await tester.pumpAndSettle();

    // The translation opens, says which languages and that taps play the
    // original recording, not a reading of the translation.
    expect(find.byTooltip('复制译文'), findsOneWidget);
    expect(find.textContaining('English → 简体中文 · 点译文回听对应原声'), findsOneWidget);
    expect(find.textContaining('不是译文朗读'), findsOneWidget);
    expect(
      inReader(
        'translation-reader',
        find.text('【译】Sentence 2 is spoken here.'),
      ),
      findsOneWidget,
    );

    // Each reader keeps its own place.
    await tester.drag(
      find.byKey(const ValueKey('translation-reader')),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    final translationPosition = readerScroll(
      tester,
      'translation-reader',
    ).pixels;
    expect(translationPosition, greaterThan(0));
    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    expect(readerScroll(tester, 'source-reader').pixels, sourcePosition);
    await tester.tap(find.text('译文'));
    await tester.pumpAndSettle();
    expect(
      readerScroll(tester, 'translation-reader').pixels,
      translationPosition,
    );

    // A translated sentence seeks the original audio of its source sentence.
    await tapTranslated(tester, 12);
    expect(c.playbackRequests.last, (
      path,
      const Duration(seconds: 48),
      147100,
    ));
    expect(find.byTooltip('复制译文'), findsOneWidget, reason: '回听后仍停在译文');

    // Restart: the saved mapping still plays the right source sentence.
    await tester.pumpWidget(const SizedBox.shrink());
    final restarted = await start(tester, _Apple());
    await showDetail(tester, restarted);
    await tester.tap(find.text('译文'));
    await tester.pumpAndSettle();
    expect(find.textContaining('English → 简体中文 · 点译文回听对应原声'), findsOneWidget);
    await tapTranslated(tester, 3);
    expect(restarted.playbackRequests, [
      (path, const Duration(seconds: 12), 147100),
    ]);
  });

  testWidgets('原文改过后旧译文标为过时，不能点译文回听，重启后仍标明', (tester) async {
    addTearDown(() => emptyStore(tester));
    await seed(
      tester,
      translations: {
        key: RecordingTranslation(
          text: segments.map((s) => '旧译 ${s.text}').join('\n\n'),
          sourceLanguage: 'en-US',
          targetLanguage: 'zh-Hans',
          provider: SttProvider.apple,
          sourceRevision: 1,
          sourceDigest: transcriptSourceDigest(text),
          segments: [for (final s in segments) '旧译 ${s.text}'],
        ),
      },
    );
    final c = await start(tester, _Apple());
    await showDetail(tester, c);

    // Change one word in the source through the editor.
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑正文'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('transcript-edit-input')),
      text.replaceFirst('Sentence 0', 'Opening line'),
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    var saved = false;
    for (var i = 0; i < 300 && !saved; i++) {
      await tester.runAsync(() async {
        final stored = await TranscriptStore.load();
        saved = stored.manualByKey[key]?.startsWith('Opening line') ?? false;
        if (!saved) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
    }
    expect(saved, isTrue);
    await tester.pumpAndSettle();

    Future<void> expectStale(_TranslationController c) async {
      await tester.tap(find.text('译文'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('translation-stale-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('按旧版原文翻译'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '重新翻译'), findsOneWidget);
      // Still readable, but with no sentence to play.
      expect(
        inReader('translation-reader', find.textContaining('旧译 Sentence 5')),
        findsOneWidget,
      );
      expect(
        inReader('translation-reader', find.byKey(const ValueKey('segment-5'))),
        findsNothing,
      );
      await tester.tap(
        inReader('translation-reader', find.textContaining('旧译 Sentence 5')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(c.playbackRequests, isEmpty);
    }

    await expectStale(c);
    await tester.pumpWidget(const SizedBox.shrink());
    final restarted = await start(tester, _Apple());
    await showDetail(tester, restarted);
    await expectStale(restarted);
  });

  testWidgets('没有句段映射的旧译文只能阅读；重新翻译失败保留原文和旧译文，成功后可回听', (tester) async {
    addTearDown(() => emptyStore(tester));
    await seed(
      tester,
      translations: const {
        // A translation saved before #147: one block, no sentence mapping.
        key: RecordingTranslation(
          text: '整段旧译文。',
          sourceLanguage: 'en-US',
          targetLanguage: 'zh-Hans',
          provider: SttProvider.apple,
          sourceRevision: 1,
        ),
      },
    );
    final apple = _Apple()
      ..failure = PlatformException(code: 'resources_missing');
    final c = await start(tester, apple);
    await showDetail(tester, c);
    await tester.tap(find.text('译文'));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有和原文句子对齐，只能阅读，不能点译文回听原声'), findsOneWidget);
    await tester.tap(find.text('整段旧译文。'));
    await tester.pumpAndSettle();
    expect(c.playbackRequests, isEmpty, reason: '不能按译文长度推算原声时间');

    // Re-translating fails: source and the old translation are untouched.
    await tester.tap(find.widgetWithText(TextButton, '重新翻译'));
    await tester.pumpAndSettle();
    await confirmTranslation(tester);
    expect(find.textContaining('翻译失败，原文未改动'), findsWidgets);
    expect(find.text('整段旧译文。'), findsOneWidget);
    await tester.tap(find.text('原文'));
    await tester.pumpAndSettle();
    expect(
      inReader('source-reader', find.text('Sentence 1 is spoken here.')),
      findsOneWidget,
    );

    // It succeeds once resources are there; the new version is aligned.
    apple.failure = null;
    await tester.tap(find.text('译文'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '重新翻译'));
    await tester.pumpAndSettle();
    await confirmTranslation(tester);
    var saved = false;
    for (var i = 0; i < 300 && !saved; i++) {
      await tester.runAsync(() async {
        final stored = await TranscriptStore.load();
        saved = stored.translations[key]?.segments != null;
        if (!saved) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
    }
    expect(saved, isTrue);
    await tester.pumpAndSettle();
    expect(find.textContaining('点译文回听对应原声'), findsOneWidget);
    await tapTranslated(tester, 2);
    expect(c.playbackRequests, [(path, const Duration(seconds: 8), 147100)]);
  });
}

class _TranslationController extends RecorderController {
  _TranslationController(_Apple apple)
    : super(loadPersistedState: true, appleSpeech: apple) {
    appleCapabilities = const AppleSpeechCapabilities(
      supported: true,
      speechStatus: SpeechResourceStatus.ready,
      translationStatus: SpeechResourceStatus.ready,
      translationLanguages: [
        SpeechLanguage(code: 'en-US', name: 'English'),
        SpeechLanguage(code: 'zh-Hans', name: '简体中文'),
      ],
    );
  }

  final playbackRequests = <(String, Duration, int?)>[];

  @override
  Duration? localDurationForPath(String path) => const Duration(seconds: 160);

  @override
  Future<void> playFrom(String path, Duration start, {int? fileId}) async {
    playbackRequests.add((path, start, fileId));
  }
}

/// Stands in for on-device Apple translation; no service is called.
class _Apple extends AppleSpeechService {
  Object? failure;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async => const AppleSpeechCapabilities(
    supported: true,
    speechStatus: SpeechResourceStatus.ready,
    translationStatus: SpeechResourceStatus.ready,
    translationLanguages: [
      SpeechLanguage(code: 'en-US', name: 'English'),
      SpeechLanguage(code: 'zh-Hans', name: '简体中文'),
    ],
  );

  @override
  Future<String> translate(
    String text, {
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (failure != null) throw failure!;
    return '【译】$text';
  }
}
