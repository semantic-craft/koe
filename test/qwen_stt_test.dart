import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anker_recorder/ai/qwen_stt.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default file body is Qwen-Audio 3.1 with file_urls', () {
    final body = qwenTranscriptionBody(
      model: QwenSttService.defaultModel,
      fileUrl: 'oss://dashscope-instant/x/audio.ogg',
      language: 'zh',
    );

    expect(QwenSttService.defaultModel, 'qwen-audio-3.1-asr-flash-filetrans');
    expect(body['model'], 'qwen-audio-3.1-asr-flash-filetrans');
    expect(body['input'], {
      'file_urls': ['oss://dashscope-instant/x/audio.ogg'],
    });
    expect((body['input'] as Map).containsKey('file_url'), isFalse);
    expect(body['parameters'], {
      'channel_id': [0],
      'diarization_enabled': true,
      'language_hints': ['zh'],
    });
    expect(
      qwenLanguageHints(model: QwenSttService.defaultModel, language: 'yue'),
      isNull,
    );
    expect(
      qwenLanguageHints(model: QwenSttService.defaultModel, language: 'auto'),
      isNull,
    );
    expect(qwenLanguageHints(model: 'paraformer-v2', language: 'yue'), ['yue']);
  });

  test('base URL stays an https origin', () {
    expect(
      normalizeDashScopeBaseUrl('dashscope-intl.aliyuncs.com/api/v1/'),
      'https://dashscope-intl.aliyuncs.com',
    );
    expect(
      () => normalizeDashScopeBaseUrl('http://dashscope.aliyuncs.com'),
      throwsA(isA<QwenSttException>()),
    );
  });

  test('qwen3-asr-flash-filetrans is not sent as file_urls', () async {
    final service = QwenSttService();
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(
        'unused',
        apiKey: 'test-key',
        model: QwenSttService.incompatibleFileUrlModel,
      ),
      throwsA(
        isA<QwenSttException>().having(
          (error) => error.message,
          'message',
          contains('input.file_url'),
        ),
      ),
    );
  });

  test('task JSON and transcript sentences parse without the network', () {
    final pending = parseQwenTask({
      'output': {'task_id': 'task-1', 'task_status': 'PENDING'},
    });
    expect(pending.status, 'PENDING');
    expect(pending.transcriptionUrls, isEmpty);

    final done = parseQwenTask({
      'output': {
        'task_id': 'task-1',
        'task_status': 'SUCCEEDED',
        'results': [
          {
            'subtask_status': 'SUCCEEDED',
            'transcription_url': 'https://result.example.com/t.json',
          },
          {
            'subtask_status': 'FAILED',
            'code': 'FILE_DOWNLOAD_FAILED',
            'message': 'FILE_DOWNLOAD_FAILED',
          },
        ],
      },
      'usage': {'duration': 9},
    });
    expect(done.transcriptionUrls, ['https://result.example.com/t.json']);
    expect(done.durationSec, 9);
    expect(done.failureMessage, contains('FILE_DOWNLOAD_FAILED'));

    final text = renderQwenTranscript({
      'properties': {'original_duration_in_milliseconds': 4000},
      'transcripts': [
        {
          'text': '你好世界',
          'sentences': [
            {'text': '你好', 'speaker_id': 0},
            {'text': '世界', 'speaker_id': 1},
          ],
        },
      ],
    });
    expect(text, '说话人 0：你好\n说话人 1：世界');
    expect(
      qwenDurationSec({
        'properties': {'original_duration_in_milliseconds': 4000},
      }),
      4,
    );
  });

  test(
    'file transcription uploads, polls, and reads transcription_url',
    () async {
      final directory = await Directory.systemTemp.createTemp('qwen-http-');
      addTearDown(() => directory.delete(recursive: true));
      final audio = Uint8List(80);
      audio.setRange(0, 4, const [0x4F, 0x67, 0x67, 0x53]);
      final file = File('${directory.path}/clip.ogg');
      await file.writeAsBytes(audio);

      final client = _ScriptedClient();
      client.enqueue(200, {
        'data': {
          'policy': 'policy-token',
          'signature': 'sig',
          'upload_dir': 'dashscope-instant/x/',
          'upload_host': 'https://oss.example.com/bucket',
          'oss_access_key_id': 'access',
          'x_oss_object_acl': 'private',
          'x_oss_forbid_overwrite': 'true',
        },
      });
      client.enqueue(200, '');
      client.enqueue(200, {
        'output': {'task_id': 'task-1', 'task_status': 'PENDING'},
      });
      client.enqueue(200, {
        'output': {'task_id': 'task-1', 'task_status': 'PENDING'},
      });
      client.enqueue(200, {
        'output': {
          'task_id': 'task-1',
          'task_status': 'SUCCEEDED',
          'results': [
            {
              'subtask_status': 'SUCCEEDED',
              'transcription_url': 'https://result.example.com/t.json',
            },
          ],
        },
        'usage': {'duration': 3},
      });
      client.enqueue(200, {
        'transcripts': [
          {
            'text': '你好',
            'sentences': [
              {'text': '你好', 'speaker_id': 0},
            ],
          },
        ],
      });

      final service = QwenSttService(
        client: client,
        pollInterval: Duration.zero,
      );
      addTearDown(service.dispose);
      final result = await service.transcribePath(
        file.path,
        apiKey: 'test-key',
        language: 'en',
      );

      expect(result.text, '说话人 0：你好');
      expect(result.language, 'en');
      expect(result.durationSec, 3);

      final policy = client.requests[0];
      expect(policy.method, 'GET');
      expect(policy.url.path, '/api/v1/uploads');
      expect(policy.url.queryParameters['action'], 'getPolicy');
      expect(
        policy.url.queryParameters['model'],
        'qwen-audio-3.1-asr-flash-filetrans',
      );
      expect(policy.headers['authorization'], 'Bearer test-key');

      final upload = client.requests[1] as http.MultipartRequest;
      expect(upload.method, 'POST');
      expect(upload.url.toString(), 'https://oss.example.com/bucket');
      expect(upload.fields['key'], 'dashscope-instant/x/audio.ogg');
      expect(upload.fields['OSSAccessKeyId'], 'access');

      final submit = client.requests[2] as http.Request;
      expect(submit.method, 'POST');
      expect(submit.url.path, '/api/v1/services/audio/asr/transcription');
      expect(submit.headers['x-dashscope-async'], 'enable');
      expect(submit.headers['x-dashscope-ossresourceresolve'], 'enable');
      final body = jsonDecode(submit.body) as Map<String, dynamic>;
      expect(body['model'], 'qwen-audio-3.1-asr-flash-filetrans');
      expect(body['input'], {
        'file_urls': ['oss://dashscope-instant/x/audio.ogg'],
      });
      expect((body['parameters'] as Map)['language_hints'], ['en']);

      final poll = client.requests[4];
      expect(poll.method, 'GET');
      expect(poll.url.path, '/api/v1/tasks/task-1');
      expect(
        client.requests[5].url.toString(),
        'https://result.example.com/t.json',
      );
    },
  );

  test('Qwen is the fallback only when Apple and Soniox are unavailable', () {
    expect(
      initialSpeechProvider(
        saved: null,
        appleSupported: false,
        sonioxConfigured: false,
        qwenConfigured: true,
      ),
      SttProvider.qwen,
    );
    expect(
      initialSpeechProvider(
        saved: null,
        appleSupported: false,
        sonioxConfigured: true,
        qwenConfigured: true,
      ),
      SttProvider.soniox,
    );
    expect(
      initialSpeechProvider(
        saved: SttProvider.qwen,
        appleSupported: true,
        sonioxConfigured: true,
      ),
      SttProvider.qwen,
    );
  });

  testWidgets('settings exposes the Qwen key, URL, and model', (tester) async {
    final controller = RecorderController(loadPersistedState: false)
      ..setSpeechProvider(SttProvider.qwen);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    expect(find.byKey(const ValueKey('apikey-qwen')), findsOneWidget);
    expect(find.byKey(const ValueKey('qwen-base-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('qwen-model')), findsOneWidget);
    expect(find.text('通义 Qwen'), findsWidgets);
    expect(
      find.byKey(const ValueKey('stt-display-mode-selector')),
      findsNothing,
    );
  });
}

class _ScriptedClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final _responses = <http.StreamedResponse>[];

  void enqueue(int status, Object body) {
    final encoded = body is String ? body : jsonEncode(body);
    _responses.add(
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(encoded)),
        status,
      ),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) {
      throw StateError('unexpected ${request.method} ${request.url}');
    }
    return _responses.removeAt(0);
  }
}
