import 'dart:async';
import 'package:anker_recorder/state/file_job_journal.dart';
import 'package:anker_recorder/state/speech_configuration.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Endian;

import 'package:http/http.dart' as http;

import 'package:anker_recorder/ai/apple_speech.dart';
import 'package:anker_recorder/ai/doubao_stt.dart';
import 'package:anker_recorder/audio/ogg_opus.dart';
import 'package:anker_recorder/ai/engine_config.dart';
import 'package:anker_recorder/ai/qwen_stt.dart';
import 'package:anker_recorder/ai/stt_types.dart';
import 'package:anker_recorder/ble/ble_service.dart';
import 'package:anker_recorder/ble/realtime_stream.dart';
import 'package:anker_recorder/protocol/frame.dart';
import 'package:anker_recorder/protocol/models.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RecorderController controller(_Apple apple, {_Ble? ble, _Cloud? cloud}) {
    final result =
        RecorderController(
            loadPersistedState: false,
            ble: ble,
            appleSpeech: apple,
            doubaoSpeech: cloud,
          )
          ..speechProvider = SttProvider.apple
          ..appleSourceLanguage = 'en-US';
    addTearDown(() async {
      result.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    return result;
  }

  test('journal write failure prevents a cloud request', () async {
    final qwen = _Qwen();
    final c =
        RecorderController(
            loadPersistedState: false,
            qwenSpeech: qwen,
            fileJobJournal: _UnwritableJournal(),
          )
          ..setQwenConfig(const EngineConfig(apiKey: 'key'))
          ..setSpeechProvider(SttProvider.qwen);
    addTearDown(c.dispose);
    await c.transcribeLocalFile('/not-submitted.wav');
    expect(qwen.calls, 0);
    expect(
      c
          .recordingView(const RecordingReference(path: '/not-submitted.wav'))
          .error,
      contains('存储空间'),
    );
  });

  for (final stage in ['queued', 'result', 'running', 'submitted']) {
    test(
      'controller restart recovers $stage without duplicate submission',
      () async {
        final dir = await Directory.systemTemp.createTemp('restart-test-');
        addTearDown(() => dir.delete(recursive: true));
        final audio = File('${dir.path}/998877.wav');
        await audio.writeAsBytes([1, 2, 3]);
        final file = File('${dir.path}/jobs.json');
        final journal = FileJobJournal(file: file);
        final job = await journal.enqueue(
          'file:998877',
          audio.path,
          const SpeechConfiguration(
            provider: SttProvider.qwen,
            sourceLanguage: 'zh',
            targetLanguage: 'en',
            ownerLanguage: 'zh',
            guestLanguage: 'en',
            mode: SttDisplayMode.transcription,
            enabled: true,
            appleReady: false,
            appleTranslationReady: false,
            engines: {
              SttProvider.qwen: EngineConfig(
                baseUrl: QwenSttService.defaultBaseUrl,
                model: 'saved-model',
              ),
            },
          ),
        );
        job.stage = stage == 'submitted' ? 'running' : stage;
        if (stage == 'submitted') job.taskId = 'saved-task-id';
        if (stage == 'result') {
          job.text = 'Recovered result';
          job.language = 'zh';
        }
        await journal.save();
        final reopened = FileJobJournal(file: file);
        final qwen = _Qwen();
        final c =
            RecorderController(
              loadPersistedState: false,
              qwenSpeech: qwen,
              fileJobJournal: reopened,
            )..setQwenConfig(
              const EngineConfig(apiKey: 'current-key', model: 'new-model'),
            );
        addTearDown(c.dispose);
        if (stage == 'running') {
          await settleUntil(() => reopened.jobs.isNotEmpty);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(qwen.calls, 0);
          expect(reopened.jobs.values.single.error, contains('重复计费'));
        } else {
          await settleUntil(
            () => reopened.jobs.values.any((j) => j.stage == 'complete'),
          );
          expect(qwen.calls, stage == 'result' ? 0 : 1);
          if (stage == 'submitted') expect(qwen.seenTaskId, 'saved-task-id');
          expect(
            c.transcriptForPath(audio.path),
            stage == 'result' ? 'Recovered result' : '通义文本',
          );
          if (stage == 'queued') expect(qwen.seenModel, 'saved-model');
        }
      },
    );
  }

  test(
    'retrieved audio obeys auto switch and deduplicates repeated completion',
    () async {
      final dir = await Directory.systemTemp.createTemp('retrieved-test-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/987654.wav';
      await File(path).writeAsBytes([1, 2, 3]);
      final qwen = _Qwen();
      final journal = FileJobJournal(inMemory: true);
      final c =
          RecorderController(
              loadPersistedState: false,
              qwenSpeech: qwen,
              fileJobJournal: journal,
            )
            ..setQwenConfig(const EngineConfig(apiKey: 'key'))
            ..setSpeechProvider(SttProvider.qwen)
            ..setAutoTranscribe(false);
      addTearDown(c.dispose);
      await c.processRetrievedRecording(path);
      expect(qwen.calls, 0);
      c.setAutoTranscribe(true);
      await Future.wait([
        c.processRetrievedRecording(path),
        c.processRetrievedRecording(path),
      ]);
      for (
        var i = 0;
        i < 100 && journal.jobs.values.first.stage != 'complete';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(qwen.calls, 1);
      expect(c.transcriptForPath(path), '通义文本');
      expect(journal.jobs.values.single.stage, 'complete');
      await c.processRetrievedRecording(path);
      expect(qwen.calls, 1);
    },
  );

  test(
    'retrieved raw audio and missing configuration do not make requests',
    () async {
      final qwen = _Qwen();
      final c = RecorderController(loadPersistedState: false, qwenSpeech: qwen)
        ..setSpeechProvider(SttProvider.qwen)
        ..setAutoTranscribe(true);
      addTearDown(c.dispose);
      await c.processRetrievedRecording('/not-decoded.opus.bin');
      await c.processRetrievedRecording('/not-configured.wav');
      expect(qwen.calls, 0);
      expect(
        c
            .recordingView(
              const RecordingReference(path: '/not-configured.wav'),
            )
            .error,
        contains('配置'),
      );
    },
  );

  test(
    'Qwen file transcription starts after stop and keeps the take settings',
    () async {
      final directory = await Directory.systemTemp.createTemp('qwen-stop-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/301.wav');
      await file.writeAsBytes([1, 2, 3]);
      final qwen = _Qwen()..apiKeyOverride = 'qwen-key';
      final ble = _Ble();
      final c = RecorderController(
        loadPersistedState: false,
        ble: ble,
        qwenSpeech: qwen,
        appleSpeech: _Apple(),
      )..setSpeechProvider(SttProvider.qwen);
      addTearDown(c.dispose);
      c.setTranscriptLanguage('zh');
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          active: true,
          fileId: 301,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      c.handleRealtimeOpusFrameForTesting(Uint8List(160));
      expect(qwen.calls, 0);
      expect(c.pcmFramesDecoded, 0);
      expect(c.streamingSttActive, isFalse);
      c.setQwenConfig(const EngineConfig(apiKey: 'changed-key'));
      c.setSpeechProvider(SttProvider.apple);
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 301, path: file.path, bytesReceived: 320),
      );
      await settleUntil(() => qwen.calls == 1);
      expect(qwen.seenKey, 'qwen-key');
      expect(qwen.seenLanguage, 'zh');
      expect(qwen.seenModel, QwenSttService.defaultModel);
      expect(qwen.seenBase, QwenSttService.defaultBaseUrl);
      final view = c.recordingView(RecordingReference(path: file.path));
      expect(view.text, '通义文本');
      expect(view.provider, SttProvider.qwen);
    },
  );

  test(
    'Doubao file transcription starts after stop and keeps the take settings',
    () async {
      final directory = await Directory.systemTemp.createTemp('doubao-stop-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/401.wav');
      await file.writeAsBytes([1, 2, 3]);
      final doubao = _Doubao()..apiKeyOverride = 'doubao-key';
      final ble = _Ble();
      final c = RecorderController(
        loadPersistedState: false,
        ble: ble,
        doubaoSpeech: doubao,
        appleSpeech: _Apple(),
      )..setSpeechProvider(SttProvider.doubao);
      addTearDown(c.dispose);
      c.setTranscriptLanguage('zh');
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          active: true,
          fileId: 401,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      c.handleRealtimeOpusFrameForTesting(Uint8List(160));
      expect(doubao.calls, 0);
      c.setDoubaoConfig(const EngineConfig(apiKey: 'changed-key'));
      c.setSpeechProvider(SttProvider.apple);
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 401, path: file.path, bytesReceived: 320),
      );
      await settleUntil(() => doubao.calls == 1);
      expect(doubao.seenKey, 'doubao-key');
      expect(doubao.seenLanguage, 'zh');
      expect(doubao.seenModel, DoubaoSttService.defaultModel);
      expect(doubao.seenBase, DoubaoSttService.defaultBaseUrl);
      final view = c.recordingView(RecordingReference(path: file.path));
      expect(view.text, '豆包文本');
      expect(view.provider, SttProvider.doubao);
    },
  );

  test('queued deferred jobs run one at a time in FIFO order', () async {
    final directory = await Directory.systemTemp.createTemp('qwen-fifo-');
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/311.wav');
    await first.writeAsBytes([1, 2, 3]);
    final second = File('${directory.path}/312.wav');
    await second.writeAsBytes([1, 2, 3]);
    final qwen = _Qwen()
      ..apiKeyOverride = 'qwen-key'
      ..pending = Completer<void>();
    final ble = _Ble();
    final c = RecorderController(
      loadPersistedState: false,
      ble: ble,
      qwenSpeech: qwen,
      appleSpeech: _Apple(),
    )..setSpeechProvider(SttProvider.qwen);
    addTearDown(c.dispose);

    Future<void> recordTake(int fileId, File file) async {
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          active: true,
          fileId: fileId,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      c.handleRealtimeOpusFrameForTesting(Uint8List(160));
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          fileId: fileId,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }

    await recordTake(311, first);
    await settleUntil(() => qwen.calls == 1);
    // The first job is still in flight; record and stop a second take so it
    // queues behind it.
    await recordTake(312, second);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(qwen.calls, 1, reason: '单并发：第二个任务必须等第一个完成');
    qwen.pending!.complete();
    await settleUntil(() => qwen.calls == 2);
    expect(qwen.paths, [first.path, second.path]);
  });

  test('a repeated stop event does not rerun a started deferred job', () async {
    final directory = await Directory.systemTemp.createTemp('qwen-redo-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/313.wav');
    await file.writeAsBytes([1, 2, 3]);
    final qwen = _Qwen()..apiKeyOverride = 'qwen-key';
    final ble = _Ble();
    final c = RecorderController(
      loadPersistedState: false,
      ble: ble,
      qwenSpeech: qwen,
      appleSpeech: _Apple(),
    )..setSpeechProvider(SttProvider.qwen);
    addTearDown(c.dispose);
    await c.startRecord();
    c.handleRealtimeStateForTesting(
      RealtimeStreamState(
        active: true,
        fileId: 313,
        path: file.path,
        bytesReceived: 320,
      ),
    );
    c.handleRealtimeOpusFrameForTesting(Uint8List(160));
    ble.stopRecording();
    await Future<void>.delayed(Duration.zero);
    final stopped = RealtimeStreamState(
      fileId: 313,
      path: file.path,
      bytesReceived: 320,
    );
    c.handleRealtimeStateForTesting(stopped);
    await settleUntil(() => qwen.calls == 1);
    // A duplicated stop notification must not transcribe the take again.
    c.handleRealtimeStateForTesting(stopped);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(qwen.calls, 1);
  });

  test(
    'Doubao failure shows a readable error and one manual retry succeeds',
    () async {
      final directory = await Directory.systemTemp.createTemp('doubao-retry-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/403.wav');
      await file.writeAsBytes([1, 2, 3]);
      final doubao = _Doubao()
        ..apiKeyOverride = 'doubao-key'
        ..failure = const DoubaoSttException('豆包请求过多，请稍后重试');
      final ble = _Ble();
      final c = RecorderController(
        loadPersistedState: false,
        ble: ble,
        doubaoSpeech: doubao,
        appleSpeech: _Apple(),
      )..setSpeechProvider(SttProvider.doubao);
      addTearDown(c.dispose);
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          active: true,
          fileId: 403,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      c.handleRealtimeOpusFrameForTesting(Uint8List(160));
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 403, path: file.path, bytesReceived: 320),
      );

      // The automatic attempt failed once and surfaced the readable cause.
      await settleUntil(() => doubao.calls == 1);
      final failed = c.recordingView(RecordingReference(path: file.path));
      expect(failed.error, '豆包请求过多，请稍后重试');
      expect(failed.text, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(doubao.calls, 1, reason: '失败后不自动重试');

      // The manual retry from the detail screen succeeds with current
      // settings and replaces the error with the transcript.
      doubao.failure = null;
      await c.transcribeLocalFile(file.path);
      expect(doubao.calls, 2);
      final recovered = c.recordingView(RecordingReference(path: file.path));
      expect(recovered.text, '豆包文本');
      expect(recovered.error, isNull);
    },
  );

  test(
    'Doubao model rejection reaches the detail as a readable error',
    () async {
      final directory = await Directory.systemTemp.createTemp('doubao-model-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/404.wav');
      await file.writeAsBytes([1, 2, 3]);
      final doubao = _Doubao()
        ..apiKeyOverride = 'doubao-key'
        ..failure = DoubaoSttException(
          doubaoModelRejection('volc.seedasr.auc')!,
        );
      final c = RecorderController(
        loadPersistedState: false,
        doubaoSpeech: doubao,
        appleSpeech: _Apple(),
      )..setSpeechProvider(SttProvider.doubao);
      addTearDown(c.dispose);

      await c.transcribeLocalFile(file.path);

      final view = c.recordingView(RecordingReference(path: file.path));
      expect(view.error, contains('标准版'));
      expect(view.error, contains('volc.bigasr.auc_turbo'));
      expect(view.text, isEmpty);
    },
  );

  test(
    'Doubao manual trigger without a key prompts to configure first',
    () async {
      final directory = await Directory.systemTemp.createTemp('doubao-nokey-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/405.wav');
      await file.writeAsBytes([1, 2, 3]);
      final doubao = _Doubao();
      final c = RecorderController(
        loadPersistedState: false,
        doubaoSpeech: doubao,
        appleSpeech: _Apple(),
      )..setSpeechProvider(SttProvider.doubao);
      addTearDown(c.dispose);

      await c.transcribeLocalFile(file.path);

      expect(doubao.calls, 0);
      expect(
        c.recordingView(RecordingReference(path: file.path)).error,
        '请在设置中配置 豆包',
      );
    },
  );

  test(
    'Doubao demo path: record a take, stop, and read the Chinese transcript',
    () async {
      final directory = await Directory.systemTemp.createTemp('doubao-demo-');
      addTearDown(() => directory.delete(recursive: true));
      final audio = OggOpus.muxRawFrames(
        Uint8List.fromList(List.filled(160, 1)),
      );
      final file = File('${directory.path}/406.wav');
      await file.writeAsBytes(audio);

      final client = _ScriptedClient();
      client.enqueue(
        200,
        {
          'audio_info': {'duration': 6312},
          'result': {'text': '你好，世界。'},
        },
        headers: {'x-api-status-code': '20000000'},
      );
      final service = DoubaoSttService(client: client);
      final ble = _Ble();
      final c =
          RecorderController(
              loadPersistedState: false,
              ble: ble,
              doubaoSpeech: service,
              appleSpeech: _Apple(),
            )
            ..setSpeechProvider(SttProvider.doubao)
            ..setDoubaoConfig(const EngineConfig(apiKey: 'doubao-key'));
      addTearDown(c.dispose);
      c.setTranscriptLanguage('zh');

      // 录一段（假传输）。
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          active: true,
          fileId: 406,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      c.handleRealtimeOpusFrameForTesting(Uint8List(160));
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(fileId: 406, path: file.path, bytesReceived: 320),
      );

      await settleUntil(
        () =>
            c.recordingView(RecordingReference(path: file.path)).text ==
            '你好，世界。',
      );
      final request = client.requests.single;
      expect(
        request.url.toString(),
        'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
      );
      expect(request.headers['x-api-key'], 'doubao-key');
      expect(request.headers['x-api-resource-id'], 'volc.bigasr.auc_turbo');
      final body = jsonDecode(client.bodies.single) as Map<String, dynamic>;
      expect((body['audio'] as Map)['data'], base64Encode(audio));
      expect((body['audio'] as Map)['language'], 'zh-CN');

      // 详情出中文文稿。
      final view = c.recordingView(RecordingReference(path: file.path));
      expect(view.text, '你好，世界。');
      expect(view.provider, SttProvider.doubao);
      expect(view.error, isNull);
    },
  );

  test(
    'Doubao job reports in-flight progress to the recording detail',
    () async {
      final directory = await Directory.systemTemp.createTemp('doubao-prog-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/407.wav');
      await file.writeAsBytes([1, 2, 3]);
      final doubao = _Doubao()
        ..apiKeyOverride = 'doubao-key'
        ..pending = Completer<void>();
      final c = RecorderController(
        loadPersistedState: false,
        doubaoSpeech: doubao,
        appleSpeech: _Apple(),
      )..setSpeechProvider(SttProvider.doubao);
      addTearDown(c.dispose);

      final work = c.transcribeLocalFile(file.path);
      await settleUntil(() => doubao.calls == 1);

      // In flight: the detail shows processing with the live stage.
      final view = c.recordingView(RecordingReference(path: file.path));
      expect(view.processing, isTrue);
      expect(view.progress?.stage, SttFileStage.uploading);

      doubao.pending!.complete();
      await work;
      final done = c.recordingView(RecordingReference(path: file.path));
      expect(done.processing, isFalse);
      expect(done.text, '豆包文本');
    },
  );

  test('Qwen and Doubao transcripts coexist across engine switches', () async {
    final directory = await Directory.systemTemp.createTemp('mixed-eng-');
    addTearDown(() => directory.delete(recursive: true));
    final qwenFile = File('${directory.path}/501.wav');
    await qwenFile.writeAsBytes([1, 2, 3]);
    final doubaoFile = File('${directory.path}/502.wav');
    await doubaoFile.writeAsBytes([1, 2, 3]);
    final qwen = _Qwen()..apiKeyOverride = 'qwen-key';
    final doubao = _Doubao()..apiKeyOverride = 'doubao-key';
    final ble = _Ble();
    final c = RecorderController(
      loadPersistedState: false,
      ble: ble,
      qwenSpeech: qwen,
      doubaoSpeech: doubao,
      appleSpeech: _Apple(),
    )..setSpeechProvider(SttProvider.qwen);
    addTearDown(c.dispose);

    Future<void> recordTake(int fileId, File file) async {
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          active: true,
          fileId: fileId,
          path: file.path,
          bytesReceived: 320,
        ),
      );
      c.handleRealtimeOpusFrameForTesting(Uint8List(160));
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      c.handleRealtimeStateForTesting(
        RealtimeStreamState(
          fileId: fileId,
          path: file.path,
          bytesReceived: 320,
        ),
      );
    }

    // Take 1 on Qwen.
    await recordTake(501, qwenFile);
    await settleUntil(() => qwen.calls == 1);
    // Take 2 on Doubao after switching the default engine.
    c.setSpeechProvider(SttProvider.doubao);
    await recordTake(502, doubaoFile);
    await settleUntil(() => doubao.calls == 1);

    // Switching the default engine again changes neither stored result.
    c.setSpeechProvider(SttProvider.apple);
    final first = c.recordingView(RecordingReference(path: qwenFile.path));
    final second = c.recordingView(RecordingReference(path: doubaoFile.path));
    expect(first.text, '通义文本');
    expect(first.provider, SttProvider.qwen);
    expect(second.text, '豆包文本');
    expect(second.provider, SttProvider.doubao);
    expect(qwen.calls, 1);
    expect(doubao.calls, 1);
  });

  test('provider defaults preserve explicit choices and configured cloud', () {
    expect(
      initialSpeechProvider(
        saved: null,
        appleSupported: true,
        qwenConfigured: false,
      ),
      SttProvider.apple,
    );
    expect(
      initialSpeechProvider(
        saved: null,
        appleSupported: true,
        qwenConfigured: true,
      ),
      SttProvider.qwen,
    );
    expect(
      initialSpeechProvider(
        saved: SttProvider.doubao,
        appleSupported: true,
        qwenConfigured: false,
      ),
      SttProvider.doubao,
    );
    expect(
      initialSpeechProvider(
        saved: SttProvider.apple,
        appleSupported: false,
        qwenConfigured: true,
      ),
      SttProvider.apple,
    );
  });

  test(
    'device refresh waits for the final inventory page and coalesces pulls',
    () async {
      final ble = _Ble();
      final c = controller(_Apple(), ble: ble)
        ..connected = true
        ..autoRealtime = false;
      var completed = false;
      final refresh = c.refreshDeviceFiles().then((_) => completed = true);
      final repeated = c.refreshDeviceFiles();
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      ble.filePage(List.generate(10, (i) => 100 + i));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(c.files, hasLength(10));
      expect(completed, isFalse);
      ble.filePage([110]);
      await refresh.timeout(const Duration(seconds: 1));
      await repeated;
      expect(c.files, hasLength(11));
    },
  );

  testWidgets('device refresh times out without removing existing recordings', (
    tester,
  ) async {
    final c = RecorderController(loadPersistedState: false, ble: _Ble())
      ..connected = true
      ..autoRealtime = false
      ..files = [OfflineFileEntry(fileId: 100, sizeBytes: 160)];
    addTearDown(c.dispose);
    final refresh = c.refreshDeviceFiles();
    await tester.pump();
    await tester.pump(const Duration(seconds: 21));
    await refresh;
    expect(c.errorMessage, '刷新超时，请下拉重试');
    expect(c.files.single.fileId, 100);
  });

  test('suggested source is checked before exposing Apple readiness', () async {
    final apple = _Apple();
    final c = controller(apple)..appleSourceLanguage = '';
    await c.refreshAppleCapabilities();
    expect(apple.queries, [null, 'en-US']);
    expect(c.appleSourceLanguage, 'en-US');
    expect(c.sttConfigured, isTrue);
    c.setSttMode(SttDisplayMode.conversation);
    expect(c.conversationModeAvailable, isFalse);
    expect(c.sttMode, SttDisplayMode.transcription);
  });

  test('Apple file failure preserves text and never calls cloud', () async {
    final apple = _Apple()
      ..failure = PlatformException(code: 'resources_missing');
    final cloud = _Cloud();
    final c = controller(apple, cloud: cloud);
    await c.refreshAppleCapabilities();
    const ref = RecordingReference(path: '/tmp/123.wav');
    c.rememberTranscript(ref.path!, 'Existing transcript');
    await c.transcribeRecording(ref);
    expect(c.recordingView(ref).text, 'Existing transcript');
    expect(c.recordingView(ref).error, contains('下载'));
    expect(apple.fileCalls, 1);
    expect(cloud.fileCalls, 0);
  });

  test('saved-file transcription does not replace the live draft', () async {
    final apple = _Apple();
    final c = controller(apple)..transcript = 'Unrelated draft';
    await c.refreshAppleCapabilities();
    const ref = RecordingReference(path: '/tmp/124.wav');
    await c.transcribeRecording(ref);
    expect(c.transcript, 'Unrelated draft');
    expect(c.recordingView(ref).text, 'Apple result');
    expect(c.recordingView(ref).provider, SttProvider.apple);
    expect(c.recordingView(ref).sourceLanguage, 'en-US');
  });

  test(
    'recording language overrides an unavailable global language and is remembered',
    () async {
      final apple = _Apple()
        ..statuses['en-US'] = SpeechResourceStatus.needsDownload;
      final c = controller(apple);
      await c.refreshAppleCapabilities();
      expect(c.sttConfigured, isFalse);
      const ref = RecordingReference(path: '/tmp/130.wav');
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(apple.fileLanguages, ['zh-CN']);
      expect(c.recordingView(ref).sourceLanguage, 'zh-CN');
      expect(c.appleSourceLanguage, 'en-US');
      expect(c.sttConfigured, isFalse);
      await c.transcribeRecording(ref);
      expect(apple.fileLanguages, ['zh-CN', 'zh-CN']);
    },
  );

  test(
    'only an explicit download action prepares the selected speech language',
    () async {
      final apple = _Apple()
        ..statuses['zh-CN'] = SpeechResourceStatus.needsDownload;
      final c = controller(apple);
      const ref = RecordingReference(path: '/tmp/131.wav');
      c.rememberTranscript(
        ref.path!,
        'Previous result',
        sourceLanguage: 'en-US',
      );
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(apple.preparedLanguages, isEmpty);
      expect(apple.fileCalls, 0);
      expect(c.recordingView(ref).text, 'Previous result');
      await c.transcribeRecording(
        ref,
        sourceLanguage: 'zh-CN',
        prepareLanguages: true,
      );
      expect(apple.preparedLanguages, [('zh-CN', null)]);
      expect(apple.fileLanguages, ['zh-CN']);
      expect(c.appleSourceLanguage, 'en-US');
    },
  );

  test(
    'a failed language change retains the original language and translation',
    () async {
      final apple = _Apple();
      final c = controller(apple);
      const ref = RecordingReference(path: '/tmp/132.wav');
      c.rememberTranscript(ref.path!, 'Apple result', sourceLanguage: 'en-US');
      await c.translateRecording(ref);
      apple.failure = PlatformException(code: 'processing_failed');
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(c.recordingView(ref).sourceLanguage, 'en-US');
      expect(c.recordingView(ref).translation?.text, '译文');
      apple.failure = null;
      await c.transcribeRecording(ref, sourceLanguage: 'zh-CN');
      expect(c.recordingView(ref).text, 'Apple result');
      expect(c.recordingView(ref).sourceLanguage, 'zh-CN');
      expect(c.recordingView(ref).translation, isNull);
    },
  );

  test(
    'unsupported recording language never reaches transcription or the cloud',
    () async {
      final apple = _Apple()
        ..statuses['unsupported'] = SpeechResourceStatus.unsupported;
      final cloud = _Cloud();
      final c = controller(apple, cloud: cloud);
      const ref = RecordingReference(path: '/tmp/133.wav');
      await c.transcribeRecording(
        ref,
        sourceLanguage: 'unsupported',
        prepareLanguages: true,
      );
      expect(apple.fileCalls, 0);
      expect(cloud.fileCalls, 0);
      expect(apple.preparedLanguages, isEmpty);
      expect(c.recordingView(ref).error, contains('更换语言'));
    },
  );

  test('late translation cannot attach to a replaced source', () async {
    final pending = Completer<String>();
    final apple = _Apple()..pendingTranslation = pending;
    final c = controller(apple);
    const ref = RecordingReference(path: '/tmp/125.wav');
    c.rememberTranscript(ref.path!, 'First source');
    final translating = c.translateRecording(ref);
    await Future<void>.delayed(Duration.zero);
    c.rememberTranscript(ref.path!, 'Replacement source');
    pending.complete('Old translation');
    await translating;
    expect(c.recordingView(ref).translation, isNull);
    expect(c.recordingView(ref).text, 'Replacement source');
  });

  test('translation survives failed retranscription and file rename', () async {
    final directory = await Directory.systemTemp.createTemp(
      'soundcore-translation-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/126.wav');
    await file.writeAsBytes([1, 2, 3]);
    final apple = _Apple();
    final c = controller(apple)..exportedPaths = [file.path];
    await c.refreshAppleCapabilities();
    final ref = RecordingReference(fileId: 126, path: file.path);
    c.rememberTranscript(file.path, 'Original');
    await c.translateRecording(ref);
    expect(c.recordingView(ref).translation?.text, '译文');
    apple.failure = PlatformException(code: 'processing_failed');
    await c.transcribeRecording(ref);
    expect(c.recordingView(ref).translation?.text, '译文');
    final renamed = await c.renameLocalExport(file.path, 'Interview');
    expect(c.recordingView(ref).path, renamed);
    expect(c.recordingView(ref).translation?.text, '译文');
    c.rememberTranscript(renamed, 'New source');
    expect(c.recordingView(ref).translation, isNull);
  });

  test(
    'pause then continue keeps recording identity and earlier text',
    () async {
      final c = controller(_Apple(), ble: _Ble());
      await c.refreshAppleCapabilities();
      await c.startRecord();
      final ref = c.currentRecordingReference!;
      final first = _Stream();
      c.attachSttStreamForTesting(first);
      first.emit('First section.');
      await Future<void>.delayed(Duration.zero);
      await c.pauseRecord();
      await c.startRecord();
      expect(c.currentRecordingReference!.key, ref.key);
      expect(c.recordingView(ref).text, contains('First section.'));
    },
  );

  test(
    'a disconnected paused take becomes a saved detail rather than a dead continue control',
    () async {
      final ble = _Ble();
      final c = controller(_Apple(), ble: ble);
      await c.startRecord();
      final ref = c.currentRecordingReference!;
      await c.pauseRecord();
      expect(c.recordingView(ref).paused, isTrue);
      ble.disconnected();
      await Future<void>.delayed(Duration.zero);
      expect(c.recordingView(ref).paused, isFalse);
    },
  );

  test('an old inventory entry cannot become the new live recording', () async {
    final ble = _Ble();
    final c = controller(_Apple(), ble: ble);
    await c.startRecord();
    final ref = c.currentRecordingReference!;
    c.connected = true;
    ble.filePage([10, 20]);
    await Future<void>.delayed(Duration.zero);
    expect(c.currentRecordingReference!.key, ref.key);
    expect(
      c.currentRecordingReference!.fileId,
      isNull,
      reason:
          'wait for a current timestamp or 1A06, not a historical list entry',
    );
  });

  test(
    'device pause info and duplicate resume preserve file identity and configuration',
    () async {
      final ble = _Ble();
      final c = controller(_Apple(), ble: ble);
      await c.refreshAppleCapabilities();
      await c.startRecord();
      c.handleRealtimeStateForTesting(
        const RealtimeStreamState(active: true, fileId: 44),
      );
      final ref = c.currentRecordingReference!;
      await c.pauseRecord();
      ble.deviceStatus(2);
      await Future<void>.delayed(Duration.zero);
      expect(c.info!.recordingStatus, 2);
      expect(c.recordingPaused, isTrue);
      c.setSpeechProvider(SttProvider.doubao);
      await c.startRecord();
      ble.deviceStatus(1);
      await Future<void>.delayed(Duration.zero);
      expect(c.currentRecordingReference!.key, ref.key);
      expect(c.currentRecordingReference!.fileId, 44);
      expect(c.recordingView(ref).provider, SttProvider.apple);
      expect(c.recordingView(ref).paused, isFalse);
    },
  );

  test(
    'Apple live revisions replace partial text and stop rejects late events',
    () async {
      final ble = _Ble();
      final c = controller(_Apple(), ble: ble);
      await c.refreshAppleCapabilities();
      await c.startRecord();
      final ref = c.currentRecordingReference!;
      final stream = _Stream();
      c.attachSttStreamForTesting(stream);
      stream.emit('I scream');
      await Future<void>.delayed(Duration.zero);
      stream.emit('Ice cream');
      await Future<void>.delayed(Duration.zero);
      expect(c.recordingView(ref).text, 'Ice cream');
      await c.pauseRecord();
      stream.emit('Late callback');
      await Future<void>.delayed(Duration.zero);
      expect(c.recordingView(ref).text, 'Ice cream');
      expect(c.recordingView(ref).paused, isTrue);
      expect(stream.closed, isTrue);
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      await c.startRecord();
      final next = _Stream();
      c.attachSttStreamForTesting(next);
      next.emit('Different take');
      await Future<void>.delayed(Duration.zero);
      expect(c.recordingView(ref).text, 'Ice cream');
      expect(
        c.recordingView(c.currentRecordingReference!).text,
        'Different take',
      );
    },
  );

  test(
    'provider and language changes take effect only for the next take',
    () async {
      final ble = _Ble();
      final c = controller(_Apple(), ble: ble);
      await c.refreshAppleCapabilities();
      await c.startRecord();
      final ref = c.currentRecordingReference!;
      c.setSpeechProvider(SttProvider.doubao);
      c.setTranscriptLanguage('ja');
      expect(c.recordingView(ref).provider, SttProvider.apple);
      expect(c.recordingView(ref).sourceLanguage, 'en-US');
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      await c.startRecord();
      final next = c.recordingView(c.currentRecordingReference!);
      expect(next.provider, SttProvider.doubao);
      expect(next.sourceLanguage, 'ja');
    },
  );

  test(
    'starting recording cancels Apple file work and rejects its result',
    () async {
      final pending = Completer<SttResult>();
      final apple = _Apple()..pendingFile = pending;
      final c = controller(apple, ble: _Ble());
      await c.refreshAppleCapabilities();
      const ref = RecordingReference(path: '/tmp/127.wav');
      c.rememberTranscript(ref.path!, 'Original');
      final processing = c.transcribeRecording(ref);
      await Future<void>.delayed(Duration.zero);
      await c.startRecord();
      pending.complete(const SttResult(text: 'Cancelled result'));
      await processing;
      expect(apple.cancelCalls, 1);
      expect(c.recordingView(ref).text, 'Original');
      expect(c.recordingView(ref).error, contains('重试'));
    },
  );

  test(
    'late Apple recording completion never adopts the next cloud provider',
    () async {
      final ble = _Ble();
      final cloud = _Cloud()..apiKeyOverride = 'configured-test-key';
      final c = controller(_Apple(), ble: ble, cloud: cloud);
      await c.refreshAppleCapabilities();
      await c.startRecord();
      c.setSpeechProvider(SttProvider.doubao);
      ble.stopRecording();
      await Future<void>.delayed(Duration.zero);
      expect(c.recording, isFalse);
      c.handleRealtimeStateForTesting(
        const RealtimeStreamState(
          fileId: 129,
          path: '/tmp/129.wav',
          bytesReceived: 32000,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cloud.fileCalls, 0);
      expect(
        c.recordingView(c.currentRecordingReference!).provider,
        SttProvider.apple,
      );
    },
  );

  test(
    'active recording cannot be renamed shared or removed from the catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'soundcore-active-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/128.wav');
      await file.writeAsBytes([1, 2, 3]);
      final c = controller(_Apple())
        ..recording = true
        ..realtimeState = RealtimeStreamState(
          active: true,
          fileId: 128,
          path: file.path,
        )
        ..exportedPaths = [file.path];
      expect(() => c.renameLocalExport(file.path, 'Busy'), throwsStateError);
      expect(() => c.prepareLocalSharePaths([file.path]), throwsStateError);
      final deleted = await c.deleteLocalExports([file.path]);
      expect(deleted.deleted, 0);
      expect(c.exportedPaths, [file.path]);
      expect(await file.exists(), isTrue);
    },
  );
}

