import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/playback_history.dart';
import 'package:koe/state/recording_library.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-store-files-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('an unreadable recording library is kept aside, not overwritten by the '
      'next save', () async {
    final file = File('${temp.path}/recording_library.json');
    const unreadable = '{"assets": [ {"path": "/a.wav", "displayName": "会议';
    await file.writeAsString(unreadable);

    final store = RecordingLibraryStore(file: file);
    await store.load();
    expect(store.recoveryNotice, isNotNull);
    await store.upsert(
      RecordingAsset(
        path: '/b.wav',
        displayName: '新导入',
        source: RecordingSource.localImport,
        importedAt: DateTime(2026, 10, 19, 9),
      ),
    );

    final kept = temp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('recording_library.json.corrupt-'))
        .toList();
    expect(kept, hasLength(1));
    expect(await kept.single.readAsString(), unreadable);
  });

  test('two stores saving the same file at once both succeed', () async {
    // A relaunch can open a second store on the same file while the first is
    // still saving; they must not rename each other's temporary file away.
    final file = File('${temp.path}/playback_history.json');
    final first = PlaybackHistoryStore(file: file);
    final second = PlaybackHistoryStore(file: file);
    final saves = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      saves
        ..add(first.setSpeed(1.25))
        ..add(second.setSpeed(1.5));
    }
    await Future.wait(saves);

    final reloaded = PlaybackHistoryStore(file: file);
    await reloaded.load();
    expect(reloaded.speed, anyOf(1.25, 1.5));
    expect(
      temp.listSync().where((f) => f.path.endsWith('.tmp')),
      isEmpty,
    );
  });
}
