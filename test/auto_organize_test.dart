import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/state/organize_store.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

/// On-device transcription that answers with a fixed sentence.
class _Apple extends AppleSpeechService {
  int calls = 0;
  Completer<void>? hold;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async => AppleSpeechCapabilities(
    supported: true,
    speechStatus: SpeechResourceStatus.ready,
    translationStatus: SpeechResourceStatus.ready,
    suggestedSourceLanguage: 'zh-CN',
  );

  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    calls++;
    await hold?.future;
    return SttResult(text: '我明天去买牛奶。', language: sourceLanguage);
  }
}

/// Summary model. [timeouts] answers that many calls with a timeout, the way
/// a request lost after reaching the provider looks to the app.
class _Summarizer implements AnalysisService {
  int calls = 0;
  int timeouts = 0;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    if (timeouts > 0) {
      timeouts--;
      throw TimeoutException('no answer');
    }
    return '要点：买牛奶';
  }

  @override
  void dispose() {}
}

/// Commitment extraction model.
class _Extractor implements AnalysisService {
  int calls = 0;
  int timeouts = 0;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    if (timeouts > 0) {
      timeouts--;
      throw TimeoutException('no answer');
    }
    return '{"items":[{"type":"mine","title":"买牛奶","due":null,'
        '"segment":1}],"updates":[]}';
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late _Apple apple;
  late _Summarizer summarizer;
  late _Extractor extractor;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-organize-');
    apple = _Apple();
    summarizer = _Summarizer();
    extractor = _Extractor();
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  Future<RecorderController> build({
    OrganizeStore? store,
    bool owned = true,
  }) async {
    final c =
        RecorderController(
            loadPersistedState: false,
            appleSpeech: apple,
            qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
            analysisController: RecordingAnalysis(
              service: summarizer,
              inMemory: true,
            ),
            contextAnalysisService: extractor,
            organizeStore: store,
            transcriptPersister: ({bool strict = false}) async {},
            libraryDirectory: Directory('${directory.path}/imports'),
          )
          ..speechProvider = SttProvider.apple
          ..appleSourceLanguage = 'zh-CN';
    if (owned) addTearDown(c.dispose);
    await c.refreshAppleCapabilities();
    return c;
  }

