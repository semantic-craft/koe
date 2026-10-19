import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/container_paths.dart';
import 'package:koe/state/recording_library.dart';

const _old = 'C2BFBFB1-04BA-40D6-A991-62BA8716B781';
const _now = '7E1D2C3B-0000-4A4A-8B8B-123456789ABC';
const _root = '/var/mobile/Containers/Data/Application';

void main() {
  test('after a reinstall, saved phone recordings and their transcripts '
      'point into the current container', () async {
    final dir = await Directory.systemTemp.createTemp('koe-container-');
    addTearDown(() => dir.delete(recursive: true));
    final oldWav = '$_root/$_old/Documents/AnkerRecorder/imports/phone_1.wav';
    final newWav = '$_root/$_now/Documents/AnkerRecorder/imports/phone_1.wav';
    await File('${dir.path}/transcripts.json').writeAsString(
      jsonEncode({
        'byPath': {oldWav: '我明天去买牛奶。'},
        'metadata': {'path:$oldWav': {}},
      }),
    );
    await File('${dir.path}/recording_library.json').writeAsString(
      jsonEncode({
        'version': 1,
        'assets': [
          {
            'path': oldWav,
            'displayName': '手机录音 10-19 11:33',
            'source': 'phone',
            'importedAt': '2026-10-19T11:34:00',
            'originalPath': '/private$oldWav',
          },
        ],
      }),
    );
    final untouched = File('${dir.path}/notes.txt')..writeAsStringSync(oldWav);

    final changed = await relocateStoredPaths(dir, '$_root/$_now/Documents');

    expect(changed, 2);
    final transcripts = jsonDecode(
      await File('${dir.path}/transcripts.json').readAsString(),
    );
    expect(transcripts['byPath'][newWav], '我明天去买牛奶。');
    expect((transcripts['metadata'] as Map).keys, ['path:$newWav']);
    final library = RecordingLibraryStore.decode(
      await File('${dir.path}/recording_library.json').readAsString(),
    )!;
    expect(library.keys, [newWav]);
    expect(untouched.readAsStringSync(), oldWav);
  });

  test('off iOS nothing is rewritten', () async {
    final dir = await Directory.systemTemp.createTemp('koe-container-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/transcripts.json')
      ..writeAsStringSync('{"byPath":{"$_root/$_old/Documents/a.wav":"x"}}');
    final before = file.readAsStringSync();

    expect(await relocateStoredPaths(dir, '/Users/me/Library/Documents'), 0);
    expect(file.readAsStringSync(), before);
  });
}
