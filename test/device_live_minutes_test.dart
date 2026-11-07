import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/ble/ble_service.dart';
import 'package:koe/ble/realtime_stream.dart';
import 'package:koe/platform/answer_speaker.dart';
import 'package:koe/protocol/frame.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/live_minutes_store.dart';
import 'package:koe/state/live_minutes.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/widgets/live_meeting_panel.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

class _Ble extends BleService {
  final packetsController = StreamController<DecodedPacket>.broadcast();
  void stop() => packetsController.add(
    DecodedPacket(
      raw: Uint8List(0),
      statusByte: 1,
      cmdType: 0x18,
      cmdId: 0x82,
      payload: Uint8List.fromList([0]),
    ),
  );
  @override
  Stream<DecodedPacket> get packets => packetsController.stream;
  @override
  Stream<List<ScannedDevice>> get scanResults => const Stream.empty();
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> writeCommand(List<int> frame) async {}
  @override
  Future<void> dispose() => packetsController.close();
}

class _Speech implements SttStreamSession {
  final eventsController = StreamController<SttStreamEvent>.broadcast();
  final finished = Completer<SttStreamEvent?>();
  final finishStarted = Completer<void>();
  void emit(String text) => eventsController.add(
    SttStreamEvent(type: 'partial', text: text, speechFinal: true),
  );
  @override
  Stream<SttStreamEvent> get events => eventsController.stream;
  @override
  bool get isOpen => true;
  @override
  bool get isServerReady => true;
  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {}
  @override
  void sendPcm(Uint8List pcm16le) {}
  @override
  void finalizeUtterance() {}
  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) {
    if (!finishStarted.isCompleted) finishStarted.complete();
    return finished.future;
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() => eventsController.close();
}

class _Apple extends AppleSpeechService {
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
  }) async => SttResult(
    text: '完整录音重新转写，包含最后补充',
    sourcePath: path,
    language: sourceLanguage,
  );
}

class _Qwen extends QwenSttService {
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
  }) async =>
      SttResult(text: '完整录音重新转写，包含最后补充', sourcePath: path, language: 'zh');
}

class _Model implements AnalysisService {
  final fullSources = <String>[];
  final liveSources = <String>[];
  Completer<String>? liveResponse;
  bool failLive = false;
  String minutes(String text) => jsonEncode({
    'schemaVersion': 2,
    'title': '录音豆记录',
    'overview': text,
    'topics': [
      {
        'text': '记录',
        'summary': text,
        'sources': ['S1'],
        'points': [
          {
            'text': text,
            'sources': ['S1'],
          },
        ],
      },
    ],
    'terms': [],
    'decisions': [],
    'actions': [],
    'questions': [],
  });
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    if (instruction.contains('实时增量')) {
      liveSources.add(source);
      if (failLive) throw TimeoutException('provider unavailable');
      return liveResponse == null ? minutes('阶段摘要') : liveResponse!.future;
    }
    if (instruction.contains('结构化会议纪要')) {
      fullSources.add(source);
      return minutes(source.contains('最后补充') ? '包含最后补充' : '缺少末句');
    }
    if (instruction.contains('items')) return '{"items":[],"updates":[]}';
    return '录音摘要';
  }

  @override
  void dispose() {}
}

class _Speaker implements AnswerSpeaker {
  final spoken = <String>[];
  int stopped = 0;