class _Apple extends AppleSpeechService {
  Object? failure;
  Completer<SttResult>? pendingFile;
  Completer<String>? pendingTranslation;
  final queries = <String?>[];
  final statuses = <String, SpeechResourceStatus>{};
  final fileLanguages = <String>[];
  final preparedLanguages = <(String, String?)>[];
  int fileCalls = 0;
  int cancelCalls = 0;

  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async {
    queries.add(sourceLanguage);
    return AppleSpeechCapabilities(
      supported: true,
      speechStatus: sourceLanguage == null
          ? SpeechResourceStatus.unsupported
          : statuses[sourceLanguage] ?? SpeechResourceStatus.ready,
      translationStatus: SpeechResourceStatus.ready,
      suggestedSourceLanguage: 'en-US',
    );
  }

  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    fileCalls++;
    fileLanguages.add(sourceLanguage);
    if (failure != null) throw failure!;
    return pendingFile?.future ??
        SttResult(text: 'Apple result', language: sourceLanguage);
  }

  @override
  Future<void> prepareLanguages({
    required String sourceLanguage,
    String? targetLanguage,
  }) async {
    preparedLanguages.add((sourceLanguage, targetLanguage));
    statuses[sourceLanguage] = SpeechResourceStatus.ready;
  }

  @override
  Future<String> translate(
    String text, {
    required String sourceLanguage,
    required String targetLanguage,
  }) async {
    if (failure != null) throw failure!;
    return pendingTranslation?.future ?? '译文';
  }

  @override
  Future<void> cancelFileProcessing() async {
    cancelCalls++;
  }
}

