import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/doubao_stt.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/platform/phone_mic_stream.dart';
import 'package:koe/platform/phone_recorder.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/context/commitments.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/speech_configuration.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:provider/provider.dart';

import 'support/fake_foreground_service.dart';
import 'support/wav_fixture.dart';

/// Distinct non-zero PCM sample pattern written into test recordings so wire
/// assertions can check both container headers and raw/base64 sample bytes.
final List<int> _pcmPattern = List<int>.generate(
  64,
  (i) => ((i * 37 + 0x5A) & 0xFE) | 1,
);

Uint8List _patternedWav({int repeats = 200}) {
  final samples = <int>[
    for (var i = 0; i < repeats; i++) ..._pcmPattern,
  ];
  return wavBytes(samples);
}

bool _containsSublist(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty || haystack.length < needle.length) return false;
  final limit = haystack.length - needle.length;
  for (var i = 0; i <= limit; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

class _RecordedWireRequest {
  _RecordedWireRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.bodyBytes,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);
}

/// Fake HTTP client that serializes every outgoing request into real bytes via
/// `request.finalize().toBytes()` before answering Qwen STT, OSS upload,
/// Doubao STT, and Qwen chat-completion analysis endpoints.
class _WireRecordingClient extends http.BaseClient {
  final requests = <_RecordedWireRequest>[];
  Completer<void>? requestReached;
  Completer<void>? requestGate;
  String? gatePathSubstring;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final wireBytes = await request.finalize().toBytes();
    requests.add(
      _RecordedWireRequest(
        method: request.method,
        url: request.url,
        headers: Map<String, String>.from(request.headers),
        bodyBytes: wireBytes,
      ),
    );
    if (requestGate != null &&
        (gatePathSubstring == null ||
            request.url.path.contains(gatePathSubstring!))) {
      if (requestReached != null && !requestReached!.isCompleted) {
        requestReached!.complete();
      }
      final gate = requestGate!;
      requestGate = null;
      gatePathSubstring = null;
      await gate.future;
    }

    final path = request.url.path;
    Object responseBody;
    var headers = const <String, String>{};

    if (path == '/api/v1/uploads') {
      responseBody = {
        'data': {
          'policy': 'policy-token',
          'signature': 'sig',
          'upload_dir': 'dashscope-instant/test/',
          'upload_host': 'https://oss.example.com/bucket',
          'oss_access_key_id': 'access',
          'x_oss_object_acl': 'private',
          'x_oss_forbid_overwrite': 'true',
        },
      };
    } else if (request.url.host == 'oss.example.com') {
      responseBody = '';
    } else if (path.endsWith('/services/audio/asr/transcription')) {
      responseBody = {
        'output': {'task_id': 'task-cloud-1', 'task_status': 'PENDING'},
      };
    } else if (path == '/api/v1/tasks/task-cloud-1') {
      responseBody = {
        'output': {
          'task_id': 'task-cloud-1',
          'task_status': 'SUCCEEDED',
          'results': [
            {
              'subtask_status': 'SUCCEEDED',
              'transcription_url': 'https://result.example.com/transcript.json',
            },
          ],
        },
      };
    } else if (request.url.host == 'result.example.com') {
      responseBody = {
        'transcripts': [
          {'text': '云端千问转写结果'},
        ],
      };
    } else if (path.contains('/auc/bigmodel/recognize')) {
      headers = const {'x-api-status-code': '20000000'};
      responseBody = {
        'result': {'text': '云端豆包转写结果'},
      };
    } else if (path.endsWith('/compatible-mode/v1/chat/completions')) {
      final decoded = jsonDecode(utf8.decode(wireBytes)) as Map<String, dynamic>;
      final messages = (decoded['messages'] as List).cast<Map>();
      final userContent = '${messages.last['content']}';
      String content;
      if (userContent.contains('结构化会议纪要')) {
        content = jsonEncode({
          'title': '第1期评审会议',
          'overview': '确定会议录音默认只留本机 [S1]',
          'topics': [
            {
              'text': '会议录音转写不上传音频 [S1]',
              'sources': ['S1'],
            },
          ],
          'decisions': [
            {
              'text': '默认打开录音只留本机开关 [S1]',
              'sources': ['S1'],
            },
          ],
          'actions': [
            {
              'text': '周五前提交纪要方案',
              'owner': '我',
              'due': '周五前',
              'sources': ['S1'],
            },
          ],
          'questions': <Object>[],
        });
      } else if (userContent.contains('提取出用户自己承诺要做的事') ||
          userContent.contains('"items"')) {
        content =
            '{"items":[{"type":"mine","title":"周五前提交纪要方案","due":null,"segment":1}],"updates":[]}';
      } else {
        content = '会议决定默认打开录音只留本机，周五前提交纪要方案 [S1]。';
      }
      responseBody = {
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': content},
          },
        ],
      };
    } else {
      throw StateError('Unexpected request: ${request.method} ${request.url}');
    }

    final encoded =
        responseBody is String ? responseBody : jsonEncode(responseBody);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(encoded)),
      200,
      headers: headers,
    );
  }
}

class _OnDeviceAppleSpeech extends AppleSpeechService {
  _OnDeviceAppleSpeech({this.supported = true});

  final bool supported;
  int fileCalls = 0;
  int streamCalls = 0;