  @override
  bool get available => true;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {
    stopped++;
  }
}

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue, reason: 'expected durable result did not arrive');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Ble ble;
  late _Speech speech;
  late _Model model;
  late RecorderController c;
  late File audio;
  late File analysisFile;
  late File liveFile;
  final opening = '这次记录要讨论产品需求，保留理由和具体例子。' * 15;

  Future<void> start({
    bool localOnly = false,
    bool organize = true,
    bool onDevice = false,
  }) async {
    dir = await Directory.systemTemp.createTemp('koe-device-minutes-');
    ble = _Ble();
    speech = _Speech();
    model = _Model();
    audio = File('${dir.path}/301.wav');
    await audio.writeAsBytes(wavBytes(List.filled(3200, 0)));
    analysisFile = File('${dir.path}/analysis.json');
    liveFile = File('${dir.path}/live.json');
    c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: localOnly,
      ble: ble,
      qwenSpeech: _Qwen()..apiKeyOverride = 'test-key',
      appleSpeech: _Apple(),
      analysisController: RecordingAnalysis(service: model, file: analysisFile),
      contextAnalysisService: model,
      liveMeetingStore: LiveMinutesStore(file: liveFile),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${dir.path}/imports'),
    )..speechProvider = SttProvider.qwen;
    addTearDown(() async {
      if (!speech.finished.isCompleted) speech.finished.complete(null);
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    if (onDevice) {
      c.speechProvider = SttProvider.apple;
      c.appleSourceLanguage = 'zh-CN';
      await c.refreshAppleCapabilities();
    }
    if (organize) await c.setAutoOrganize(true);
    await c.startRecord();
    c.attachSttStreamForTesting(speech);
    c.handleRealtimeStateForTesting(
      RealtimeStreamState(
        active: true,
        fileId: 301,
        path: audio.path,
        bytesReceived: 3200,
      ),
    );
  }

  test('device recording automatically publishes live minutes', () async {
    await start();
    speech.emit(opening);
    await _until(() => c.liveMeetingSegments.isNotEmpty);
    await c.liveMinutes?.tick();
    await _until(() => c.liveMinutes?.active != null);
    expect(c.liveMinutes!.active, contains('阶段摘要'));
    expect(model.fullSources, isEmpty);
    final journal = await LiveMinutesStore(
      file: liveFile,
    ).read(c.liveMeetingId!);
    expect(journal!['active'], contains('阶段摘要'));
  });

  test(
    'full minutes wait for stop and final ASR then survive disk reload',
    () async {
      await start();
      speech.emit(opening);
      await _until(
        () => c
            .recordingView(RecordingReference(path: audio.path))
            .text
            .isNotEmpty,
      );
      await c.waitForOrganize();
      expect(c.organizeStatusFor(audio.path).stage, OrganizeStage.waiting);
      expect(model.fullSources, isEmpty, reason: 'recording text is not final');
      ble.stop();
      await _until(() => !c.recording);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 301, path: audio.path, bytesReceived: 3200),
      );
      await speech.finishStarted.future;
      await c.waitForOrganize();
      expect(model.fullSources, isEmpty, reason: 'last ASR segment is pending');
      speech.finished.complete(
        SttStreamEvent(type: 'done', text: '$opening 最后补充', speechFinal: true),
      );
      final key =
          '${c.analysisKey(RecordingReference(path: audio.path))}/minutes';
      await c.waitForOrganize();
      await _until(() => c.analysis.results[key]?.isDraft == false);
      expect(c.analysis.results[key]!.text, contains('包含最后补充'));
      final reopened = RecordingAnalysis(service: _Model(), file: analysisFile);
      await reopened.load();
      expect(reopened.results[key]!.text, contains('包含最后补充'));
      expect(reopened.results[key]!.isDraft, isFalse);
      reopened.dispose();
    },
  );
  test(
    'late pause packet after stop does not block automatic full minutes finalization',
    () async {
      await start();
      speech.emit(opening);
      await _until(() => c.liveMeetingSegments.isNotEmpty);
      await c.finalizeLiveRecordingAfterHostStopForTesting();
      await _until(() => !c.recording);
      // In-flight device_info response still carrying recordingStatus=1 arrives
      // right before the hardware pause ACK (0x18/0x82 status=2).
      final rawInfo = Uint8List.fromList([
        0x09, 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x4B, 0x00,
        0x01, 0x09, 0x00, 0x30, 0x34, 0x2E, 0x39, 0x32, 0x33, 0x32, 0x30,
        0x30, 0x30, 0x30, 0x37, 0x66, 0x31, 0x64, 0x30, 0x36, 0x36, 0x33,
        0x39, 0x64, 0x00, 0xF1, 0xA3, 0x03, 0x80, 0xD2, 0xA3, 0x03, 0x00,
        0x31, 0x2E, 0x32, 0x2E, 0x32, 0x09, 0x21, 0x21, 0x21, 0x21, 0x21,
        0x21, 0x32, 0x00, 0x01, 0x00, 0x00, 0x01, 0x30, 0x33, 0x2E, 0x30,
        0x36, 0x01, 0x00, 0xBE, 0x2A, 0xEC, 0x6A, 0x00, 0x00, 0x00, 0xD9,
      ]);
      ble.packetsController.add(
        DecodedPacket(
          raw: rawInfo,
          statusByte: 1,
          cmdType: 0x01,
          cmdId: 0x01,
          payload: rawInfo.sublist(9, rawInfo.length - 1),
        ),
      );
      ble.packetsController.add(
        DecodedPacket(
          raw: Uint8List(0),
          statusByte: 1,
          cmdType: 0x18,
          cmdId: 0x82,
          payload: Uint8List.fromList([2]),
        ),
      );
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 301, path: audio.path, bytesReceived: 3200),
      );
      await speech.finishStarted.future;
      speech.finished.complete(
        SttStreamEvent(type: 'done', text: '$opening 最后补充', speechFinal: true),
      );
      final key =
          '${c.analysisKey(RecordingReference(path: audio.path))}/minutes';
      await c.waitForOrganize();
      await _until(() => c.analysis.results[key]?.isDraft == false);
      expect(c.analysis.results[key]!.text, contains('包含最后补充'));
    },
  );
  test(
    'local-only change aborts automatic live text before publication',
    () async {
      await start();
      model.liveResponse = Completer<String>();
      speech.emit(opening);
      await _until(() => c.liveMeetingSegments.isNotEmpty);
      final work = c.liveMinutes!.tick();
      await _until(() => model.liveSources.isNotEmpty);
      c.setMeetingLocalOnly(true);
      expect(c.liveMinutes!.paused, isTrue);
      model.liveResponse!.complete(model.minutes('迟到云结果'));
      await work;
      expect(c.liveMinutes!.active, isNull);
      expect(c.liveMeetingNotice, contains('本机'));
    },
  );

  test('duplicate stop waits for the same final ASR result', () async {
    await start();
    speech.emit(opening);
    await _until(() => c.liveMeetingSegments.isNotEmpty);
    ble.stop();
    await _until(() => !c.recording);
    final stopped = RealtimeStreamState(
      fileId: 301,
      path: audio.path,
      bytesReceived: 3200,
    );
    c.handleRealtimeStateForTesting(stopped);
    await speech.finishStarted.future;
    c.handleRealtimeStateForTesting(stopped);
    await c.waitForOrganize();
    expect(
      c.recordingView(RecordingReference(path: audio.path)).processing,
      isTrue,
    );
    expect(model.fullSources, isEmpty);
    speech.finished.complete(
      SttStreamEvent(type: 'done', text: '$opening 最后补充', speechFinal: true),
    );
    final key =
        '${c.analysisKey(RecordingReference(path: audio.path))}/minutes';
    await _until(() => c.analysis.results[key]?.isDraft == false);
    expect(c.analysis.results[key]!.text, contains('包含最后补充'));
  });
  test(
    'failed automatic revision stays unknown after restart without retry',
    () async {
      await start();
      model.failLive = true;
      speech.emit(opening);
      await _until(() => c.liveMeetingSegments.isNotEmpty);
      expect(c.liveMinutes, isNotNull);
      await c.liveMinutes!.tick();
      expect(c.liveMinutes!.error, contains('未自动重发'));
      await c.liveMinutes!.tick();
      expect(model.liveSources, hasLength(1));
      final recovered = LiveMinutes(
        sessionId: c.liveMeetingId!,
        store: LiveMinutesStore(file: liveFile),
        request: (_) => throw StateError('must not retry'),
      );
      await recovered.restore();
      await recovered.tick();
      expect(recovered.requestStatus, 'unknown');
      expect(recovered.error, contains('未自动重发'));
      expect(recovered.sources.join(), opening);
      recovered.dispose();
    },
  );

  test(
    'late automatic revision cannot publish into the next recording',
    () async {
      await start();
      model.liveResponse = Completer<String>();
      speech.emit(opening);
      await _until(() => c.liveMeetingSegments.isNotEmpty);
      expect(c.liveMinutes, isNotNull);
      final old = c.liveMinutes!;
      final work = old.tick();
      await _until(() => model.liveSources.isNotEmpty);
      c.beginLiveMeeting('next');
      model.liveResponse!.complete(model.minutes('迟到旧场结果'));
      await work;
      expect(c.liveMinutesEnabled, isFalse);
      expect(c.liveMinutes, isNull);
      expect(old.active, isNull);
      final journal = await LiveMinutesStore(
        file: liveFile,
      ).read(old.sessionId);
      expect(journal!['active'], isNull);
      old.dispose();
    },
  );
  test(
    'next recording cannot release previous finalization or consume its last sentence',
    () async {
      await start();
      speech.emit(opening);
      await _until(() => c.liveMeetingSegments.isNotEmpty);
      ble.stop();
      await _until(() => !c.recording);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 301, path: audio.path, bytesReceived: 3200),
      );
      await speech.finishStarted.future;
      await c.startRecord();
      await c.waitForOrganize();
      expect(
        c.recordingView(RecordingReference(path: audio.path)).processing,
        isTrue,
      );
      expect(model.fullSources, isEmpty);
      speech.finished.complete(
        SttStreamEvent(type: 'done', text: '$opening 最后补充', speechFinal: true),
      );
      final key =
          '${c.analysisKey(RecordingReference(path: audio.path))}/minutes';
      await _until(() => c.analysis.results[key]?.isDraft == false);
      expect(c.analysis.results[key]!.text, contains('包含最后补充'));
      expect(c.transcript, isEmpty);
      expect(c.liveMeetingSegments, isEmpty);
    },
  );
  test(
    'failed final ASR with partial text retries full audio before final minutes',
    () async {
      await start(onDevice: true);
      speech.emit(opening);
      await _until(() => c.liveMeetingSegments.isNotEmpty);
      ble.stop();
      await _until(() => !c.recording);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 301, path: audio.path, bytesReceived: 3200),
      );
      await speech.finishStarted.future;
      speech.finished.completeError(TimeoutException('final ASR unavailable'));
      await _until(
        () => c.organizeStatusFor(audio.path).stage == OrganizeStage.failed,
      );
      expect(model.fullSources, isEmpty);
      await c.retryOrganize(audio.path);
      final key =
          '${c.analysisKey(RecordingReference(path: audio.path))}/minutes';
      await _until(() => c.analysis.results[key]?.isDraft == false);
      expect(model.fullSources.single, contains('完整录音重新转写'));
      expect(c.analysis.results[key]!.text, contains('包含最后补充'));
    },
  );
  testWidgets(
    'mid-recording crash recovers stage draft and unknown notice in detail view without overwriting formal minutes',
    (tester) async {
      await tester.runAsync(() async {
        await start();
        speech.emit(opening);
        await _until(() => c.liveMeetingSegments.isNotEmpty);
        await c.liveMinutes!.tick();
        await _until(() => c.liveMinutes?.active != null);
      });
      final secondModel = _Model();
      late RecorderController crashedWithFailure;
      await tester.runAsync(() async {
        // Also record a mid-recording failed live revision on a second file to verify failure notice recovery.
        final secondAudio = File('${dir.path}/302.wav');
        await secondAudio.writeAsBytes(wavBytes(List.filled(3200, 0)));
        secondModel.failLive = true;
        crashedWithFailure = RecorderController(
          loadPersistedState: false,
          meetingLocalOnly: false,
          ble: ble,
          qwenSpeech: _Qwen()..apiKeyOverride = 'test-key',
          appleSpeech: _Apple(),
          analysisController: RecordingAnalysis(
            service: secondModel,
            file: analysisFile,
          ),
          contextAnalysisService: secondModel,
          liveMeetingStore: LiveMinutesStore(file: liveFile),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${dir.path}/imports'),
        )..speechProvider = SttProvider.qwen;
        await crashedWithFailure.setAutoOrganize(true);
        await crashedWithFailure.startRecord();
        final speech2 = _Speech();
        crashedWithFailure.attachSttStreamForTesting(speech2);
        crashedWithFailure.handleRealtimeStateForTesting(
          RealtimeStreamState(
            active: true,
            fileId: 302,
            path: secondAudio.path,
            bytesReceived: 3200,
          ),
        );
        speech2.emit(opening);
        await _until(() => crashedWithFailure.liveMeetingSegments.isNotEmpty);
        await crashedWithFailure.liveMinutes!.tick();
        expect(crashedWithFailure.liveMinutes!.requestStatus, 'unknown');
        await speech2.dispose();
        crashedWithFailure.dispose();
      });

      late RecorderController restarted;
      await tester.runAsync(() async {
        restarted = RecorderController(
          loadPersistedState: false,
          meetingLocalOnly: false,
          ble: _Ble(),
          qwenSpeech: _Qwen()..apiKeyOverride = 'test-key',
          appleSpeech: _Apple(),
          analysisController: RecordingAnalysis(
            service: secondModel,
            file: analysisFile,
          ),
          contextAnalysisService: secondModel,
          liveMeetingStore: LiveMinutesStore(file: liveFile),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${dir.path}/imports'),
        )..speechProvider = SttProvider.qwen;
        await restarted.waitForOrganize();
      });
      addTearDown(restarted.dispose);
      expect(
        secondModel.liveSources,
        hasLength(1),
        reason: 'restart must not retry unknown live request',
      );

      Future<void> openMinutesFor(String path) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          ChangeNotifierProvider<RecorderController>.value(
            value: restarted,
            child: MaterialApp(
              home: RecordingDetailScreen(
                reference: RecordingReference(
                  path: path,
                  fileId: restarted.fileIdFromPath(path),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final analysisButton = find.byTooltip('摘要与分析');
        await tester.ensureVisible(analysisButton);
        await tester.tap(analysisButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('结构化纪要'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MinutesPanel), findsOneWidget);
      }

      await openMinutesFor(audio.path);
      expect(find.text('阶段摘要'), findsWidgets);
      expect(find.textContaining('草稿纪要（实时识别生成）'), findsOneWidget);

      await openMinutesFor('${dir.path}/302.wav');
      expect(find.textContaining('未自动重发'), findsOneWidget);

      // Formal minutes protection: once formal minutes exist, recovering live.json on next restart must not overwrite them.
      late RecorderController afterFormal;
      await tester.runAsync(() async {
        restarted.rememberTranscript(audio.path, '$opening 最后补充');
        await _until(
          () => restarted.analysis.results['file:301/minutes']?.isDraft == false,
        );
        afterFormal = RecorderController(
          loadPersistedState: false,
          meetingLocalOnly: false,
          ble: _Ble(),
          qwenSpeech: _Qwen()..apiKeyOverride = 'test-key',
          appleSpeech: _Apple(),
          analysisController: RecordingAnalysis(
            service: secondModel,
            file: analysisFile,
          ),
          contextAnalysisService: secondModel,
          liveMeetingStore: LiveMinutesStore(file: liveFile),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${dir.path}/imports'),
        )..speechProvider = SttProvider.qwen;
        await afterFormal.waitForOrganize();
      });
      addTearDown(afterFormal.dispose);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: afterFormal,
          child: MaterialApp(
            home: RecordingDetailScreen(
              reference: RecordingReference(path: audio.path, fileId: 301),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('摘要与分析'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(AppBar), matching: find.text('结构化纪要')),
      );
      await tester.pumpAndSettle();
      expect(find.text('包含最后补充'), findsWidgets);
      expect(find.text('阶段摘要'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'realtime BLE stream auto-starts cloud WebSocket STT and beginLiveMeeting, '
    'shows LiveMeetingPanel in RecordingDetailScreen, and reads translated captions aloud',
    (tester) async {
      late Directory tempDir;
      late _Ble testBle;
      late _Speech wsSpeech;
      late _Model testModel;
      late _Speaker speaker;
      late RecorderController controller;
      late File clip;

      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('koe-bean-live-');
        testBle = _Ble();
        wsSpeech = _Speech();
        testModel = _Model();
        speaker = _Speaker();
        clip = File('${tempDir.path}/305.wav');
        await clip.writeAsBytes(wavBytes(List.filled(3200, 0)));
        controller = RecorderController(
          loadPersistedState: false,
          meetingLocalOnly: false,
          ble: testBle,
          qwenSpeech: _Qwen()..apiKeyOverride = 'test-key',
          appleSpeech: _Apple(),
          speechStream: (_) => wsSpeech,
          answerSpeaker: speaker,
          analysisController: RecordingAnalysis(
            service: testModel,
            file: File('${tempDir.path}/analysis.json'),
          ),
          contextAnalysisService: testModel,
          liveMeetingStore: LiveMinutesStore(
            file: File('${tempDir.path}/live.json'),
          ),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${tempDir.path}/imports'),
        )..speechProvider = SttProvider.qwen;
        await controller.setAutoOrganize(true);
        // Simulate RealtimeBleStream becoming active directly without manual attachSttStreamForTesting.
        controller.recording = true;
        controller.handleRealtimeStateForTesting(
          RealtimeStreamState(
            active: true,
            fileId: 305,
            path: clip.path,
            bytesReceived: 1600,
          ),
        );
        await _until(
          () =>
              controller.streamingSttActive &&
              controller.liveMeetingId != null &&
              controller.liveMeetingAvailable,
        );
      });
      addTearDown(() async {
        if (!wsSpeech.finished.isCompleted) wsSpeech.finished.complete(null);
        controller.dispose();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
      });

      final ref = controller.currentRecordingReference!;
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(home: RecordingDetailScreen(reference: ref)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LiveMeetingPanel), findsOneWidget);
      expect(find.text('实时纪要与双语字幕'), findsOneWidget);

      await tester.tap(find.text('实时纪要与双语字幕'));
      await tester.pumpAndSettle();

      final speechSwitch = find.byKey(
        const ValueKey('live-caption-speech-switch'),
      );
      expect(speechSwitch, findsOneWidget);
      await tester.tap(speechSwitch);
      await tester.pumpAndSettle();

      expect(controller.liveCaptionsEnabled, isTrue);

      await tester.runAsync(() async {
        wsSpeech.emit('Hello everyone, let us begin.');
        await _until(() => speaker.spoken.isNotEmpty);
      });
      await tester.pumpAndSettle();

      expect(speaker.spoken, ['录音摘要']);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
