import 'dart:async';
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
  Completer<void>? gate;
  Completer<void>? entered;

  @override
  Future<void> saveIndex({Map<String, ArchiveDeskEntry>? entries}) async {
    final pending = gate;
    if (pending != null) {
      gate = null;
      if (!(entered?.isCompleted ?? true)) entered!.complete();
      await pending.future;
    }
    if (failures > 0) {
      failures--;
      throw const FileSystemException('synthetic index write failure');
    }
    return super.saveIndex(entries: entries);
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
      expect(client.connected, isFalse);
      expect(deskStore.entries, isEmpty);
      expect(await (await deskStore.filesDirectory()).list().toList(), isEmpty);

      deskStore.failures = 0;
      final retry = await connect();
      addTearDown(retry.close);
      final result = await upload(retry, file);
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

  test(
    'an uncommitted index write is invisible to a duplicate upload',
    () async {
      final file = await makeAudio('gated.wav', seed: 83);
      final hash = (await archiveFileHash(file.path))!;
      final first = await connect();
      final second = await connect();
      addTearDown(first.close);
      addTearDown(second.close);
      deskStore
        ..failures = 1
        ..gate = Completer<void>()
        ..entered = Completer<void>();
      final gate = deskStore.gate!;
      final entered = deskStore.entered!;

      final firstUpload = upload(first, file);
      await entered.future;
      expect(deskStore.entryForHash(hash), isNull);

      var secondDone = false;
      final secondUpload = upload(second, file);
      secondUpload.then<void>((_) => secondDone = true, onError: (Object _) {});
      await Future<void>.delayed(Duration.zero);
      expect(secondDone, isFalse);

      gate.complete();
      await expectLater(firstUpload, throwsA(isA<ArchiveRemoteException>()));
      final secondResult = await secondUpload;
      expect(secondResult.duplicate, isFalse);
      expect(deskStore.entries, hasLength(1));
      final entry = deskStore.entries.single;
      expect(entry.contentHash, hash);
      final stored = await deskStore.fileForEntry(entry);
      expect(await archiveFileHash(stored.path), hash);
      expect(await deskStore.verifyEntry(entry), isTrue);
    },
  );

  test(
    'startup adoption verifies bytes before exposing a recovered entry',
    () async {
      final directory = Directory('${root.path}/recovered');
      final first = ArchiveDeskStore(directory: directory);
      await first.load();
      final files = await first.filesDirectory();
      await files.create(recursive: true);

      final fakeHash = archiveHashBytes(<int>[1, 2, 3]);
      final fake = File('${files.path}/$fakeHash.wav');
      await fake.writeAsBytes(<int>[4, 5, 6], flush: true);
      final reopened = ArchiveDeskStore(directory: directory);
      await reopened.load();
      expect(reopened.entries, isEmpty);
      expect(await fake.exists(), isTrue);

      final bytes = Uint8List.fromList(<int>[7, 8, 9, 10, 11]);
      final goodHash = archiveHashBytes(bytes);
      final good = File('${files.path}/$goodHash.opus.bin');
      await good.writeAsBytes(bytes, flush: true);
      final recovered = ArchiveDeskStore(directory: directory);
      await recovered.load();
      expect(recovered.entries, hasLength(1));
      expect(recovered.entries.single.contentHash, goodHash);
      expect(recovered.entries.single.extension, '.opus.bin');
      expect(await recovered.verifyEntry(recovered.entries.single), isTrue);
    },
  );
}
