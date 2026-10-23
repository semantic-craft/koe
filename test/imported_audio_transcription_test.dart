import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:koe/ai/doubao_stt.dart';
import 'package:koe/ai/oss_upload_request.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/audio/audio_transcoder.dart';
import 'package:koe/state/recorder_controller.dart';

import 'support/wav_fixture.dart';

/// Imported audio (#233): m4a/mp3 from the Files picker, never device Opus.
Uint8List m4aBytes() {
  final bytes = Uint8List(400);
  // `ftyp` box with the M4A brand, then opaque AAC payload.
  bytes.setRange(0, 4, const [0, 0, 0, 0x18]);
  bytes.setRange(4, 12, ascii.encode('ftypM4A '));
  for (var i = 24; i < bytes.length; i++) {
    bytes[i] = (i * 31) & 0xff;
  }
  return bytes;
}

Uint8List mp3Bytes() {
  final bytes = Uint8List(400);
  bytes.setRange(0, 3, ascii.encode('ID3'));
  bytes[3] = 4;
  for (var i = 10; i < bytes.length; i++) {
    bytes[i] = (i * 17) & 0xff;
  }
  return bytes;
}

/// Records each Doubao flash request body and answers with one sentence.
class _FlashServer extends http.BaseClient {
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    bodies.add(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"result":{"text":"导入的音频"}}')),
      200,
      headers: {'x-api-status-code': '20000000'},
    );
  }
}

class _FakeTranscoder implements AudioTranscoder {
  final calls = <String>[];
  final outputs = <String>[];
  Object? failure;

  @override
  Future<void> toWav(String input, String output) async {
    calls.add(input);
    outputs.add(output);
    if (failure != null) throw failure!;
    await File(output).writeAsBytes(wavBytes(List.filled(3200, 7)));
  }
}