  @override
  bool get offered => supported;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async {
    if (!supported) return const AppleSpeechCapabilities.unsupported();
    return const AppleSpeechCapabilities(
      supported: true,
      speechStatus: SpeechResourceStatus.ready,
      translationStatus: SpeechResourceStatus.ready,
      suggestedSourceLanguage: 'zh-CN',
      speechLanguages: [
        SpeechLanguage(code: 'zh-CN', name: '简体中文'),
        SpeechLanguage(code: 'en-US', name: 'English'),
        SpeechLanguage(code: 'ja-JP', name: '日本語'),
      ],
    );
  }

  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    if (!supported) throw StateError('unsupported');
    fileCalls++;
    return SttResult(
      text: '我们决定会议录音只留本机，我周五前提交纪要方案。',
      sourcePath: path,
      language: sourceLanguage,
      segments: const [
        SttSegment(
          text: '我们决定会议录音只留本机，我周五前提交纪要方案。',
          startMs: 0,
          endMs: 3000,
        ),
      ],
    );
  }

  @override
  SttStreamSession createStreamSession({
    required String sourceLanguage,
    String? targetLanguage,
  }) {
    streamCalls++;
    return _FakeStreamSession('本机实时转写文字。');
  }
}

class _FakeStreamSession implements SttStreamSession {
  _FakeStreamSession(this.finalText);

  final String finalText;
  final _events = StreamController<SttStreamEvent>.broadcast();
  bool _open = false;

  @override
  Stream<SttStreamEvent> get events => _events.stream;

  @override
  bool get isOpen => _open;

  @override
  bool get isServerReady => _open;

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {
    _open = true;
  }

  @override
  void sendPcm(Uint8List pcm16le) {
    if (!_open) return;
    _events.add(
      SttStreamEvent(type: 'partial', text: finalText, speechFinal: true),
    );
  }

  @override
  void finalizeUtterance() {}

  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    _open = false;
    return SttStreamEvent(type: 'done', text: finalText, isFinal: true);
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  @override
  Future<void> dispose() async {
    _open = false;
    await _events.close();
  }
}

class _FakePhoneRecorder implements PhoneRecorder {
  final _states = StreamController<PhoneMicState>.broadcast();
  String? _path;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => _states.stream;

  @override
  Future<void> start(String path) async {
    _path = path;
    await File(path).writeAsBytes(_patternedWav(repeats: 200));
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    if (_path != null) {
      await File(_path!).writeAsBytes(_patternedWav(repeats: 200));
    }
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async => _states.close();
}

class _FakeMicStream implements PhoneMicStream {
  final _states = StreamController<PhoneMicState>.broadcast();
  StreamController<Uint8List>? _samples;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<PhoneMicState> get states => _states.stream;

  @override
  Future<Stream<Uint8List>> start() async {
    _samples = StreamController<Uint8List>();
    return _samples!.stream;
  }

  void emitVoicedSecond() {
    final bytes = Uint8List(32000);
    final view = ByteData.sublistView(bytes);
    for (var i = 0; i < 16000; i++) {
      view.setInt16(i * 2, 1200, Endian.little);
    }
    _samples?.add(bytes);
  }

  @override
  Future<void> stop() async {
    await _samples?.close();
    _samples = null;
  }

  @override
  Future<void> dispose() async {
    await _samples?.close();
    await _states.close();
  }
}

class _NoPlace implements PlaceCapture {
  const _NoPlace();
  @override
  Future<RecordingPlace?> capture() async => null;
}

class _ControllableFileJobJournal extends FileJobJournal {
  _ControllableFileJobJournal({required super.file});

  Completer<void>? runningSaveReached;
  Completer<void>? runningSaveGate;

