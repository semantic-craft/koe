import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_pairing.dart';
import 'package:koe/platform/credential_store.dart';
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
  Future<void> archiveDidRestore(
    ArchivePhoneRecord record,
    String path, {
    required int length,
    required String contentHash,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-storage-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'pairing storage never falls back to Documents or a shared temp path',
    () async {
      final phone = ArchivePhoneStore(
        supportDirectory: () async =>
            throw const FileSystemException('support unavailable'),
      );
      await phone.load();
      expect(phone.storageUnavailable, isTrue);
      await expectLater(
        phone.storageDirectory(),
        throwsA(isA<ArchiveException>()),
      );
      final controller = MacArchiveController(
        source: _NoopSource(),
        isDesk: false,
        phoneStore: phone,
        deskStore: ArchiveDeskStore(inMemory: true),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await expectLater(
        controller.pairWithCode(
          ArchivePairing(
            deskId: 'b' * 32,
            key: ArchivePairing.generateKey(),
            hosts: const <String>['127.0.0.1'],
            port: 47831,
          ).encode(),
        ),
        throwsA(isA<ArchiveException>()),
      );
    },
  );

  test(
    'debug and release archive state use separate private folders',
    () async {
      final support = Directory('${root.path}/support');
      await support.create(recursive: true);
      final devPhone = ArchivePhoneStore(
        supportDirectory: () async => support,
        developmentProfile: true,
      );
      final prodPhone = ArchivePhoneStore(
        supportDirectory: () async => support,
        developmentProfile: false,
      );
      await devPhone.load();
      await prodPhone.load();
      expect(
        (await devPhone.storageDirectory()).path,
        contains('KoeArchiveDevelopment'),
      );
      expect((await prodPhone.storageDirectory()).path, contains('KoeArchive'));
      expect(
        (await devPhone.storageDirectory()).path,
        isNot((await prodPhone.storageDirectory()).path),
      );

      final devDesk = ArchiveDeskStore(
        supportDirectory: () async => support,
        developmentProfile: true,
      );
      final prodDesk = ArchiveDeskStore(
        supportDirectory: () async => support,
        developmentProfile: false,
      );
      await devDesk.load();
      await prodDesk.load();
      expect(
        (await devDesk.storageDirectory()).path,
        contains('KoeArchiveDevelopment'),
      );
      expect((await prodDesk.storageDirectory()).path, contains('KoeArchive'));
    },
  );

  test('a Mac without private storage refuses to start receiving', () async {
    final desk = ArchiveDeskStore(
      supportDirectory: () async =>
          throw const FileSystemException('support unavailable'),
    );
    await desk.load();
    expect(desk.storageUnavailable, isTrue);
    final controller = MacArchiveController(
      source: _NoopSource(),
      isDesk: true,
      phoneStore: ArchivePhoneStore(inMemory: true),
      deskStore: desk,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.deskRunning, isFalse);
    await expectLater(
      controller.setDeskReceiving(true),
      throwsA(isA<ArchiveException>()),
    );
  });

  test(
    'credential isolation mode selects separate private archive folders',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var mode = 'system';
      final calls = <String>[];
      messenger.setMockMethodCallHandler(CredentialStore.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'mode') return mode;
        throw MissingPluginException();
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(CredentialStore.channel, null),
      );
      final support = Directory('${root.path}/mode-support');
      await support.create(recursive: true);

      final systemStore = ArchivePhoneStore(
        supportDirectory: () async => support,
      );
      await systemStore.load();
      final systemPath = (await systemStore.storageDirectory()).path;
      expect(systemPath, contains('KoeArchive/phone'));
      expect(systemPath, isNot(contains('KoeArchiveDevelopment')));

      mode = 'isolated';
      final isolatedStore = ArchivePhoneStore(
        supportDirectory: () async => support,
      );
      await isolatedStore.load();
      final isolatedPath = (await isolatedStore.storageDirectory()).path;
      expect(isolatedPath, contains('KoeArchiveDevelopment/phone'));
      expect(isolatedPath, isNot(systemPath));
      expect(calls, everyElement('mode'));

      messenger.setMockMethodCallHandler(CredentialStore.channel, (call) async {
        if (call.method == 'mode') {
          throw MissingPluginException('mode unavailable');
        }
        throw MissingPluginException();
      });
      final unavailable = ArchivePhoneStore(
        supportDirectory: () async => support,
      );
      await unavailable.load();
      expect(
        (await unavailable.storageDirectory()).path,
        contains('KoeArchiveDevelopment/phone'),
      );
    },
  );
}