class _Qwen extends QwenSttService {
  String? seenTaskId;
  int calls = 0;
  final paths = <String>[];
  Completer<void>? pending;
  String? seenKey;
  String? seenModel;
  String? seenBase;
  String? seenLanguage;

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
    seenTaskId = recovery?.taskId;
    paths.add(path);
    if (pending != null) await pending!.future;
    seenKey = apiKey;
    seenBase = baseUrl;
    seenModel = model;
    seenLanguage = language;
    return SttResult(
      text: '通义文本',
      sourcePath: path,
      language: language ?? 'auto',
    );
  }
}

class _Doubao extends DoubaoSttService {
  Object? failure;
  Completer<void>? pending;
  int calls = 0;
  String? seenKey;
  String? seenModel;
  String? seenBase;
  String? seenLanguage;
  final progressStages = <SttFileStage>[];

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
    seenKey = apiKey;
    seenBase = baseUrl;
    seenModel = model;
    seenLanguage = language;
    onProgress?.call(const SttFileProgress(SttFileStage.preparing));
    onProgress?.call(
      const SttFileProgress(SttFileStage.uploading, uploadedBytes: 1),
    );
    if (pending != null) await pending!.future;
    onProgress?.call(const SttFileProgress(SttFileStage.fetching));
    if (failure != null) throw failure!;
    return SttResult(
      text: '豆包文本',
      sourcePath: path,
      language: language ?? 'auto',
    );
  }
}

