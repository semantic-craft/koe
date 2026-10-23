// Screenshot tour of the main phone pages with sample data, for before/after
// comparisons of visual changes. It asserts nothing and is not part of
// `check`. Run on a booted iOS simulator:
//
//   flutter drive -d <simulator-id> \
//     --driver=test_driver/screenshot_driver.dart \
//     --target=integration_test/screenshots/app_tour.dart
//
// PNGs land in build/screenshots/ (override with KOE_SCREENSHOT_DIR).
// Everything lives in a temporary folder and in-memory stores; no BLE device,
// credential or personal data is touched.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/answer_speaker.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/ask_koe_screen.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recording_bookmarks.dart';
import 'package:koe/ui/screens/minutes_document_screen.dart';
import 'package:koe/ui/screens/new_recording_sheet.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/screens/todos_screen.dart';
import 'package:koe/ui/widgets/scan_sheet.dart';

class _Assistant implements AnalysisService {
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    final label = RegExp(r'\[(S\d+)\][^\n]*开工').firstMatch(source)?.group(1);
    return label == null ? '没有找到相关的话。' : '师傅说下周一开工 [$label]。';
  }

  @override
  void dispose() {}
}

/// On-device translation stand-in: canned English for the sample sentences.
class _Translator extends AppleSpeechService {
  static const _english = {
    '这周先把厨房的水电定下来。': 'Let’s settle the kitchen plumbing and wiring this week.',
    '水电我周三能出图。': 'I can have the drawings ready on Wednesday.',
    '瓷砖样品明天到。': 'The tile samples arrive tomorrow.',
    '那我周四去看样品。': 'Then I’ll look at the samples on Thursday.',
    '（听不清）': '(inaudible)',
    '预算先按二十万算。': 'Let’s plan on a budget of 200,000 for now.',
    '可以，超出的部分再商量。': 'Fine, we’ll discuss anything over that.',
  };

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async => _capabilities;

  @override
  Future<String> translate(
    String text, {
    required String sourceLanguage,
    required String targetLanguage,
  }) async =>
      _english[text.trim()] ??
      'We talked about moving over dinner with friends.';
}

/// Speech recognition stand-in for hold-to-talk: never reaches the network.
class _TourStt extends QwenSttService {
  String reply = '';
  Object? failure;

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    int? expectedSpeakers,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    if (failure != null) throw failure!;
    return SttResult(text: reply, sourcePath: path);
  }
}

/// Microphone stand-in: writes a second of silence on stop.
class _TourMic implements PhoneRecorder {
  String? path;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => const Stream.empty();

  @override
  Future<void> start(String path) async {
    this.path = path;
    await File(path).writeAsBytes(_silentWav(Duration.zero));
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    await File(path!).writeAsBytes(_silentWav(const Duration(seconds: 2)));
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

/// Keeps the tour off the system location prompt.
class _TourPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}

class _TourSpeaker implements AnswerSpeaker {
  final Completer<void> _done = Completer<void>();

  @override
  bool get available => true;

  @override
  Future<void> speak(String text) => _done.future;

  @override
  Future<void> stop() async {
    if (!_done.isCompleted) _done.complete();
  }
}

const _capabilities = AppleSpeechCapabilities(
  supported: true,
  speechStatus: SpeechResourceStatus.ready,
  translationStatus: SpeechResourceStatus.ready,
  translationLanguages: [
    SpeechLanguage(code: 'zh-Hans', name: '简体中文'),
    SpeechLanguage(code: 'en-US', name: 'English'),
  ],
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone page tour', (tester) async {
    final directory = await Directory.systemTemp.createTemp('koe-tour-');
    final topics = TopicStore(inMemory: true);
    final stt = _TourStt();
    final c = RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: topics,
      analysisController: RecordingAnalysis(inMemory: true),
      qwenSpeech: stt..apiKeyOverride = 'tour-key',
      appleSpeech: _Translator(),
      contextAnalysisService: _Assistant(),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
      phoneRecorder: _TourMic(),
      phoneRecordingEnabled: true,
      answerSpeaker: _TourSpeaker(),
      placeCapture: _TourPlace(),
    );

    final now = DateTime.now();
    Future<String> add(DateTime at, String? text, {String? name}) async {
      final id = at.millisecondsSinceEpoch ~/ 1000;
      final path = '${directory.path}/${name ?? id}.wav';
      await File(path).writeAsBytes([1, 2, 3, 4]);
      c.exportedPaths.add(path);
      if (text != null) {
        c.rememberTranscript(
          path,
          text,
          segments: [TranscriptSegment(text: text, start: Duration.zero)],
        );
      }
      return path;
    }

