import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/files_screen.dart';
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
