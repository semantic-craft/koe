import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_pairing.dart';
import 'package:koe/archive/archive_service.dart';
import 'package:koe/archive/archive_store.dart';
import 'package:koe/archive/archive_wire.dart';
import 'package:koe/archive/mac_archive_controller.dart';

class _TestSource implements ArchiveSource {
  final Set<String> paths = <String>{};
  final List<String> restored = <String>[];

  void add(String path) => paths.add(path);

  @override
  Future<List<ArchiveCandidate>> archiveCandidates() async {
    final candidates = <ArchiveCandidate>[];
    for (final path in paths) {
      final candidate = await archiveCandidate(path);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  @override
  Future<ArchiveCandidate?> archiveCandidate(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) return null;
    final lower = path.toLowerCase();
    final extension = lower.endsWith('.opus.bin')
        ? '.opus.bin'
        : lower.substring(lower.lastIndexOf('.'));
    if (!archiveAllowedSourceExtensions.contains(extension)) return null;
    return ArchiveCandidate(
      path: path,
      displayName: file.uri.pathSegments.last,
      extension: extension,
      length: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  @override
  Future<String> archiveRestoreTarget(ArchivePhoneRecord record) async =>
      record.localPath;

  @override
  Future<void> archiveDidRestore(
    ArchivePhoneRecord record,
    String path, {
    required int length,
    required String contentHash,
  }) async {
    paths.add(path);
    restored.add(path);
  }
}

class _GatedRestoreSource extends _TestSource {
  Completer<void>? gate;
  Completer<void>? entered;

  @override
  Future<String> archiveRestoreTarget(ArchivePhoneRecord record) async {
    if (!(entered?.isCompleted ?? true)) entered!.complete();
    final pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    return record.localPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ArchiveDeskStore deskStore;
  late ArchiveDeskServer server;
  late ArchivePairing pairing;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-controller-');
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
    int seed = 3,
    int length = 120000,
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

  MacArchiveController phone(_TestSource source, {Directory? storeDirectory}) =>
      MacArchiveController(
        source: source,
        isDesk: false,
        phoneStore: ArchivePhoneStore(
          directory: storeDirectory ?? Directory('${root.path}/phone'),
        ),
        deskStore: ArchiveDeskStore(inMemory: true),
      );

  test(
    'verified archive state and pairing survive a controller restart',
    () async {
      final source = _TestSource();
      final file = await makeAudio('persisted.wav');
      source.add(file.path);
      final first = phone(source);
      await first.initialize();
      await first.pairWithCode(pairing.encode());
      await first.archiveNow(file.path);
      await first.waitForWorker();

      final record = first.recordForPath(file.path);
      expect(record?.phase, MacArchivePhase.verified);
      expect(record?.contentHash, await archiveFileHash(file.path));
      expect(deskStore.entries, hasLength(1));
      first.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final source2 = _TestSource()..add(file.path);
      final second = phone(source2);
      addTearDown(second.dispose);
      await second.initialize();
      await second.waitForWorker();
      expect(second.pairing, isNotNull);
      expect(second.autoArchive, isTrue);
      final restored = second.recordForPath(file.path);
      expect(restored?.phase, MacArchivePhase.verified);
      expect(second.archivedWithoutLocal, isEmpty);
      expect(deskStore.entries, hasLength(1));
    },
  );

  test('a new original is picked up automatically after pairing', () async {
    final source = _TestSource();
    final controller = phone(source);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.pairWithCode(pairing.encode());
    await controller.waitForWorker();

    await Future<void>.delayed(const Duration(milliseconds: 10));
    final file = await makeAudio('new.wav', seed: 17);
    source.add(file.path);
    await controller.onLocalLibraryChanged();
    await controller.waitForWorker();

    expect(
      controller.recordForPath(file.path)?.phase,
      MacArchivePhase.verified,
    );
    expect(deskStore.entries, hasLength(1));
  });

  test(
    'a deleted phone original stays visibly archival and can be restored',
    () async {
      final source = _TestSource();
      final file = await makeAudio('deleted.wav', seed: 29);
      source.add(file.path);
      final controller = phone(source);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.pairWithCode(pairing.encode());
      await controller.archiveNow(file.path);
      await controller.waitForWorker();
      final hash = (await archiveFileHash(file.path))!;
      expect(
        controller.recordForPath(file.path)?.phase,
        MacArchivePhase.verified,
      );

      await file.delete();
      await controller.onLocalLibraryChanged();
      await controller.waitForWorker();
      expect(
        controller.recordForPath(file.path)?.phase,
        MacArchivePhase.verified,
      );
      expect(controller.archivedWithoutLocal, contains(file.path));

      final restoredPath = await controller.restoreFromArchive(file.path);
      expect(restoredPath, file.path);
      expect(await File(file.path).exists(), isTrue);
      expect(await archiveFileHash(file.path), hash);
      expect(source.restored, contains(file.path));
      expect(controller.archivedWithoutLocal, isEmpty);
    },
  );

  test(
    'a changed source becomes a new verified version without overwriting the old archive',
    () async {
      final source = _TestSource();
      final file = await makeAudio('changed.wav', seed: 41);
      source.add(file.path);
      final controller = phone(source);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.pairWithCode(pairing.encode());
      await controller.archiveNow(file.path);
      await controller.waitForWorker();
      final oldHash = (await archiveFileHash(file.path))!;

      await Future<void>.delayed(const Duration(milliseconds: 10));
      final replacement = Uint8List(4096);
      for (var i = 0; i < replacement.length; i++) {
        replacement[i] = (i * 17) & 0xff;
      }
      await file.writeAsBytes(replacement, flush: true);
      await controller.archiveNow(file.path);
      await controller.waitForWorker();

      final record = controller.recordForPath(file.path);
      expect(record?.phase, MacArchivePhase.verified);
      expect(record?.contentHash, isNot(oldHash));
      expect(record?.contentHash, await archiveFileHash(file.path));
      expect(deskStore.entries, hasLength(2));
      expect(
        deskStore.entries.map((entry) => entry.contentHash),
        contains(oldHash),
      );
    },
  );

  test(
    'changing Mac target invalidates old verified state before any new confirm',
    () async {
      final secondStore = ArchiveDeskStore(
        directory: Directory('${root.path}/desk-second'),
      );
      await secondStore.load();
      final secondServer = ArchiveDeskServer(store: secondStore);
      await secondServer.start(port: 0);
      addTearDown(secondServer.stop);
      final secondPairing = ArchivePairing(
        deskId: secondStore.config.deskId,
        key: secondStore.config.pairingKey,
        hosts: const <String>['127.0.0.1'],
        port: secondServer.port!,
      );

      final source = _TestSource();
      final file = await makeAudio('switch.wav', seed: 61);
      source.add(file.path);
      final controller = phone(source);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.pairWithCode(pairing.encode());
      await controller.archiveNow(file.path);
      await controller.waitForWorker();
      expect(controller.recordForPath(file.path)?.deskId, pairing.deskId);
      expect(
        controller.recordForPath(file.path)?.phase,
        MacArchivePhase.verified,
      );

      await controller.pairWithCode(secondPairing.encode());
      final record = controller.recordForPath(file.path);
      expect(record?.deskId, secondPairing.deskId);
      if (record?.phase == MacArchivePhase.verified) {
        // A verified state is only allowed after the new Mac actually received
        // and verified a copy.
        expect(secondStore.entries, hasLength(1));
      } else {
        expect(record?.phase, MacArchivePhase.pending);
        expect(secondStore.entries, isEmpty);
      }
    },
  );

  test(
    'a late connection after disconnect is closed and never becomes connected',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      var blockNext = false;
      final controller = MacArchiveController(
        source: _TestSource(),
        isDesk: false,
        phoneStore: ArchivePhoneStore(
          directory: Directory('${root.path}/late-phone'),
        ),
        deskStore: ArchiveDeskStore(inMemory: true),
        clientConnector: (pairing, clientId) async {
          if (blockNext) {
            blockNext = false;
            if (!entered.isCompleted) entered.complete();
            await gate.future;
          }
          return ArchiveClient.connect(pairing, clientId: clientId);
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.pairWithCode(pairing.encode());
      await controller.waitForWorker();

      final source = controller.source as _TestSource;
      final file = await makeAudio('late.wav', seed: 67);
      source.add(file.path);
      blockNext = true;
      await controller.archiveNow(file.path);
      await entered.future;
      await controller.disconnect();
      gate.complete();
      await controller.waitForWorker();

      expect(controller.connected, isFalse);
      expect(
        controller.recordForPath(file.path)?.phase,
        MacArchivePhase.pending,
      );
      expect(deskStore.entries, isEmpty);
    },
  );

  test(
    'restore and manual connect use a connection independent of a paused upload',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      var blockNext = false;
      final source = _TestSource();
      final first = await makeAudio('first.wav', seed: 73);
      final second = await makeAudio('second.wav', seed: 79);
      source
        ..add(first.path)
        ..add(second.path);
      final controller = MacArchiveController(
        source: source,
        isDesk: false,
        phoneStore: ArchivePhoneStore(
          directory: Directory('${root.path}/independent-phone'),
        ),
        deskStore: ArchiveDeskStore(inMemory: true),
        clientConnector: (pairing, clientId) async {
          if (blockNext) {
            blockNext = false;
            if (!entered.isCompleted) entered.complete();
            await gate.future;
          }
          return ArchiveClient.connect(pairing, clientId: clientId);
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.pairWithCode(pairing.encode());
      await controller.archiveNow(first.path);
      await controller.waitForWorker();
      final firstHash = (await archiveFileHash(first.path))!;
      expect(
        controller.recordForPath(first.path)?.phase,
        MacArchivePhase.verified,
      );

      await controller.disconnect();
      await first.delete();
      blockNext = true;
      await controller.archiveNow(second.path);
      await entered.future;

      final restored = await controller.restoreFromArchive(first.path);
      expect(restored, first.path);
      expect(await archiveFileHash(first.path), firstHash);

      gate.complete();
      await controller.waitForWorker();
      expect(
        controller.recordForPath(second.path)?.phase,
        MacArchivePhase.verified,
      );
      expect(deskStore.entries, hasLength(2));
    },
  );

  test(
    'deleting or renaming a record while restore is paused prevents resurrection',
    () async {
      for (final action in <String>['delete', 'rename']) {
        final source = _GatedRestoreSource();
        final file = await makeAudio(
          'restore-$action.wav',
          seed: action == 'delete' ? 101 : 103,
        );
        source.add(file.path);
        final controller = phone(
          source,
          storeDirectory: Directory('${root.path}/phone-$action'),
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.pairWithCode(pairing.encode());
        await controller.archiveNow(file.path);
        await controller.waitForWorker();
        await file.delete();
        await controller.onLocalLibraryChanged();
        await controller.waitForWorker();

        source
          ..gate = Completer<void>()
          ..entered = Completer<void>();
        final gate = source.gate!;
        final entered = source.entered!;
        final restore = controller.restoreFromArchive(file.path);
        await entered.future;
        if (action == 'delete') {
          await controller.forgetLocalPath(file.path);
        } else {
          await controller.renameLocalPath(
            file.path,
            '${root.path}/renamed-$action.wav',
          );
        }
        gate.complete();
        await expectLater(restore, throwsA(isA<ArchiveException>()));
        expect(source.restored, isEmpty);
        if (action == 'delete') {
          expect(controller.recordForPath(file.path), isNull);
        } else {
          expect(controller.recordForPath(file.path), isNull);
          expect(
            controller.recordForPath('${root.path}/renamed-$action.wav')?.phase,
            MacArchivePhase.verified,
          );
        }
      }
    },
  );

  test(
    'pairing back to the original Mac restores the preserved archive receipt',
    () async {
      final secondStore = ArchiveDeskStore(
        directory: Directory('${root.path}/desk-b'),
      );
      await secondStore.load();
      final secondServer = ArchiveDeskServer(store: secondStore);
      await secondServer.start(port: 0);
      addTearDown(secondServer.stop);
      final secondPairing = ArchivePairing(
        deskId: secondStore.config.deskId,
        key: secondStore.config.pairingKey,
        hosts: const <String>['127.0.0.1'],
        port: secondServer.port!,
      );

      final source = _TestSource();
      final file = await makeAudio('roundtrip.wav', seed: 107);
      source.add(file.path);
      final controller = phone(
        source,
        storeDirectory: Directory('${root.path}/phone-roundtrip'),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.pairWithCode(pairing.encode());
      await controller.archiveNow(file.path);
      await controller.waitForWorker();
      final hash = (await archiveFileHash(file.path))!;
      await file.delete();
      await controller.onLocalLibraryChanged();
      await controller.waitForWorker();

      await controller.pairWithCode(secondPairing.encode());
      final afterB = controller.recordForPath(file.path);
      expect(afterB?.receipts.keys, contains(pairing.deskId));
      expect(afterB?.deskId, secondPairing.deskId);
      expect(afterB?.phase, isNot(MacArchivePhase.verified));

      await controller.pairWithCode(pairing.encode());
      final backOnA = controller.recordForPath(file.path);
      expect(backOnA?.deskId, pairing.deskId);
      expect(backOnA?.phase, MacArchivePhase.verified);
      expect(backOnA?.contentHash, hash);
      expect(controller.archivedWithoutLocal, contains(file.path));

      final restored = await controller.restoreFromArchive(file.path);
      expect(restored, file.path);
      expect(await archiveFileHash(file.path), hash);
    },
  );

  test(
    'manual disconnect stops the queued worker and explicit connect resumes it',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      var blockNext = false;
      final source = _TestSource();
      final first = await makeAudio('queued-a.wav', seed: 109);
      final second = await makeAudio('queued-b.wav', seed: 113);
      source
        ..add(first.path)
        ..add(second.path);
      final controller = MacArchiveController(
        source: source,
        isDesk: false,
        phoneStore: ArchivePhoneStore(
          directory: Directory('${root.path}/pause-phone'),
        ),
        deskStore: ArchiveDeskStore(inMemory: true),
        clientConnector: (pairing, clientId) async {
          if (blockNext) {
            blockNext = false;
            if (!entered.isCompleted) entered.complete();
            await gate.future;
          }
          return ArchiveClient.connect(pairing, clientId: clientId);
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.pairWithCode(pairing.encode());
      blockNext = true;
      await controller.queueAllExisting();
      await entered.future;
      await controller.disconnect();
      gate.complete();
      await controller.waitForWorker();

      expect(deskStore.entries, isEmpty);
      expect(
        controller.recordForPath(first.path)?.phase,
        isNot(MacArchivePhase.verified),
      );
      expect(
        controller.recordForPath(second.path)?.phase,
        isNot(MacArchivePhase.verified),
      );
      expect(controller.connected, isFalse);

      await controller.connectNow();
      await controller.waitForWorker();
      expect(
        controller.recordForPath(first.path)?.phase,
        MacArchivePhase.verified,
      );
      expect(
        controller.recordForPath(second.path)?.phase,
        MacArchivePhase.verified,
      );
      expect(deskStore.entries, hasLength(2));
    },
  );
}
