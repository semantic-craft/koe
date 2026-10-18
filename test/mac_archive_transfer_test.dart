import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_handshake.dart';
import 'package:koe/archive/archive_pairing.dart';
import 'package:koe/archive/archive_service.dart';
import 'package:koe/archive/archive_store.dart';
import 'package:koe/archive/archive_wire.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ArchiveDeskStore deskStore;
  late ArchiveDeskServer server;
  late ArchivePairing pairing;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-transfer-');
    deskStore = ArchiveDeskStore(directory: Directory('${root.path}/desk'));
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

  Future<File> makeAudio(
    String name, {
    int length = 180000,
    int seed = 7,
  }) async {
    final bytes = Uint8List(length);
    var value = seed;
    for (var i = 0; i < bytes.length; i++) {
      value = (value * 1103515245 + 12345) & 0x7fffffff;
      bytes[i] = value & 0xff;
    }
    final file = File('${root.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> waitFor(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('condition was not met within $timeout');
  }

  Future<ArchiveClient> connect([ArchivePairing? value]) =>
      ArchiveClient.connect(value ?? pairing, clientId: archiveRandomHex(16));

  test(
    'real loopback upload lands and verifies the exact content hash',
    () async {
      final file = await makeAudio('take.wav');
      final hash = await archiveFileHash(file.path);
      final client = await connect();
      addTearDown(client.close);

      final result = await client.uploadFile(
        path: file.path,
        contentHash: hash!,
        length: await file.length(),
        extension: '.wav',
        displayName: '访谈原件',
        clientId: archiveRandomHex(16),
      );

      expect(result.duplicate, isFalse);
      expect(result.contentHash, hash);
      expect(deskStore.entries, hasLength(1));
      final entry = deskStore.entries.single;
      expect(entry.length, await file.length());
      expect(await deskStore.verifyEntry(entry), isTrue);
      final stored = await deskStore.fileForEntry(entry);
      expect(await archiveFileHash(stored.path), hash);
    },
  );

  test(
    'uploading the same original again deduplicates instead of adding a copy',
    () async {
      final file = await makeAudio('same.wav', seed: 11);
      final hash = (await archiveFileHash(file.path))!;
      final length = await file.length();

      final first = await connect();
      final firstResult = await first.uploadFile(
        path: file.path,
        contentHash: hash,
        length: length,
        extension: '.wav',
        displayName: '第一次',
        clientId: archiveRandomHex(16),
      );
      expect(firstResult.duplicate, isFalse);
      await first.close();

      final second = await connect();
      final secondResult = await second.uploadFile(
        path: file.path,
        contentHash: hash,
        length: length,
        extension: '.wav',
        displayName: '第二次',
        clientId: archiveRandomHex(16),
      );
      expect(secondResult.duplicate, isTrue);
      await second.close();

      expect(deskStore.entries, hasLength(1));
      final files = await (await deskStore.filesDirectory()).list().toList();
      expect(files.whereType<File>(), hasLength(1));
    },
  );

  test(
    'server rejects a payload whose bytes do not match the declared hash',
    () async {
      final declaredHash = archiveHashBytes(<int>[1, 2, 3, 4]);
      final socket = await Socket.connect('127.0.0.1', server.port!);
      final session = await ArchiveHandshake.client(
        wire: ArchiveWire.adopt(socket),
        pairing: pairing,
        clientId: archiveRandomHex(16),
      );
      await session.sendControl(<String, Object?>{
        't': 'upload.begin',
        'contentHash': declaredHash,
        'length': 4,
        'extension': '.wav',
        'displayName': '损坏内容',
        'clientId': archiveRandomHex(16),
      });
      expect((await session.readControl())['t'], 'upload.ready');
      session.resetDataOrder();
      await session.sendData(Uint8List.fromList(<int>[9, 9, 9, 9]));
      await session.sendControl(<String, Object?>{'t': 'upload.finish'});
      final failed = await session.readControl();
      await session.close();

      expect(failed['t'], 'upload.failed');
      expect(failed['reason'], 'verify');
      expect(deskStore.entries, isEmpty);
      expect(await (await deskStore.filesDirectory()).list().toList(), isEmpty);
    },
  );

  test(
    'interrupted upload leaves no committed archive and a retry succeeds',
    () async {
      final file = await makeAudio('retry.wav', seed: 23);
      final hash = (await archiveFileHash(file.path))!;
      final length = await file.length();

      final socket = await Socket.connect('127.0.0.1', server.port!);
      final session = await ArchiveHandshake.client(
        wire: ArchiveWire.adopt(socket),
        pairing: pairing,
        clientId: archiveRandomHex(16),
      );
      await session.sendControl(<String, Object?>{
        't': 'upload.begin',
        'contentHash': hash,
        'length': length,
        'extension': '.wav',
        'displayName': '中断的传输',
        'clientId': archiveRandomHex(16),
      });
      expect((await session.readControl())['t'], 'upload.ready');
      session.resetDataOrder();
      final handle = await file.open();
      await session.sendData(await handle.read(1000));
      await handle.close();
      session.destroy();

      await waitFor(() async {
        final incoming = await (await deskStore.incomingDirectory())
            .list()
            .toList();
        return incoming.isEmpty;
      });
      expect(deskStore.entries, isEmpty);
      expect(await (await deskStore.filesDirectory()).list().toList(), isEmpty);

      final client = await connect();
      addTearDown(client.close);
      final result = await client.uploadFile(
        path: file.path,
        contentHash: hash,
        length: length,
        extension: '.wav',
        displayName: '重试成功',
        clientId: archiveRandomHex(16),
      );
      expect(result.duplicate, isFalse);
      expect(deskStore.entries, hasLength(1));
      expect(await deskStore.verifyEntry(deskStore.entries.single), isTrue);
    },
  );

  test('a wrong pairing key cannot open an authenticated session', () async {
    final wrong = ArchivePairing(
      deskId: pairing.deskId,
      key: ArchivePairing.generateKey(),
      hosts: const <String>['127.0.0.1'],
      port: pairing.port,
    );
    await expectLater(
      ArchiveClient.connect(wrong, clientId: archiveRandomHex(16)),
      throwsA(isA<ArchiveAuthException>()),
    );
    expect(deskStore.entries, isEmpty);
  });

  test(
    'restoring from the Mac verifies the downloaded bytes before returning',
    () async {
      final file = await makeAudio('restore.wav', seed: 31);
      final hash = (await archiveFileHash(file.path))!;
      final length = await file.length();

      final client = await connect();
      addTearDown(client.close);
      await client.uploadFile(
        path: file.path,
        contentHash: hash,
        length: length,
        extension: '.wav',
        displayName: '待恢复',
        clientId: archiveRandomHex(16),
      );
      final remote = await client.verify(hash);
      expect(remote.verified, isTrue);
      expect(remote.length, length);

      final target = '${root.path}/restored.wav';
      await client.fetchToFile(
        contentHash: hash,
        expectedLength: length,
        targetPath: target,
      );
      expect(await File(target).exists(), isTrue);
      expect(await archiveFileHash(target), hash);
      expect(await File(target).length(), length);
    },
  );

  test(
    'raw .opus.bin bytes keep their suffix and are restored unchanged',
    () async {
      final file = await makeAudio('raw.opus.bin', seed: 47);
      final hash = (await archiveFileHash(file.path))!;
      final length = await file.length();
      final originalBytes = await file.readAsBytes();

      final client = await connect();
      addTearDown(client.close);
      await client.uploadFile(
        path: file.path,
        contentHash: hash,
        length: length,
        extension: '.opus.bin',
        displayName: '原始加密字节',
        clientId: archiveRandomHex(16),
      );

      final entry = deskStore.entries.single;
      expect(entry.extension, '.opus.bin');
      final stored = await deskStore.fileForEntry(entry);
      expect(stored.path.endsWith('.opus.bin'), isTrue);
      expect(await stored.readAsBytes(), originalBytes);

      final target = '${root.path}/restored.opus.bin';
      await client.fetchToFile(
        contentHash: hash,
        expectedLength: length,
        targetPath: target,
      );
      expect(File(target).path.endsWith('.opus.bin'), isTrue);
      expect(await archiveFileHash(target), hash);
      expect(await File(target).readAsBytes(), originalBytes);
    },
  );

  test('concurrent ping and upload on one connection are serialized', () async {
    final file = await makeAudio('serialized.wav', seed: 53);
    final hash = (await archiveFileHash(file.path))!;
    final length = await file.length();
    final client = await connect();
    addTearDown(client.close);

    final upload = client.uploadFile(
      path: file.path,
      contentHash: hash,
      length: length,
      extension: '.wav',
      displayName: '串行操作',
      clientId: archiveRandomHex(16),
    );
    final ping = client.ping();
    await Future.wait(<Future<Object?>>[upload, ping]);
    expect(deskStore.entries, hasLength(1));
    expect(await deskStore.verifyEntry(deskStore.entries.single), isTrue);
  });

  test(
    'fetch never overwrites a target created after the existence check',
    () async {
      final file = await makeAudio('fetch-race.wav', seed: 137);
      final hash = (await archiveFileHash(file.path))!;
      final length = await file.length();
      final client = await connect();
      addTearDown(client.close);
      await client.uploadFile(
        path: file.path,
        contentHash: hash,
        length: length,
        extension: '.wav',
        displayName: '下载竞态',
        clientId: archiveRandomHex(16),
      );

      final targetPath = '${root.path}/created-during-download.wav';
      final otherBytes = Uint8List.fromList(<int>[9, 8, 7, 6]);
      await expectLater(
        client.fetchToFile(
          contentHash: hash,
          expectedLength: length,
          targetPath: targetPath,
          beforePublish: () =>
              File(targetPath).writeAsBytes(otherBytes, flush: true),
        ),
        throwsA(isA<ArchiveRemoteException>()),
      );
      expect(await File(targetPath).readAsBytes(), otherBytes);
      final leftovers = root
          .listSync()
          .whereType<File>()
          .where((entry) => entry.path.contains('.part-'))
          .toList();
      expect(leftovers, isEmpty);
    },
  );

  test('idle unauthenticated sockets cannot lock out a real pairing', () async {
    final existing = await connect();
    addTearDown(existing.close);
    await existing.ping();

    final idle = <Socket>[];
    for (var i = 0; i < 8; i++) {
      idle.add(await Socket.connect('127.0.0.1', server.port!));
    }
    addTearDown(() {
      for (final socket in idle) {
        socket.destroy();
      }
    });

    final legal = await connect();
    addTearDown(legal.close);
    final verify = await legal.verify(archiveHashBytes(<int>[1, 2, 3]));
    expect(verify.verified, isFalse);
    await existing.ping();
  });
  test(
    'stopping during storage preparation cancels the late receiver start',
    () async {
      final entered = Completer<void>();
      final directory = Completer<Directory>();
      final delayedStore = ArchiveDeskStore(
        supportDirectory: () {
          if (!entered.isCompleted) entered.complete();
          return directory.future;
        },
        developmentProfile: false,
      );
      final delayedServer = ArchiveDeskServer(store: delayedStore);
      addTearDown(delayedServer.stop);
      final starting = delayedServer.start(port: 0);
      await entered.future;
      await delayedServer.stop();
      directory.complete(root);
      await expectLater(starting, throwsA(isA<ArchiveException>()));
      expect(delayedServer.running, isFalse);
      expect(delayedServer.port, isNull);
    },
  );
}
