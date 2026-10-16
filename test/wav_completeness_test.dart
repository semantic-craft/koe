import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/wav_completeness.dart';

// #13: only a finished WAV may enter transcription. A header that has not been
// patched yet (still writing), a truncated data chunk or a missing data chunk
// is reported as incomplete.

Uint8List wav(
  List<int> pcm, {
  int? dataSize,
  int? riffSize,
  List<int> extraChunk = const [],
}) {
  final header = ByteData(44);
  void ascii(int offset, String value) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  final declared = dataSize ?? pcm.length;
  ascii(0, 'RIFF');
  header.setUint32(
    4,
    riffSize ?? 36 + extraChunk.length + pcm.length,
    Endian.little,
  );
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, declared, Endian.little);
  final bytes = header.buffer.asUint8List();
  return Uint8List.fromList([
    ...bytes.sublist(0, 36),
    ...extraChunk,
    ...bytes.sublist(36),
    ...pcm,
  ]);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('wav-complete-'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<WavInspection> inspect(List<int> bytes) async {
    final file = File('${dir.path}/1.wav')..writeAsBytesSync(bytes);
    return inspectWav(file.path);
  }

  test('a finished WAV is complete', () async {
    final result = await inspect(wav(List.filled(320, 1)));
    expect(result.complete, isTrue, reason: result.problem);
    expect(result.length, 44 + 320);
  });

  test('chunks before data are skipped, including odd-size padding', () async {
    final list = [...'LIST'.codeUnits, 3, 0, 0, 0, 7, 7, 7, 0];
    final result = await inspect(wav(List.filled(8, 1), extraChunk: list));
    expect(result.complete, isTrue, reason: result.problem);
  });

  test('header not patched yet (placeholder sizes) is incomplete', () async {
    final result = await inspect(
      wav(List.filled(320, 1), dataSize: 0, riffSize: 36),
    );
    expect(result.complete, isFalse);
    expect(result.problem, contains('仍在写入'));
  });

  test('a file still growing past its header is incomplete', () async {
    final result = await inspect([
      ...wav(List.filled(320, 1)),
      ...List.filled(160, 2),
    ]);
    expect(result.complete, isFalse);
    expect(result.problem, contains('仍在写入'));
  });

  test('a truncated data chunk is incomplete', () async {
    // Consistent RIFF size, but data declares more than the file holds.
    final result = await inspect(
      wav(List.filled(160, 1), dataSize: 320, riffSize: 36 + 160),
    );
    expect(result.complete, isFalse);
    expect(result.problem, contains('音频数据不完整'));
  });

  test('an empty data chunk is incomplete', () async {
    final result = await inspect(wav(const []));
    expect(result.complete, isFalse);
    expect(result.problem, contains('没有音频数据'));
  });

  test('non-WAV and too-short files are incomplete', () async {
    expect((await inspect([1, 2, 3])).complete, isFalse);
    expect((await inspect(List.filled(64, 0))).complete, isFalse);
  });

  test('a missing file is incomplete, not an exception', () async {
    final result = await inspectWav('${dir.path}/missing.wav');
    expect(result.complete, isFalse);
  });
}