class _ScriptedClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final bodies = <String>[];
  final _responses = <http.StreamedResponse>[];

  void enqueue(int status, Object body, {Map<String, String>? headers}) {
    final encoded = body is String ? body : jsonEncode(body);
    _responses.add(
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(encoded)),
        status,
        headers: headers ?? const {},
      ),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    bodies.add(await request.finalize().bytesToString());
    requests.add(request);
    if (_responses.isEmpty) {
      throw StateError('unexpected ${request.method} ${request.url}');
    }
    return _responses.removeAt(0);
  }
}

class _Cloud extends DoubaoSttService {
  int fileCalls = 0;
  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    bool Function()? isCurrent,
    String? language,
    SttFileProgressCallback? onProgress,
  }) async {
    fileCalls++;
    return const SttResult(text: 'Cloud result');
  }
}

class _Ble extends BleService {
  final _connections = StreamController<bool>.broadcast();
  void disconnected() => _connections.add(false);
  final _packets = StreamController<DecodedPacket>.broadcast();
  void filePage(List<int> ids) {
    final data = ByteData(2 + ids.length * 12)
      ..setUint16(0, ids.length, Endian.little);
    for (var i = 0; i < ids.length; i++) {
      data.setUint32(2 + i * 12, ids[i], Endian.little);
      data.setUint32(6 + i * 12, ids[i] + 5, Endian.little);
      data.setUint32(10 + i * 12, 160, Endian.little);
    }
    _packets.add(
      DecodedPacket(
        raw: Uint8List(0),
        statusByte: 1,
        cmdType: 0x1B,
        cmdId: 0x0E,
        payload: data.buffer.asUint8List(),
      ),
    );
  }

