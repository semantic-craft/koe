import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_pairing.dart';
import 'package:koe/archive/archive_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-phone-store-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  ArchivePhoneRecord record(String path, MacArchivePhase phase) =>
      ArchivePhoneRecord(
        localPath: path,
        displayName: phase.name,
        originalExtension: '.wav',
        phase: phase,
        length: 4,
        sourceModifiedMs: 1,
        updatedAt: DateTime(2026, 10, 18),
      );

  test(
    'a failed concurrent update never erases the following update',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      var failFirst = true;
      final store = ArchivePhoneStore(
        directory: Directory('${root.path}/phone'),
        writeInterceptor: () async {
          if (!failFirst) return;
          failFirst = false;
          entered.complete();
          await gate.future;
          throw const FileSystemException('synthetic phone write failure');
        },
      );
      await store.load();
      final path = '${root.path}/same.wav';
      final first = record(path, MacArchivePhase.pending);
      final second = record(path, MacArchivePhase.verified);

      final firstWrite = store.upsert(first);
      await entered.future;
      expect(store.recordForPath(path), isNull);
      final secondWrite = store.upsert(second);
      await Future<void>.delayed(Duration.zero);
      expect(store.recordForPath(path), isNull);

      gate.complete();
      await expectLater(firstWrite, throwsA(isA<FileSystemException>()));
      await secondWrite;
      expect(store.recordForPath(path)?.phase, MacArchivePhase.verified);

      final reopened = ArchivePhoneStore(
        directory: Directory('${root.path}/phone'),
      );
      await reopened.load();
      expect(reopened.recordForPath(path)?.phase, MacArchivePhase.verified);
      expect(reopened.recordForPath(path)?.displayName, second.displayName);
    },
  );

  test(
    'a failed pairing save cannot leak into the next record snapshot',
    () async {
      var failNext = true;
      final store = ArchivePhoneStore(
        directory: Directory('${root.path}/phone-config'),
        writeInterceptor: () async {
          if (!failNext) return;
          failNext = false;
          throw const FileSystemException('synthetic config failure');
        },
      );
      await store.load();
      final pairing = ArchivePairing(
        deskId: 'c' * 32,
        key: ArchivePairing.generateKey(),
        hosts: const <String>['127.0.0.1'],
        port: 47831,
      );
      await expectLater(
        store.setConfiguration(
          pairing: pairing,
          autoArchive: true,
          autoArchiveFrom: DateTime(2026, 10, 18),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.pairing, isNull);
      expect(store.autoArchive, isFalse);

      final path = '${root.path}/after-failure.wav';
      await store.upsert(record(path, MacArchivePhase.pending));
      final reopened = ArchivePhoneStore(
        directory: Directory('${root.path}/phone-config'),
      );
      await reopened.load();
      expect(reopened.pairing, isNull);
      expect(reopened.autoArchive, isFalse);
      expect(reopened.recordForPath(path)?.phase, MacArchivePhase.pending);
    },
  );

  test(
    'a failed Mac config write never publishes the new receiving state',
    () async {
      var failNext = true;
      final store = ArchiveDeskStore(
        directory: Directory('${root.path}/desk-config'),
        configWriteInterceptor: () async {
          if (!failNext) return;
          failNext = false;
          throw const FileSystemException('synthetic desk config failure');
        },
      );
      await store.load();
      await expectLater(
        store.setReceiving(enabled: true, preferredPort: 47831),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.config.receivingEnabled, isFalse);
      await store.setReceiving(enabled: true, preferredPort: 47831);
      expect(store.config.receivingEnabled, isTrue);

      final reopened = ArchiveDeskStore(
        directory: Directory('${root.path}/desk-config'),
      );
      await reopened.load();
      expect(reopened.config.receivingEnabled, isTrue);
    },
  );
}
