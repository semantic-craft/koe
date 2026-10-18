import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_pairing.dart';
import 'package:koe/archive/archive_service.dart';
import 'package:koe/archive/archive_store.dart';
import 'package:koe/archive/archive_wire.dart';

class _FailingDeskStore extends ArchiveDeskStore {
  _FailingDeskStore({required super.directory});

  int failures = 0;

  @override
  Future<void> saveIndex() async {
    if (failures > 0) {
      failures--;
      throw const FileSystemException('synthetic index write failure');
    }
    return super.saveIndex();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FailingDeskStore deskStore;
  late ArchiveDeskServer server;
  late ArchivePairing pairing;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-commit-');
    deskStore = _FailingDeskStore(directory: Directory('${root.path}/desk'));
    await deskStore.load();
    server = ArchiveDeskServer(store: deskStore);
    await server.start(port: 0);
    pairing = ArchivePairing(
      deskId: deskStore.config.deskId,
      key: deskStore.config.pairingKey,
      hosts: const <String>['127.0.0.1'],
      port: server.port!,
    );
  });

  tearDown(() async {
    await server.stop();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> makeAudio(String name, {int seed = 5}) async {
    final bytes = Uint8List(90000);
    var value = seed;
    for (var i = 0; i < bytes.length; i++) {
      value = (value * 1103515245 + 12345) & 0x7fffffff;
      bytes[i] = value & 0xff;
    }
    final file = File('${root.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<ArchiveClient> connect() =>
      ArchiveClient.connect(pairing, clientId: archiveRandomHex(16));

  Future<ArchiveUploadResult> upload(ArchiveClient client, File file) async {
    final hash = (await archiveFileHash(file.path))!;
    return client.uploadFile(
      path: file.path,
      contentHash: hash,
      length: await file.length(),
      extension: '.wav',
      displayName: file.uri.pathSegments.last,
      clientId: archiveRandomHex(16),
    );
  }

  test(
    'an index write failure rolls back the file and never confirms',
    () async {
      final file = await makeAudio('rollback.wav');
      final client = await connect();
      addTearDown(client.close);
      deskStore.failures = 1;
      await expectLater(
        upload(client, file),
        throwsA(isA<ArchiveRemoteException>()),
      );
      expect(deskStore.entries, isEmpty);
      expect(await (await deskStore.filesDirectory()).list().toList(), isEmpty);

      deskStore.failures = 0;
      final result = await upload(client, file);
      expect(result.duplicate, isFalse);
      expect(deskStore.entries, hasLength(1));
      final stored = await deskStore.fileForEntry(deskStore.entries.single);
      expect(await stored.exists(), isTrue);
      expect(await deskStore.verifyEntry(deskStore.entries.single), isTrue);
    },
  );

  test(
    'concurrent same-content commits expose no file without an index entry',
    () async {
      final file = await makeAudio('concurrent.wav', seed: 71);
      final hash = (await archiveFileHash(file.path))!;
      final first = await connect();
      final second = await connect();
      addTearDown(first.close);
      addTearDown(second.close);
      deskStore.failures = 1;

      final outcomes = await Future.wait<bool>(<Future<bool>>[
        upload(first, file).then((_) => true).catchError((Object _) => false),
        upload(second, file).then((_) => true).catchError((Object _) => false),
      ]);
      expect(outcomes.where((value) => value).length, 1);
      expect(deskStore.entries, hasLength(1));
      final entry = deskStore.entries.single;
      expect(entry.contentHash, hash);
      final stored = await deskStore.fileForEntry(entry);
      expect(await stored.exists(), isTrue);
      expect(await archiveFileHash(stored.path), hash);
      expect(await deskStore.verifyEntry(entry), isTrue);
    },
  );
}
