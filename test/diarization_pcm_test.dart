import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/diarization_pcm.dart';

Uint8List wav(int rate, int count) {
  final data = ByteData(44 + count * 2);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, 'WAVEfmt '.codeUnits);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  data.setUint32(40, count * 2, Endian.little);
  for (var i = 0; i < count; i++) {
    data.setInt16(44 + i * 2, i.isEven ? 16384 : -16384, Endian.little);
  }
  return bytes;
}

void main() {
  test(
    'bounded PCM reads preserve sample rate, polarity and exact windows',
    () async {
      final dir = await Directory.systemTemp.createTemp('koe-pcm-');
      try {
        for (final rate in [16000, 48000]) {
          final file = File('${dir.path}/$rate.wav')
            ..writeAsBytesSync(wav(rate, 100));
          final pcm = DiarizationPcm.open(file.path);
          try {
            expect(pcm.rate, rate);
            expect(pcm.sampleCount, 100);
            expect(pcm.read(1, 4), [-.5, .5, -.5]);
          } finally {
            pcm.close();
          }
        }
        final short = File('${dir.path}/short.wav')
          ..writeAsBytesSync(wav(16000, 100).sublist(0, 50));
        expect(() => DiarizationPcm.open(short.path), throwsFormatException);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
