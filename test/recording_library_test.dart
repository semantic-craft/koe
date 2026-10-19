import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/ui/screens/files_screen.dart';
import 'package:koe/ui/screens/trash_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  late Directory temp;
  late Directory imports;
  late File storeFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-library-');
    imports = Directory('${temp.path}/imports');
    storeFile = File('${temp.path}/recording_library.json');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  RecorderController controller() => RecorderController(
    loadPersistedState: false,
    libraryStore: RecordingLibraryStore(file: storeFile),
    libraryDirectory: imports,
  );

  Future<File> sourceAudio(String name, {int seed = 1}) async {
    final file = File('${temp.path}/$name.wav');
    await file.writeAsBytes(wavBytes([seed, seed + 1, seed + 2, seed + 3]));
    return file;
  }

  test('导入原件后重启仍能恢复同一资料和播放路径', () async {
    final source = await sourceAudio('会议记录');
    final first = controller();
    final imported = await first.importLocalAudio(
      source.path,
      recordedAt: DateTime(2026, 10, 1, 9, 30),
    );

    expect(imported.duplicate, isFalse);
    expect(await File(imported.path).exists(), isTrue);
    expect(first.exportedPaths, contains(imported.path));
    final view = first.recordingView(RecordingReference(path: imported.path));
    expect(view.title, '会议记录');
    expect(view.source, RecordingSource.localImport);
    expect(view.recordedAt, DateTime(2026, 10, 1, 9, 30));
    expect(view.importedAt, isNotNull);
    expect(view.originalPresent, isTrue);
    expect(await storeFile.exists(), isTrue);

    first.dispose();
    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();

    expect(restarted.exportedPaths, contains(imported.path));
    final restored = restarted.recordingView(
      RecordingReference(path: imported.path),
    );
    expect(restored.title, '会议记录');
    expect(restored.recordedAt, DateTime(2026, 10, 1, 9, 30));
    expect(restored.originalPresent, isTrue);
    expect(
      restarted.recordingAssetForPath(imported.path)?.contentHash,
      imported.asset.contentHash,
    );
  });

  test('同一内容重复导入复用已有资料且不新增原件', () async {
    final source = await sourceAudio('voice');
    final c = controller();
    addTearDown(c.dispose);

    final first = await c.importLocalAudio(source.path);
    final second = await c.importLocalAudio(source.path);

    expect(second.duplicate, isTrue);
    expect(second.path, first.path);
    expect(c.exportedPaths.where((path) => path.contains('_voice.wav')), [
      first.path,
    ]);
    expect(
      imports.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.wav'),
      ),
      hasLength(1),
    );
  });

  test('资料库写入失败时删除新复制文件且不报告保存完成', () async {
    final blocked = File('${temp.path}/blocked');
    await blocked.writeAsString('not a directory');
    final brokenStore = RecordingLibraryStore(
      file: File('${blocked.path}/recording_library.json'),
    );
    final c = RecorderController(
      loadPersistedState: false,
      libraryStore: brokenStore,
      libraryDirectory: imports,
    );
    addTearDown(c.dispose);
    final source = await sourceAudio('will-fail');

    await expectLater(c.importLocalAudio(source.path), throwsA(anything));

    expect(c.statusMessage, contains('保存失败'));
    expect(c.errorMessage, contains('保存失败'));
    expect(
      await imports.exists()
          ? imports.listSync().whereType<File>().toList()
          : <File>[],
      isEmpty,
    );
  });

  test('较早写入失败不会回滚更新的资料信息', () async {
    final store = _FailOnceLibraryStore(file: storeFile);
    final old = RecordingAsset(
      path: '/tmp/place-race.wav',
      displayName: '旧标题',
      source: RecordingSource.localImport,
      importedAt: DateTime(2026, 10, 18, 9),
    );
    final newer = old.copyWith(displayName: '新标题');

    final first = store.upsert(old);
    final second = store.upsert(newer);
    await expectLater(first, throwsA(isA<StateError>()));
    await second;

    expect(store.assetForPath(old.path)?.displayName, '新标题');
    final reloaded = RecordingLibraryStore(file: storeFile);
    await reloaded.load();
    expect(reloaded.assetForPath(old.path)?.displayName, '新标题');
  });

  test('连续写入失败回到最后一次成功保存的值', () async {
    final store = _FailNextLibraryStore(file: storeFile);
    final seed = RecordingAsset(
      path: '/tmp/place-chain.wav',
      displayName: '已保存标题',
      source: RecordingSource.localImport,
      importedAt: DateTime(2026, 10, 18, 9),
    );
    await store.upsert(seed);

    store.failures = 2;
    final first = store.upsert(seed.copyWith(displayName: '未保存一'));
    final second = store.upsert(seed.copyWith(displayName: '未保存二'));
    await expectLater(first, throwsA(isA<StateError>()));
    await expectLater(second, throwsA(isA<StateError>()));

    expect(store.assetForPath(seed.path)?.displayName, '已保存标题');
    final reloaded = RecordingLibraryStore(file: storeFile);
    await reloaded.load();
    expect(reloaded.assetForPath(seed.path)?.displayName, '已保存标题');
  });

  test('失败写入不会被另一路径的后续保存带盘', () async {
    final store = _FailNextLibraryStore(file: storeFile);
    final firstAsset = RecordingAsset(
      path: '/tmp/place-a.wav',
      displayName: 'A 已保存',
      source: RecordingSource.localImport,
      importedAt: DateTime(2026, 10, 18, 9),
    );
    final secondAsset = RecordingAsset(
      path: '/tmp/place-b.wav',
      displayName: 'B 已保存',
      source: RecordingSource.localImport,
      importedAt: DateTime(2026, 10, 18, 9),
    );
    await store.upsert(firstAsset);
    await store.upsert(secondAsset);

    store.failures = 1;
    final failed = store.upsert(firstAsset.copyWith(displayName: 'A 未保存'));
    final succeeding = store.upsert(secondAsset.copyWith(displayName: 'B 新标题'));
    await expectLater(failed, throwsA(isA<StateError>()));
    await succeeding;

    expect(store.assetForPath(firstAsset.path)?.displayName, 'A 已保存');
    final reloaded = RecordingLibraryStore(file: storeFile);
    await reloaded.load();
    expect(reloaded.assetForPath(firstAsset.path)?.displayName, 'A 已保存');
    expect(reloaded.assetForPath(secondAsset.path)?.displayName, 'B 新标题');
  });

  test('删除不会被排队中的旧写入复活', () async {
    final store = _BlockingLibraryStore(file: storeFile);
    final asset = RecordingAsset(
      path: '/tmp/place-remove.wav',
      displayName: '已保存标题',
      source: RecordingSource.localImport,
      importedAt: DateTime(2026, 10, 18, 9),
    );
    await store.upsert(asset);

    final gate = Completer<void>();
    store.gate = gate;
    final pending = store.upsert(asset.copyWith(displayName: '排队标题'));
    final removal = store.remove(asset.path);
    gate.complete();
    await pending;
    await removal;

    expect(store.assetForPath(asset.path), isNull);
    final reloaded = RecordingLibraryStore(file: storeFile);
    await reloaded.load();
    expect(reloaded.assetForPath(asset.path), isNull);
  });

  test('改名不会被排队中的旧写入重新建出旧路径', () async {
    final store = _BlockingLibraryStore(file: storeFile);
    final asset = RecordingAsset(
      path: '/tmp/place-rename.wav',
      displayName: '旧标题',
      source: RecordingSource.localImport,
      importedAt: DateTime(2026, 10, 18, 9),
    );
    await store.upsert(asset);
    const renamedPath = '/tmp/place-renamed.wav';

    final gate = Completer<void>();
    store.gate = gate;
    final pending = store.upsert(asset.copyWith(displayName: '排队标题'));
    final renamed = store.rename(
      asset.path,
      asset.copyWith(path: renamedPath, displayName: '新标题'),
    );
    gate.complete();
    await pending;
    await renamed;

    expect(store.assetForPath(asset.path), isNull);
    expect(store.assetForPath(renamedPath)?.displayName, '新标题');
    final reloaded = RecordingLibraryStore(file: storeFile);
    await reloaded.load();
    expect(reloaded.assetForPath(asset.path), isNull);
    expect(reloaded.assetForPath(renamedPath)?.displayName, '新标题');
  });

  test('移到回收站保留原件与转写，重启后可恢复', () async {
    final source = await sourceAudio('可恢复资料');
    final first = controller();
    final imported = await first.importLocalAudio(source.path);
    first.rememberTranscript(imported.path, '人工校订后的正文');
    addTearDown(first.dispose);

    final trashed = await first.trashLocalExports([imported.path]);

    expect(trashed.trashed, 1);
    expect(first.exportedPaths, isNot(contains(imported.path)));
    expect(await File(imported.path).exists(), isTrue);
    expect(first.transcriptForPath(imported.path), '人工校订后的正文');
    expect(first.trashedAssets.single.path, imported.path);
    expect(
      first.recordingView(RecordingReference(path: imported.path)).archived,
      isTrue,
    );

    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();

    expect(restarted.exportedPaths, isNot(contains(imported.path)));
    expect(restarted.trashedAssets.single.path, imported.path);

    await restarted.restoreTrashed(imported.path);

    expect(restarted.exportedPaths, contains(imported.path));
    expect(restarted.trashedAssets, isEmpty);
    expect(await File(imported.path).exists(), isTrue);
  });

  test('没有资料条目的导入原件也能移到回收站，重启后仍在回收站', () async {
    final source = await sourceAudio('缺条目原件', seed: 61);
    final first = controller();
    final imported = await first.importLocalAudio(source.path);
    // 导入原件文件名以微秒时间戳开头；资料条目丢失时要按路径新建条目。
    await first.library.remove(imported.path);
    expect(first.recordingAssetForPath(imported.path), isNull);
    addTearDown(first.dispose);

    final trashed = await first.trashLocalExports([imported.path]);

    expect(trashed.failed, isEmpty);
    expect(trashed.trashed, 1);
    expect(first.trashedAssets.single.path, imported.path);
    expect(first.trashedAssets.single.recordedAt, isNull);

    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();

    expect(restarted.trashedAssets.single.path, imported.path);
    expect(restarted.exportedPaths, isNot(contains(imported.path)));
  });

  test('回收站标记保存失败时回滚内存状态', () async {
    final blocker = File('${temp.path}/blocked');
    await blocker.writeAsString('not a directory');
    final store = RecordingLibraryStore(
      file: File('${blocker.path}/library.json'),
    );
    final asset = RecordingAsset(
      path: '/tmp/rollback.wav',
      displayName: '回滚测试',
      source: RecordingSource.device,
      importedAt: DateTime(2026, 10, 18),
    );

    await expectLater(
      store.upsert(asset.copyWith(archived: true, deletedAt: DateTime.now())),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.assets, isEmpty);
  });

  test('超过 30 天的回收站资料在启动时清理，其他原件保留', () async {
    final expireSource = await sourceAudio('过期资料', seed: 11);
    final keepSource = await sourceAudio('保留资料', seed: 21);
    final first = controller();
    final expiring = await first.importLocalAudio(expireSource.path);
    final keeping = await first.importLocalAudio(keepSource.path);
    final old = DateTime.now().subtract(const Duration(days: 31));
    await first.trashLocalExports([expiring.path], now: old);
    first.dispose();

    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();
    await restarted.purgeExpiredTrash();

    expect(await File(expiring.path).exists(), isFalse);
    expect(restarted.recordingAssetForPath(expiring.path), isNull);
    expect(await File(keeping.path).exists(), isTrue);
    expect(restarted.exportedPaths, contains(keeping.path));
  });

  test('回收站最后一天仍显示可恢复，满 30 天才失效', () async {
    final source = await sourceAudio('最后一天资料');
    final c = controller();
    addTearDown(c.dispose);
    final imported = await c.importLocalAudio(source.path);
    final now = DateTime(2026, 10, 18, 12);
    await c.trashLocalExports([
      imported.path,
    ], now: now.subtract(const Duration(days: 29, hours: 1)));
    final asset = c.trashedAssets.single;

    expect(c.trashDaysRemaining(asset, now: now), 1);
    expect(
      c.trashDaysRemaining(asset, now: now.add(const Duration(hours: 23))),
      0,
    );
  });

  test('启动清理过期资料时等转写加载完成，彻底删除不会复活', () async {
    final source = await sourceAudio('过期转写资料');
    final store = RecordingLibraryStore(inMemory: true);
    await store.load();
    await store.upsert(
      RecordingAsset(
        path: source.path,
        displayName: '过期转写资料',
        source: RecordingSource.localImport,
        importedAt: DateTime.now().subtract(const Duration(days: 40)),
        archived: true,
        deletedAt: DateTime.now().subtract(const Duration(days: 31)),
      ),
    );

    await TranscriptStore.save(
      byPath: {source.path: '需要彻底删除的转写内容。'},
      byFileId: const {},
      aliasesByPath: const {},
      aliasesByFileId: const {},
    );
    addTearDown(
      () => TranscriptStore.save(
        byPath: const {},
        byFileId: const {},
        aliasesByPath: const {},
        aliasesByFileId: const {},
      ),
    );

    final restarted = RecorderController(
      loadPersistedState: true,
      libraryStore: store,
      libraryDirectory: imports,
    );
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();
    await restarted.purgeExpiredTrash();
    await restarted.waitForTranscripts();

    expect(await File(source.path).exists(), isFalse);
    expect(restarted.transcriptForPath(source.path), isNull);
    final saved = await TranscriptStore.load();
    expect(saved.byPath.containsKey(source.path), isFalse);
  });

  test('再次导入回收站中的同一音频会恢复原资料而不复制', () async {
    final source = await sourceAudio('重复导入资料', seed: 41);
    final c = controller();
    addTearDown(c.dispose);
    final first = await c.importLocalAudio(source.path);
    await c.trashLocalExports([first.path]);

    final second = await c.importLocalAudio(source.path);

    expect(second.duplicate, isTrue);
    expect(second.path, first.path);
    expect(c.trashedAssets, isEmpty);
    expect(c.exportedPaths, contains(first.path));
    expect(
      imports.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.wav'),
      ),
      hasLength(1),
    );
  });

  test('回收站资料不会被后续传输重新登记到资料库', () async {
    final source = await sourceAudio('传输后移入回收站');
    final c = controller();
    addTearDown(c.dispose);
    final imported = await c.importLocalAudio(source.path);
    await c.trashLocalExports([imported.path]);

    await c.completeWifiTransfer([imported.path], decrypted: false);

    expect(c.exportedPaths, isNot(contains(imported.path)));
    expect(c.trashedAssets.single.path, imported.path);
  });

  test('回收站里的设备录音算作已传输，不再自动补传', () async {
    const id = '1783917005';
    final renamed = File('${temp.path}/${id}_旧名字.wav');
    await renamed.writeAsBytes([1, 2, 3, 4]);
    final c = controller();
    addTearDown(c.dispose);
    await c.library.upsert(
      RecordingAsset(
        path: renamed.path,
        displayName: '旧名字',
        source: RecordingSource.device,
        importedAt: DateTime(2026, 10, 1),
        archived: true,
        deletedAt: DateTime(2026, 10, 1),
      ),
    );

    expect(
      c.copyStatusOf(OfflineFileEntry(fileId: int.parse(id), sizeBytes: 4)),
      DeviceCopyStatus.dismissed,
    );
  });

  test('彻底删除设备录音后重启仍保留墓碑，不会自动补传', () async {
    const id = '1783917006';
    final audio = File('${temp.path}/$id.wav');
    await audio.writeAsBytes(wavBytes([1, 2, 3, 4]));
    final first = controller();
    await first.library.upsert(
      RecordingAsset(
        path: audio.path,
        displayName: '设备原件',
        source: RecordingSource.device,
        importedAt: DateTime(2026, 10, 1),
      ),
    );
    await first.trashLocalExports([audio.path]);

    final removed = await first.emptyTrash(paths: [audio.path]);

    expect(removed.deleted, 1);
    expect(await audio.exists(), isFalse);
    expect(first.trashedAssets, isEmpty);
    first.dispose();

    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();
    expect(restarted.trashedAssets, isEmpty);
    expect(
      restarted.copyStatusOf(
        OfflineFileEntry(fileId: int.parse(id), sizeBytes: 4),
      ),
      DeviceCopyStatus.dismissed,
    );
  });

  test('清理缓存只删除派生播放文件，不删除原件', () async {
    const id = '1783917000';
    final original = File('${temp.path}/$id.opus.bin');
    final wav = File('${temp.path}/$id.wav');
    final ogg = File('${temp.path}/$id.ogg');
    await original.writeAsBytes([1, 2, 3, 4]);
    await wav.writeAsBytes([5, 6, 7, 8]);
    await ogg.writeAsBytes([9, 10, 11, 12]);
    final c = controller();
    addTearDown(c.dispose);
    c.exportedPaths.add(original.path);
    await c.library.upsert(
      RecordingAsset(
        path: original.path,
        displayName: '设备录音',
        source: RecordingSource.device,
        importedAt: DateTime(2026, 10, 1),
      ),
    );

    final result = await c.clearRecoverableCache(original.path);

    expect(result.removed, 2);
    expect(await original.exists(), isTrue);
    expect(await wav.exists(), isFalse);
    expect(await ogg.exists(), isFalse);
    expect(c.exportedPaths, contains(original.path));
  });

  test('设备传输的 WAV 清理缓存时保留同名字节原始流', () async {
    const id = '1783917002';
    final wav = File('${temp.path}/$id.wav');
    final raw = File('${temp.path}/$id.opus');
    final ogg = File('${temp.path}/$id.ogg');
    await wav.writeAsBytes([1, 2, 3, 4]);
    await raw.writeAsBytes([5, 6, 7, 8]);
    await ogg.writeAsBytes([9, 10, 11, 12]);
    final c = controller();
    addTearDown(c.dispose);
    c.exportedPaths.add(wav.path);
    await c.library.upsert(
      RecordingAsset(
        path: wav.path,
        displayName: '设备传输',
        source: RecordingSource.device,
        importedAt: DateTime(2026, 10, 1),
      ),
    );

    expect(c.hasRecoverableCacheForPath(wav.path), isTrue);
    final result = await c.clearRecoverableCache(wav.path);

    expect(result.removed, 1);
    expect(await wav.exists(), isTrue);
    expect(await raw.exists(), isTrue);
    expect(await ogg.exists(), isFalse);
  });

  test('彻底删除改名录音时一并删除源文件派生的 Ogg sidecar', () async {
    final raw = File('${temp.path}/1783917003_会议.opus');
    final sidecar = File('${temp.path}/1783917003_会议.ogg');
    await raw.writeAsBytes([1, 2, 3, 4]);
    await sidecar.writeAsBytes([5, 6, 7, 8]);
    final c = controller();
    addTearDown(c.dispose);
    c.exportedPaths.add(raw.path);
    await c.library.upsert(
      RecordingAsset(
        path: raw.path,
        displayName: '会议',
        source: RecordingSource.device,
        importedAt: DateTime(2026, 10, 1),
      ),
    );

    final result = await c.deleteLocalExports([raw.path]);

    expect(result.deleted, 1);
    expect(await raw.exists(), isFalse);
    expect(await sidecar.exists(), isFalse);
    expect(c.exportedPaths, isNot(contains(raw.path)));
  });

  test('导入未提供发生时间时不会把微秒文件名当成日期', () async {
    final source = await sourceAudio('无日期资料', seed: 31);
    final c = controller();
    addTearDown(c.dispose);

    final imported = await c.importLocalAudio(source.path);
    final view = c.recordingView(RecordingReference(path: imported.path));

    expect(view.recordedAt, isNull);
    expect(view.title, '无日期资料');
  });

  testWidgets('资料行显示发生时间、来源与原件状态，信息页区分两个时间', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late RecorderController c;
    late ({String path, bool duplicate, RecordingAsset asset}) imported;
    await tester.runAsync(() async {
      c = controller();
      final source = await sourceAudio('访谈');
      imported = await c.importLocalAudio(
        source.path,
        recordedAt: DateTime(2026, 10, 1, 9, 30),
      );
    });
    addTearDown(c.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: c,
        child: const MaterialApp(home: Scaffold(body: FilesBody())),
      ),
    );
    await tester.pump();

    final facts = tester.widget<Text>(
      find.byKey(ValueKey('recording-facts-${imported.path}')),
    );
    expect(facts.data, contains('发生 2026-10-01 09:30'));
    expect(facts.data, contains('本地导入'));
    expect(facts.data, contains('原件已保存'));

    await tester.tap(find.byKey(ValueKey('recording-row-${imported.path}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('资料信息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('录音发生时间'), findsOneWidget);
    expect(find.text('2026-10-01 09:30'), findsOneWidget);
    expect(find.text('导入资料库'), findsOneWidget);
    expect(find.text('本地导入'), findsWidgets);
    expect(find.text('已保留'), findsOneWidget);
    expect(find.text('资料库'), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(2));
  });

  testWidgets('回收站在窄屏 200% 字号下不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    late RecorderController c;
    late String path;
    await tester.runAsync(() async {
      final source = await sourceAudio('窄屏回收站', seed: 51);
      c = controller();
      final imported = await c.importLocalAudio(source.path);
      path = imported.path;
      await c.trashLocalExports([path]);
    });
    addTearDown(c.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: c,
        child: const MaterialApp(home: TrashScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('trash-row-$path')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _FailOnceLibraryStore extends RecordingLibraryStore {
  _FailOnceLibraryStore({super.file});

  int _saves = 0;

  @override
  Future<void> save({bool strict = true}) {
    _saves++;
    if (_saves == 1) {
      return Future<void>.error(StateError('first save failed'));
    }
    return super.save(strict: strict);
  }
}

class _FailNextLibraryStore extends RecordingLibraryStore {
  _FailNextLibraryStore({super.file});

  int failures = 0;

  @override
  Future<void> save({bool strict = true}) {
    if (failures > 0) {
      failures--;
      return Future<void>.error(StateError('save failed'));
    }
    return super.save(strict: strict);
  }
}

class _BlockingLibraryStore extends RecordingLibraryStore {
  _BlockingLibraryStore({super.file});

  Completer<void>? gate;

  @override
  Future<void> save({bool strict = true}) async {
    final current = gate;
    if (current != null) {
      gate = null;
      await current.future;
    }
    return super.save(strict: strict);
  }
}