    // A 90 s silent WAV with diarized segments for the speaker view: two
    // people overlap once and one sentence has no speaker.
    final meetingAt = now.subtract(const Duration(hours: 5));
    final meeting =
        '${directory.path}/${meetingAt.millisecondsSinceEpoch ~/ 1000}.wav';
    await File(meeting).writeAsBytes(_silentWav(const Duration(seconds: 90)));
    c.exportedPaths.add(meeting);
    TranscriptSegment line(String text, int from, int to, String? who) =>
        TranscriptSegment(
          text: text,
          start: Duration(seconds: from),
          end: Duration(seconds: to),
          speaker: who,
          speakerChanged: who != null,
        );
    final meetingLines = [
      line('这周先把厨房的水电定下来。', 0, 9, '1'),
      line('水电我周三能出图。', 7, 15, '2'),
      line('瓷砖样品明天到。', 18, 24, '1'),
      line('那我周四去看样品。', 25, 31, '2'),
      line('（听不清）', 33, 36, null),
      line('预算先按二十万算。', 40, 52, '1'),
      line('可以，超出的部分再商量。', 55, 66, '2'),
    ];
    c.rememberTranscript(
      meeting,
      meetingLines
          .map((s) => s.speaker == null ? s.text : '说话人 ${s.speaker}：${s.text}')
          .join('\n'),
      segments: meetingLines,
    );
    await c.renameTranscriptSpeaker(meeting, '1', '林舟');

