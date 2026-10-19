import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_pairing.dart';
import 'package:koe/archive/archive_service.dart';
import 'package:koe/archive/archive_store.dart';
import 'package:koe/archive/archive_wire.dart';
import 'package:koe/archive/mac_archive_controller.dart';

class _NoopSource implements ArchiveSource {
  @override
  Future<List<ArchiveCandidate>> archiveCandidates() async => const [];

  @override
  Future<ArchiveCandidate?> archiveCandidate(String path) async => null;

  @override
  Future<String> archiveRestoreTarget(ArchivePhoneRecord record) async =>
      record.localPath;

  @override
  Future<bool> archiveDidRestore(
    ArchivePhoneRecord record,
    String path, {
    required int length,
    required String contentHash,
    required bool Function() isCurrent,
  }) async => isCurrent();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-rotate-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<ArchiveClient> connect(ArchivePairing pairing) =>
      ArchiveClient.connect(pairing, clientId: archiveRandomHex(16));

  Future<File> makeAudio() async {
    final file = File('${root.path}/rotation.wav');
    await file.writeAsBytes(
      Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
      flush: true,
    );
    return file;
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('Mac 重置配对凭据或关闭接收后，手机不再显示已连接', () async {
    final deskStore = ArchiveDeskStore(
      directory: Directory('${root.path}/desk'),
    );
    await deskStore.load();
    final desk = MacArchiveController(
      source: _NoopSource(),
      isDesk: true,
      phoneStore: ArchivePhoneStore(inMemory: true),
      deskStore: deskStore,
    );
    addTearDown(desk.dispose);
    await desk.initialize();
    await desk.setDeskReceiving(true);
    MacArchiveController phone() => MacArchiveController(
      source: _NoopSource(),
      isDesk: false,
      phoneStore: ArchivePhoneStore(inMemory: true),
      deskStore: ArchiveDeskStore(inMemory: true),
      linkCheckInterval: const Duration(milliseconds: 50),
    );

    final reset = phone();
    addTearDown(reset.dispose);
    await reset.initialize();
    await reset.pairWithCode(desk.deskPairing!.encode());
    await reset.connectNow();
    expect(reset.linkLabel, '已连接');

    await desk.resetDeskPairing();
    await until(() => !{'已连接', '连接中'}.contains(reset.linkLabel));
    expect(reset.linkLabel, '连接失败');
    expect(reset.linkDetail, contains('配对密钥无效'));

    final closed = phone();
    addTearDown(closed.dispose);
    await closed.initialize();
    await closed.pairWithCode(desk.deskPairing!.encode());
    await closed.connectNow();
    expect(closed.linkLabel, '已连接');

    await desk.setDeskReceiving(false);
    await until(() => !{'已连接', '连接中'}.contains(closed.linkLabel));
    expect(closed.linkLabel, isNot('已连接'));
  });

  test(
    'old authenticated clients and old codes are invalid after rotation',
    () async {
      final deskStore = ArchiveDeskStore(
        directory: Directory('${root.path}/desk'),
      );
      await deskStore.load();
      final controller = MacArchiveController(
        source: _NoopSource(),
        isDesk: true,
        phoneStore: ArchivePhoneStore(inMemory: true),
        deskStore: deskStore,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setDeskReceiving(true);
      final oldPairing = controller.deskPairing!;
      final oldKey = oldPairing.key;
      final file = await makeAudio();
      final hash = (await archiveFileHash(file.path))!;
      final oldClient = await connect(oldPairing);
      addTearDown(oldClient.close);
      await oldClient.uploadFile(
        path: file.path,
        contentHash: hash,
        length: await file.length(),
        extension: '.wav',
        displayName: 'rotation',
        clientId: archiveRandomHex(16),
      );
      final entry = deskStore.entries.single;

      await controller.resetDeskPairing();
      final newPairing = controller.deskPairing!;
      expect(newPairing.key, isNot(oldKey));
      expect(newPairing.deskId, oldPairing.deskId);
      expect(deskStore.entries, hasLength(1));
      await expectLater(oldClient.ping(), throwsA(isA<ArchiveException>()));
      final revokedAtNewEndpoint = ArchivePairing(
        deskId: newPairing.deskId,
        key: oldPairing.key,
        hosts: newPairing.hosts,
        port: newPairing.port,
      );
      await expectLater(
        connect(revokedAtNewEndpoint),
        throwsA(isA<ArchiveException>()),
      );
      final newClient = await connect(newPairing);
      addTearDown(newClient.close);
      final verified = await newClient.verify(hash);
      expect(verified.verified, isTrue);
      expect(await deskStore.verifyEntry(entry), isTrue);

      await controller.setDeskReceiving(false);
      await controller.resetDeskPairing();
      final closedKey = deskStore.config.pairingKey;
      expect(closedKey, isNot(newPairing.key));

      final reopenedStore = ArchiveDeskStore(
        directory: Directory('${root.path}/desk'),
      );
      await reopenedStore.load();
      expect(reopenedStore.config.pairingKey, closedKey);
      final reopened = MacArchiveController(
        source: _NoopSource(),
        isDesk: true,
        phoneStore: ArchivePhoneStore(inMemory: true),
        deskStore: reopenedStore,
      );
      addTearDown(reopened.dispose);
      await reopened.initialize();
      await reopened.setDeskReceiving(true);
      final closedPairing = reopened.deskPairing!;
      final revokedAfterRestart = ArchivePairing(
        deskId: closedPairing.deskId,
        key: newPairing.key,
        hosts: closedPairing.hosts,
        port: closedPairing.port,
      );
      await expectLater(
        connect(revokedAfterRestart),
        throwsA(isA<ArchiveException>()),
      );
      expect(closedPairing.key, closedKey);
      final finalClient = await connect(closedPairing);
      addTearDown(finalClient.close);
      expect((await finalClient.verify(hash)).verified, isTrue);
    },
  );

  test(
    'a failed key write keeps the old key, session and receiver running',
    () async {
      var failNext = false;
      final deskStore = ArchiveDeskStore(
        directory: Directory('${root.path}/desk-failure'),
        configWriteInterceptor: () async {
          if (!failNext) return;
          failNext = false;
          throw const FileSystemException('synthetic rotation write failure');
        },
      );
      await deskStore.load();
      final controller = MacArchiveController(
        source: _NoopSource(),
        isDesk: true,
        phoneStore: ArchivePhoneStore(inMemory: true),
        deskStore: deskStore,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setDeskReceiving(true);
      final oldPairing = controller.deskPairing!;
      final client = await connect(oldPairing);
      addTearDown(client.close);
      failNext = true;
      await expectLater(
        controller.resetDeskPairing(),
        throwsA(isA<ArchiveException>()),
      );
      expect(deskStore.config.pairingKey, oldPairing.key);
      expect(controller.deskRunning, isTrue);
      expect(controller.deskError, isNotNull);
      await client.ping();

      await controller.resetDeskPairing();
      expect(deskStore.config.pairingKey, isNot(oldPairing.key));
    },
  );
}