  @override
  Future<void> save() async {
    final hasRunningWithoutTask = jobs.values.any(
      (j) => j.stage == 'running' && j.taskId == null,
    );
    if (hasRunningWithoutTask && runningSaveGate != null) {
      if (runningSaveReached != null && !runningSaveReached!.isCompleted) {
        runningSaveReached!.complete();
      }
      final gate = runningSaveGate!;
      runningSaveGate = null;
      await gate.future;
    }
    await super.save();
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 300 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    FakeForegroundService();
    dir = await Directory.systemTemp.createTemp('koe-meeting-local-only-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  test(
    '(a) 会议场景开关打开，跑完整录音→转写→整理，序列化后的真实请求字节不含音频，不请求 OSS 或豆包上传端点，整理请求只含文字',
    () async {
      final wire = _WireRecordingClient();
      final apple = _OnDeviceAppleSpeech(supported: true);
      final phoneRecorder = _FakePhoneRecorder();

      final controller = RecorderController(
        loadPersistedState: false,
        appleSpeech: apple,
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
        phoneRecorder: phoneRecorder,
        phoneRecordingEnabled: true,
        placeCapture: const _NoPlace(),
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${dir.path}/imports'),
      );
      addTearDown(controller.dispose);

      await controller.refreshAppleCapabilities();
      await controller.setAutoOrganize(true);

      // 1. 完整录音（写入真实 WAV 字节，含 RIFF/WAVE 头与非零 PCM 样本）
      await controller.startPhoneRecording();
      final recordedPath = await controller.stopPhoneRecording();
      expect(recordedPath, isNotNull);
      final recordedBytes = await File(recordedPath!).readAsBytes();
      expect(
        _containsSublist(recordedBytes, ascii.encode('RIFF')),
        isTrue,
        reason: '测试原件本身必须是含 RIFF 头的真实 WAV 音频',
      );
      expect(
        _containsSublist(recordedBytes, _pcmPattern),
        isTrue,
        reason: '测试原件本身必须含特征 PCM 样本字节',
      );

      // 2. 自动转写 + 自动整理（摘要 + 提取待办）
      await _until(
        () =>
            controller.organizeStatusFor(recordedPath).stage ==
            OrganizeStage.done,
      );

      final ref = RecordingReference(path: recordedPath);
      final view = controller.recordingView(ref);

      // 3. 生成结构化会议纪要
      final recKey = controller.analysisKey(ref);
      await controller.analysis.run(
        recording: recKey,
        source: view.text,
        apiKey: controller.analysisApiKey,
        templateId: minutesTemplateId,
        currentSource: () => controller.recordingView(ref).text,
      );
      final minutesKey = RecordingAnalysis.keyForTemplate(
        recKey,
        minutesTemplateId,
      );
      expect(controller.analysis.results[minutesKey]?.text, contains('第1期评审会议'));

      // 4. 检查所有出网请求与序列化后的真实请求字节
      expect(wire.requests, isNotEmpty, reason: '整理与纪要请求应正常发出');

      final base64SampleFragment = base64Encode(_pcmPattern).substring(0, 24);
      final audioCarryingRequests = [
        for (final req in wire.requests)
          if (_containsSublist(req.bodyBytes, ascii.encode('RIFF')) ||
              _containsSublist(req.bodyBytes, ascii.encode('WAVE')) ||
              _containsSublist(req.bodyBytes, ascii.encode('ftyp')) ||
              _containsSublist(req.bodyBytes, ascii.encode('M4A ')) ||
              _containsSublist(req.bodyBytes, ascii.encode('OggS')) ||
              _containsSublist(req.bodyBytes, ascii.encode('OpusHead')) ||
              _containsSublist(req.bodyBytes, _pcmPattern) ||
              req.bodyText.contains(base64SampleFragment))
            '${req.method} ${req.url} (${req.bodyBytes.length} bytes)',
      ];
      expect(
        audioCarryingRequests,
        isEmpty,
        reason: '任何出网请求的序列化真实字节都不得含音频头（WAV/RIFF、M4A/ftyp、Ogg/Opus）或原始 PCM 样本',
      );

      final uploadEndpoints = [
        for (final req in wire.requests)
          if (req.url.host.contains('oss') ||
              req.url.path.contains('/api/v1/uploads') ||
              req.url.path.contains('/services/audio/asr/transcription') ||
              req.url.host.contains('openspeech.bytedance.com') ||
              req.url.path.contains('/auc/bigmodel/recognize'))
            '${req.method} ${req.url}',
      ];
      expect(
        uploadEndpoints,
        isEmpty,
        reason: '不得向 OSS 或豆包上传端点发出请求',
      );

      for (final req in wire.requests) {
        // 全部出网请求都是千问文字对话整理接口
        expect(req.url.path, '/compatible-mode/v1/chat/completions');

        // 整理请求体必须是合法 JSON 且只包含转写文字与提示词
        final jsonBody =
            jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
        expect(jsonBody.containsKey('audio'), isFalse);
        expect(jsonBody.containsKey('file_urls'), isFalse);
        expect(jsonBody.containsKey('file_url'), isFalse);
        expect(
          req.bodyText,
          contains('我们决定会议录音只留本机，我周五前提交纪要方案。'),
        );
      }

      expect(view.text, '我们决定会议录音只留本机，我周五前提交纪要方案。');
      expect(view.provider, SttProvider.apple);
      expect(apple.fileCalls, 1);
      expect(controller.todos.openMine.single.title, '周五前提交纪要方案');
      expect(const AppSettings().toJson()['meetingLocalOnly'], isTrue);
      expect(AppSettings.fromJson(const {}).meetingLocalOnly, isTrue);
      await AppSettingsStore.save(
        const AppSettings(meetingLocalOnly: false),
        strict: true,
      );
      expect((await AppSettingsStore.load()).meetingLocalOnly, isFalse);
      await AppSettingsStore.save(
        const AppSettings(meetingLocalOnly: true),
        strict: true,
      );
      expect((await AppSettingsStore.load()).meetingLocalOnly, isTrue);

      // 5. 本端没有可用本机引擎时明确提示，不回落到云端
      wire.requests.clear();
      final unsupportedController = RecorderController(
        loadPersistedState: false,
        appleSpeech: _OnDeviceAppleSpeech(supported: false),
        qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
          ..apiKeyOverride = 'qwen-test-key',
        doubaoSpeech: DoubaoSttService(client: wire)
          ..apiKeyOverride = 'doubao-test-key',
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${dir.path}/imports-unsupported'),
      );
      addTearDown(unsupportedController.dispose);
      final retrievedWav = File('${dir.path}/1760000901.wav');
      await retrievedWav.writeAsBytes(_patternedWav(repeats: 100));
      await unsupportedController.processRetrievedRecording(retrievedWav.path);
      expect(
        wire.requests,
        isEmpty,
        reason: '无可用本机引擎时绝不回落到云端上传音频',
      );
      expect(
        unsupportedController
            .recordingView(RecordingReference(path: retrievedWav.path))
            .error,
        contains('录音只留本机'),
      );
    },
  );

  testWidgets(
    '(b) 默认设置下「录音只留本机」开启，但日常语音输入（纯文字记录、按住说话、全天监听）仍选千问',
    (tester) async {
      expect(
        initialSpeechProvider(
          saved: null,
          appleSupported: true,
          qwenConfigured: true,
        ),
        SttProvider.qwen,
      );

      final wire = _WireRecordingClient();
      final apple = _OnDeviceAppleSpeech(supported: true);
      final micStream = _FakeMicStream();
      final phoneRecorder = _FakePhoneRecorder();
      final streamProviders = <SttProvider>[];

      late RecorderController controller;
      await tester.runAsync(() async {
        controller = RecorderController(
          loadPersistedState: false,
          appleSpeech: apple,
          qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
            ..apiKeyOverride = 'qwen-test-key',
          doubaoSpeech: DoubaoSttService(client: wire)
            ..apiKeyOverride = 'doubao-test-key',
          analysisController: RecordingAnalysis(
            inMemory: true,
            service: QwenAnalysisService(client: wire),
          ),
          contextAnalysisService: QwenAnalysisService(client: wire),
          phoneRecorder: phoneRecorder,
          micStream: micStream,
          phoneRecordingEnabled: true,
          placeCapture: const _NoPlace(),
          minutesStore: MinutesDocumentStore(
            file: File('${dir.path}/minutes.json'),
          ),
          askStore: AskStore(file: File('${dir.path}/asks.json')),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${dir.path}/imports-voice'),
          speechStream: (config) {
            streamProviders.add(config.provider);
            return _FakeStreamSession('千问流式识别文字。');
          },
        );
        await controller.refreshAppleCapabilities();
      });
      addTearDown(controller.dispose);

      // 默认设置下：日常语音引擎仍是千问
      expect(controller.speechProvider, SttProvider.qwen);

      // 设置界面：「录音只留本机」默认打开，云端引擎显示「已关闭：会上传音频」
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('录音只留本机'), findsOneWidget);
      final switchFinder = find.descendant(
        of: find.byKey(const ValueKey('settings-meeting-local-only')),
        matching: find.byType(Switch),
      );
      expect(tester.widget<Switch>(switchFinder).value, isTrue);
      expect(find.text('会议录音已关闭：会上传音频'), findsWidgets);

      // 1. 纯文字记录与全天监听走千问（不走 Apple 设备端）
      await tester.runAsync(() async {
        expect(await controller.startTextCapture(), isTrue);
        micStream.emitVoicedSecond();
        await _until(() => controller.textCaptureText.contains('千问流式识别文字'));
        final captureOutcome = await controller.stopTextCapture();
        expect(captureOutcome?.document?.bodyText, '千问流式识别文字。');
        expect(streamProviders, [SttProvider.qwen]);

        expect(await controller.startTextCapture(allDay: true), isTrue);
        micStream.emitVoicedSecond();
        await _until(() => streamProviders.length == 2);
        await controller.stopTextCapture();
        expect(streamProviders, [SttProvider.qwen, SttProvider.qwen]);

        // 2. 按住说话（新记录语音记录）走千问
        expect(await controller.startVoiceHold(VoiceTarget.note), isTrue);
        final notePath = await controller.finishVoiceNote();
        expect(notePath, isNotNull);
        final noteRef = RecordingReference(path: notePath);
        await _until(
          () =>
              controller.transcriptForPath(notePath!) == '云端千问转写结果' &&
              !controller.fileProcessingBusy &&
              !controller.recordingView(noteRef).processing,
        );
        expect(controller.fileProcessingBusy, isFalse);
        expect(controller.recordingView(noteRef).processing, isFalse);
        expect(
          controller.recordingView(noteRef).provider,
          SttProvider.qwen,
        );
        expect(apple.fileCalls, 0);
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    '(c) 已有录音手动点云端转写要二次确认，未确认时不发出任何请求',
    (tester) async {
      final wire = _WireRecordingClient();
      final apple = _OnDeviceAppleSpeech(supported: true);
      late RecorderController controller;
      late File audio;

      await tester.runAsync(() async {
        audio = File('${dir.path}/1760000888.wav');
        await audio.writeAsBytes(_patternedWav(repeats: 100));
        controller = RecorderController(
          loadPersistedState: false,
          appleSpeech: apple,
          qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
            ..apiKeyOverride = 'qwen-test-key',
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${dir.path}/imports-confirm'),
        )..exportedPaths = [audio.path];
        await controller.refreshAppleCapabilities();
      });
      addTearDown(controller.dispose);

      final ref = RecordingReference(fileId: 1760000888, path: audio.path);

      // 界面层：打开已有录音详情页，点击「转写录音」
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(home: RecordingDetailScreen(reference: ref)),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('转写录音'));
      await tester.pumpAndSettle();

      // 弹出二次确认对话框；未确认时不得发出任何请求
      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: '对已有录音点云端转写必须先弹二次确认框',
      );
      expect(find.textContaining('上传'), findsWidgets);
      expect(wire.requests, isEmpty);

      // 点「取消」，关闭对话框，仍不发出任何请求
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(wire.requests, isEmpty);

      // 控制器层直接调 transcribeRecording（未确认）也不发任何请求
      await tester.runAsync(() => controller.transcribeRecording(ref));
      expect(
        wire.requests.map((r) => '${r.method} ${r.url}').toList(),
        isEmpty,
        reason: '未确认云端转写时不得发出任何 HTTP 请求',
      );
      expect(
        controller.recordingView(ref).error,
        contains('确认'),
      );

      // 再次点击并确认上传，才发出云端转写请求
      await tester.tap(find.text('转写录音'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-cloud-transcribe')));
      for (
        var i = 0;
        i < 100 &&
            (controller.recordingView(ref).text != '云端千问转写结果' ||
                controller.recordingView(ref).processing ||
                controller.fileProcessingBusy);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(controller.fileProcessingBusy, isFalse);
      expect(controller.recordingView(ref).processing, isFalse);
      expect(wire.requests, isNotEmpty);
      expect(controller.recordingView(ref).text, '云端千问转写结果');
    },
  );

  testWidgets(
    '(d) 本机不可用→整理失败→点重试：零音频上传（检查序列化后的真实字节）',
    (tester) async {
      final wire = _WireRecordingClient();
      final apple = _OnDeviceAppleSpeech(supported: false);
      late RecorderController controller;
      late String path;

      await tester.runAsync(() async {
        controller = RecorderController(
          loadPersistedState: false,
          appleSpeech: apple,
          qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
            ..apiKeyOverride = 'qwen-test-key',
          doubaoSpeech: DoubaoSttService(client: wire)
            ..apiKeyOverride = 'doubao-test-key',
          analysisController: RecordingAnalysis(
            inMemory: true,
            service: QwenAnalysisService(client: wire),
          ),
          contextAnalysisService: QwenAnalysisService(client: wire),
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${dir.path}/imports-retry'),
        );
        await controller.setAutoOrganize(true);
        final source = File('${dir.path}/meeting-fail.wav');
        await source.writeAsBytes(_patternedWav(repeats: 100));
        path = (await controller.importLocalAudio(source.path)).path;
        await _until(
          () => controller.organizeStatusFor(path).stage == OrganizeStage.failed,
        );
      });
      addTearDown(controller.dispose);

      expect(wire.requests, isEmpty);

      final ref = RecordingReference(path: path);
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(home: RecordingDetailScreen(reference: ref)),
        ),
      );
      await tester.pumpAndSettle();

      // 点击整理横幅上的「重试」按钮
      expect(find.byKey(const ValueKey('organize-retry')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('organize-retry')));
      for (
        var i = 0;
        i < 40 &&
            (i < 5 ||
                controller.fileProcessingBusy ||
                controller.recordingView(ref).processing);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }

      final audioRequests = [
        for (final req in wire.requests)
          if (_containsSublist(req.bodyBytes, ascii.encode('RIFF')) ||
              _containsSublist(req.bodyBytes, _pcmPattern) ||
              req.url.host.contains('oss') ||
              req.url.path.contains('/api/v1/uploads') ||
              req.url.path.contains('/services/audio/asr/transcription'))
            '${req.method} ${req.url} (${req.bodyBytes.length} bytes)',
      ];
      expect(
        audioRequests,
        isEmpty,
        reason: '本机不可用导致整理失败后点重试，不得绕过本机限制上传音频',
      );
      expect(wire.requests, isEmpty);
      expect(controller.organizeStatusFor(path).stage, OrganizeStage.failed);
      expect(controller.fileProcessingBusy, isFalse);
    },
  );

  test(
    '(e) 启动恢复旧的 queued 云端会议任务（无 taskId）：开关打开时不上传',
    () async {
      final wire = _WireRecordingClient();
      final audio = File('${dir.path}/1760000950.wav');
      await audio.writeAsBytes(_patternedWav(repeats: 100));

      final journalFile = File('${dir.path}/file_jobs.json');
      final seededJournal = FileJobJournal(file: journalFile);
      await seededJournal.enqueue(
        'file:1760000950',
        audio.path,
        const SpeechConfiguration(
          provider: SttProvider.qwen,
          sourceLanguage: 'auto',
          targetLanguage: 'zh',
          ownerLanguage: 'zh',
          guestLanguage: 'en',
          mode: SttDisplayMode.transcription,
          enabled: true,
          appleReady: false,
          appleTranslationReady: false,
          engines: {
            SttProvider.qwen: EngineConfig(
              apiKey: 'qwen-test-key',
              baseUrl: QwenSttService.defaultBaseUrl,
              model: QwenSttService.defaultModel,
            ),
          },
        ),
      );
      expect(seededJournal.jobs['file:1760000950']?.stage, 'queued');
      expect(seededJournal.jobs['file:1760000950']?.taskId, isNull);

      final controller = RecorderController(
        loadPersistedState: false,
        appleSpeech: _OnDeviceAppleSpeech(supported: true),
        qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
          ..apiKeyOverride = 'qwen-test-key',
        fileJobJournal: FileJobJournal(file: journalFile),
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${dir.path}/imports-restore'),
      )..exportedPaths = [audio.path];
      addTearDown(controller.dispose);

      // 等待启动恢复任务完成检查，并从磁盘读回确认日志已持久化为 failed
      final ref = RecordingReference(fileId: 1760000950, path: audio.path);
      Future<FileJob?> rereadFromDisk() async {
        final reader = FileJobJournal(file: journalFile);
        await reader.load();
        return reader.jobs['file:1760000950'];
      }

      FileJob? persistedJob;
      await _until(() {
        return controller.recordingView(ref).error != null &&
            !controller.fileProcessingBusy &&
            !controller.recordingView(ref).processing;
      });
      for (var i = 0; i < 100; i++) {
        persistedJob = await rereadFromDisk();
        if (persistedJob?.stage == 'failed') break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        wire.requests.map((r) => '${r.method} ${r.url}').toList(),
        isEmpty,
        reason: '启动恢复无 taskId 的 queued 云端会议任务时，在开关打开下不得上传音频',
      );
      expect(persistedJob?.stage, 'failed');
      expect(persistedJob?.error, contains('确认'));
      expect(controller.fileProcessingBusy, isFalse);
      expect(controller.recordingView(ref).processing, isFalse);
      expect(controller.recordingView(ref).error, contains('确认'));

      // 覆盖「已排队后才打开开关」：阻塞第一个任务，在开关关闭时将第二个云端会议任务入队，
      // 再打开开关并释放第一个任务，断言第二个任务零上传
      final firstAudio = File('${dir.path}/1760000951.wav');
      final secondAudio = File('${dir.path}/1760000952.wav');
      await firstAudio.writeAsBytes(_patternedWav(repeats: 100));
      await secondAudio.writeAsBytes(_patternedWav(repeats: 100));

      final queueJournal = FileJobJournal(
        file: File('${dir.path}/queue_jobs.json'),
      );
      final queueController = RecorderController(
        loadPersistedState: false,
        meetingLocalOnly: false,
        appleSpeech: _OnDeviceAppleSpeech(supported: true),
        qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
          ..apiKeyOverride = 'qwen-test-key',
        fileJobJournal: queueJournal,
        retrievedAudioSettleTime: Duration.zero,
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${dir.path}/imports-queue'),
      )..exportedPaths = [firstAudio.path, secondAudio.path];
      addTearDown(queueController.dispose);

      final firstReached = Completer<void>();
      final firstGate = Completer<void>();
      wire.gatePathSubstring = '/api/v1/tasks/';
      wire.requestReached = firstReached;
      wire.requestGate = firstGate;

      // 第一个任务在开关关闭时启动并阻塞在已提交后的轮询处
      unawaited(queueController.processRetrievedRecording(firstAudio.path));
      await firstReached.future;

      // 开关仍关闭时将第二个任务真正排入 _deferredJobs 队列
      expect(queueController.meetingLocalOnly, isFalse);
      await queueController.processRetrievedRecording(secondAudio.path);

      // 第二个任务尚在队列等待时打开「录音只留本机」，然后释放第一个任务
      queueController.setMeetingLocalOnly(true);
      firstGate.complete();

      final firstRef = RecordingReference(
        fileId: 1760000951,
        path: firstAudio.path,
      );
      final secondRef = RecordingReference(
        fileId: 1760000952,
        path: secondAudio.path,
      );
      await _until(
        () =>
            queueController.recordingView(firstRef).text == '云端千问转写结果' &&
            queueController.recordingView(secondRef).error != null &&
            !queueController.fileProcessingBusy &&
            !queueController.recordingView(secondRef).processing,
      );

      final ossUploads = wire.requests
          .where((r) => r.url.host == 'oss.example.com')
          .toList();
      expect(
        ossUploads,
        hasLength(1),
        reason: '只有开关关闭时已执行的第一个任务允许上传，排队期间打开开关的第二个任务必须零上传',
      );
      expect(queueController.recordingView(secondRef).text, isEmpty);
      expect(queueController.recordingView(secondRef).error, contains('确认'));
    },
  );

  test(
    '(f) 导入文件名为「语音记录 会议.wav」的音频仍按会议处理不上传；按住说话记一条后改标题仍按日常处理',
    () async {
      final wire = _WireRecordingClient();
      final apple = _OnDeviceAppleSpeech(supported: true);
      final phoneRecorder = _FakePhoneRecorder();

      final libraryFile = File('${dir.path}/library-title.json');
      final controller = RecorderController(
        loadPersistedState: false,
        appleSpeech: apple,
        qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
          ..apiKeyOverride = 'qwen-test-key',
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
        phoneRecorder: phoneRecorder,
        phoneRecordingEnabled: true,
        placeCapture: const _NoPlace(),
        transcriptPersister: ({bool strict = false}) async {},
        libraryStore: RecordingLibraryStore(file: libraryFile),
        libraryDirectory: Directory('${dir.path}/imports-title'),
      );
      addTearDown(controller.dispose);

      await controller.refreshAppleCapabilities();
      await controller.setAutoOrganize(true);

      // 1. 导入文件名为「语音记录 会议.wav」的音频：不得因标题前缀误判为日常语音记录
      final spoofedFile = File('${dir.path}/语音记录 会议.wav');
      await spoofedFile.writeAsBytes(_patternedWav(repeats: 100));
      final imported = await controller.importLocalAudio(spoofedFile.path);
      expect(imported.asset.displayName, '语音记录 会议');

      await _until(
        () =>
            controller.organizeStatusFor(imported.path).stage ==
                OrganizeStage.done &&
            !controller.fileProcessingBusy,
      );

      final uploadRequests = [
        for (final req in wire.requests)
          if (req.url.host.contains('oss') ||
              req.url.path.contains('/api/v1/uploads') ||
              req.url.path.contains('/services/audio/asr/transcription') ||
              _containsSublist(req.bodyBytes, ascii.encode('RIFF')) ||
              _containsSublist(req.bodyBytes, _pcmPattern))
            '${req.method} ${req.url}',
      ];
      expect(
        uploadRequests,
        isEmpty,
        reason: '导入文件名为「语音记录 会议.wav」时仍须按会议录音处理，不得上传音频',
      );
      expect(
        controller
            .recordingView(RecordingReference(path: imported.path))
            .provider,
        SttProvider.apple,
      );

      // 2. 按住说话记一条后改标题（去掉「语音记录 」前缀），仍按日常用途处理
      await controller.setAutoOrganize(false);
      wire.requests.clear();
      expect(await controller.startVoiceHold(VoiceTarget.note), isTrue);
      final notePath = await controller.finishVoiceNote();
      expect(notePath, isNotNull);
      await _until(
        () =>
            controller.transcriptForPath(notePath!) == '云端千问转写结果' &&
            !controller.fileProcessingBusy,
      );
      final renamedPath = await controller.renameLocalExport(
        notePath!,
        '客户回访备忘',
      );
      expect(
        controller.library.assetForPath(renamedPath)?.displayName,
        '客户回访备忘',
      );
      // 落盘后用新 RecordingLibraryStore 读回，确认 voiceNote: true 与导入录音的 false 均持久化
      final reloadedLibrary = RecordingLibraryStore(file: libraryFile);
      await reloadedLibrary.load();
      expect(reloadedLibrary.assetForPath(renamedPath)?.voiceNote, isTrue);
      expect(reloadedLibrary.assetForPath(imported.path)?.voiceNote, isFalse);
      // 改名后清除文字并直接重跑转写（无需会议二次确认，仍走千问日常通道）
      controller.transcriptsByPath.remove(renamedPath);
      wire.requests.clear();
      await controller.transcribeRecording(
        RecordingReference(path: renamedPath),
      );
      await _until(
        () =>
            controller.transcriptForPath(renamedPath) == '云端千问转写结果' &&
            !controller.fileProcessingBusy,
      );
      expect(
        controller
            .recordingView(RecordingReference(path: renamedPath))
            .error,
        isNull,
      );
      expect(
        controller
            .recordingView(RecordingReference(path: renamedPath))
            .text,
        '云端千问转写结果',
      );
      expect(
        controller
            .recordingView(RecordingReference(path: renamedPath))
            .provider,
        SttProvider.qwen,
      );
    },
  );

  testWidgets(
    '(g) 开关关闭或开启、全局引擎 Apple 时，点「使用通义 Qwen 转写…」「使用豆包转写…」请求真实发往对应服务且不改全局引擎',
    (tester) async {
      final wire = _WireRecordingClient();
      final apple = _OnDeviceAppleSpeech(supported: true);
      late RecorderController controller;
      late File audio;

      await tester.runAsync(() async {
        audio = File('${dir.path}/1760000999.wav');
        await audio.writeAsBytes(_patternedWav(repeats: 100));
        controller = RecorderController(
          loadPersistedState: false,
          appleSpeech: apple,
          qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
            ..apiKeyOverride = 'qwen-test-key',
          doubaoSpeech: DoubaoSttService(client: wire)
            ..apiKeyOverride = 'doubao-test-key',
          transcriptPersister: ({bool strict = false}) async {},
          libraryDirectory: Directory('${dir.path}/imports-menu'),
        )..exportedPaths = [audio.path];
        await controller.refreshAppleCapabilities();
        controller.setMeetingLocalOnly(false);
        controller.setSpeechProvider(SttProvider.apple);
      });
      addTearDown(controller.dispose);

      final ref = RecordingReference(fileId: 1760000999, path: audio.path);
      expect(controller.meetingLocalOnly, isFalse);
      expect(controller.speechProvider, SttProvider.apple);

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(home: RecordingDetailScreen(reference: ref)),
        ),
      );
      await tester.pumpAndSettle();

      // 1. 开关关闭时点「使用通义 Qwen 转写…」：无需二次确认，请求真实发到千问
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('使用通义 Qwen 转写…'), findsOneWidget);
      expect(find.text('使用豆包转写…'), findsOneWidget);
      await tester.tap(find.text('使用通义 Qwen 转写…'));
      for (
        var i = 0;
        i < 100 &&
            (controller.recordingView(ref).text != '云端千问转写结果' ||
                controller.recordingView(ref).processing ||
                controller.fileProcessingBusy);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();

      expect(
        wire.requests.any(
          (r) => r.url.path.endsWith('/services/audio/asr/transcription'),
        ),
        isTrue,
        reason: '开关关闭且全局引擎为 Apple 时，点「使用通义 Qwen 转写…」必须真实发请求到千问',
      );
      expect(controller.recordingView(ref).text, '云端千问转写结果');
      expect(controller.recordingView(ref).provider, SttProvider.qwen);
      expect(controller.speechProvider, SttProvider.apple);
      expect(controller.fileProcessingBusy, isFalse);
      expect(controller.recordingView(ref).processing, isFalse);

      // 2. 开关关闭时点「使用豆包转写…」：请求真实发到豆包
      wire.requests.clear();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用豆包转写…'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-cloud-transcribe')));
      for (
        var i = 0;
        i < 100 &&
            (controller.recordingView(ref).text != '云端豆包转写结果' ||
                controller.recordingView(ref).processing ||
                controller.fileProcessingBusy);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(
        wire.requests.any((r) => r.url.path.contains('/auc/bigmodel/recognize')),
        isTrue,
        reason: '点「使用豆包转写…」必须真实发请求到豆包',
      );
      expect(controller.recordingView(ref).text, '云端豆包转写结果');
      expect(controller.recordingView(ref).provider, SttProvider.doubao);
      expect(controller.speechProvider, SttProvider.apple);

      // 3. 开关开启时点「使用通义 Qwen 转写…」：先二次确认，运行中显示「停止等待（保留已提交任务）」，确认后发到千问且全局仍为 Apple
      controller.setMeetingLocalOnly(true);
      wire.requests.clear();
      final qwenReached = Completer<void>();
      final qwenGate = Completer<void>();
      addTearDown(() {
        if (!qwenGate.isCompleted) qwenGate.complete();
      });
      wire.requestReached = qwenReached;
      wire.requestGate = qwenGate;
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用通义 Qwen 转写…'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('录音只留本机'), findsOneWidget);
      expect(wire.requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('confirm-cloud-transcribe')));
      for (var i = 0; i < 50 && !qwenReached.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(qwenReached.isCompleted, isTrue);
      expect(controller.speechProvider, SttProvider.apple);
      expect(
        find.text('停止等待（保留已提交任务）'),
        findsOneWidget,
        reason: '全局引擎为 Apple 但当前任务实际运行千问时，详情页应显示千问停止等待按钮',
      );
      qwenGate.complete();
      for (
        var i = 0;
        i < 100 &&
            (controller.recordingView(ref).text != '云端千问转写结果' ||
                controller.recordingView(ref).processing ||
                controller.fileProcessingBusy);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(
        wire.requests.any(
          (r) => r.url.path.endsWith('/services/audio/asr/transcription'),
        ),
        isTrue,
      );
      expect(controller.recordingView(ref).text, '云端千问转写结果');
      expect(controller.speechProvider, SttProvider.apple);
    },
  );

