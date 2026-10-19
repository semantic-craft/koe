import 'dart:io';
import 'dart:typed_data';

import 'package:koe/audio/ogg_opus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes a standard WAV header', () {
    final header = Uint8List(44);
    header.setAll(0, 'RIFF'.codeUnits);
    header.setAll(8, 'WAVE'.codeUnits);
    expect(OggOpus.isWav(header), isTrue);
  });

  test('mux raw 160-byte frames yields OggS', () {
    final frames = 10;
    final raw = Uint8List(frames * OggOpus.frameSize);
    // Non-zero payload so frames are not trimmed to empty.
    for (var i = 0; i < frames; i++) {
      final o = i * OggOpus.frameSize;
      raw[o] = 0xbc;
      for (var j = 1; j < OggOpus.frameSize; j++) {
        raw[o + j] = (j * 17 + i) & 0xFF;
      }
    }
    final ogg = OggOpus.muxRawFrames(raw);
    expect(OggOpus.isOgg(ogg), isTrue);
    expect(ogg.length, greaterThan(200));
  });

  test('imported m4a plays as itself, not re-wrapped as device Opus', () async {
    final dir = await Directory.systemTemp.createTemp('koe-playable-');
    addTearDown(() => dir.delete(recursive: true));
    final m4a = File('${dir.path}/imported.m4a');
    // `ftyp` box: an MPEG-4 file AVPlayer opens directly.
    await m4a.writeAsBytes([
      0,
      0,
      0,
      24,
      ...'ftypM4A '.codeUnits,
      0,
      0,
      0,
      0,
      ...'M4A isom'.codeUnits,
      ...List.filled(400, 7),
    ]);

    expect(await OggOpus.ensurePlayable(m4a.path), m4a.path);
    expect(File('${m4a.path}.ogg').existsSync(), isFalse);
  });

  test('ensurePlayable on sample file if present', () async {
    final path =
        '${Platform.environment['HOME']}/Library/Containers/com.anker.ankerRecorder/Data/Documents/AnkerRecorder/exports/1783822462.opus';
    final f = File(path);
    if (!await f.exists()) return;
    final playable = await OggOpus.ensurePlayable(path);
    expect(playable.endsWith('.ogg'), isTrue);
    final bytes = await File(playable).readAsBytes();
    expect(OggOpus.isOgg(bytes), isTrue);
    expect(bytes.length, greaterThan(1000));
  });

  test('已有较新的 Ogg 缓存时直接复用，不再读取原始文件', () async {
    final dir = await Directory.systemTemp.createTemp('ogg-cache');
    addTearDown(() async {
      await Process.run('chmod', ['-R', 'u+rw', dir.path]);
      await dir.delete(recursive: true);
    });
    final raw = File('${dir.path}/1783822462.opus');
    await raw.writeAsBytes(
      List.generate(OggOpus.frameSize * 20, (i) => (i % 251) + 1),
    );
    final first = await OggOpus.ensurePlayable(raw.path);
    expect(first, '${dir.path}/1783822462.ogg');
    await File(first).setLastModified(
      (await raw.lastModified()).add(const Duration(seconds: 5)),
    );
    // The source can no longer be read; only its metadata is available.
    await Process.run('chmod', ['000', raw.path]);

    expect(await OggOpus.ensurePlayable(raw.path), first);
  });
}
