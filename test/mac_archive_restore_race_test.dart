import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/archive/archive_service.dart';
import 'package:koe/state/recorder_controller.dart';

class _GatedLibraryStore extends RecordingLibraryStore {
  _GatedLibraryStore({required super.file});

  Completer<void>? gate;
  Completer<void>? activeGate;
  Completer<void>? entered;
  String? gatePath;
  String? gateHash;

  void arm(String path, String hash) {
    gatePath = path;
    gateHash = hash;
    gate = Completer<void>();
    activeGate = gate;
    entered = Completer<void>();
  }

  @override
  Future<void> upsert(RecordingAsset asset, {bool strict = true}) async {
    await super.upsert(asset, strict: strict);
    final pending = gate;
    if (pending != null &&
        asset.path == gatePath &&
        asset.contentHash == gateHash) {
      gate = null;
      final reached = entered;
      if (reached != null && !reached.isCompleted) reached.complete();
      await pending.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ArchiveDeskStore deskStore;
  late ArchiveDeskServer server;
  late ArchivePairing pairing;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-restore-race-');
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

  Future<void> waitFor(Future<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('condition was not met');
  }

  Future<
    ({
      RecorderController controller,
      _GatedLibraryStore library,
      File file,
      String hash,
    })
  >
  prepare() async {
    final file = File('${root.path}/1700000000.wav');
    await file.writeAsBytes(
      Uint8List.fromList(List<int>.generate(512, (i) => i % 251)),
      flush: true,
    );
    final hash = (await archiveFileHash(file.path))!;
    final library = _GatedLibraryStore(
      file: File('${root.path}/recording_library.json'),
    );
    final controller = RecorderController(
      loadPersistedState: false,
      libraryStore: library,
      libraryDirectory: Directory('${root.path}/imports'),
      archivePhoneStore: ArchivePhoneStore(
        directory: Directory('${root.path}/phone'),
      ),
      archiveDeskStore: ArchiveDeskStore(inMemory: true),
    );
    addTearDown(controller.dispose);
    await controller.library.upsert(
      RecordingAsset(
        path: file.path,
        displayName: 'restore race',
        source: RecordingSource.localImport,
        importedAt: DateTime(2026, 10, 18),
        contentHash: hash,
      ),
    );
    controller.exportedPaths = <String>[file.path];
    await controller.archive.initialize();
    await controller.archive.pairWithCode(pairing.encode());
    await controller.archive.archiveNow(file.path);
    await controller.archive.waitForWorker();
    expect(
      controller.archive.recordForPath(file.path)?.phase,
      MacArchivePhase.verified,
    );
    await file.delete();
    await controller.archive.onLocalLibraryChanged();
    await controller.archive.waitForWorker();
    return (controller: controller, library: library, file: file, hash: hash);
  }

  test(
    'real delete during archiveDidRestore leaves no resurrected asset',
    () async {
      final setup = await prepare();
      setup.library.arm(setup.file.path, setup.hash);
      final restore = setup.controller.archive.restoreFromArchive(
        setup.file.path,
      );
      await setup.library.entered!.future;

      await setup.controller.deleteLocalExports(<String>[setup.file.path]);
      final gate = setup.library.activeGate!;
      gate.complete();
      await expectLater(restore, throwsA(isA<ArchiveException>()));
      await waitFor(
        () async =>
            setup.controller.archive.recordForPath(setup.file.path) == null,
      );
      expect(setup.controller.library.assetForPath(setup.file.path), isNull);
      expect(setup.controller.exportedPaths, isNot(contains(setup.file.path)));
      final reopened = RecordingLibraryStore(
        file: File('${root.path}/recording_library.json'),
      );
      await reopened.load();
      expect(reopened.assetForPath(setup.file.path), isNull);
    },
  );

  test('real rename during archiveDidRestore wins the old path', () async {
    final setup = await prepare();
    setup.library.arm(setup.file.path, setup.hash);
    final restore = setup.controller.archive.restoreFromArchive(
      setup.file.path,
    );
    await setup.library.entered!.future;
    final renamed = await setup.controller.renameLocalExport(
      setup.file.path,
      'renamed',
    );
    setup.library.activeGate!.complete();
    await expectLater(restore, throwsA(isA<ArchiveException>()));
    await waitFor(
      () async => setup.controller.archive.recordForPath(renamed) != null,
    );
    expect(setup.controller.library.assetForPath(setup.file.path), isNull);
    expect(setup.controller.library.assetForPath(renamed), isNotNull);
    expect(setup.controller.exportedPaths, contains(renamed));
    expect(setup.controller.exportedPaths, isNot(contains(setup.file.path)));
    final reopened = RecordingLibraryStore(
      file: File('${root.path}/recording_library.json'),
    );
    await reopened.load();
    expect(reopened.assetForPath(setup.file.path), isNull);
    expect(reopened.assetForPath(renamed), isNotNull);
  });

  test(
    'a failed rename after restore library write preserves the original metadata',
    () async {
      final setup = await prepare();
      final before = setup.controller.library.assetForPath(setup.file.path);
      expect(before, isNotNull);
      setup.library.arm(setup.file.path, setup.hash);
      final restore = setup.controller.archive.restoreFromArchive(
        setup.file.path,
      );
      await setup.library.entered!.future;

      final target = File('${root.path}/1700000000_renamed.wav');
      await target.writeAsBytes(<int>[9, 9, 9], flush: true);
      await expectLater(
        setup.controller.renameLocalExport(setup.file.path, 'renamed'),
        throwsA(isA<StateError>()),
      );
      setup.library.activeGate!.complete();
      await expectLater(restore, throwsA(isA<ArchiveException>()));

      final after = setup.controller.library.assetForPath(setup.file.path);
      expect(after, isNotNull);
      expect(after!.toJson(), before!.toJson());
      expect(setup.controller.exportedPaths, contains(setup.file.path));
      final reopened = RecordingLibraryStore(
        file: File('${root.path}/recording_library.json'),
      );
      await reopened.load();
      expect(reopened.assetForPath(setup.file.path)?.toJson(), before.toJson());
    },
  );
}
