import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';

class _StoreGate {
  Completer<void>? gate;
  Completer<void>? entered;
  bool failNext = false;

  Future<void> call() async {
    final pending = gate;
    if (pending != null) {
      gate = null;
      if (!(entered?.isCompleted ?? true)) entered!.complete();
      await pending.future;
    }
    if (failNext) {
      failNext = false;
      throw const FileSystemException('synthetic phone store failure');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late File audio;
  late String hash;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-persist-');
    audio = File('${root.path}/1700000000.wav');
    await audio.writeAsBytes(
      Uint8List.fromList(List<int>.generate(128, (i) => i % 251)),
      flush: true,
    );
    hash = (await archiveFileHash(audio.path))!;
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<
    ({RecorderController controller, ArchivePhoneStore store, _StoreGate gate})
  >
  prepare() async {
    final gate = _StoreGate();
    final store = ArchivePhoneStore(
      directory: Directory('${root.path}/phone'),
      writeInterceptor: gate.call,
    );
    await store.load();
    await store.upsert(
      ArchivePhoneRecord(
        localPath: audio.path,
        displayName: 'rename persistence',
        originalExtension: '.wav',
        contentHash: hash,
        length: await audio.length(),
        sourceModifiedMs: 1,
        phase: MacArchivePhase.verified,
        verifiedAt: DateTime(2026, 10, 18),
        verifiedLength: await audio.length(),
        updatedAt: DateTime(2026, 10, 18),
      ),
    );
    final library = RecordingLibraryStore(
      file: File('${root.path}/recording_library.json'),
    );
    final controller = RecorderController(
      loadPersistedState: false,
      libraryStore: library,
      libraryDirectory: Directory('${root.path}/imports'),
      archivePhoneStore: store,
      archiveDeskStore: ArchiveDeskStore(inMemory: true),
    );
    addTearDown(controller.dispose);
    await controller.library.upsert(
      RecordingAsset(
        path: audio.path,
        displayName: 'rename persistence',
        source: RecordingSource.localImport,
        importedAt: DateTime(2026, 10, 18),
        contentHash: hash,
      ),
    );
    controller.exportedPaths = <String>[audio.path];
    await controller.archive.initialize();
    return (controller: controller, store: store, gate: gate);
  }

  test(
    'rename waits for archive persistence before reporting success',
    () async {
      final setup = await prepare();
      final gate = Completer<void>();
      setup.gate.gate = gate;
      setup.gate.entered = Completer<void>();
      final future = setup.controller.renameLocalExport(audio.path, 'renamed');
      try {
        await setup.gate.entered!.future;
        var completed = false;
        future.then<void>((_) => completed = true, onError: (Object _) {});
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
      final renamed = await future;
      expect(renamed, isNot(audio.path));
      expect(setup.controller.archive.recordForPath(audio.path), isNull);
      expect(setup.controller.archive.recordForPath(renamed), isNotNull);
    },
  );

  test(
    'rename metadata precommit failure leaves everything retryable',
    () async {
      final setup = await prepare();
      setup.gate.failNext = true;
      await expectLater(
        setup.controller.renameLocalExport(audio.path, 'renamed'),
        throwsA(isA<StateError>()),
      );
      expect(setup.controller.errorMessage, contains('预提交失败'));
      expect(await audio.exists(), isTrue);
      expect(setup.controller.library.assetForPath(audio.path), isNotNull);
      expect(setup.controller.exportedPaths, contains(audio.path));
      expect(setup.controller.archive.recordForPath(audio.path), isNotNull);

      final renamed = await setup.controller.renameLocalExport(
        audio.path,
        'renamed',
      );
      expect(await audio.exists(), isFalse);
      expect(setup.controller.library.assetForPath(renamed), isNotNull);
      expect(setup.controller.exportedPaths, contains(renamed));
      expect(setup.controller.archive.recordForPath(audio.path), isNull);
      expect(setup.controller.archive.recordForPath(renamed), isNotNull);

      final reopened = ArchivePhoneStore(
        directory: Directory('${root.path}/phone'),
      );
      await reopened.load();
      expect(reopened.recordForPath(audio.path), isNull);
      expect(reopened.recordForPath(renamed), isNotNull);
    },
  );

  test('delete waits for archive cleanup before reporting success', () async {
    final setup = await prepare();
    final gate = Completer<void>();
    setup.gate.gate = gate;
    setup.gate.entered = Completer<void>();
    final future = setup.controller.deleteLocalExports(<String>[audio.path]);
    try {
      await setup.gate.entered!.future;
      var completed = false;
      future.then<void>((_) => completed = true, onError: (Object _) {});
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
    final result = await future;
    expect(result.deleted, 1);
    expect(setup.controller.archive.recordForPath(audio.path), isNull);
  });

  test(
    'delete metadata failure leaves the original and retries cleanly',
    () async {
      final setup = await prepare();
      setup.gate.failNext = true;
      final failed = await setup.controller.deleteLocalExports(<String>[
        audio.path,
      ]);
      expect(failed.deleted, 0);
      expect(failed.failed, hasLength(1));
      expect(setup.controller.errorMessage, contains('无法删除'));
      expect(await audio.exists(), isTrue);
      expect(setup.controller.library.assetForPath(audio.path), isNotNull);
      expect(setup.controller.exportedPaths, contains(audio.path));
      expect(setup.controller.archive.recordForPath(audio.path), isNotNull);

      final retry = await setup.controller.deleteLocalExports(<String>[
        audio.path,
      ]);
      expect(retry.deleted, 1);
      expect(await audio.exists(), isFalse);
      expect(setup.controller.exportedPaths, isNot(contains(audio.path)));
      expect(setup.controller.archive.recordForPath(audio.path), isNull);

      final reopened = ArchivePhoneStore(
        directory: Directory('${root.path}/phone'),
      );
      await reopened.load();
      expect(reopened.recordForPath(audio.path), isNull);
    },
  );

  test(
    'a physical rename failure rolls back only its own archive precommit',
    () async {
      final setup = await prepare();
      final gate = Completer<void>();
      setup.gate.gate = gate;
      setup.gate.entered = Completer<void>();
      final targetPath = '${root.path}/1700000000_renamed.wav';
      final future = setup.controller.renameLocalExport(audio.path, 'renamed');
      try {
        await setup.gate.entered!.future;
        await Directory(targetPath).create();
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
      await expectLater(future, throwsA(isA<StateError>()));
      expect(await audio.exists(), isTrue);
      expect(setup.controller.library.assetForPath(audio.path), isNotNull);
      expect(setup.controller.exportedPaths, contains(audio.path));
      expect(setup.controller.archive.recordForPath(audio.path), isNotNull);
      expect(setup.controller.archive.recordForPath(targetPath), isNull);
      expect(setup.controller.errorMessage, contains('重命名失败'));

      await Directory(targetPath).delete();
      final renamed = await setup.controller.renameLocalExport(
        audio.path,
        'renamed',
      );
      expect(renamed, targetPath);
      expect(setup.controller.archive.recordForPath(targetPath), isNotNull);
    },
  );
}