  void deviceStatus(int status) {
    final raw = Uint8List(75)..[59] = status;
    _packets.add(
      DecodedPacket(
        raw: raw,
        statusByte: 1,
        cmdType: 1,
        cmdId: 1,
        payload: Uint8List.sublistView(raw, 9, 74),
      ),
    );
  }

  void stopRecording() => _packets.add(
    DecodedPacket(
      raw: Uint8List(0),
      statusByte: 1,
      cmdType: 0x18,
      cmdId: 0x82,
      payload: Uint8List.fromList([0]),
    ),
  );
  @override
  Stream<DecodedPacket> get packets => _packets.stream;
  @override
  Stream<List<ScannedDevice>> get scanResults => const Stream.empty();
  @override
  Stream<bool> get connectionState => _connections.stream;
  @override
  Stream<String> get logs => const Stream.empty();
  @override
  bool get isConnected => true;
  @override
  Future<void> writeCommand(List<int> frame) async {}
  @override
  Future<void> dispose() async {
    await _packets.close();
    await _connections.close();
  }
}

class _Stream implements SttStreamSession {
  final _events = StreamController<SttStreamEvent>.broadcast();
  bool closed = false;
  void emit(String text) {
    if (!_events.isClosed) {
      _events.add(SttStreamEvent(type: 'partial', text: text));
    }
  }

  @override
  Stream<SttStreamEvent> get events => _events.stream;
  @override
  bool get isOpen => !closed;
  @override
  bool get isServerReady => !closed;
  @override
  Future<void> start({Duration timeout = const Duration(seconds: 15)}) async {}
  @override
  void sendPcm(Uint8List pcm16le) {}
  @override
  void finalizeUtterance() {}
  @override
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  }) async => null;
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

class _UnwritableJournal extends FileJobJournal {
  _UnwritableJournal() : super(inMemory: true);
  @override
  Future<void> save() async => throw const FileSystemException('disk full');
}

Future<void> settleUntil(bool Function() predicate) async {
  for (var i = 0; i < 100; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: 'condition did not settle');
}
