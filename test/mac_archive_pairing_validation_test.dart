import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_pairing.dart';
import 'package:koe/archive/archive_service.dart';
import 'package:koe/archive/archive_store.dart';
import 'package:koe/archive/archive_wire.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-pairing-validation-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'an invalid persisted pairing key is domain-invalid but valid records still load',
    () async {
      final invalidCode = ArchivePairing(
        deskId: 'a' * 32,
        key: '!!!not-a-valid-base64-key!!!',
        hosts: const <String>['127.0.0.1'],
        port: 47831,
      ).encode();
      final hash = archiveHashBytes(<int>[1, 2, 3, 4]);
      final record = ArchivePhoneRecord(
        localPath: '${root.path}/still-here.wav',
        displayName: '有效资料',
        originalExtension: '.wav',
        deskId: 'a' * 32,
        contentHash: hash,
        length: 4,
        sourceModifiedMs: 1,
        phase: MacArchivePhase.verified,
        verifiedAt: DateTime(2026, 10, 18),
        verifiedLength: 4,
        receipts: <String, ArchiveDeskReceipt>{
          'a' * 32: ArchiveDeskReceipt(
            contentHash: hash,
            length: 4,
            extension: '.wav',
            verifiedAt: DateTime(2026, 10, 18),
            sourceLength: 4,
            sourceModifiedMs: 1,
          ),
        },
        updatedAt: DateTime(2026, 10, 18),
      );
      final store = ArchivePhoneStore(
        directory: Directory('${root.path}/phone'),
      );
      final target = File('${root.path}/phone/phone_archive.json');
      await target.parent.create(recursive: true);
      await target.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'config': <String, Object?>{
            'pairing': invalidCode,
            'autoArchive': false,
            'clientId': 'b' * 32,
          },
          'records': <Object?>[record.toJson()],
        }),
        flush: true,
      );

      await store.load();
      expect(store.pairing, isNull);
      expect(store.recordForPath(record.localPath), isNotNull);
      expect(
        store.recordForPath(record.localPath)?.receipts['a' * 32]?.contentHash,
        hash,
      );
      expect(ArchivePairing.tryParse(invalidCode), isNull);
      expect(
        () => ArchivePairing.parse(invalidCode),
        throwsA(isA<ArchiveProtocolException>()),
      );
    },
  );

  test(
    'generated pairing hosts are valid even when the resolver returns more than eight',
    () async {
      final hosts = <String>[
        '10.0.0.1',
        '10.0.0.2',
        '10.0.0.1',
        for (var i = 3; i <= 12; i++) '10.0.0.$i',
      ];
      final store = ArchiveDeskStore(directory: Directory('${root.path}/desk'));
      await store.load();
      final server = ArchiveDeskServer(
        store: store,
        addressResolver: () async => hosts,
      );
      addTearDown(server.stop);
      await server.start(port: 0);
      final pairing = server.pairing!;
      final parsed = ArchivePairing.parse(pairing.encode());
      expect(parsed.hosts, pairing.hosts);
      expect(pairing.hosts, <String>[
        '10.0.0.1',
        '10.0.0.2',
        '10.0.0.3',
        '10.0.0.4',
        '10.0.0.5',
        '10.0.0.6',
        '10.0.0.7',
        '10.0.0.8',
      ]);
    },
  );
}