  test(
    '(h) running 阶段日志保存期间打开「录音只留本机」开关：释放后不上传音频（检查序列化后的真实字节与上传端点）',
    () async {
      final wire = _WireRecordingClient();
      final audio = File('${dir.path}/1760000977.wav');
      await audio.writeAsBytes(_patternedWav(repeats: 100));

      final runningSaveReached = Completer<void>();
      final runningSaveGate = Completer<void>();
      final journalFile = File('${dir.path}/running_window_jobs.json');
      final journal = _ControllableFileJobJournal(file: journalFile)
        ..runningSaveReached = runningSaveReached
        ..runningSaveGate = runningSaveGate;

      final controller = RecorderController(
        loadPersistedState: false,
        meetingLocalOnly: false,
        appleSpeech: _OnDeviceAppleSpeech(supported: true),
        qwenSpeech: QwenSttService(client: wire, pollInterval: Duration.zero)
          ..apiKeyOverride = 'qwen-test-key',
        fileJobJournal: journal,
        retrievedAudioSettleTime: Duration.zero,
        transcriptPersister: ({bool strict = false}) async {},
        libraryDirectory: Directory('${dir.path}/imports-window'),
      )..exportedPaths = [audio.path];
      addTearDown(controller.dispose);

      // 开关关闭时发起转写，使任务通过前置检查并进入 running 阶段落盘等待
      final transcription = controller.transcribeLocalFile(audio.path);
      await runningSaveReached.future;
      expect(wire.requests, isEmpty, reason: 'running 落盘完成前尚未发起网络请求');

      // 在 running 阶段落盘等待窗口内打开「录音只留本机」开关，然后释放落盘
      controller.setMeetingLocalOnly(true);
      runningSaveGate.complete();
      await transcription;

      final ref = RecordingReference(fileId: 1760000977, path: audio.path);
      await _until(
        () =>
            !controller.fileProcessingBusy &&
            !controller.recordingView(ref).processing,
      );

      final audioCarryingRequests = [
        for (final req in wire.requests)
          if (_containsSublist(req.bodyBytes, ascii.encode('RIFF')) ||
              _containsSublist(req.bodyBytes, ascii.encode('WAVE')) ||
              _containsSublist(req.bodyBytes, _pcmPattern) ||
              req.url.host.contains('oss') ||
              req.url.path.contains('/api/v1/uploads') ||
              req.url.path.contains('/services/audio/asr/transcription'))
            '${req.method} ${req.url} (${req.bodyBytes.length} bytes)',
      ];
      expect(
        audioCarryingRequests,
        isEmpty,
        reason: 'running 落盘期间打开开关后，释放时不得开始上传任何音频字节或请求上传端点',
      );
      expect(wire.requests, isEmpty);
      expect(controller.recordingView(ref).error, contains('确认'));

      final reloaded = FileJobJournal(file: journalFile);
      await reloaded.load();
      expect(reloaded.jobs['file:1760000977']?.stage, 'failed');
    },
  );
}