  Future<String> importAudio(RecorderController c, String name) async {
    final source = File('${directory.path}/$name.wav');
    await source.writeAsBytes(
      wavBytes(List.generate(3200, (i) => (i * 7 + name.hashCode) & 0xff)),
    );
    return (await c.importLocalAudio(source.path)).path;
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  test('once on, only new recordings are transcribed, summarized and '
      'scanned for todos', () async {
    final c = await build();
    final before = await importAudio(c, 'old');
    await c.waitForOrganize();

    await c.setAutoOrganize(true);
    final fresh = await importAudio(c, 'new');
    await until(() => c.organizeStatusFor(fresh).stage == OrganizeStage.done);

    expect(c.recordingView(RecordingReference(path: fresh)).text, '我明天去买牛奶。');
    expect(c.todos.openMine.single.title, '买牛奶');
    expect(c.organizeStore.queued, isEmpty);
    expect(c.organizeStatusFor(before).stage, OrganizeStage.none);
    expect(apple.calls, 1);
    expect(summarizer.calls, 1);
    expect(extractor.calls, 1);
  });

  test(
    'history runs only for the chosen range and reuses finished steps',
    () async {
      final c = await build();
      final recent = await importAudio(c, 'recent');
      final old = await importAudio(c, 'oldest');
      await c.waitForOrganize();
      await c.setAutoOrganize(true);
      c.rememberTranscript(recent, '已有的手改文字');
      final now = DateTime.now();
      // The old one was recorded 40 days ago.
      await c.library.upsert(
        c.library
            .assetForPath(old)!
            .copyWith(recordedAt: now.subtract(const Duration(days: 40))),
      );
      await c.library.upsert(
        c.library
            .assetForPath(recent)!
            .copyWith(recordedAt: now.subtract(const Duration(days: 2))),
      );

      final week = c.organizeCandidates(OrganizeRange.lastWeek, now: now);
      expect(week, [recent]);
      expect(await c.organizeHistory(week), 1);
      await until(
        () => c.organizeStatusFor(recent).stage == OrganizeStage.done,
      );
      await c.waitForOrganize();

      // The existing transcript was kept, not re-transcribed.
      expect(apple.calls, 0);
      expect(c.recordingView(RecordingReference(path: recent)).text, '已有的手改文字');
      expect(c.organizeStatusFor(old).stage, OrganizeStage.none);
      expect(summarizer.calls, 1);
    },
  );

  test(
    'an unknown summary request is not resent until the user confirms',
    () async {
      summarizer.timeouts = 1;
      final c = await build();
      await c.waitForOrganize();
      await c.setAutoOrganize(true);
      final path = await importAudio(c, 'lost');
      await until(
        () => c.organizeStatusFor(path).stage == OrganizeStage.needsCheck,
      );
      expect(c.organizeStatusFor(path).message, contains('结果未知'));

      // Later activity wakes the organizer; it must not resend on its own.
      await importAudio(c, 'other');
      await until(() => summarizer.calls >= 2);
      await c.waitForOrganize();
      final callsForBoth = summarizer.calls;
      expect(c.organizeStatusFor(path).stage, OrganizeStage.needsCheck);

      await c.retryOrganize(path);
      await until(() => c.organizeStatusFor(path).stage == OrganizeStage.done);
      expect(summarizer.calls, callsForBoth + 1);
    },
  );

  test('an unknown todo extraction waits for the user', () async {
    extractor.timeouts = 1;
    final c = await build();
    await c.waitForOrganize();
    await c.setAutoOrganize(true);
    final path = await importAudio(c, 'todo');
    await until(
      () => c.organizeStatusFor(path).stage == OrganizeStage.needsCheck,
    );
    await c.waitForOrganize();
    expect(extractor.calls, 1);

    await c.retryOrganize(path);
    await until(() => c.organizeStatusFor(path).stage == OrganizeStage.done);
    expect(extractor.calls, 2);
    expect(c.todos.openMine.single.title, '买牛奶');
  });

  test('a user-edited summary is never overwritten', () async {
    final c = await build();
    await c.waitForOrganize();
    await c.setAutoOrganize(true);
    final path = await importAudio(c, 'edit');
    await until(() => c.organizeStatusFor(path).stage == OrganizeStage.done);
    final key = RecordingAnalysis.keyForTemplate(
      c.analysisKey(RecordingReference(path: path)),
      summaryTemplateId,
    );
    await c.analysis.editResult(key, c.analysis.results[key]!, '我自己写的摘要');
    c.rememberTranscript(path, '校订后的文字：我明天去买牛奶。');
    await c.organizeHistory([path]);
    await until(() => c.organizeStore.queued.isEmpty);

    expect(c.analysis.results[key]!.text, '我自己写的摘要');
    expect(summarizer.calls, 1);
  });

  test('queued recordings continue after a restart', () async {
    final storeFile = File('${directory.path}/organize.json');
    final first = await build(
      store: OrganizeStore(file: storeFile),
      owned: false,
    );
    await first.waitForOrganize();
    await first.setAutoOrganize(true);
    final path = await importAudio(first, 'restart');
    // Killed before anything ran: the queue is all that survives.
    first.organizeStore.queued
      ..clear()
      ..add(path);
    await first.organizeStore.save();
    await first.organizeStore.idle;
    first.dispose();

    final second = await build(store: OrganizeStore(file: storeFile));
    second.exportedPaths.add(path);
    await until(
      () => second.organizeStatusFor(path).stage == OrganizeStage.done,
    );
    expect(second.autoOrganize, isTrue);
    await second.waitForOrganize();
    await second.organizeStore.idle;
  });

  testWidgets('the detail page asks before resending an unknown request', (
    tester,
  ) async {
    summarizer.timeouts = 1;
    late RecorderController c;
    late String path;
    await tester.runAsync(() async {
      c = await build();
      await c.waitForOrganize();
      await c.setAutoOrganize(true);
      path = await importAudio(c, 'detail');
      await until(
        () => c.organizeStatusFor(path).stage == OrganizeStage.needsCheck,
      );
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          home: RecordingDetailScreen(
            reference: RecordingReference(path: path),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('自动整理暂停：结果待核实'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('organize-retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('先不'));
    await tester.pumpAndSettle();
    expect(summarizer.calls, 1);

    await tester.tap(find.byKey(const ValueKey('organize-retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('organize-retry-confirm')));
    await tester.pump();
    for (
      var i = 0;
      i < 100 && c.organizeStatusFor(path).stage != OrganizeStage.done;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(summarizer.calls, 2);
    expect(find.byKey(const ValueKey('organize-banner')), findsNothing);
  });

  test('a transcription still running is not reported as unknown', () async {
    apple.hold = Completer<void>();
    final c = await build();
    await c.waitForOrganize();
    await c.setAutoOrganize(true);
    final path = await importAudio(c, 'running');
    await until(() => apple.calls == 1);

    expect(c.organizeStatusFor(path).stage, OrganizeStage.transcribing);
    apple.hold!.complete();
    await until(() => c.organizeStatusFor(path).stage == OrganizeStage.done);
  });
}