    final morning = now.subtract(const Duration(hours: 3));
    final a = await add(morning, '装修师傅说下周一开工。预算控制在二十万以内。');
    await add(now.subtract(const Duration(hours: 1)), '晚上和朋友吃饭，聊到搬家。');
    await add(now.subtract(const Duration(minutes: 20)), null, name: '散步');
    await c.contextItems.load();
    final move = await c.createProject('搬家', goal: '月底前搬完');
    final renovation = await topics.createTopic(
      kind: TopicKind.general,
      title: '装修',
    );
    final fileKey = 'file:${morning.millisecondsSinceEpoch ~/ 1000}';
    await topics.moveRecording(fileKey, renovation.id);
    c.contextItemsForDay(now);
    await c.setContextItemProjects('recording:$fileKey', [move.id]);
    await c.setContextItemTopics('recording:$fileKey', [renovation.id]);
    for (final (id, title, kind) in [
      ('t1', '周五量房', TodoKind.mine),
      ('t2', '确认开工日期', TodoKind.others),
    ]) {
      await c.todos.put(
        Todo(
          id: id,
          kind: kind,
          title: title,
          owner: kind == TodoKind.others ? '装修师傅' : null,
          source: ContextSource(recordingKey: fileKey),
          quote: '装修师傅说下周一开工。',
          projectIds: [move.id],
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    final session = await c.newAskSession();
    await c.ask(session.id, '装修什么时候开工？');

    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // Flutter on iOS renders into a platform view; switch to an image
    // surface once so takeScreenshot can read pixels.
    await binding.convertFlutterSurfaceToImage();
    await tester.pumpAndSettle();

    Future<void> shot(String name) async {
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await binding.takeScreenshot(name);
    }

    BuildContext shell() => tester.element(find.byType(Scaffold).first);
    Future<void> pushAndShot(
      String name,
      Widget page, {
      bool scrolled = false,
    }) async {
      Navigator.of(shell()).push(MaterialPageRoute<void>(builder: (_) => page));
      await shot(name);
      if (scrolled) {
        final list = find.descendant(
          of: find.byWidget(page),
          matching: find.byType(Scrollable),
        );
        await tester.drag(list.first, const Offset(0, -500));
        await shot('$name-scrolled');
      }
      Navigator.of(shell()).pop();
      await tester.pumpAndSettle();
    }

    await shot('01-today');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await shot('02-today-scrolled');
    await tester.tap(find.byKey(const ValueKey('nav-projects')));
    await shot('03-projects');
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await shot('04-library');
    await tester.tap(find.byKey(ValueKey('recording-row-$a')));
    await shot('05-recording-detail');
    Navigator.of(tester.element(find.byType(RecordingDetailScreen))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-today')));
    await tester.pumpAndSettle();

    await pushAndShot(
      '06-settings',
      const SettingsScreen(showBack: true),
      scrolled: true,
    );
    await pushAndShot('07-ask-koe', const AskKoeScreen());
    await pushAndShot('08-todos', const TodosScreen());

    c.devices = [
      ScannedDevice(
        id: 'tour-d3200',
        name: 'soundcore Work',
        rssi: -52,
        isD3200: true,
      ),
      ScannedDevice(id: 'tour-other', name: 'Other BLE', rssi: -80),
    ];
    showScanDevicesSheet(shell());
    await shot('09-scan-devices');
    Navigator.of(shell()).pop();
    await tester.pumpAndSettle();

    showNewRecordingSheet(shell());
    await shot('10-new-record');
    Navigator.of(shell()).pop();
    await tester.pumpAndSettle();

    final meetingRef = RecordingReference(
      fileId: meetingAt.millisecondsSinceEpoch ~/ 1000,
      path: meeting,
    );
    Navigator.of(shell()).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingDetailScreen(reference: meetingRef),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发言人'));
    await shot('11-speakers');
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -600));
    await shot('12-speakers-segments');
    await tester.ensureVisible(find.byKey(const ValueKey('speaker-segment-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('speaker-segment-3')));
    await shot('13-speakers-source');
    await tester.tap(find.byTooltip('返回发言人'));
    await tester.pumpAndSettle();
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    final empty = RecordingReference(path: '${directory.path}/散步.wav');
    Navigator.of(shell()).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingDetailScreen(reference: empty),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发言人'));
    await shot('14-speakers-no-transcript');
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();

    // #147: sentence-by-sentence translation of the meeting plays the
    // source sentence's audio; edited source and unaligned text read only.
    await c.stopPlayback();
    c.appleCapabilities = _capabilities;
    await c.translateRecording(
      meetingRef,
      sourceLanguage: 'zh-Hans',
      targetLanguage: 'en-US',
    );
    Navigator.of(shell()).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingDetailScreen(reference: meetingRef),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('译文'));
    await shot('15-translation-aligned');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('translation-reader')),
        matching: find.textContaining('samples on Thursday'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await shot('16-translation-plays-source');
    await c.stopPlayback();
    await c.saveManualTranscript(
      meeting,
      c.recordingView(meetingRef).text.replaceFirst('周三', '周二'),
    );
    await shot('17-translation-stale');
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    final dinnerAt = now.subtract(const Duration(minutes: 40));
    final dinner =
        '${directory.path}/${dinnerAt.millisecondsSinceEpoch ~/ 1000}.wav';
    await File(dinner).writeAsBytes(_silentWav(const Duration(seconds: 20)));
    c.exportedPaths.add(dinner);
    c.rememberTranscript(dinner, '晚上和朋友吃饭，聊到搬家。');
    final dinnerRef = RecordingReference(
      fileId: dinnerAt.millisecondsSinceEpoch ~/ 1000,
      path: dinner,
    );
    await c.translateRecording(
      dinnerRef,
      sourceLanguage: 'zh-Hans',
      targetLanguage: 'en-US',
    );
    Navigator.of(shell()).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingDetailScreen(reference: dinnerRef),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('译文'));
    await shot('18-translation-unaligned');
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();

    // #145: export the meeting as a restorable pack, then restore it into a
    // second, empty library ("another phone"), with and without its audio.
    await c.addBookmark(
      meetingRef,
      position: const Duration(seconds: 19),
      segment: meetingLines[2],
      note: '样品到了再定颜色',
    );
    await c.setRecordingPlace(meeting, '杭州市西湖区');
    Navigator.of(shell()).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordingDetailScreen(reference: meetingRef),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出…'));
    await shot('19-export-pack');
    await tester.tap(find.byKey(const ValueKey('material-export-audio')));
    await shot('20-export-pack-with-audio');
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();

    final withAudio = await c.exportMaterialPack(
      meetingRef,
      includeAudio: true,
    );
    final textOnly = await c.exportMaterialPack(
      meetingRef,
      includeAudio: false,
    );
    RecorderController otherPhone(String name) => RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: TopicStore(inMemory: true),
      analysisController: RecordingAnalysis(inMemory: true),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/$name/imports'),
      libraryStore: RecordingLibraryStore(inMemory: true),
      minutesStore: MinutesDocumentStore(inMemory: true),
      bookmarkStore: RecordingBookmarkStore(inMemory: true),
    );
    final restoredPhone = otherPhone('phone-b');
    final restored = (await restoredPhone.importMaterialPack(
      withAudio.path,
    )).path!;
    Navigator.of(shell()).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider<RecorderController>.value(
          value: restoredPhone,
          child: RecordingDetailScreen(
            reference: RecordingReference(
              fileId: restoredPhone.fileIdFromPath(restored),
              path: restored,
            ),
          ),
        ),
      ),
    );
    await shot('21-import-restored');
    await tester.tap(find.byKey(const ValueKey('bookmark-list-button')));
    await shot('22-import-restored-bookmarks');
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    final textPhone = otherPhone('phone-c');
    final minutesId = (await textPhone.importMaterialPack(
      textOnly.path,
    )).minutesId!;
    Navigator.of(shell()).push(
      MaterialPageRoute<void>(
        builder: (_) => ChangeNotifierProvider<RecorderController>.value(
          value: textPhone,
          child: MinutesDocumentScreen(documentId: minutesId),
        ),
      ),
    );
    await shot('23-import-without-audio');
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    restoredPhone.dispose();
    textPhone.dispose();

