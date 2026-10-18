import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/files_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:provider/provider.dart';

class _UiSource implements ArchiveSource {
  final Set<String> paths = <String>{};

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
    return ArchiveCandidate(
      path: path,
      displayName: file.uri.pathSegments.last,
      extension: '.wav',
      length: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

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
    if (!isCurrent()) return false;
    paths.add(path);
    return true;
  }
}

class _ControlledArchiveController extends MacArchiveController {
  _ControlledArchiveController({
    required super.source,
    required super.isDesk,
    super.phoneStore,
    super.deskStore,
  });

  Completer<void>? restoreGate;

  @override
  Future<String> restoreFromArchive(String path) async {
    final gate = restoreGate;
    if (gate != null) await gate.future;
    throw const ArchiveRemoteException('恢复失败：合成故障');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('koe-archive-ui-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<({RecorderController recorder, MacArchiveController archive})>
  pumpArchive(
    WidgetTester tester, {
    Future<void> Function(ArchivePhoneStore store)? seed,
    List<String> exportedPaths = const <String>[],
  }) async {
    final pair = await tester.runAsync(() async {
      final store = ArchivePhoneStore(inMemory: true);
      await store.load();
      if (seed != null) await seed(store);
      final archive = MacArchiveController(
        source: _UiSource(),
        isDesk: false,
        phoneStore: store,
        deskStore: ArchiveDeskStore(inMemory: true),
      );
      await archive.initialize();
      final recorder = RecorderController(
        loadPersistedState: false,
        archiveController: archive,
      )..exportedPaths = [...exportedPaths];
      return (recorder: recorder, archive: archive);
    });
    if (pair == null) fail('archive fixture did not start');
    addTearDown(pair.recorder.dispose);
    addTearDown(pair.archive.dispose);
    return pair;
  }

  Future<void> pumpSettings(
    WidgetTester tester,
    RecorderController controller,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mac-archive-section')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  Future<void> openInfo(WidgetTester tester, String path) async {
    await tester.tap(find.byKey(ValueKey('recording-row-$path')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('资料信息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('settings expose pairing, auto switch, connect and disconnect', (
    tester,
  ) async {
    final pair = await pumpArchive(
      tester,
      seed: (store) => store.setConfiguration(
        pairing: ArchivePairing(
          deskId: 'a' * 32,
          key: ArchivePairing.generateKey(),
          hosts: const <String>['127.0.0.1'],
          port: 47831,
        ),
        autoArchive: true,
        autoArchiveFrom: DateTime(2026, 10, 18),
      ),
    );
    await pumpSettings(tester, pair.recorder);

    expect(find.byKey(const ValueKey('mac-archive-section')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-archive-auto')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-archive-connect')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('phone-archive-disconnect')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('phone-archive-queue-existing')),
      findsOneWidget,
    );
    expect(find.text('等待 Mac'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'a verified archive with no phone copy shows restore, not playback',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final missing = '${root.path}/missing.wav';
      final hash = archiveHashBytes(<int>[1, 2, 3, 4]);
      final pair = await pumpArchive(
        tester,
        seed: (store) => store.upsert(
          ArchivePhoneRecord(
            localPath: missing,
            displayName: '已归档的旧资料',
            originalExtension: '.wav',
            contentHash: hash,
            length: 4,
            sourceModifiedMs: 1,
            phase: MacArchivePhase.verified,
            verifiedAt: DateTime(2026, 10, 18, 10, 30),
            verifiedLength: 4,
            updatedAt: DateTime(2026, 10, 18, 10, 30),
          ),
        ),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: pair.recorder,
          child: const MaterialApp(home: Scaffold(body: FilesBody())),
        ),
      );
      await tester.pump();

      expect(find.byKey(ValueKey('recording-row-$missing')), findsOneWidget);
      expect(
        find.byKey(ValueKey('recording-mac-archive-$missing')),
        findsOneWidget,
      );
      expect(find.textContaining('已校验归档'), findsWidgets);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      await openInfo(tester, missing);
      expect(find.byKey(const ValueKey('restore-from-mac')), findsOneWidget);
      expect(find.textContaining('原件已彻底缺失'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a failed archive shows retry and keeps the phone original usable',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final file = File('${root.path}/failed.wav');
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      await tester.runAsync(() => file.writeAsBytes(bytes, flush: true));
      final hash = archiveHashBytes(bytes);
      final pair = await pumpArchive(
        tester,
        seed: (store) => store.upsert(
          ArchivePhoneRecord(
            localPath: file.path,
            displayName: '失败可重试',
            originalExtension: '.wav',
            contentHash: hash,
            length: bytes.length,
            sourceModifiedMs: 1,
            phase: MacArchivePhase.failed,
            error: 'Mac 未确认归档',
            updatedAt: DateTime(2026, 10, 18),
          ),
        ),
        exportedPaths: <String>[file.path],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: pair.recorder,
          child: const MaterialApp(home: Scaffold(body: FilesBody())),
        ),
      );
      await tester.pump();

      expect(find.textContaining('失败可重试'), findsWidgets);
      await openInfo(tester, file.path);
      expect(find.byKey(const ValueKey('retry-mac-archive')), findsOneWidget);
      expect(find.byKey(const ValueKey('restore-from-mac')), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an incomplete original is visible but never becomes a complete Mac candidate',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final file = File('${root.path}/incomplete.wav');
      final fixture = await tester.runAsync(() async {
        await file.writeAsBytes(<int>[1, 2, 3, 4]);
        final recorder = RecorderController(loadPersistedState: false);
        await recorder.library.upsert(
          RecordingAsset(
            path: file.path,
            displayName: '不完整原件',
            source: RecordingSource.localImport,
            importedAt: DateTime(2026, 10, 18),
            originalComplete: false,
          ),
        );
        recorder.exportedPaths = <String>[file.path];
        final candidates = await recorder.archive.source.archiveCandidates();
        return (recorder: recorder, candidates: candidates);
      });
      if (fixture == null) fail('incomplete fixture did not start');
      final recorder = fixture.recorder;
      addTearDown(recorder.dispose);
      expect(fixture.candidates, isEmpty);

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: recorder,
          child: const MaterialApp(home: Scaffold(body: FilesBody())),
        ),
      );
      await tester.pump();
      final facts = tester.widget<Text>(
        find.byKey(ValueKey('recording-facts-${file.path}')),
      );
      expect(facts.data, contains('原件不完整'));
      expect(find.textContaining('Mac：'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('restore keeps busy disabled and retains a retryable error', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final missing = '${root.path}/busy-missing.wav';
    final hash = archiveHashBytes(<int>[1, 2, 3, 4]);
    final pair = await tester.runAsync(() async {
      final store = ArchivePhoneStore(inMemory: true);
      await store.load();
      await store.upsert(
        ArchivePhoneRecord(
          localPath: missing,
          displayName: '恢复测试',
          originalExtension: '.wav',
          contentHash: hash,
          length: 4,
          sourceModifiedMs: 1,
          phase: MacArchivePhase.verified,
          verifiedAt: DateTime(2026, 10, 18),
          verifiedLength: 4,
          updatedAt: DateTime(2026, 10, 18),
        ),
      );
      final archive = _ControlledArchiveController(
        source: _UiSource(),
        isDesk: false,
        phoneStore: store,
        deskStore: ArchiveDeskStore(inMemory: true),
      );
      await archive.initialize();
      final recorder = RecorderController(
        loadPersistedState: false,
        archiveController: archive,
      );
      return (recorder: recorder, archive: archive);
    });
    if (pair == null) fail('controlled fixture did not start');
    addTearDown(pair.recorder.dispose);
    addTearDown(pair.archive.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: pair.recorder,
        child: const MaterialApp(home: Scaffold(body: FilesBody())),
      ),
    );
    await tester.pump();
    await openInfo(tester, missing);

    final gate = Completer<void>();
    pair.archive.restoreGate = gate;
    await tester.tap(find.byKey(const ValueKey('restore-from-mac')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('restore-from-mac')))
          .onPressed,
      isNull,
    );

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('mac-archive-action-error')),
      findsOneWidget,
    );
    expect(find.textContaining('恢复失败'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('restore-from-mac')))
          .onPressed,
      isNotNull,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('an open info sheet refreshes when the archive phase changes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final file = File('${root.path}/refresh.wav');
    await tester.runAsync(() => file.writeAsBytes(<int>[1, 2, 3, 4]));
    final hash = archiveHashBytes(<int>[1, 2, 3, 4]);
    late ArchivePhoneStore storeRef;
    final pair = await pumpArchive(
      tester,
      seed: (store) async {
        storeRef = store;
        await store.upsert(
          ArchivePhoneRecord(
            localPath: file.path,
            displayName: '刷新测试',
            originalExtension: '.wav',
            contentHash: hash,
            length: 4,
            sourceModifiedMs: 1,
            phase: MacArchivePhase.failed,
            error: 'Mac 未确认归档',
            updatedAt: DateTime(2026, 10, 18),
          ),
        );
      },
      exportedPaths: <String>[file.path],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: pair.recorder,
        child: const MaterialApp(home: Scaffold(body: FilesBody())),
      ),
    );
    await tester.pump();
    await openInfo(tester, file.path);
    expect(find.text('Mac 副本'), findsNothing);

    await tester.runAsync(() async {
      await storeRef.upsert(
        storeRef
            .recordForPath(file.path)!
            .copyWith(
              phase: MacArchivePhase.verified,
              verifiedAt: DateTime(2026, 10, 18, 11),
              verifiedLength: 4,
              error: null,
              clearError: true,
            ),
      );
      await pair.archive.disconnect();
    });
    await tester.pump();
    expect(find.text('Mac 副本'), findsOneWidget);
    expect(find.textContaining('已校验'), findsWidgets);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'a missing original with another Mac receipt stays visible and explains recovery',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const currentDesk = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const oldDesk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final missing = '${root.path}/other-mac.wav';
      final pair = await pumpArchive(
        tester,
        seed: (store) async {
          await store.setConfiguration(
            pairing: ArchivePairing(
              deskId: currentDesk,
              key: ArchivePairing.generateKey(),
              hosts: const <String>['127.0.0.1'],
              port: 47831,
            ),
            autoArchive: false,
            autoArchiveFrom: DateTime(2026, 10, 18),
          );
          await store.upsert(
            ArchivePhoneRecord(
              localPath: missing,
              displayName: '另一台 Mac 的资料',
              originalExtension: '.wav',
              deskId: currentDesk,
              phase: MacArchivePhase.failed,
              length: 0,
              sourceModifiedMs: 1,
              error: '当前 Mac 没有副本',
              receipts: <String, ArchiveDeskReceipt>{
                oldDesk: ArchiveDeskReceipt(
                  contentHash: archiveHashBytes(<int>[7, 8, 9]),
                  length: 3,
                  extension: '.wav',
                  verifiedAt: DateTime(2026, 10, 17),
                  sourceLength: 3,
                  sourceModifiedMs: 1,
                ),
              },
              updatedAt: DateTime(2026, 10, 18),
            ),
          );
        },
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: pair.recorder,
          child: const MaterialApp(home: Scaffold(body: FilesBody())),
        ),
      );
      await tester.pump();

      expect(find.byKey(ValueKey('recording-row-$missing')), findsOneWidget);
      expect(find.textContaining('原件在另一台 Mac'), findsWidgets);

      await openInfo(tester, missing);
      expect(find.text('Mac 副本'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('other-mac-archive-notice')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('open-archive-settings')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('restore-from-mac')), findsNothing);
      expect(find.textContaining('原件已彻底缺失'), findsNothing);

      await tester.ensureVisible(
        find.byKey(const ValueKey('open-archive-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('open-archive-settings')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SettingsScreen), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a never-verified other desk without receipts is not a recoverable copy',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const oldDesk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final missing = '${root.path}/never-verified.wav';
      final pair = await pumpArchive(
        tester,
        seed: (store) => store.upsert(
          ArchivePhoneRecord(
            localPath: missing,
            displayName: '从未成功的资料',
            originalExtension: '.wav',
            deskId: oldDesk,
            phase: MacArchivePhase.failed,
            length: 4,
            sourceModifiedMs: 1,
            error: '从未归档成功',
            updatedAt: DateTime(2026, 10, 18),
          ),
        ),
        exportedPaths: <String>[missing],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: pair.recorder,
          child: const MaterialApp(home: Scaffold(body: FilesBody())),
        ),
      );
      await tester.pump();
      await openInfo(tester, missing);

      expect(find.textContaining('原件已彻底缺失'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('other-mac-archive-notice')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('open-archive-settings')), findsNothing);
      expect(find.byKey(const ValueKey('restore-from-mac')), findsNothing);
      expect(find.text('Mac 副本'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('unpair storage failure is visible and keeps the pairing', (
    tester,
  ) async {
    var failNext = false;
    final pair = await tester.runAsync(() async {
      final store = ArchivePhoneStore(
        directory: Directory('${root.path}/unpair-phone'),
        writeInterceptor: () async {
          if (!failNext) return;
          failNext = false;
          throw const FileSystemException('synthetic unpair write failure');
        },
      );
      await store.load();
      await store.setConfiguration(
        pairing: ArchivePairing(
          deskId: 'c' * 32,
          key: ArchivePairing.generateKey(),
          hosts: const <String>['127.0.0.1'],
          port: 47831,
        ),
        autoArchive: false,
        autoArchiveFrom: DateTime(2026, 10, 18),
      );
      final archive = MacArchiveController(
        source: _UiSource(),
        isDesk: false,
        phoneStore: store,
        deskStore: ArchiveDeskStore(inMemory: true),
      );
      await archive.initialize();
      final recorder = RecorderController(
        loadPersistedState: false,
        archiveController: archive,
      );
      return (recorder: recorder, archive: archive);
    });
    if (pair == null) fail('unpair fixture did not start');
    addTearDown(pair.recorder.dispose);
    addTearDown(pair.archive.dispose);
    await pumpSettings(tester, pair.recorder);
    failNext = true;
    final action =
        tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('phone-archive-unpair')),
                )
                .onPressed
            as Future<void> Function();
    await tester.runAsync(action);
    await tester.pump();
    expect(find.textContaining('保存取消配对失败'), findsOneWidget);
    expect(pair.archive.pairing, isNotNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
