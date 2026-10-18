import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/listening_queue.dart';

void main() {
  late Directory temp;
  late File queueFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-queue-');
    queueFile = File('${temp.path}/listening_queue.json');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  ListeningQueueEntry entry(String name, {int? fileId, DateTime? addedAt}) =>
      ListeningQueueEntry(
        path: '${temp.path}/$name',
        fileId: fileId,
        title: name,
        addedAt: addedAt ?? DateTime(2026, 10, 18, 9),
      );

  test('队列增删重排与当前项写盘，重启后顺序和当前资料保持', () async {
    final store = ListeningQueueStore(file: queueFile);
    await store.load();

    expect(await store.add(entry('100.wav', fileId: 100)), isTrue);
    expect(await store.add(entry('178.wav', fileId: 178)), isTrue);
    expect(await store.add(entry('200.wav', fileId: 200)), isTrue);
    expect(
      await store.add(entry('100.wav', fileId: 100)),
      isFalse,
      reason: '同一份资料不能在队列里出现两次',
    );

    expect(await store.move(2, 0), isTrue);
    await store.setCurrent('id:178');
    await store.remove('id:100');

    final restarted = ListeningQueueStore(file: queueFile);
    await restarted.load();

    expect(restarted.entries.map((item) => item.fileId).toList(), [200, 178]);
    expect(restarted.currentKey, 'id:178');
    expect(restarted.current?.title, '178.wav');
  });

  test('队列写入失败时不改变内存，旧顺序和当前项保持原样', () async {
    final store = _FailingStore(file: queueFile);
    await store.load();
    await store.add(entry('100.wav', fileId: 100));
    await store.setCurrent('id:100');
    store.fail = true;

    await expectLater(
      store.add(entry('178.wav', fileId: 178)),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(store.move(0, 0), completes, reason: '无效重排不应触发写入');
    await expectLater(
      store.remove('id:100'),
      throwsA(isA<FileSystemException>()),
    );

    expect(store.entries.map((item) => item.fileId), [100]);
    expect(store.currentKey, 'id:100');
  });

  test('队列文件损坏时另存原文件并提示，不静默覆盖', () async {
    await queueFile.writeAsString('{not json');
    final store = ListeningQueueStore(file: queueFile);
    await store.load();

    expect(store.entries, isEmpty);
    expect(store.recoveryNotice, isNotNull);
    final backups = temp
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('listening_queue.json.unreadable-'))
        .toList();
    expect(backups, isNotEmpty);
  });
}

class _FailingStore extends ListeningQueueStore {
  _FailingStore({super.file});

  bool fail = false;

  @override
  Future<void> writeSnapshot(String json) async {
    if (fail) throw const FileSystemException('queue write failed');
    await super.writeSnapshot(json);
  }
}