    // Hold-to-talk (#142).
    Future<TestGesture> press(Finder button) async {
      final gesture = await tester.startGesture(tester.getCenter(button));
      for (var i = 0; i < 20 && c.voiceHoldTarget == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 600));
      return gesture;
    }

    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // Holding animations never settle, so these shots pump a fixed time.
    Future<void> heldShot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      await binding.takeScreenshot(name);
    }

    showNewRecordingSheet(shell());
    await shot('24-new-record-voice');
    final noteButton = find.byKey(const ValueKey('new-record-hold-to-talk'));
    var gesture = await press(noteButton);
    await heldShot('25-new-record-holding');
    stt.reply = '记一下，旅行预算暂定五千。';
    await gesture.up();
    await waitFor(() => find.text('已保存为原件 · 已转写').evaluate().isNotEmpty);
    await shot('26-new-record-saved');
    await tester.tap(find.byKey(const ValueKey('new-record-type')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-record-text')),
      '周六上午去看瓷砖样品',
    );
    await shot('27-new-record-typed');
    Navigator.of(shell()).pop();
    await tester.pumpAndSettle();

    Navigator.of(
      shell(),
    ).push(MaterialPageRoute<void>(builder: (_) => const AskKoeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ask-new-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ask-voice-toggle')));
    await shot('28-ask-voice-mode');
    final askButton = find.byKey(const ValueKey('ask-hold-to-talk'));
    gesture = await press(askButton);
    await heldShot('29-ask-holding');
    await gesture.moveBy(const Offset(0, -120));
    await heldShot('30-ask-cancel-zone');
    await gesture.up();
    await tester.pumpAndSettle();

    stt.failure = const SocketException('offline');
    gesture = await press(askButton);
    await gesture.up();
    await waitFor(
      () => find.byKey(const ValueKey('ask-voice-retry')).evaluate().isNotEmpty,
    );
    await shot('31-ask-voice-kept');
    stt
      ..failure = null
      ..reply = '装修师傅说什么时候开工？';
    await tester.tap(find.byKey(const ValueKey('ask-voice-retry')));
    await waitFor(
      () =>
          find.text('语音识别 · 已发送').evaluate().isNotEmpty &&
          find.textContaining('下周一开工').evaluate().isNotEmpty,
    );
    await shot('32-ask-voice-answered');
    stt.reply = '把装修的事交给代理去办';
    gesture = await press(askButton);
    await gesture.up();
    await waitFor(() => find.textContaining('外部交办暂未开放').evaluate().isNotEmpty);
    await shot('33-ask-delegation-closed');
    await tester.tap(find.byKey(const ValueKey('ask-read-aloud')));
    await tester.pumpAndSettle();
    final answer = c.asks.sessions.first.messages.firstWhere(
      (m) => m.role == AskRole.koe && !m.notice,
    );
    await tester.tap(find.byKey(ValueKey('ask-speak-${answer.id}')));
    await tester.pump(const Duration(milliseconds: 300));
    await binding.takeScreenshot('34-ask-read-aloud');
    await tester.tap(find.byKey(const ValueKey('ask-stop-speaking')));
    Navigator.of(shell()).popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();

    c.dispose();
    topics.dispose();
    await directory.delete(recursive: true);
  });
}

/// 8 kHz 8-bit mono silence, so the app can read a real duration.
Uint8List _silentWav(Duration length) {
  const rate = 8000;
  final samples = rate * length.inSeconds;
  final bytes = ByteData(44 + samples);
  void text(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + samples, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate, Endian.little);
  bytes.setUint16(32, 1, Endian.little);
  bytes.setUint16(34, 8, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, samples, Endian.little);
  for (var i = 0; i < samples; i++) {
    bytes.setUint8(44 + i, 128);
  }
  return bytes.buffer.asUint8List();
}
