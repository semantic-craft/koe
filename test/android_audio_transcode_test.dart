import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:koe/ai/doubao_stt.dart';

import 'support/temp_dir.dart';
import 'support/wav_fixture.dart';

/// Imported audio on Android (#341): the system decoder behind audio_decoder
/// turns m4a into the 16 kHz mono WAV Doubao reads.
const _decoder = MethodChannel('audio_decoder');

Uint8List _m4aBytes() {
  final bytes = Uint8List(400);
  bytes.setRange(0, 4, const [0, 0, 0, 0x18]);
  bytes.setRange(4, 12, ascii.encode('ftypM4A '));
  return bytes;
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File source;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    dir = await Directory.systemTemp.createTemp('koe-android-transcode-');
    source = File('${dir.path}/imported.m4a');
    await source.writeAsBytes(_m4aBytes());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_decoder, null);
    await deleteTemporaryDirectory(dir);
  });

  test('an imported m4a is decoded to 16 kHz mono WAV and sent', () async {
    final pcm = wavBytes(List.filled(3200, 5));
    Map<Object?, Object?>? arguments;
    messenger.setMockMethodCallHandler(_decoder, (call) async {
      arguments = call.arguments as Map<Object?, Object?>;
      await File(arguments!['outputPath'] as String).writeAsBytes(pcm);
      return arguments!['outputPath'];
    });
    final server = _FlashServer();
    final service = DoubaoSttService(client: server);
    addTearDown(service.dispose);

    final result = await service.transcribePath(source.path, apiKey: 'k');

    expect(result.text, '导入的音频');
    expect(arguments, containsPair('inputPath', source.path));
    expect(arguments, containsPair('sampleRate', 16000));
    expect(arguments, containsPair('channels', 1));
    expect(arguments, containsPair('bitDepth', 16));
    final audio = server.bodies.single['audio'] as Map;
    expect(audio['format'], 'wav');
    expect(base64Decode(audio['data'] as String), pcm);
  });

  test('audio the system cannot decode says it cannot be converted', () async {
    messenger.setMockMethodCallHandler(_decoder, (call) async {
      throw PlatformException(
        code: 'CONVERSION_ERROR',
        message: 'Failed to instantiate extractor.',
      );
    });
    final server = _FlashServer();
    final service = DoubaoSttService(client: server);
    addTearDown(service.dispose);

    await expectLater(
      service.transcribePath(source.path, apiKey: 'k'),
      throwsA(
        isA<DoubaoSttException>().having(
          (e) => e.message,
          'message',
          // Before #341 every file failed as "此设备无法转换音频格式".
          allOf(
            contains('无法转换音频'),
            isNot(contains('此设备')),
            isNot(contains('extractor')),
          ),
        ),
      ),
    );
    expect(server.bodies, isEmpty);
  });
}
