import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/retrieved_audio.dart';

import 'support/wav_fixture.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('retrieved-audio-');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  test('finished WAV is accepted', () async {
    final path = await write('ok.wav', wavBytes([1, 0, 2, 0]));
    expect(
      await incompleteRetrievedAudioReason(path, settle: Duration.zero),
      isNull,
    );
  });

  test(
    'extra chunks before data, including odd padding, are accepted',
    () async {
      final path = await write(
        'list.wav',
        wavBytes([1, 0, 2, 0], extraChunk: (id: 'LIST', body: [1, 2, 3])),
      );
      expect(
        await incompleteRetrievedAudioReason(path, settle: Duration.zero),
        isNull,
      );
    },
  );

  test('truncated audio is rejected and the file is kept', () async {
    final path = await write(
      'cut.wav',
      wavBytes([1, 0, 2, 0], declaredDataSize: 4000, riffSize: 4036),
    );
    final reason = await incompleteRetrievedAudioReason(
      path,
      settle: Duration.zero,
    );
    expect(reason, contains('未完整取回'));
    expect(File(path).existsSync(), isTrue);
  });

  test('unfinalized placeholder header is rejected', () async {
    final path = await write(
      'part.wav',
      wavBytes([1, 0, 2, 0], declaredDataSize: 0, riffSize: 0),
    );
    expect(
      await incompleteRetrievedAudioReason(path, settle: Duration.zero),
      contains('仍在写入'),
    );
  });

  test('empty data chunk is rejected', () async {
    final path = await write('empty.wav', wavBytes(const []));
    expect(
      await incompleteRetrievedAudioReason(path, settle: Duration.zero),
      isNotNull,
    );
  });

  test('short or non-WAV files are rejected', () async {
    final short = await write('short.wav', [1, 2, 3]);
    final notWav = await write('ogg.wav', List.filled(64, 0x4f));
    expect(
      await incompleteRetrievedAudioReason(short, settle: Duration.zero),
      isNotNull,
    );
    expect(
      await incompleteRetrievedAudioReason(notWav, settle: Duration.zero),
      contains('WAV'),
    );
  });

  test('missing file is rejected', () async {
    expect(
      await incompleteRetrievedAudioReason(
        '${dir.path}/none.wav',
        settle: Duration.zero,
      ),
      contains('不存在'),
    );
  });

  test('file that grows during the settle window is rejected', () async {
    final path = await write('grow.wav', wavBytes([1, 0, 2, 0]));
    final check = incompleteRetrievedAudioReason(
      path,
      settle: const Duration(milliseconds: 200),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await File(path).writeAsBytes([9, 9], mode: FileMode.append, flush: true);
    expect(await check, contains('仍在写入'));
  });

  group('retrievedTransferComplete (shared BLE/Wi-Fi rule)', () {
    test('done signal is complete even below the announced size', () {
      expect(
        retrievedTransferComplete(
          doneSignal: true,
          received: 10,
          expected: 100,
        ),
        isTrue,
      );
    });

    test('every announced byte is complete without a done signal', () {
      expect(
        retrievedTransferComplete(
          doneSignal: false,
          received: 100,
          expected: 100,
        ),
        isTrue,
      );
    });

    test('>= 95% without a done signal is incomplete', () {
      expect(
        retrievedTransferComplete(
          doneSignal: false,
          received: 96,
          expected: 100,
        ),
        isFalse,
      );
    });

    test('unknown size without a done signal is incomplete', () {
      expect(
        retrievedTransferComplete(doneSignal: false, received: 96, expected: 0),
        isFalse,
      );
    });
  });
}
