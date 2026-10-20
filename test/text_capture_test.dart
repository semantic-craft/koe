import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/platform/phone_mic_stream.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

/// One second of 16 kHz mono PCM16.
const _second = 32000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late _Mic mic;
  late _FileStt fileStt;
  late List<_Stream> streams;
  late bool offline;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-text-capture-');
    mic = _Mic();
    fileStt = _FileStt();
    streams = [];
    offline = false;
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  Directory spoolDir() => Directory('${directory.path}/text_capture');
  File minutesFile() => File('${directory.path}/minutes.json');

  RecorderController build({bool disposeAtEnd = true}) {
    final controller = RecorderController(
      loadPersistedState: false,
      analysisController: RecordingAnalysis(inMemory: true),
      qwenSpeech: fileStt..apiKeyOverride = 'test-key',
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${directory.path}/imports'),
      minutesStore: MinutesDocumentStore(file: minutesFile()),
      placeCapture: _NoPlace(),
      phoneRecordingEnabled: true,
      micStream: mic,
      speechStream: (_) {
        final stream = _Stream(offline: offline);
        streams.add(stream);
        return stream;
      },
    );
    if (disposeAtEnd) addTearDown(controller.dispose);
    return controller;
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  bool noSpools() =>
      !spoolDir().existsSync() ||
      spoolDir().listSync().whereType<File>().isEmpty;

  test(
    'a dropped connection reconnects and resends the unfinished sentence',
    () async {
      final controller = build();
      expect(await controller.startTextCapture(), isTrue);
      await until(() => controller.textCaptureConnected);

      mic.speak(_second);
      await until(() => streams.first.received == _second);
      streams.first.emit('第一句。', speechFinal: true);
      mic.speak(_second ~/ 2);
      await until(() => streams.first.received == _second + _second ~/ 2);
      streams.first.emit('第一句。\n第二');
      await Future<void>.delayed(Duration.zero);
      expect(controller.textCaptureText, '第一句。\n第二');

      streams.first.fail();
      await until(() => streams.length == 2 && streams[1].received > 0);
      // Only the speech after the finished sentence goes out again.
      await until(() => streams[1].received == _second ~/ 2);
      streams[1].emit('第二句说完了。', speechFinal: true);
      streams[1].finalText = '第二句说完了。';

      final outcome = await controller.stopTextCapture();

      expect(outcome!.document!.bodyText, '第一句。\n第二句说完了。');
      expect(outcome.document!.textOnly, isTrue);
      expect(outcome.pendingSeconds, 0);
      expect(controller.minutesDocuments.single.warning, isNull);
      expect(controller.library.assets, isEmpty);
      expect(noSpools(), isTrue);
    },
  );

  test(
    'speech with no network is recognized from the phone after stopping',
    () async {
      offline = true;
      final controller = build();
      expect(await controller.startTextCapture(), isTrue);
      mic.speak(_second * 2);
      await until(() => controller.textCaptureElapsed.inSeconds == 2);
      expect(controller.textCaptureConnected, isFalse);
      fileStt.reply = '地铁里说的话。';

      final outcome = await controller.stopTextCapture();
      expect(outcome!.pendingSeconds, 2);

      await until(() => controller.minutesDocuments.single.warning == null);
      expect(controller.minutesDocuments.single.bodyText, '地铁里说的话。');
      expect(fileStt.calls, 1);
      expect(controller.library.assets, isEmpty);
      await until(noSpools);
    },
  );

  test('a capture cut off by a crash is finished on the next launch', () async {
    final first = build(disposeAtEnd: false);
    expect(await first.startTextCapture(), isTrue);
    await until(() => first.textCaptureConnected);
    mic.speak(_second);
    await until(() => streams.first.received == _second);
    streams.first.emit('崩溃前说完的。', speechFinal: true);
    await until(
      () => first.minutesDocuments.any((d) => d.bodyText == '崩溃前说完的。'),
    );
    mic.speak(_second);
    await until(() => streams.first.received == _second * 2);
    // Let the draft's position reach disk, then kill without stopping.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    first.dispose();

    fileStt.reply = '崩溃后没来得及识别的。';
    mic = _Mic();
    final second = build();
    await second.waitForMinutesDocuments();
    await until(() => second.minutesDocuments.single.warning == null);

    expect(second.minutesDocuments.single.bodyText, '崩溃前说完的。\n崩溃后没来得及识别的。');
    expect(fileStt.calls, 1);
    await until(noSpools);
  });

  test('keeping the audio saves an original that carries the text', () async {
    final controller = build();
    expect(await controller.startTextCapture(), isTrue);
    await until(() => controller.textCaptureConnected);
    mic.speak(_second);
    await until(() => streams.first.received == _second);
    streams.first.emit('留着原声。', speechFinal: true);
    streams.first.finalText = '留着原声。';

    final outcome = await controller.stopTextCapture(keepAudio: true);

    final path = outcome!.recordingPath!;
    expect(File(path).lengthSync(), 44 + _second);
    expect(controller.transcriptForPath(path), '留着原声。');
    expect(controller.minutesDocuments, isEmpty);
    expect(noSpools(), isTrue);
  });
  testWidgets('new record offers text-only capture and saves its text', (
    tester,
  ) async {
    final controller = (await tester.runAsync(() async => build()))!;
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue);
    }

    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-record-text-capture')));
    await settle(() => controller.textCaptureConnected);
    expect(find.text('纯文字记录中'), findsOneWidget);

    streams.first.emit('界面上看得到的话。', speechFinal: true);
    streams.first.finalText = '界面上看得到的话。';
    await tester.pump();
    expect(find.text('界面上看得到的话。'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('stop-text-capture')));
    await settle(() => !controller.textCaptureActive);
    await tester.pumpAndSettle();
    expect(find.text('文字已保存到资料'), findsOneWidget);
    expect(controller.minutesDocuments.single.bodyText, '界面上看得到的话。');
  });
}

class _Mic implements PhoneMicStream {
  StreamController<Uint8List>? _samples;

  void speak(int bytes) => _samples!.add(Uint8List(bytes));

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => const Stream.empty();

  @override
  Future<Stream<Uint8List>> start() async {
    _samples = StreamController<Uint8List>();
    return _samples!.stream;
  }

  @override
  Future<void> stop() async {
    await _samples?.close();
  }

  @override
  Future<void> dispose() async {}
}

class _Stream implements SttStreamSession {
  _Stream({required this.offline});

  final bool offline;
  final _events = StreamController<SttStreamEvent>.broadcast();
  bool _ready = false;
  int received = 0;
  String? finalText;

  void emit(String text, {bool speechFinal = false}) => _events.add(
    SttStreamEvent(type: 'partial', text: text, speechFinal: speechFinal),
  );

  void fail() {
    _ready = false;
    _events.add(const SttStreamEvent(type: 'error', error: 'dropped'));
  }

  @override
  Stream<SttStreamEvent> get events => _events.stream;

  @override
  bool get isOpen => _ready;

  @override
  bool get isServerReady => _ready;

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    if (offline) throw const SocketException('offline');
    _ready = true;
  }

  @override
  void sendPcm(Uint8List pcm16le) => received += pcm16le.length;

  @override
  void finalizeUtterance() {}

  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _ready = false;
    return SttStreamEvent(type: 'done', text: finalText ?? '', isFinal: true);
  }

  @override
  Future<void> close() async => _ready = false;

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

class _FileStt extends QwenSttService {
  String reply = '';
  int calls = 0;

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
    calls++;
    return SttResult(text: reply);
  }
}

class _NoPlace implements PlaceCapture {
  @override
  Future<RecordingPlace?> capture() async => null;
}
