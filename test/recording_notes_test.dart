import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recording_bookmarks.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:path/path.dart' as p;

import 'support/wav_fixture.dart';

/// Notes and highlights made while recording (#400): they become the take's
/// bookmarks, survive a kill, and reach the model that writes summaries and
/// minutes.
void main() {
  late Directory directory;
  late Directory imports;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-notes-');
    imports = Directory('${directory.path}/imports');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  group('while recording', () {
    late _Mic mic;
    late RecorderController controller;

    RecorderController build() {
      mic = _Mic();
      return RecorderController(
        loadPersistedState: false,
        topicsEnabled: true,
        libraryDirectory: imports,
        phoneRecorder: mic,
        phoneRecordingEnabled: true,
        placeCapture: _NoPlace(),
      );
    }

    Future<void> startRecording(WidgetTester tester) async {
      controller = (await tester.runAsync(() async => build()))!;
      addTearDown(controller.dispose);
      await tester.pumpWidget(KoeApp(controller: controller));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      await tester.tap(find.byKey(const ValueKey('new-recording')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-record-phone')));
      await settle(tester, () => controller.phoneRecordingActive);
    }

    final notes = find.byKey(const ValueKey('phone-recording-notes'));
    final mark = find.byKey(const ValueKey('mark-phone-recording-highlight'));

    testWidgets(
      'each note line and a ⌘B highlight are saved at their recording times',
      (tester) async {
        await startRecording(tester);

        await tester.enterText(notes, '先和法务确认合同');
        await tester.pump();
        // The recording clock is the wall clock, so let real time pass.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1100)),
        );
        final first = tester.widget<TextField>(notes).controller!.text;
        await tester.enterText(notes, '$first\n下周三发布');
        // Pressed while typing, so it must not end up in the notes.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(
          tester.widget<TextField>(notes).controller!.text,
          matches(RegExp(r'^\[00:0\d\] 先和法务确认合同\n\[00:0\d\] 下周三发布$')),
        );
        expect(find.textContaining('已标 1 处'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('stop-phone-recording')));
        List<RecordingBookmark> saved() => controller.library.assets.isEmpty
            ? const []
            : controller.bookmarksFor(
                RecordingReference(path: controller.library.assets.single.path),
              );
        await settle(tester, () => saved().length == 3);

        final [note1, note2, highlight] = saved();
        expect(note1.note, '先和法务确认合同');
        expect(note2.note, '下周三发布');
        expect(note1.position, lessThan(note2.position));
        expect(
          note2.position,
          greaterThanOrEqualTo(const Duration(seconds: 1)),
        );
        expect(
          highlight.position,
          greaterThanOrEqualTo(const Duration(milliseconds: 1100)),
        );
        expect(highlight.note, '录音中标的重点');
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets('a take cut off by a kill comes back with its notes', (
      tester,
    ) async {
      await startRecording(tester);
      final take = mic.path!;
      final draft = File(p.setExtension(take, '.notes.json'));

      await tester.tap(mark);
      await tester.enterText(notes, '预算砍到八十万');
      await settle(
        tester,
        () =>
            draft.existsSync() && draft.readAsStringSync().contains('预算砍到八十万'),
      );

      // The process dies: the take holds audio its header never counted, and
      // the next launch starts from what is on disk.
      final relaunched = (await tester.runAsync(() async {
        await File(take).writeAsBytes(
          wavBytes(List.filled(32000, 0x10), declaredDataSize: 0, riffSize: 0),
        );
        final next = build();
        await next.waitForPhoneTakeRecovery();
        return next;
      }))!;
      addTearDown(relaunched.dispose);

      expect(relaunched.library.assetForPath(take), isNotNull);
      expect(
        relaunched
            .bookmarksFor(RecordingReference(path: take))
            .map((bookmark) => bookmark.note),
        unorderedEquals(['预算砍到八十万', '录音中标的重点']),
      );
      expect(draft.existsSync(), isFalse);
    });

    testWidgets('pinyin still being composed is left alone until it commits', (
      tester,
    ) async {
      await startRecording(tester);
      await tester.showKeyboard(notes);
      String field() => tester.widget<TextField>(notes).controller!.text;

      // Rewriting the field now would end the composition and leave the
      // letters in the notes.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'nihao',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        ),
      );
      await tester.pump();
      expect(field(), 'nihao');

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '你好',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      expect(field(), matches(RegExp(r'^\[00:0\d\] 你好$')));
    });
  });

  testWidgets('minutes are written with the bookmarks, and stay current', (
    tester,
  ) async {
    final service = _Minutes();
    final manager = RecordingAnalysis(inMemory: true, service: service);
    final controller = _Meeting(manager);
    addTearDown(controller.dispose);
    const reference = RecordingReference(fileId: 1);
    Future<void> show() async {
      await tester.pumpWidget(
        MaterialApp(
          home: MinutesPanel(controller: controller, reference: reference),
        ),
      );
      await tester.pumpAndSettle();
    }

    bool shown(String title) => find.text(title).evaluate().isNotEmpty;

    await show();
    await tester.tap(find.text('生成纪要'));
    await settle(tester, () => shown('项目会议 1'));
    // Without bookmarks the model gets what it always got.
    expect(service.inputs.single, '[S1] 讨论发布，请核对发布。');

    final now = DateTime(2026, 10, 22, 9);
    final key = controller.recordingKeyFor(reference);
    await controller.bookmarks.addAll([
      RecordingBookmark(
        id: 'note',
        recordingKey: key,
        position: const Duration(seconds: 2),
        note: '发布前先问法务',
        createdAt: now,
        updatedAt: now,
      ),
      RecordingBookmark(
        id: 'highlight',
        recordingKey: key,
        position: const Duration(seconds: 9),
        createdAt: now,
        updatedAt: now,
      ),
    ]);
    await show();
    expect(shown('项目会议 1'), isTrue);
    expect(find.textContaining('已过期'), findsNothing);

    await tester.tap(find.text('重新生成纪要'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '重新生成'));
    await settle(tester, () => shown('项目会议 2'));
    final input = service.inputs.last;
    expect(input, contains('[00:02] 发布前先问法务'));
    // A highlight carries the sentence being said at that moment.
    expect(input, contains('[00:09] 请核对发布。'));
    expect(input, endsWith('\n[S1] 讨论发布，请核对发布。'));
    expect(input.indexOf('发布前先问法务'), lessThan(input.indexOf('[S1]')));
    expect(find.textContaining('已过期'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('the automatic summary is written with the bookmarks', () async {
    final apple = _Apple()..hold = Completer<void>();
    final summarizer = _Summary();
    final c =
        RecorderController(
            loadPersistedState: false,
            appleSpeech: apple,
            qwenSpeech: QwenSttService()..apiKeyOverride = 'test-key',
            analysisController: RecordingAnalysis(
              service: summarizer,
              inMemory: true,
            ),
            contextAnalysisService: _NoTodos(),
            transcriptPersister: ({bool strict = false}) async {},
            libraryDirectory: imports,
          )
          ..speechProvider = SttProvider.apple
          ..appleSourceLanguage = 'zh-CN';
    addTearDown(c.dispose);
    await c.refreshAppleCapabilities();
    await c.waitForOrganize();
    await c.setAutoOrganize(true);

    final source = File('${directory.path}/meeting.wav');
    await source.writeAsBytes(wavBytes(List.filled(3200, 0x20)));
    final path = (await c.importLocalAudio(source.path)).path;
    await _until(() => apple.calls == 1);
    final now = DateTime(2026, 10, 22, 9);
    await c.bookmarks.add(
      RecordingBookmark(
        id: 'note',
        recordingKey: c.recordingKeyFor(RecordingReference(path: path)),
        position: Duration.zero,
        note: '牛奶要低脂的',
        createdAt: now,
        updatedAt: now,
      ),
    );
    apple.hold!.complete();
    await _until(() => c.organizeStatusFor(path).stage == OrganizeStage.done);

    final input = summarizer.inputs.single;
    expect(input, contains('[00:00] 牛奶要低脂的'));
    expect(input, endsWith('\n[S1] 我明天去买牛奶。'));
  });
}

/// Pumps real async work (file writes, hashing) until [done] holds.
Future<void> settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue);
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

/// Writes a header-only WAV on start and real audio on stop.
class _Mic implements PhoneRecorder {
  String? path;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => const Stream.empty();

  @override
  Future<void> start(String path) async {
    this.path = path;
    await File(path).writeAsBytes(wavBytes(const []));
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    await File(path!).writeAsBytes(wavBytes(List.filled(64000, 0x10)));
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

/// A meeting whose transcript has two timed sentences.
class _Meeting extends RecorderController {
  _Meeting(RecordingAnalysis manager)
    : super(loadPersistedState: false, analysisController: manager);

  @override
  String get analysisApiKey => 'test-key';
  @override
  String analysisKey(RecordingReference ref) => 'file:1';
  @override
  RecordingViewData recordingView(RecordingReference ref) => RecordingViewData(
    reference: ref,
    title: '短录音',
    text: '讨论发布，请核对发布。',
    path: '/1.wav',
    segments: const [
      TranscriptSegment(
        text: '讨论发布，',
        start: Duration.zero,
        end: Duration(seconds: 4),
      ),
      TranscriptSegment(
        text: '请核对发布。',
        start: Duration(seconds: 8),
        end: Duration(seconds: 12),
      ),
    ],
  );
  @override
  Duration? localDurationForPath(String path) => const Duration(seconds: 30);
  @override
  bool recordingAudioChanged(RecordingReference ref) => false;
}

/// Minutes model; keeps every input it was given.
class _Minutes implements AnalysisService {
  final inputs = <String>[];

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    inputs.add(source);
    return jsonEncode({
      'schemaVersion': 2,
      'title': '项目会议 ${inputs.length}',
      'overview': '讨论发布',
      'topics': [
        {
          'text': '发布安排',
          'sources': ['S1'],
        },
      ],
      'decisions': [],
      'actions': [],
      'questions': [],
    });
  }

  @override
  void dispose() {}
}

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

/// Summary model; keeps every input it was given.
class _Summary implements AnalysisService {
  final inputs = <String>[];

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    if (instruction.contains('结构化会议纪要')) {
      return jsonEncode({
        'schemaVersion': 2,
        'title': '日常安排',
        'overview': '我明天去买牛奶。',
        'topics': [
          {
            'text': '日常安排',
            'sources': ['S1'],
            'summary': '我明天去买牛奶。',
            'points': [
              {'text': '我明天去买牛奶 [S1]', 'sources': ['S1']},
            ],
          },
        ],
        'terms': <Object>[],
        'decisions': <Object>[],
        'actions': <Object>[],
        'questions': <Object>[],
      });
    }
    inputs.add(source);
    return '要点：买牛奶';
  }

  @override
  void dispose() {}
}

class _NoTodos implements AnalysisService {
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => '{"items":[],"updates":[]}';

  @override
  void dispose() {}
}
