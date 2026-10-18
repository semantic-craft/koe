import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:koe/ai/doubao_stt.dart';
import 'package:koe/audio/ogg_opus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default flash body embeds base64 audio with mapped language', () {
    final body = doubaoTranscriptionBody(data: 'aGVsbG8=', language: 'zh');

    expect(body['user'], {'uid': 'anker-recorder'});
    expect(body['audio'], {
      'data': 'aGVsbG8=',
      'format': 'ogg',
      'codec': 'opus',
      'rate': 48000,
      'bits': 16,
      'channel': 1,
      'language': 'zh-CN',
    });
    expect((body['audio'] as Map).containsKey('url'), isFalse);
    expect(body['request'], {
      'model_name': 'bigmodel',
      'enable_itn': true,
      'enable_punc': true,
      'enable_speaker_info': true,
      'show_utterances': true,
      'ssd_version': '200',
    });

    // Language mapping: ISO short codes -> BCP-47; auto/unknown -> omitted.
    expect(doubaoLanguageCode('zh'), 'zh-CN');
    expect(doubaoLanguageCode('en'), 'en-US');
    expect(doubaoLanguageCode('ja'), 'ja-JP');
    expect(doubaoLanguageCode('ko'), 'ko-KR');
    expect(doubaoLanguageCode('yue'), 'yue-CN');
    expect(doubaoLanguageCode('zh-CN'), 'zh-CN');
    expect(doubaoLanguageCode('auto'), isNull);
    expect(doubaoLanguageCode(''), isNull);
    expect(doubaoLanguageCode(null), isNull);
    expect(doubaoLanguageCode('xx'), isNull);

    // auto omits the language key entirely.
    final auto = doubaoTranscriptionBody(data: 'aGVsbG8=', language: 'auto');
    expect((auto['audio'] as Map).containsKey('language'), isFalse);
  });

  test('base URL stays an https origin', () {
    expect(
      normalizeDoubaoBaseUrl('openspeech.bytedance.com/api/v3/'),
      'https://openspeech.bytedance.com',
    );
    expect(
      normalizeDoubaoBaseUrl('https://openspeech.bytedance.com/'),
      'https://openspeech.bytedance.com',
    );
    expect(
      normalizeDoubaoBaseUrl(
        'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
      ),
      'https://openspeech.bytedance.com',
    );
    expect(
      resolveDoubaoBaseUrl(null, environment: ' openspeech.bytedance.com '),
      'https://openspeech.bytedance.com',
    );
    expect(
      resolveDoubaoBaseUrl('  ', environment: null),
      DoubaoSttService.defaultBaseUrl,
    );
    expect(
      () => normalizeDoubaoBaseUrl('http://openspeech.bytedance.com'),
      throwsA(isA<DoubaoSttException>()),
    );
    expect(
      () => normalizeDoubaoBaseUrl('ftp://openspeech.bytedance.com'),
      throwsA(isA<DoubaoSttException>()),
    );
    expect(
      () => normalizeDoubaoBaseUrl('https://'),
      throwsA(isA<DoubaoSttException>()),
    );
  });

  test('non-flash models are rejected with a readable reason', () {
    expect(DoubaoSttService.defaultModel, 'volc.bigasr.auc_turbo');
    expect(doubaoModelRejection('volc.bigasr.auc_turbo'), isNull);
    expect(doubaoModelRejection('volc.bigasr.auc_turbo.v2'), isNull);

    final standard = doubaoModelRejection('volc.seedasr.auc');
    expect(standard, contains('标准版'));
    expect(standard, contains('audio.url'));
    expect(standard, contains('volc.bigasr.auc_turbo'));
    expect(doubaoModelRejection('volc.bigasr.auc'), contains('标准版'));

    final streaming = doubaoModelRejection('volc.bigasr.sauc.duration');
    expect(streaming, contains('流式'));
    expect(doubaoModelRejection('volc.bigasr.sauc.wss'), contains('流式'));

    expect(doubaoModelRejection('gpt-4o-audio'), isNotNull);
  });

  test('status codes map to readable messages', () {
    expect(doubaoStatusMessage('20000000', 'OK'), isNull);
    expect(doubaoStatusMessage('45000002', 'empty audio'), '音频太短或无效，无法转写');
    expect(doubaoStatusMessage('20000003', ''), '未识别到语音，可重试');
    expect(doubaoStatusMessage('45000131', ''), '豆包请求过多，请稍后重试');
    expect(doubaoStatusMessage('45000132', ''), '音频超过大小限制，无法转写');
    expect(doubaoStatusMessage('45000151', ''), '音频格式不支持，请更换格式');
    expect(doubaoStatusMessage('55000031', ''), '豆包服务繁忙，请稍后重试');
    expect(doubaoStatusMessage('55099999', ''), '豆包转写失败，请重试');
    expect(
      doubaoStatusMessage('45000001', 'invalid audio format'),
      contains('invalid audio format'),
    );
    expect(
      doubaoStatusMessage('45000001', 'invalid api key'),
      '豆包 API Key 无效，请在设置中更新',
    );
  });

  test('recognize JSON and utterances parse without the network', () {
    final json = {
      'audio_info': {'duration': 6312},
      'result': {
        'text': '你好世界',
        'utterances': [
          {
            'additions': {'speaker': '1'},
            'text': '你好',
            'start_time': 480,
            'end_time': 5880,
          },
          {
            'additions': {'speaker': '2'},
            'text': '世界',
            'start_time': 5880,
            'end_time': 6312,
          },
        ],
      },
    };

    final parsed = parseDoubaoRecognize(json);
    expect(parsed.text, '你好世界');
    expect(parsed.durationSec, 6.312);
    expect(parsed.utterances, hasLength(2));
    expect(parsed.utterances.first.speaker, '1');
    expect(parsed.utterances.first.startTimeMs, 480);

    expect(renderDoubaoTranscript(json), '说话人 1：你好\n说话人 2：世界');

    // No utterances: fall back to the plain text.
    final plain = {
      'result': {'text': '全文'},
    };
    expect(parseDoubaoRecognize(plain).utterances, isEmpty);
    expect(renderDoubaoTranscript(plain), '全文');

    // Empty result is a failure, not an empty transcript.
    expect(
      () => parseDoubaoRecognize({'result': <String, dynamic>{}}),
      throwsA(isA<DoubaoSttException>()),
    );
  });

  test('utterance times become replay segments only when complete', () {
    final json = {
      'result': {
        'utterances': [
          {
            'additions': {'speaker': '1'},
            'text': '你好',
            'start_time': 480,
            'end_time': 5880,
          },
          {
            'additions': {'speaker': '1'},
            'text': '世界',
            'start_time': 5880,
            'end_time': 6312,
          },
        ],
      },
    };
    final segments = doubaoTranscriptSegments(json);
    expect(segments, hasLength(2));
    expect(segments[0].startMs, 480);
    expect(segments[1].startMs, 5880);
    expect(segments[1].speaker, '1');
    expect(segments[1].speakerChanged, isFalse);

    final missingEnd = {
      'result': {
        'utterances': [
          {'text': '缺终点', 'start_time': 480},
        ],
      },
    };
    expect(doubaoTranscriptSegments(missingEnd), isEmpty);
  });

  test(
    'flash transcription posts base64 audio once and parses the reply',
    () async {
      final directory = await Directory.systemTemp.createTemp('doubao-http-');
      addTearDown(() => directory.delete(recursive: true));
      final audio = OggOpus.muxRawFrames(
        Uint8List.fromList(List.filled(160, 1)),
      );
      final file = File('${directory.path}/clip.ogg');
      await file.writeAsBytes(audio);

      final client = _ScriptedClient();
      client.enqueue(
        200,
        {
          'audio_info': {'duration': 6312},
          'result': {
            'text': '你好',
            'utterances': [
              {
                'additions': {'speaker': '0'},
                'text': '你好',
              },
            ],
          },
        },
        headers: {'x-api-status-code': '20000000', 'x-api-message': 'OK'},
      );

      final service = DoubaoSttService(client: client);
      addTearDown(service.dispose);
      final result = await service.transcribePath(
        file.path,
        apiKey: 'test-key',
        language: 'zh',
      );

      expect(result.text, '说话人 0：你好');
      expect(result.language, 'zh');
      expect(result.durationSec, 6.312);
      expect(result.sourcePath, file.path);

      final request = client.requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
      );
      expect(request.headers['x-api-key'], 'test-key');
      expect(request.headers['x-api-resource-id'], 'volc.bigasr.auc_turbo');
      expect(request.headers['x-api-request-id'], isNotEmpty);
      final body = jsonDecode(client.bodies.single) as Map<String, dynamic>;
      expect((body['audio'] as Map)['data'], base64Encode(audio));
      expect((body['audio'] as Map)['language'], 'zh-CN');
    },
  );

  test('flash error status becomes a readable message', () async {
    final directory = await Directory.systemTemp.createTemp('doubao-http-');
    addTearDown(() => directory.delete(recursive: true));
    final audio = OggOpus.muxRawFrames(Uint8List.fromList(List.filled(160, 1)));
    final file = File('${directory.path}/clip.ogg');
    await file.writeAsBytes(audio);

    final client = _ScriptedClient();
    client.enqueue(
      200,
      {},
      headers: {'x-api-status-code': '45000002', 'x-api-message': 'empty'},
    );

    final service = DoubaoSttService(client: client);
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(file.path, apiKey: 'test-key'),
      throwsA(
        isA<DoubaoSttException>().having(
          (error) => error.message,
          'message',
          '音频太短或无效，无法转写',
        ),
      ),
    );
    expect(client.requests, hasLength(1));
  });

  test('missing status header is a parse failure', () async {
    final file = await _tinyOgg();

    final client = _ScriptedClient();
    client.enqueue(200, {});

    final service = DoubaoSttService(client: client);
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(file.path, apiKey: 'test-key'),
      throwsA(
        isA<DoubaoSttException>().having(
          (error) => error.message,
          'message',
          '豆包返回无法解析',
        ),
      ),
    );
  });

  test('HTTP 401 maps to an invalid key message', () async {
    final file = await _tinyOgg();

    final client = _ScriptedClient();
    client.enqueue(
      401,
      {'message': 'bad key'},
      headers: {'x-api-status-code': '45000001'},
    );

    final service = DoubaoSttService(client: client);
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(file.path, apiKey: 'test-key'),
      throwsA(
        isA<DoubaoSttException>().having(
          (error) => error.message,
          'message',
          '豆包 API Key 无效，请在设置中更新',
        ),
      ),
    );
  });

  test('missing key is rejected before the network', () async {
    final service = DoubaoSttService();
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath('unused'),
      throwsA(
        isA<DoubaoSttException>().having(
          (error) => error.message,
          'message',
          '请在设置中配置豆包',
        ),
      ),
    );
  });

  test('oversized audio is rejected before the network', () async {
    final directory = await Directory.systemTemp.createTemp('doubao-big-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/clip.ogg');
    final sparse = await file.open(mode: FileMode.write);
    await sparse.writeFrom([0x4F, 0x67, 0x67, 0x53]);
    await sparse.truncate(DoubaoSttService.maxDirectUploadBytes + 1);
    await sparse.close();

    final client = _ScriptedClient();
    final service = DoubaoSttService(client: client);
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(file.path, apiKey: 'test-key'),
      throwsA(
        isA<DoubaoSttException>().having(
          (error) => error.message,
          'message',
          contains('音频超过 100 MB'),
        ),
      ),
    );
    expect(client.requests, isEmpty);
  });

  test('timeout maps to a readable message', () async {
    final file = await _tinyOgg();
    final service = DoubaoSttService(
      client: _FailingClient(TimeoutException('slow')),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(file.path, apiKey: 'test-key'),
      throwsA(
        isA<DoubaoSttException>().having(
          (error) => error.message,
          'message',
          contains('豆包转写超时'),
        ),
      ),
    );
  });

  test('socket failure maps to a connect failure message', () async {
    final file = await _tinyOgg();
    final service = DoubaoSttService(
      client: _FailingClient(const SocketException('offline')),
    );
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(file.path, apiKey: 'test-key'),
      throwsA(
        isA<DoubaoSttException>().having(
          (error) => error.message,
          'message',
          contains('结果未确认'),
        ),
      ),
    );
  });
}

Future<File> _tinyOgg() async {
  final directory = await Directory.systemTemp.createTemp('doubao-tiny-');
  addTearDown(() => directory.delete(recursive: true));
  final audio = OggOpus.muxRawFrames(Uint8List.fromList(List.filled(160, 1)));
  final file = File('${directory.path}/clip.ogg');
  await file.writeAsBytes(audio);
  return file;
}

class _ScriptedClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final bodies = <String>[];
  final _responses = <http.StreamedResponse>[];

  void enqueue(
    int status,
    Object body, {
    Map<String, String> headers = const {},
  }) {
    final encoded = body is String ? body : jsonEncode(body);
    _responses.add(
      http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(encoded)),
        status,
        headers: headers,
      ),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(await request.finalize().bytesToString());
    if (_responses.isEmpty) {
      throw StateError('unexpected ${request.method} ${request.url}');
    }
    return _responses.removeAt(0);
  }
}

class _FailingClient extends http.BaseClient {
  _FailingClient(this.error);

  final Object error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw error;
  }
}
