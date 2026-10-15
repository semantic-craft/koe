import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:anker_recorder/ai/doubao_stt.dart';
import 'package:anker_recorder/ai/streaming_audio_json.dart';
import 'package:anker_recorder/audio/upload_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class UploadClient extends http.BaseClient {
  int calls = 0, bytes = 0, largest = 0;
  void Function()? beforeResponse;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    await for (final chunk in request.finalize()) {
      bytes += chunk.length;
      if (chunk.length > largest) largest = chunk.length;
    }
    beforeResponse?.call();
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"result":{"text":"成功"}}')),
      200,
      headers: {'x-api-status-code': '20000000'},
    );
  }
}

Future<File> wav(String path, int size) async {
  final f = File(path);
  final out = await f.open(mode: FileMode.write);
  final header = Uint8List(44);
  final d = ByteData.sublistView(header);
  header.setRange(0, 4, ascii.encode('RIFF'));
  header.setRange(8, 12, ascii.encode('WAVE'));
  header.setRange(12, 16, ascii.encode('fmt '));
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, 16000, Endian.little);
  d.setUint32(28, 32000, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  header.setRange(36, 40, ascii.encode('data'));
  d.setUint32(40, size - 44, Endian.little);
  d.setUint32(4, size - 8, Endian.little);
  await out.writeFrom(header);
  await out.truncate(size);
  await out.close();
  return f;
}

class WaitingClient extends http.BaseClient {
  final started = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    started.complete();
    await (request as http.Abortable).abortTrigger;
    throw http.RequestAbortedException();
  }
}

void main() {
  test(
    'invalidated run rejects late result with explicit unknown status',
    () async {
      final dir = await Directory.systemTemp.createTemp('late-flash');
      addTearDown(() => dir.delete(recursive: true));
      final f = await wav('${dir.path}/clip.wav', 32044);
      var current = true;
      final client = UploadClient()..beforeResponse = () => current = false;
      final service = DoubaoSttService(client: client);
      addTearDown(service.dispose);
      await expectLater(
        service.transcribePath(
          f.path,
          apiKey: 'test',
          isCurrent: () => current,
        ),
        throwsA(
          isA<DoubaoSttException>().having(
            (e) => e.message,
            'message',
            contains('结果未确认'),
          ),
        ),
      );
    },
  );

  test('separate byte and duration boundaries use decimal MB', () {
    for (final length in [
      20 * 1024 * 1024,
      20 * 1024 * 1024 + 1,
      99999999,
      100000000,
    ]) {
      validateDoubaoAudio(length: length, duration: const Duration(hours: 2));
    }
    expect(
      () => validateDoubaoAudio(length: 100000001),
      throwsA(isA<DoubaoSttException>()),
    );
    expect(
      () => validateDoubaoAudio(
        length: 64,
        duration: const Duration(hours: 2, microseconds: 1),
      ),
      throwsA(isA<DoubaoSttException>()),
    );
  });
  test(
    'base64 carry and Content-Length match exact JSON at chunk boundaries',
    () async {
      final dir = await Directory.systemTemp.createTemp('base64-stream');
      addTearDown(() => dir.delete(recursive: true));
      for (final length in [1, 2, 3, 65535, 65536, 65537]) {
        final bytes = List<int>.generate(length, (i) => i % 256);
        final f = File('${dir.path}/$length');
        await f.writeAsBytes(bytes);
        final request = StreamingAudioJsonRequest(
          Uri.parse('https://example.com'),
          file: f,
          body: doubaoTranscriptionBody(
            data: '',
            language: 'zh',
            format: 'wav',
          ),
          abort: Completer<void>().future,
          isCurrent: () => true,
          onProgress: (_, _) {},
          onUploaded: () {},
        );
        final data = await request.finalize().toBytes();
        expect(data.length, request.contentLength);
        expect(
          (jsonDecode(utf8.decode(data))['audio'] as Map)['data'],
          base64Encode(bytes),
        );
      }
    },
  );
  test(
    'matching compressed sidecar is chosen but mismatch stays WAV',
    () async {
      final dir = await Directory.systemTemp.createTemp('source-select');
      addTearDown(() => dir.delete(recursive: true));
      final f = await wav('${dir.path}/clip.wav', 32044);
      final raw = File('${dir.path}/clip.opus');
      await raw.writeAsBytes(List.filled(8000, 1));
      expect(await compressedUploadSource(f.path), raw.path);
      await raw.writeAsBytes(List.filled(160, 1));
      expect(await compressedUploadSource(f.path), f.path);
      await raw.delete();
      expect(await compressedUploadSource(f.path), f.path);
    },
  );
  test('cancel aborts response wait without accepting a late result', () async {
    final dir = await Directory.systemTemp.createTemp('cancel-flash');
    addTearDown(() => dir.delete(recursive: true));
    final f = await wav('${dir.path}/clip.wav', 32044);
    final client = WaitingClient();
    final service = DoubaoSttService(client: client);
    addTearDown(service.dispose);
    final result = service.transcribePath(f.path, apiKey: 'test');
    final check = expectLater(
      result,
      throwsA(
        isA<DoubaoSttException>().having(
          (e) => e.message,
          'message',
          contains('结果未确认'),
        ),
      ),
    );
    await client.started.future;
    service.cancelCurrent();
    await check;
    expect(await f.exists(), isTrue);
  });
  test(
    'response timeout aborts request and preserves original recording',
    () async {
      final dir = await Directory.systemTemp.createTemp('timeout-flash');
      addTearDown(() => dir.delete(recursive: true));
      final f = await wav('${dir.path}/clip.wav', 32044);
      final client = WaitingClient();
      final service = DoubaoSttService(
        client: client,
        requestTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(service.dispose);
      await expectLater(
        service.transcribePath(f.path, apiKey: 'test'),
        throwsA(
          isA<DoubaoSttException>().having(
            (e) => e.message,
            'message',
            contains('重新上传'),
          ),
        ),
      );
      expect(await f.exists(), isTrue);
    },
  );
  test('invalid format fails before request', () async {
    final dir = await Directory.systemTemp.createTemp('bad-flash');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/bad.ogg');
    await f.writeAsBytes(List.filled(100, 0));
    final client = UploadClient();
    final service = DoubaoSttService(client: client);
    addTearDown(service.dispose);
    await expectLater(
      service.transcribePath(f.path, apiKey: 'test'),
      throwsA(isA<DoubaoSttException>()),
    );
    expect(client.calls, 0);
  });

  test('WAV above old 20 MiB threshold uploads with bounded chunks', () async {
    final dir = await Directory.systemTemp.createTemp('doubao-large');
    addTearDown(() => dir.delete(recursive: true));
    final f = await wav('${dir.path}/large.wav', 25 * 1024 * 1024);
    final client = UploadClient();
    final service = DoubaoSttService(client: client);
    addTearDown(service.dispose);
    final result = await service.transcribePath(f.path, apiKey: 'test');
    expect(result.text, '成功');
    expect(client.calls, 1);
    expect(client.bytes, greaterThan(25 * 1024 * 1024));
    expect(client.largest, lessThanOrEqualTo(128 * 1024));
  });
}
