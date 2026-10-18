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
  Future<void> archiveDidRestore(
    ArchivePhoneRecord record,
    String path, {
    required int length,
    required String contentHash,
  }) async {
    paths.add(path);
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

  ArchivePhoneStore newStore() =>
      ArchivePhoneStore(directory: Directory('${root.path}/phone'));

  Future<({RecorderController recorder, MacArchiveController archive})>
  pumpArchive(
    WidgetTester tester,
    ArchivePhoneStore store, {
    List<String> exportedPaths = const <String>[],
  }) async {
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
    addTearDown(recorder.dispose);
    addTearDown(archive.dispose);
    return (recorder: recorder, archive: archive);
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
    final store = newStore();
    await store.load();
    await store.setConfiguration(
      pairing: ArchivePairing(
        deskId: 'a' * 32,
        key: ArchivePairing.generateKey(),
        hosts: const <String>['127.0.0.1'],
        port: 47831,
      ),
      autoArchive: true,
      autoArchiveFrom: DateTime(2026, 10, 18),
    );
    final pair = await pumpArchive(tester, store);
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
      final store = newStore();
      await store.load();
      await store.upsert(
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
      );
      final pair = await pumpArchive(tester, store);
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
      await file.writeAsBytes(bytes, flush: true);
      final hash = archiveHashBytes(bytes);
      final store = newStore();
      await store.load();
      await store.upsert(
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
      );
      final pair = await pumpArchive(
        tester,
        store,
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
      await tester.runAsync(() => file.writeAsBytes(<int>[1, 2, 3, 4]));
      final recorder = RecorderController(loadPersistedState: false);
      addTearDown(recorder.dispose);
      await tester.runAsync(
        () => recorder.library.upsert(
          RecordingAsset(
            path: file.path,
            displayName: '不完整原件',
            source: RecordingSource.localImport,
            importedAt: DateTime(2026, 10, 18),
            originalComplete: false,
          ),
        ),
      );
      recorder.exportedPaths = <String>[file.path];
      expect(
        await tester.runAsync(
          () => recorder.archive.source.archiveCandidates(),
        ),
        isEmpty,
      );

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
}
