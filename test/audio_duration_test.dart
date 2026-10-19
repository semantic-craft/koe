import 'dart:io';
import 'dart:typed_data';

import 'package:koe/audio/audio_duration.dart';
import 'package:koe/audio/ogg_opus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/wav_fixture.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('audio-duration-');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('reads duration from generated PCM WAV metadata', () async {
    final file = File('${directory.path}/1.wav');
    // The fixture is 16 kHz mono 16-bit: 32000 bytes per second.
    await file.writeAsBytes(wavBytes(Uint8List(32000 * 2)));

    expect(await AudioDuration.read(file.path), const Duration(seconds: 2));
  });

  test(
    'reads duration when iPhone recording adds JUNK and FLLR chunks',
    () async {
      // AVAudioRecorder writes JUNK before `fmt ` and pads with FLLR before
      // `data`; the fixed 44-byte layout read a zero byte rate and showed --:--.
      final wav = wavBytes(
        Uint8List(32000 * 3),
        extraChunk: (id: 'FLLR', body: Uint8List(4000)),
      );
      final junk = [...'JUNK'.codeUnits, 28, 0, 0, 0, ...Uint8List(28)];
      final file = File('${directory.path}/phone.wav');
      await file.writeAsBytes([
        ...wav.sublist(0, 12),
        ...junk,
        ...wav.sublist(12),
      ]);

      expect(await AudioDuration.read(file.path), const Duration(seconds: 3));
    },
  );

  test('estimates duration from raw Opus frame count', () async {
    final file = File('${directory.path}/1.opus');
    await file.writeAsBytes(Uint8List(OggOpus.frameSize * 10));

    expect(
      await AudioDuration.read(file.path),
      const Duration(milliseconds: 200),
    );
  });

  test('reads duration from the final Ogg granule', () async {
    final raw = Uint8List(OggOpus.frameSize * 50);
    for (var i = 0; i < raw.length; i += OggOpus.frameSize) {
      raw[i] = 0xbc;
    }
    final file = File('${directory.path}/1.opus');
    await file.writeAsBytes(OggOpus.muxRawFrames(raw));

    expect(await AudioDuration.read(file.path), const Duration(seconds: 1));
  });
}
