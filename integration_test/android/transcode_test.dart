// Android transcode scenario (#341): the Pixel's system decoders turn each
// imported format into the 16 kHz mono PCM16 WAV every speech service
// accepts, and an undecodable file says so. Run with `scripts/android-check`.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/audio/audio_transcoder.dart';

import 'transcode_samples.dart';

class _Wav {
  _Wav(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = ascii.decode(bytes.sublist(offset, offset + 4));
      final size = view.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        format = view.getUint16(body, Endian.little);
        channels = view.getUint16(body + 2, Endian.little);
        sampleRate = view.getUint32(body + 4, Endian.little);
        bits = view.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final end = (body + size).clamp(body, bytes.length);
        samples = Int16List.fromList([
          for (var i = body; i + 1 < end; i += 2)
            view.getInt16(i, Endian.little),
        ]);
      }
      offset = body + size + (size & 1);
    }
  }

  int format = 0, channels = 0, sampleRate = 0, bits = 0;
  Int16List samples = Int16List(0);

  /// Tone frequency from upward zero crossings over the middle half, away
  /// from codec priming and the tail.
  double frequency() {
    final from = samples.length ~/ 4, to = samples.length * 3 ~/ 4;
    var crossings = 0;
    for (var i = from + 1; i < to; i++) {
      if (samples[i - 1] < 0 && samples[i] >= 0) crossings++;
    }
    return crossings / ((to - from) / sampleRate);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const transcoder = PlatformAudioTranscoder();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('koe-transcode-');
  });
  tearDown(() => dir.delete(recursive: true));

  for (final MapEntry(key: ext, value: (seconds, data))
      in transcodeSamples.entries) {
    testWidgets('$ext becomes 16 kHz mono PCM16 WAV', (tester) async {
      final input = File('${dir.path}/tone.$ext');
      await input.writeAsBytes(base64Decode(data));
      final output = '${dir.path}/tone-$ext.wav';

      await transcoder.toWav(input.path, output);

      final wav = _Wav(await File(output).readAsBytes());
      expect(wav.format, 1, reason: 'PCM');
      expect(wav.channels, 1);
      expect(wav.sampleRate, 16000);
      expect(wav.bits, 16);
      // Codec priming and padding add a few tens of milliseconds.
      expect(wav.samples.length / 16000, closeTo(seconds, 0.15));
      // A wrong source rate or channel layout would shift the pitch.
      expect(wav.frequency(), closeTo(440, 15));
    });
  }

  testWidgets('a file no decoder reads says it cannot be converted', (
    tester,
  ) async {
    final input = File('${dir.path}/broken.m4a');
    await input.writeAsBytes([
      0, 0, 0, 0x18, ...ascii.encode('ftypM4A '), //
      ...List.filled(400, 0x5A),
    ]);

    await expectLater(
      transcoder.toWav(input.path, '${dir.path}/broken.wav'),
      throwsA(
        isA<AudioTranscodeException>().having(
          (e) => e.message,
          'message',
          '无法转换音频',
        ),
      ),
    );
  });
}
