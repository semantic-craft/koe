import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/main.dart';
import 'package:koe/platform/answer_speaker.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/widgets/hold_to_talk.dart';

/// Hold-to-talk (#142): the entry decides what a take becomes, cancel sends
/// nothing, and a spoken question survives failures and restarts.
void main() {
  late Directory directory;
  late _Mic mic;
  late _Stt stt;
  late _Assistant assistant;
  late _Speaker speaker;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-hold-');
    mic = _Mic();
    stt = _Stt();
    assistant = _Assistant();
    speaker = _Speaker();
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  File askFile() => File('${directory.path}/ask.json');

  Future<RecorderController> build(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final c = RecorderController(
          loadPersistedState: false,
          analysisController: RecordingAnalysis(inMemory: true),
          qwenSpeech: stt..apiKeyOverride = 'test-key',
          contextAnalysisService: assistant,
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${directory.path}/imports'),
          phoneRecorder: mic,
          phoneRecordingEnabled: true,
          askStore: AskStore(file: askFile()),
          answerSpeaker: speaker,
        );
        final source = '${directory.path}/1760850000.wav';
        await File(source).writeAsBytes([1, 2, 3, 4]);
        c.exportedPaths.add(source);
        c.rememberTranscript(
          source,
          '装修师傅说下周一开工。',
          segments: const [
            TranscriptSegment(text: '装修师傅说下周一开工。', start: Duration.zero),
          ],
        );
        await c.contextItems.load();
        await c.asks.load();
        return c;
      }))!;

  /// Pumps real async work (file writes, hashing) until [done] holds.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done(), isTrue);
    // Let the notification that follows the awaited save reach the screen.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Presses [button], keeps holding past the tap threshold, optionally
  /// slides, then lifts the finger.
  Future<void> hold(
    WidgetTester tester,
    RecorderController c,
    Finder button, {
    Offset slide = Offset.zero,
  }) async {
    final gesture = await tester.startGesture(tester.getCenter(button));
    await settle(tester, () => c.voiceHoldTarget != null);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    if (slide != Offset.zero) {
      await gesture.moveBy(slide);
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  Future<void> openAsk(WidgetTester tester, RecorderController c) async {
    await tester.tap(find.byKey(const ValueKey('ask-koe')));
    await tester.pumpAndSettle();
    await settle(tester, () => c.asks.sessions.isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('ask-voice-toggle')));
    await tester.pump();
  }

  final askButton = find.byKey(const ValueKey('ask-hold-to-talk'));

  testWidgets('in Ask Koe a held question is recognized and answered; '
      'sliding up sends nothing', (tester) async {
    final c = await build(tester);
    addTearDown(c.dispose);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    await openAsk(tester, c);

    // A diarizing engine labels the speaker; the question is only the words.
    stt.reply = '说话人 1：装修师傅说什么时候开工';
    assistant.reply = '下周一开工 [S1]。';
    await hold(tester, c, askButton);
    await settle(
      tester,
      () =>
          c.asks.sessions.first.messages.any(
            (m) => m.role == AskRole.koe && m.status == AskStatus.done,
          ) &&
          !c.askBusy(c.asks.sessions.first.id),
    );
    await tester.pump();
    expect(find.text('装修师傅说什么时候开工'), findsOneWidget);
    expect(find.text('语音识别 · 已发送'), findsOneWidget);
    expect(find.textContaining('下周一开工'), findsWidgets);
    expect(assistant.instructions.single, contains('装修师傅说什么时候开工'));
    final askedPath = stt.paths.single;
    expect(File(askedPath).existsSync(), isFalse);
    // Saved, not just shown: a reload sees the voice question and no clip.
    final reloaded = AskStore(file: askFile());
    await tester.runAsync(reloaded.load);
    final saved = reloaded.sessions.first;
    expect(saved.voice, isNull);
    expect(saved.messages.first.viaVoice, isTrue);
    // A synthetic voice reads nothing unless the user turned it on.
    expect(speaker.spoken, isEmpty);

    // Mid-hold the take is being recorded, not a waiting question: no
    // retry card, and the button stays live under the finger.
    final gesture = await tester.startGesture(tester.getCenter(askButton));
    await settle(tester, () => c.asks.sessions.first.voice != null);
    expect(find.byKey(const ValueKey('ask-voice-clip')), findsNothing);
    expect(tester.widget<HoldToTalkButton>(askButton).enabled, isTrue);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await gesture.up();
    await settle(
      tester,
      () => mic.cancelled == 1 && !File(mic.path!).existsSync(),
    );
    await tester.pump();
    expect(stt.paths, hasLength(1));
    expect(c.asks.sessions.first.messages, hasLength(2));
    expect(c.asks.sessions.first.voice, isNull);
    expect(File(mic.path!).existsSync(), isFalse);
  });

  testWidgets('a failed recognition keeps the spoken question, which comes '
      'back after a restart and can be sent then', (tester) async {
    var c = await build(tester);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    await openAsk(tester, c);

    stt.failure = const SocketException('offline');
    await hold(tester, c, askButton);
    await settle(tester, () => c.asks.sessions.first.voice?.error != null);
    await tester.pump();
    expect(find.textContaining('网络连接失败，这句话已保留'), findsOneWidget);
    expect(c.asks.sessions.first.messages, isEmpty);
    final clip = c.asks.sessions.first.voice!.path;
    expect(File(clip).existsSync(), isTrue);

    await tester.pumpWidget(const SizedBox());
    var written = false;
    unawaited(c.asks.idle.then((_) => written = true));
    await settle(tester, () => written);
    // The next launch reads only what reached the disk.
    addTearDown(c.dispose);
    stt
      ..failure = null
      ..reply = '开工时间定了吗';
    assistant.reply = '下周一 [S1]。';
    c = await build(tester);
    addTearDown(c.dispose);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    await openAsk(tester, c);
    expect(find.textContaining('网络连接失败，这句话已保留'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ask-voice-retry')));
    await settle(
      tester,
      () =>
          c.asks.sessions.first.messages.any(
            (m) => m.role == AskRole.koe && m.status == AskStatus.done,
          ) &&
          !c.askBusy(c.asks.sessions.first.id),
    );
    await tester.pump();
    expect(find.text('开工时间定了吗'), findsOneWidget);
    expect(find.byKey(const ValueKey('ask-voice-clip')), findsNothing);
    expect(File(clip).existsSync(), isFalse);
  });

  testWidgets('without microphone permission nothing is recorded and typing '
      'still sends the question', (tester) async {
    mic.permission = false;
    final c = await build(tester);
    addTearDown(c.dispose);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    await openAsk(tester, c);
    final gesture = await tester.startGesture(tester.getCenter(askButton));
    await settle(tester, () => c.voiceInputErrors[VoiceTarget.ask] != null);
    await gesture.up();
    await tester.pump();
    expect(find.textContaining('没有麦克风权限'), findsOneWidget);
    expect(mic.path, isNull);
    expect(c.asks.sessions.first.voice, isNull);

    assistant.reply = '下周一 [S1]。';
    await tester.tap(find.byKey(const ValueKey('ask-voice-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('ask-input')), '什么时候开工');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-send')));
    await settle(tester, () => assistant.instructions.isNotEmpty);
  });

  testWidgets('a held note is saved as an original and transcribed, and the '
      'command in it is not carried out', (tester) async {
    final c = await build(tester);
    addTearDown(c.dispose);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    final noteButton = find.byKey(const ValueKey('new-record-hold-to-talk'));

    // Cancelled: no material, no file.
    await hold(tester, c, noteButton, slide: const Offset(0, -120));
    await settle(
      tester,
      () => mic.cancelled == 1 && !File(mic.path!).existsSync(),
    );
    expect(c.library.assets, isEmpty);
    expect(File(mic.path!).existsSync(), isFalse);

    stt.reply = '记一下，把这份整理交给代理准备方案';
    await hold(tester, c, noteButton);
    await settle(tester, () => c.transcriptForPath(mic.path!) != null);
    await tester.pump();
    final asset = c.library.assets.single;
    expect(asset.displayName, startsWith('语音记录 '));
    expect(asset.path, mic.path);
    expect(find.text('已保存为原件 · 已转写'), findsOneWidget);
    expect(find.text('记一下，把这份整理交给代理准备方案'), findsOneWidget);
    // Saved as material only: nothing was asked, answered or turned into work.
    expect(c.asks.sessions, isEmpty);
    expect(assistant.instructions, isEmpty);
    expect(c.todos.todos, isEmpty);
  });

  testWidgets('a hand-off request is answered as not open yet without asking '
      'the model; read-aloud is opt-in, labeled synthetic and stoppable', (
    tester,
  ) async {
    final c = await build(tester);
    addTearDown(c.dispose);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    await openAsk(tester, c);
    await tester.tap(find.byKey(const ValueKey('ask-voice-toggle')));
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('ask-input')),
      '把装修的事交给代理去办',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-send')));
    await settle(tester, () => c.asks.sessions.first.messages.length == 2);
    await tester.pump();
    expect(find.textContaining('外部交办暂未开放'), findsOneWidget);
    expect(find.text('未执行'), findsOneWidget);
    expect(assistant.instructions, isEmpty);

    // Someone else's words in quotes are a question about them.
    await tester.tap(find.byKey(const ValueKey('ask-read-aloud')));
    await tester.pump();
    speaker.hold = Completer<void>();
    assistant.reply = '师傅说下周一开工 [S1]。';
    await tester.enterText(
      find.byKey(const ValueKey('ask-input')),
      '师傅说「交给代理去办」是什么时候开工？',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ask-send')));
    await settle(tester, () => speaker.spoken.isNotEmpty);
    await tester.pump();
    expect(assistant.instructions, hasLength(1));
    expect(speaker.spoken.single, '师傅说下周一开工。');
    expect(find.text('合成语音朗读中，不是录音原声'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ask-stop-speaking')));
    await tester.pump();
    expect(speaker.stopped, 1);
    expect(find.text('合成语音朗读中，不是录音原声'), findsNothing);
  });
}

class _Assistant implements AnalysisService {
  final List<String> instructions = [];
  String reply = '';

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    instructions.add(instruction);
    return reply;
  }

  @override
  void dispose() {}
}

class _Stt extends QwenSttService {
  final paths = <String>[];
  String reply = '';
  Object? failure;

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    paths.add(path);
    if (failure != null) throw failure!;
    return SttResult(text: reply, sourcePath: path);
  }
}

class _Speaker implements AnswerSpeaker {
  final spoken = <String>[];
  int stopped = 0;
  Completer<void>? hold;

  @override
  bool get available => true;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    await hold?.future;
  }

  @override
  Future<void> stop() async {
    stopped++;
    if (hold?.isCompleted == false) hold!.complete();
  }
}

/// Writes a real WAV on stop so the save path runs on actual bytes.
class _Mic implements PhoneRecorder {
  bool permission = true;
  String? path;
  int cancelled = 0;
  final _states = StreamController<PhoneMicState>.broadcast();

  @override
  Future<bool> requestPermission() async => permission;

  @override
  Stream<PhoneMicState> get states => _states.stream;

  @override
  Future<void> start(String path) async {
    this.path = path;
    await File(path).writeAsBytes(_wav(0));
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    await File(path!).writeAsBytes(_wav(64000));
  }

  @override
  Future<void> cancel() async {
    cancelled++;
  }

  @override
  Future<void> dispose() async => _states.close();
}

Uint8List _wav(int dataBytes) {
  final bytes = ByteData(44 + dataBytes);
  void tag(int at, String value) {
    for (var i = 0; i < 4; i++) {
      bytes.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 16000, Endian.little);
  bytes.setUint32(28, 32000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < dataBytes; i++) {
    bytes.setUint8(44 + i, i % 251);
  }
  return bytes.buffer.asUint8List();
}