/// Upload policy, OSS upload, submit, one poll and the transcript JSON.
class _QwenServer extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  /// The body of each task submitted to the transcription endpoint.
  final submitted = <Map<String, dynamic>>[];

  /// When set, the task is not reported done until it completes.
  Completer<void>? hold;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/transcription')) {
      final sent = await request.finalize().toBytes();
      submitted.add(jsonDecode(utf8.decode(sent)) as Map<String, dynamic>);
    }
    Object body;
    if (path == '/api/v1/uploads') {
      body = {
        'data': {
          'policy': 'p',
          'signature': 's',
          'upload_dir': 'dir/',
          'upload_host': 'https://oss.example.com/bucket',
          'oss_access_key_id': 'a',
          'x_oss_object_acl': 'private',
          'x_oss_forbid_overwrite': 'true',
        },
      };
    } else if (request.url.host == 'oss.example.com') {
      body = '';
    } else if (path.endsWith('/transcription')) {
      body = {
        'output': {'task_id': 't', 'task_status': 'PENDING'},
      };
    } else if (path == '/api/v1/tasks/t') {
      await hold?.future;
      body = {
        'output': {
          'task_id': 't',
          'task_status': 'SUCCEEDED',
          'results': [
            {
              'subtask_status': 'SUCCEEDED',
              'transcription_url': 'https://result.example.com/t.json',
            },
          ],
        },
      };
    } else {
      body = {
        'transcripts': [
          {'text': '导入的音频'},
        ],
      };
    }
    final encoded = body is String ? body : jsonEncode(body);
    return http.StreamedResponse(Stream.value(utf8.encode(encoded)), 200);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('koe-import-stt-');
    addTearDown(() => dir.delete(recursive: true));
  });

  group('Qwen', () {
    for (final (name, bytes) in [('m4a', m4aBytes()), ('mp3', mp3Bytes())]) {
      test('uploads an imported $name as the original file', () async {
        final file = File('${dir.path}/miaoji-audio.$name');
        await file.writeAsBytes(bytes);
        final server = _QwenServer();
        final service = QwenSttService(
          client: server,
          pollInterval: Duration.zero,
        );
        addTearDown(service.dispose);

        final result = await service.transcribePath(file.path, apiKey: 'k');

        expect(result.text, contains('导入的音频'));
        final upload = server.requests[1] as OssUploadRequest;
        expect(upload.fields['key'], 'dir/audio.$name');
        final wire = await upload.finalize().toBytes();
        expect(latin1.decode(wire), contains(latin1.decode(bytes)));
      });
    }

    test('unreadable audio fails with a reason, not a bare error', () async {
      final file = File('${dir.path}/notes.txt');
      await file.writeAsString('not audio at all, just some words');
      final service = QwenSttService(client: _QwenServer());
      addTearDown(service.dispose);

      await expectLater(
        service.transcribePath(file.path, apiKey: 'k'),
        throwsA(
          isA<QwenSttException>().having(
            (e) => e.message,
            'message',
            contains('不支持'),
          ),
        ),
      );
    });
  });

  group('Doubao', () {
    test('sends an imported mp3 as mp3 without converting it', () async {
      final file = File('${dir.path}/memo.mp3');
      await file.writeAsBytes(mp3Bytes());
      final server = _FlashServer();
      final transcoder = _FakeTranscoder();
      final service = DoubaoSttService(client: server, transcoder: transcoder);
      addTearDown(service.dispose);

      final result = await service.transcribePath(file.path, apiKey: 'k');

      expect(result.text, '导入的音频');
      final audio = server.bodies.single['audio'] as Map;
      expect(audio['format'], 'mp3');
      expect(base64Decode(audio['data'] as String), mp3Bytes());
      expect(transcoder.calls, isEmpty);
    });

    test('converts an imported m4a to WAV and removes the copy', () async {
      final file = File('${dir.path}/miaoji-audio.m4a');
      await file.writeAsBytes(m4aBytes());
      final server = _FlashServer();
      final transcoder = _FakeTranscoder();
      final service = DoubaoSttService(client: server, transcoder: transcoder);
      addTearDown(service.dispose);

      final result = await service.transcribePath(file.path, apiKey: 'k');

      expect(result.text, '导入的音频');
      expect(transcoder.calls, [file.path]);
      final audio = server.bodies.single['audio'] as Map;
      expect(audio['format'], 'wav');
      expect(
        base64Decode(audio['data'] as String),
        wavBytes(List.filled(3200, 7)),
      );
      expect(await File(transcoder.outputs.single).exists(), isFalse);
      expect(await file.readAsBytes(), m4aBytes());
    });

    test('a failed conversion names the reason and sends nothing', () async {
      final file = File('${dir.path}/miaoji-audio.m4a');
      await file.writeAsBytes(m4aBytes());
      final server = _FlashServer();
      final transcoder = _FakeTranscoder()
        ..failure = const AudioTranscodeException('无法读取这个音频文件');
      final service = DoubaoSttService(client: server, transcoder: transcoder);
      addTearDown(service.dispose);

      await expectLater(
        service.transcribePath(file.path, apiKey: 'k'),
        throwsA(
          isA<DoubaoSttException>().having(
            (e) => e.message,
            'message',
            allOf(contains('无法读取这个音频文件'), contains('千问')),
          ),
        ),
      );
      expect(server.bodies, isEmpty);
    });
  });

  test('an imported m4a that Doubao cannot read is retried with Qwen after '
      'switching services', () async {
    final transcoder = _FakeTranscoder()
      ..failure = const AudioTranscodeException('无法读取这个音频文件');
    final flash = _FlashServer();
    final qwen = _QwenServer();
    final c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      qwenSpeech: QwenSttService(client: qwen, pollInterval: Duration.zero)
        ..apiKeyOverride = 'k',
      doubaoSpeech: DoubaoSttService(client: flash, transcoder: transcoder)
        ..apiKeyOverride = 'k',
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${dir.path}/imports'),
    )..speechProvider = SttProvider.doubao;
    addTearDown(c.dispose);
    final source = File('${dir.path}/miaoji-audio.m4a');
    await source.writeAsBytes(m4aBytes());
    final path = (await c.importLocalAudio(source.path)).path;
    final ref = RecordingReference(path: path);

    await c.transcribeLocalFile(path);
    expect(c.recordingView(ref).error, contains('无法读取这个音频文件'));
    expect(flash.bodies, isEmpty);

    c.speechProvider = SttProvider.qwen;
    await c.transcribeLocalFile(path);

    expect(c.recordingView(ref).error, isNull);
    expect(c.recordingView(ref).text, contains('导入的音频'));
    expect(qwen.requests, isNotEmpty);
  });

  test('the number of people chosen for a recording goes to Qwen as its '
      'speaker count (#408)', () async {
    final qwen = _QwenServer();
    final c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      qwenSpeech: QwenSttService(client: qwen, pollInterval: Duration.zero)
        ..apiKeyOverride = 'k',
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${dir.path}/imports'),
    )..speechProvider = SttProvider.qwen;
    addTearDown(c.dispose);
    final source = File('${dir.path}/meeting.m4a');
    await source.writeAsBytes(m4aBytes());
    final path = (await c.importLocalAudio(source.path)).path;
    await c.setExpectedSpeakers(path, 3);

    await c.transcribeLocalFile(path);

    expect(c.recordingView(RecordingReference(path: path)).error, isNull);
    final parameters = qwen.submitted.single['parameters'] as Map;
    expect(parameters['diarization_enabled'], isTrue);
    expect(parameters['speaker_count'], 3);
  });

  test('importing a transcribed recording again keeps its number of people '
      '(#408)', () async {
    final c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      qwenSpeech: QwenSttService(
        client: _QwenServer(),
        pollInterval: Duration.zero,
      )..apiKeyOverride = 'k',
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${dir.path}/imports'),
    )..speechProvider = SttProvider.qwen;
    addTearDown(c.dispose);
    final source = File('${dir.path}/meeting.m4a');
    await source.writeAsBytes(m4aBytes());
    final path = (await c.importLocalAudio(source.path)).path;

    // Not transcribed yet, so the number chosen on importing it again counts.
    final again = await c.importLocalAudio(source.path, expectedSpeakers: 3);
    expect(again.duplicate, isTrue);
    expect(c.expectedSpeakersForPath(path), 3);

    await c.transcribeLocalFile(path);
    expect(c.transcriptForPath(path), isNotNull);

    // Its speakers were labelled with 3; a new number would not redo them.
    await c.importLocalAudio(source.path, expectedSpeakers: 5);
    expect(c.expectedSpeakersForPath(path), 3);
  });

  test('importing a recording again while it is transcribed keeps its number '
      'of people (#408)', () async {
    final server = _QwenServer()..hold = Completer<void>();
    final c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      qwenSpeech: QwenSttService(client: server, pollInterval: Duration.zero)
        ..apiKeyOverride = 'k',
      transcriptPersister: ({bool strict = false}) async {},
      libraryDirectory: Directory('${dir.path}/imports'),
    )..speechProvider = SttProvider.qwen;
    addTearDown(c.dispose);
    final source = File('${dir.path}/meeting.m4a');
    await source.writeAsBytes(m4aBytes());
    final path = (await c.importLocalAudio(source.path)).path;
    final transcription = c.transcribeLocalFile(path);
    for (var i = 0; i < 400 && server.submitted.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(server.submitted, hasLength(1));

    // The task went out without a number; a new one would not redo it.
    await c.importLocalAudio(source.path, expectedSpeakers: 3);
    expect(c.expectedSpeakersForPath(path), isNull);

    server.hold!.complete();
    await transcription;
    expect(c.transcriptForPath(path), isNotNull);
  });
}
