import 'dart:io';

import 'package:flutter/foundation.dart';
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
  Future<bool> archiveDidRestore(
    ArchivePhoneRecord record,
    String path, {
    required int length,
    required String contentHash,
    required bool Function() isCurrent,
  }) async {
    return isCurrent();
  }
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
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
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

  test(
    'closing the Mac receiver persists before stopping and reports an honest failure',
    () async {
      final directory = Directory('${root.path}/desk-toggle');
      final store = ArchiveDeskStore(directory: directory);
      await store.load();
      final controller = MacArchiveController(
        source: _NoopSource(),
        isDesk: true,
        phoneStore: ArchivePhoneStore(inMemory: true),
        deskStore: store,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.setDeskReceiving(true);
      expect(store.config.receivingEnabled, isTrue);
      expect(controller.deskRunning, isTrue);
      expect(controller.deskReceivingEnabled, isTrue);

      // A folder where the config file belongs makes the final rename fail.
      final config = File(
        '${directory.path}/${ArchiveDeskStore.configFileName}',
      );
      await config.delete();
      await Directory(config.path).create();
      await expectLater(
        controller.setDeskReceiving(false),
        throwsA(isA<ArchiveException>()),
      );
      expect(store.config.receivingEnabled, isTrue);
      expect(controller.deskRunning, isTrue);
      expect(controller.deskReceivingEnabled, isTrue);
      expect(controller.deskError, isNotNull);

      await Directory(config.path).delete();
      await controller.setDeskReceiving(false);
      expect(store.config.receivingEnabled, isFalse);
      expect(controller.deskRunning, isFalse);
      final reopened = ArchiveDeskStore(directory: directory);
      await reopened.load();
      expect(reopened.config.receivingEnabled, isFalse);
      final restarted = MacArchiveController(
        source: _NoopSource(),
        isDesk: true,
        phoneStore: ArchivePhoneStore(inMemory: true),
        deskStore: reopened,
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(restarted.deskRunning, isFalse);
      expect(restarted.deskReceivingEnabled, isFalse);
    },
  );
}
