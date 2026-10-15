import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/ogg_opus.dart';
import 'package:koe/ai/qwen_stt.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('long-upload'));
  tearDown(() async => dir.delete(recursive: true));
  test('Qwen limits are independent of Doubao and enforce duration', () {
    expect(
      () => validateQwenAudio(
        length: 25 * 1024 * 1024,
        duration: const Duration(hours: 12),
      ),
      returnsNormally,
    );
    expect(
      () => validateQwenAudio(length: QwenSttService.maxUploadBytes + 1),
      throwsA(isA<QwenSttException>()),
    );
    expect(
      () => validateQwenAudio(
        length: 100,
        duration: const Duration(hours: 12, seconds: 1),
      ),
      throwsA(isA<QwenSttException>()),
    );
  });
  test(
    'streamed Ogg output matches existing frame mux including tail',
    () async {
      final raw = Uint8List.fromList(
        List.generate(160 * 103 + 9, (i) => (i % 251) + 1),
      );
      final file = File('${dir.path}/sample.opus');
      await file.writeAsBytes(raw);
      final output = await OggOpus.prepareUpload(file.path);
      expect(await File(output).readAsBytes(), OggOpus.muxRawFrames(raw));
      expect(await file.readAsBytes(), raw);
    },
  );
  test('cancelled Ogg conversion never publishes partial file', () async {
    final file = File('${dir.path}/cancel.opus');
    await file.writeAsBytes(Uint8List(32000));
    var checks = 0;
    await expectLater(
      OggOpus.prepareUpload(file.path, isCurrent: () => ++checks < 3),
      throwsStateError,
    );
    expect(await File('${dir.path}/cancel.ogg').exists(), isFalse);
    expect(await File('${dir.path}/cancel.ogg.upload-part').exists(), isFalse);
  });
  test(
    'multipart streams large file in bounded chunks and stops on cancellation',
    () async {
      final f = File('${dir.path}/large.wav');
      final out = await f.open(mode: FileMode.write);
      await out.truncate(25 * 1024 * 1024);
      await out.close();
      var current = true;
      var maxChunk = 0;
      var received = 0;
      final part = multipartFileFromDisk(
        field: 'file',
        file: f,
        filename: 'large.wav',
        onProgress: (_, _) {},
        isCurrent: () => current,
      );
      try {
        await for (final chunk in part.finalize()) {
          received += chunk.length;
          if (chunk.length > maxChunk) maxChunk = chunk.length;
          current = false;
        }
        fail('cancel must interrupt stream');
      } on QwenSttException {
        expect(received, lessThan(25 * 1024 * 1024));
        expect(maxChunk, lessThanOrEqualTo(256 * 1024));
      }
    },
  );
  test('only matching WAV sidecar selects raw source', () async {
    final wav = File('${dir.path}/sample.wav');
    final bytes = Uint8List(44 + 96000);
    bytes.setRange(0, 4, 'RIFF'.codeUnits);
    bytes.setRange(8, 12, 'WAVE'.codeUnits);
    final data = ByteData.sublistView(bytes);
    data.setUint32(28, 96000, Endian.little);
    data.setUint32(40, 96000, Endian.little);
    await wav.writeAsBytes(bytes);
    final raw = File('${dir.path}/sample.opus');
    await raw.writeAsBytes(Uint8List(160 * 50));
    expect(await qwenUploadSource(wav.path), raw.path);
    await raw.writeAsBytes(Uint8List(160 * 100));
    expect(await qwenUploadSource(wav.path), wav.path);
  });
}
