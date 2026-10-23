import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/doubao_stt.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/audio/audio_transcoder.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/context/commitments.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

import 'support/audio_payload_detector.dart';
import 'support/scripted_speaker_diarizer.dart';
import 'support/wav_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unsupported collision metadata cannot produce a merge warning', () {
    final quality = DiarizationQuality.decode({
      'chunks': 40,
      'clusters': 1,
      'cohesion': 0.9,
      'multiSpeakerChunks': 20,
      'collisionRate': 1.0,
    })!;
    expect(quality.shouldSuggestRediarize, isFalse);
    expect(quality.mergeRisk, closeTo(0.1, 1e-9));
  });

  test('(1) 段落分配：按时间重叠分配发言人（含跨两个 turn 的段落、落在空隙里的段落、编号按首次出现顺序）', () {
    // 聚类原始编号为 9、3、7（未分到段落的 5 不应占用逐字稿编号）
    final turns = <DiarizationTurn>[
      const DiarizationTurn(
        speaker: 9,
        start: Duration(seconds: 0),
        end: Duration(seconds: 4),
      ),
      const DiarizationTurn(
        speaker: 5,
        start: Duration(milliseconds: 4100),
        end: Duration(milliseconds: 4300),
      ),
      const DiarizationTurn(
        speaker: 3,
        start: Duration(seconds: 5),
        end: Duration(seconds: 12),
      ),
      const DiarizationTurn(
        speaker: 7,
        start: Duration(seconds: 16),
        end: Duration(seconds: 22),
      ),
    ];

    final segments = <TranscriptSegment>[
      // 段 0: [0.5s, 3.5s] 完全在 cluster 9 -> 首次出现编为 '1'
      const TranscriptSegment(
        text: '各位好，今天讨论第二期方案。',
        start: Duration(milliseconds: 500),
        end: Duration(milliseconds: 3500),
      ),
      // 段 1: [3.0s, 8.0s] 跨两个 turn：与 cluster 9 重叠 1.0s ([3,4])，与 cluster 3 重叠 3.0s ([5,8]) -> 归属 cluster 3，首次出现编为 '2'
      const TranscriptSegment(
        text: '我补充一下本机区分的时间线。',
        start: Duration(seconds: 3),
        end: Duration(seconds: 8),
      ),
      // 段 2: [8.5s, 11.5s] 在 cluster 3 内 -> 仍为 '2'，speakerChanged 为 false
      const TranscriptSegment(
        text: '模型优先走 ModelScope 下载。',
        start: Duration(milliseconds: 8500),
        end: Duration(milliseconds: 11500),
      ),
      // 段 3: [12.5s, 13.5s] 完全落在 [12s, 16s] 空隙里，中点 13.0s 距 cluster 3 中点 8.5s (4.5s) 比距 cluster 7 中点 19.0s (6.0s) 更近 -> 归属 '2'
      const TranscriptSegment(
        text: '好。',
        start: Duration(milliseconds: 12500),
        end: Duration(milliseconds: 13500),
      ),
      // 段 4: [14.8s, 15.6s] 落在空隙里，中点 15.2s 距 cluster 7 中点 19.0s (3.8s) 比距 cluster 3 中点 8.5s (6.7s) 更近 -> 归属 cluster 7，首次出现编为 '3'
      const TranscriptSegment(
        text: '那我接下来说测试。',
        start: Duration(milliseconds: 14800),
        end: Duration(milliseconds: 15600),
      ),
    ];

    final assigned = assignSpeakersToSegments(turns, segments);
    expect(assigned.segments.map((s) => s.speaker).toList(), [
      '1',
      '2',
      '2',
      '2',
      '3',
    ]);
    expect(assigned.segments.map((s) => s.speakerChanged).toList(), [
      true,
      true,
      false,
      false,
      true,
    ]);
    expect(assigned.speakerNumbering, {9: '1', 3: '2', 7: '3'});
    expect(assigned.speakerNumbering.containsKey(5), isFalse);
  });

  test('(2) 并错人提示：给定触发条件的 turn/嵌入统计时出现提示，不满足时不出现', () {
    // 1) 片段数不足 30（少于约 1 分钟语音）：即使凝聚度低也不触发提示
    const shortQuality = DiarizationQuality(
      chunks: 20,
      clusters: 2,
      cohesion: 0.45,
    );
    expect(shortQuality.mergeRisk, 0.0);
    expect(shortQuality.shouldSuggestRediarize, isFalse);

    // 2) 正常多人会议（cohesion = 0.78 >= 0.6，mergeRisk = 0.22 <= 0.4）：不触发提示
    const normalQuality = DiarizationQuality(
      chunks: 40,
      clusters: 3,
      cohesion: 0.78,
    );
    expect(normalQuality.mergeRisk, closeTo(0.22, 1e-6));
    expect(normalQuality.shouldSuggestRediarize, isFalse);

    // 3) 群内嵌入分散（cohesion = 0.50 < 0.6，mergeRisk = 0.50 > 0.4）：触发提示
    const dispersedQuality = DiarizationQuality(
      chunks: 36,
      clusters: 2,
      cohesion: 0.50,
    );
    expect(dispersedQuality.mergeRisk, closeTo(0.50, 1e-6));
    expect(dispersedQuality.shouldSuggestRediarize, isTrue);

    // 5) 从原始嵌入向量计算：把正交方向的两组人塞进同一个 cluster 时 cohesion 低，触发提示；分开为 2 个 cluster 时不触发
    final mixedEmbeddings = <({int clusterSpeaker, List<double> embedding})>[
      for (var i = 0; i < 18; i++)
        (clusterSpeaker: 0, embedding: const [1.0, 0.0, 0.0, 0.0]),
      for (var i = 18; i < 36; i++)
        (clusterSpeaker: 0, embedding: const [-0.9, 0.43589, 0.0, 0.0]),
    ];
    final computedMixed = DiarizationQuality.fromTurnEmbeddings(
      mixedEmbeddings,
    );
    expect(computedMixed.chunks, 36);
    expect(computedMixed.clusters, 1);
    expect(computedMixed.shouldSuggestRediarize, isTrue);

    final separatedEmbeddings =
        <({int clusterSpeaker, List<double> embedding})>[
          for (var i = 0; i < 18; i++)
            (clusterSpeaker: 0, embedding: const [1.0, 0.0, 0.0, 0.0]),
          for (var i = 18; i < 36; i++)
            (clusterSpeaker: 1, embedding: const [0.0, 1.0, 0.0, 0.0]),
        ];
    final computedSeparated = DiarizationQuality.fromTurnEmbeddings(
      separatedEmbeddings,
    );
    expect(computedSeparated.cohesion, closeTo(1.0, 1e-6));
    expect(computedSeparated.shouldSuggestRediarize, isFalse);
  });

  test('导入的 m4a 等格式先转成 16 kHz WAV 再区分，转不了就直接报错，不先下载模型', () async {
    final dir = await Directory.systemTemp.createTemp('koe-local-diar-');
    addTearDown(() => dir.delete(recursive: true));
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('com.semanticcraft.koe/audio_transcode');
    final converted = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          converted.add(call.arguments);
          throw PlatformException(code: 'decode', message: '这段音频读不出来');
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    var requests = 0;
    final store = DiarizationModelStore(
      directory: Directory('${dir.path}/models'),
      isWifiConnected: () async => true,
      client: _CountingClient(() => requests++),
    );
    addTearDown(store.dispose);
    final input = File('${dir.path}/meeting.m4a')
      ..writeAsBytesSync([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70]);

    await expectLater(
      SherpaSpeakerDiarizer(modelStore: store).diarize(input.path),
      throwsA(
        isA<AudioTranscodeException>().having(
          (e) => e.message,
          'message',
          '这段音频读不出来',
        ),
      ),
    );
    expect(converted, [
      isA<Map<Object?, Object?>>()
          .having((a) => a['input'], 'input', input.path)
          .having((a) => a['sampleRate'], 'sampleRate', 16000),
    ]);
    expect(requests, 0);
  });

  test('本机会议先存下转写文字，发言人在转写任务之外标上', () async {
    final dir = await Directory.systemTemp.createTemp('koe-local-diar-');
    addTearDown(() => dir.delete(recursive: true));
    final diarizer = ScriptedSpeakerDiarizer([
      _turns([(0, 0, 3), (1, 3, 6)]),
    ])..gate = Completer<void>();
    final controller = _localMeetingController(
      dir,
      diarizer,
      _FakeAppleSpeech(),
    );
    addTearDown(controller.dispose);
    addTearDown(() {
      if (!diarizer.gate!.isCompleted) diarizer.gate!.complete();
    });
    final path = await _importMeeting(controller, dir);

    final job = controller.transcribeLocalFile(
      path,
      provider: SttProvider.apple,
    );
    await until(() => diarizer.calls == 1);

    // While the speaker pass runs, the transcript is already saved and the
    // engine is free for the next recording or a live session.
    expect(controller.transcriptForPath(path), '先由甲介绍背景。\n再由乙说明进展。');
    expect(controller.fileProcessingBusy, isFalse);
    await job;

    diarizer.gate!.complete();
    await until(
      () => controller
          .transcriptSegmentsForPath(path)
          .every((s) => s.speaker != null),
    );
    expect(controller.transcriptSegmentsForPath(path).map((s) => s.speaker), [
      '1',
      '2',
    ]);
  });

  test('录音时选 3 人，保存后这条录音的发言人区分用 3 人（#408）', () async {
    final dir = await Directory.systemTemp.createTemp('koe-local-diar-');
    addTearDown(() => dir.delete(recursive: true));
    final diarizer = ScriptedSpeakerDiarizer([
      _turns([(0, 0, 3), (1, 3, 6)]),
    ]);
    final controller = RecorderController(
      loadPersistedState: false,
      topicsEnabled: false,
      appleSpeech: _FakeAppleSpeech(),
      speakerDiarizer: diarizer,
      phoneRecorder: _PatternedPhoneRecorder(),
      phoneRecordingEnabled: true,
      placeCapture: const _NoPlace(),
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${dir.path}/imports'),
    );
    addTearDown(controller.dispose);
    await controller.refreshAppleCapabilities();

    await controller.startPhoneRecording();
    await controller.setPhoneRecordingExpectedSpeakers(3);
    final path = (await controller.stopPhoneRecording())!;
    await controller.transcribeLocalFile(path, provider: SttProvider.apple);
    await until(() => diarizer.calls == 1);

    expect(diarizer.lastExpectedSpeakers, 3);
  });

  test('重新转写换了文字后，旧的并错人提示不再出现', () async {
    final dir = await Directory.systemTemp.createTemp('koe-local-diar-');
    addTearDown(() => dir.delete(recursive: true));
    final diarizer = ScriptedSpeakerDiarizer(
      [
        _turns([(0, 0, 6)]),
      ],
      quality: const DiarizationQuality(
        chunks: 36,
        clusters: 1,
        cohesion: 0.48,
      ),
    );
    final apple = _FakeAppleSpeech();
    final controller = _localMeetingController(dir, diarizer, apple);
    addTearDown(controller.dispose);
    final path = await _importMeeting(controller, dir);
    await controller.transcribeLocalFile(path, provider: SttProvider.apple);
    await until(() => controller.shouldShowSpeakerMergeHint(path));
    expect(controller.shouldShowSpeakerMergeHint(path), isTrue);

    apple
      ..text = '换成另一段话。'
      ..segments = const [];
    await controller.transcribeLocalFile(path, provider: SttProvider.apple);

    expect(controller.transcriptForPath(path), '换成另一段话。');
    expect(controller.shouldShowSpeakerMergeHint(path), isFalse);
  });

  test('重新转写后取过的名字仍跟着人走（拾音 R22.2，自动区分）', () async {
    final dir = await Directory.systemTemp.createTemp('koe-local-diar-');
    addTearDown(() => dir.delete(recursive: true));
    // The first pass merges 王五 into 张总; later passes keep three people.
    final diarizer = ScriptedSpeakerDiarizer([
      _turns([(0, 0, 6), (1, 6, 16), (0, 16, 30), (1, 30, 40), (0, 40, 52)]),
      _turns([(0, 0, 6), (1, 6, 16), (2, 16, 30), (1, 30, 40), (2, 40, 52)]),
    ]);
    final apple = _FakeAppleSpeech(
      text: '王五开场。\n李工汇报。\n张总提问。\n李工回答。\n张总总结。',
      segments: _sttSegments([
        ('王五开场。', 0, 6),
        ('李工汇报。', 6, 16),
        ('张总提问。', 16, 30),
        ('李工回答。', 30, 40),
        ('张总总结。', 40, 52),
      ]),
    );
    final controller = _localMeetingController(dir, diarizer, apple);
    addTearDown(controller.dispose);
    final path = await _importMeeting(controller, dir);

    await controller.transcribeLocalFile(path, provider: SttProvider.apple);
    await until(
      () => controller
          .transcriptSegmentsForPath(path)
          .every((s) => s.speaker != null),
    );
    expect(controller.transcriptSegmentsForPath(path).map((s) => s.speaker), [
      '1',
      '2',
      '1',
      '2',
      '1',
    ]);
    await controller.renameTranscriptSpeaker(path, '1', '张总');
    await controller.renameTranscriptSpeaker(path, '2', '李工');
    await controller.rediarizeSpeakers(path, expectedSpeakers: 3);
    expect(_labels(controller, path), ['说话人 3', '李工', '张总', '李工', '张总']);

    // The same text again changes nothing and needs no new speaker pass.
    await controller.transcribeLocalFile(path, provider: SttProvider.apple);
    expect(_labels(controller, path), ['说话人 3', '李工', '张总', '李工', '张总']);
    expect(diarizer.calls, 2);

    // Same text, passages split differently: names follow the times.
    apple.segments = _sttSegments([
      ('王五开场。', 0, 6),
      ('李工汇报。', 6, 16),
      ('张总提问，', 16, 23),
      ('接着提问。', 23, 30),
      ('李工回答。', 30, 40),
      ('张总总结。', 40, 52),
    ]);
    await controller.transcribeLocalFile(path, provider: SttProvider.apple);
    await until(
      () =>
          diarizer.calls == 3 &&
          controller.transcriptSegmentsForPath(path).length == 6 &&
          controller
              .transcriptSegmentsForPath(path)
              .every((s) => s.speaker != null),
    );
    expect(_labels(controller, path), ['说话人 3', '李工', '张总', '张总', '李工', '张总']);

    // New words: the names wait for the next pass, which finds the people by
    // time.
    apple
      ..text = '王五开场。\n李工汇报。\n张总提问。\n李工回答。\n张总总结了。'
      ..segments = _sttSegments([
        ('王五开场。', 0, 6),
        ('李工汇报。', 6, 16),
        ('张总提问，', 16, 23),
        ('接着提问。', 23, 30),
        ('李工回答。', 30, 40),
        ('张总总结了。', 40, 52),
      ]);
    await controller.transcribeLocalFile(path, provider: SttProvider.apple);
    await until(
      () =>
          diarizer.calls == 4 &&
          controller
              .transcriptSegmentsForPath(path)
              .every((s) => s.speaker != null),
    );
    expect(diarizer.calls, 4);
    expect(_labels(controller, path), ['说话人 3', '李工', '张总', '张总', '李工', '张总']);
  });

  for (final realApple in [false, true]) {
    test('(3) 本机会议隐私与时间戳：realApple=$realApple', () async {
      final dir = await Directory.systemTemp.createTemp('koe-local-diar-');
      addTearDown(() => dir.delete(recursive: true));

      final wire = _WireRecordingClient();
      const appleChannel = MethodChannel('soundcore/apple_speech');
      if (realApple) {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(appleChannel, (call) async {
              if (call.method == 'capabilities') {
                return {
                  'supported': true,
                  'speechStatus': 'ready',
                  'translationStatus': 'ready',
                  'suggestedSourceLanguage': 'zh-CN',
                };
              }
              if (call.method == 'transcribeFile') {
                return {'text': '先由甲介绍背景。\n再由乙说明进展。', 'durationSec': 6.0};
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(appleChannel, null),
        );
      }
      final apple = realApple ? AppleSpeechService() : _FakeAppleSpeech();
      final diarizer = ScriptedSpeakerDiarizer([
        const [
          DiarizationTurn(
            speaker: 2,
            start: Duration.zero,
            end: Duration(seconds: 3),
          ),
          DiarizationTurn(
            speaker: 1,
            start: Duration(seconds: 3),
            end: Duration(seconds: 6),
          ),
        ],
      ]);

      final controller = RecorderController(
        loadPersistedState: false,
        topicsEnabled: false,
        appleSpeech: apple,
        speakerDiarizer: diarizer,
        qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
          ..apiKeyOverride = 'qwen-test-key',
        doubaoSpeech: DoubaoSttService(client: wire)
          ..apiKeyOverride = 'doubao-test-key',
        analysisController: RecordingAnalysis(
          inMemory: true,
          service: QwenAnalysisService(client: wire),
        ),
        contextAnalysisService: QwenAnalysisService(
          client: wire,
          systemPrompt: commitmentSystemPrompt,
          instructionLabel: '要求',
          sourceLabel: '资料',
        ),
        phoneRecorder: _PatternedPhoneRecorder(),
        phoneRecordingEnabled: true,
        placeCapture: const _NoPlace(),
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${dir.path}/imports'),
      );
      addTearDown(controller.dispose);

      await controller.refreshAppleCapabilities();
      await controller.setAutoOrganize(true);

      await controller.startPhoneRecording();
      final recordedPath = await controller.stopPhoneRecording();
      expect(recordedPath, isNotNull);

      for (
        var i = 0;
        i < 100 &&
            controller.organizeStatusFor(recordedPath!).stage !=
                OrganizeStage.done;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        controller.organizeStatusFor(recordedPath!).stage,
        OrganizeStage.done,
      );

      // 会议录音在本机模式下必须走本机区分，分出说话人 1、2；发言人在转写
      // 存下之后另行标上。
      await until(
        () => controller
            .transcriptSegmentsForPath(recordedPath)
            .every((s) => s.speaker != null),
      );
      expect(diarizer.calls, realApple ? 0 : 1);
      expect(controller.transcriptForPath(recordedPath), '先由甲介绍背景。\n再由乙说明进展。');
      final segments = controller.transcriptSegmentsForPath(recordedPath);
      expect(segments, hasLength(realApple ? 0 : 2));
      expect(
        segments.map((s) => s.speaker).toList(),
        realApple ? [] : ['1', '2'],
      );
      expect(
        segments.map((s) => s.speakerChanged).toList(),
        realApple ? [] : [true, true],
      );

      // 检查所有出网请求的真实序列化字节：使用顺手修 (a) 的新检测辅助，确认没有任何请求带音频
      expect(wire.requests, isNotEmpty, reason: '摘要与待办文字请求应正常发出');
      final audioRequests = [
        for (final req in wire.requests)
          if (requestCarriesAudioBytes(
            req.bodyBytes,
            pcmPattern: defaultTestPcmPattern,
          ))
            '${req.method} ${req.url}',
      ];
      expect(audioRequests, isEmpty);
    });
  }
}

List<DiarizationTurn> _turns(List<(int, int, int)> spans) => [
  for (final (speaker, start, end) in spans)
    DiarizationTurn(
      speaker: speaker,
      start: Duration(seconds: start),
      end: Duration(seconds: end),
    ),
];

List<SttSegment> _sttSegments(List<(String, int, int)> passages) => [
  for (final (text, start, end) in passages)
    SttSegment(text: text, startMs: start * 1000, endMs: end * 1000),
];

List<String?> _labels(RecorderController c, String path) {
  final names = {
    for (final s in c.transcriptSpeakersForPath(path)) s.id: s.displayLabel,
  };
  return [for (final s in c.transcriptSegmentsForPath(path)) names[s.speaker]];
}

RecorderController _localMeetingController(
  Directory dir,
  SpeakerDiarizer diarizer,
  AppleSpeechService apple,
) => RecorderController(
  loadPersistedState: false,
  topicsEnabled: false,
  appleSpeech: apple,
  speakerDiarizer: diarizer,
  transcriptPersister: ({bool strict = false}) async {},
  libraryDirectory: Directory('${dir.path}/imports'),
);

Future<String> _importMeeting(RecorderController c, Directory dir) async {
  await c.refreshAppleCapabilities();
  final source = File('${dir.path}/meeting.wav');
  await source.writeAsBytes(wavBytes(const [0, 0, 0, 0]));
  return (await c.importLocalAudio(source.path)).path;
}

class _FakeAppleSpeech extends AppleSpeechService {
  _FakeAppleSpeech({
    this.text = '先由甲介绍背景。\n再由乙说明进展。',
    this.segments = const [
      SttSegment(text: '先由甲介绍背景。', startMs: 200, endMs: 2800),
      SttSegment(text: '再由乙说明进展。', startMs: 3200, endMs: 5800),
    ],
  });

  String text;
  List<SttSegment> segments;

  @override
  bool get offered => true;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async => const AppleSpeechCapabilities(
    supported: true,
    speechStatus: SpeechResourceStatus.ready,
    translationStatus: SpeechResourceStatus.ready,
    suggestedSourceLanguage: 'zh-CN',
    speechLanguages: [SpeechLanguage(code: 'zh-CN', name: '简体中文')],
  );

  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async => SttResult(
    text: text,
    sourcePath: path,
    language: sourceLanguage,
    segments: segments,
  );
}

class _PatternedPhoneRecorder implements PhoneRecorder {
  final _states = StreamController<PhoneMicState>.broadcast();
  String? _path;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => _states.stream;

  @override
  Future<void> start(String path) async {
    _path = path;
    await File(path).writeAsBytes(wavBytes(const []));
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    final samples = <int>[
      for (var i = 0; i < 400; i++) ...defaultTestPcmPattern,
    ];
    await File(_path!).writeAsBytes(wavBytes(samples));
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async => _states.close();
}

class _NoPlace implements PlaceCapture {
  const _NoPlace();

  @override
  Future<RecordingPlace?> capture() async => null;
}

class _RecordedWireRequest {
  _RecordedWireRequest({
    required this.method,
    required this.url,
    required this.bodyBytes,
  });

  final String method;
  final Uri url;
  final Uint8List bodyBytes;
}

class _WireRecordingClient extends http.BaseClient {
  final List<_RecordedWireRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    requests.add(
      _RecordedWireRequest(
        method: request.method,
        url: request.url,
        bodyBytes: bodyBytes,
      ),
    );
    if (request.url.path.endsWith('/chat/completions')) {
      final decoded =
          jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
      final messages = (decoded['messages'] as List).cast<Map>();
      final userContent = '${messages.last['content']}';
      final content =
          userContent.contains('提取出用户自己承诺要做的事') ||
              userContent.contains('"items"')
          ? '{"items":[{"type":"mine","title":"跟进本机区分验收","due":null,"segment":1}],"updates":[]}'
          : '先由甲介绍背景，再由乙说明进展 [S1]。';
      final reply = jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': content},
          },
        ],
      });
      return http.StreamedResponse(
        Stream.value(utf8.encode(reply)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"error":"unexpected endpoint"}')),
      500,
    );
  }
}

class _CountingClient extends http.BaseClient {
  _CountingClient(this._onRequest);

  final void Function() _onRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _onRequest();
    throw http.ClientException('offline', request.url);
  }
}
