import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:koe/platform/place_capture.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  late Directory temp;
  late Directory imports;
  late File libraryFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-place-');
    imports = Directory('${temp.path}/imports');
    libraryFile = File('${temp.path}/recording_library.json');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  RecorderController controller({
    PlaceCapture? capture,
    bool inMemoryLibrary = false,
  }) => RecorderController(
    loadPersistedState: false,
    libraryStore: RecordingLibraryStore(
      file: inMemoryLibrary ? null : libraryFile,
      inMemory: inMemoryLibrary,
    ),
    libraryDirectory: imports,
    // Phone-take recovery would still be listing imports at teardown.
    phoneRecordingEnabled: false,
    placeCapture: capture,
  );

  Future<File> audio(String name, {int seed = 1}) async {
    final file = File('${temp.path}/$name.wav');
    await file.writeAsBytes(wavBytes([seed, seed + 1, seed + 2, seed + 3]));
    return file;
  }

  test('手动地点保存后重启仍恢复并带手动标识', () async {
    final c = controller();
    final source = await audio('会议');
    final imported = await c.importLocalAudio(source.path);
    await c.setRecordingPlace(imported.path, '上海 徐汇');
    c.dispose();

    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();

    final place = restarted.recordingAssetForPath(imported.path)?.place;
    expect(place?.label, '上海 徐汇');
    expect(place?.source, RecordingPlaceSource.manual);
  });

  test('后续自动采集不会覆盖手动地点', () async {
    final auto = RecordingPlace(
      label: '杭州 西湖',
      source: RecordingPlaceSource.automatic,
      capturedAt: _capturedAt,
    );
    final capture = _FakePlaceCapture(auto);
    final c = controller(capture: capture);
    addTearDown(c.dispose);
    final source = await audio('手动优先');
    final imported = await c.importLocalAudio(source.path);
    await c.setRecordingPlace(imported.path, '上海 徐汇');

    await c.attachAutomaticPlace(imported.path);

    expect(c.recordingAssetForPath(imported.path)?.place?.label, '上海 徐汇');
    expect(capture.calls, 0);
  });

  test('自动采集失败或无结果时保留录音且地点留空', () async {
    final c = controller(capture: _FakePlaceCapture(null));
    addTearDown(c.dispose);
    final source = await audio('拒权');
    await c.library.upsert(
      RecordingAsset(
        path: source.path,
        displayName: '拒权',
        source: RecordingSource.phone,
        importedAt: DateTime(2026, 10, 1),
      ),
    );

    await c.attachAutomaticPlace(source.path);

    expect(c.recordingAssetForPath(source.path)?.place, isNull);
    expect(await source.exists(), isTrue);
    expect(c.recordingView(RecordingReference(path: source.path)).text, '');
  });

  test('导入文件与设备录音不会使用取回地点', () async {
    final capture = _FakePlaceCapture(
      RecordingPlace(
        label: '深圳 南山',
        source: RecordingPlaceSource.automatic,
        capturedAt: _capturedAt,
      ),
    );
    final c = controller(capture: capture);
    addTearDown(c.dispose);
    final source = await audio('导入', seed: 2);
    final imported = await c.importLocalAudio(source.path);
    final device = await audio('设备', seed: 3);
    await c.library.upsert(
      RecordingAsset(
        path: device.path,
        displayName: '设备',
        source: RecordingSource.device,
        importedAt: DateTime(2026, 10, 1),
      ),
    );

    await c.attachAutomaticPlace(imported.path);
    await c.attachAutomaticPlace(device.path);

    expect(c.recordingAssetForPath(imported.path)?.place, isNull);
    expect(c.recordingAssetForPath(device.path)?.place, isNull);
    expect(capture.calls, 0);
  });

  test('设备录音没有资料条目时仍可手动补地点', () async {
    final c = controller();
    addTearDown(c.dispose);
    final path = File('${temp.path}/1783917009.wav');
    await path.writeAsBytes(wavBytes([1, 2, 3, 4]));

    await c.setRecordingPlace(path.path, '南京 鼓楼');

    final asset = c.recordingAssetForPath(path.path);
    expect(asset?.source, RecordingSource.device);
    expect(asset?.place?.label, '南京 鼓楼');
    expect(asset?.place?.source, RecordingPlaceSource.manual);
  });

  // #232: 录音豆录音补地点、重启、删除恢复后，标题仍是录音时间，不变成文件名。
  test('设备录音补地点、重启、回收站恢复后标题仍是录音时间', () async {
    final file = File('${temp.path}/1792377669.wav');
    await file.writeAsBytes(wavBytes([1, 2, 3, 4]));
    String title(RecorderController c) => c
        .recordingView(RecordingReference(fileId: 1792377669, path: file.path))
        .title;

    final c = controller();
    final before = title(c);
    expect(before, matches(RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$')));
    await c.setRecordingPlace(file.path, '上海市徐汇区');
    expect(title(c), before);
    c.dispose();

    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForRecordingLibrary();
    expect(title(restarted), before);

    await restarted.trashLocalExports([file.path]);
    await restarted.restoreTrashed(file.path);
    expect(title(restarted), before);
  });

  test('旧版本存成文件名标题的设备录音恢复为录音时间', () async {
    final file = File('${temp.path}/1792377669.wav');
    await file.writeAsBytes(wavBytes([1, 2, 3, 4]));
    final expected = controller();
    final dateTitle = expected
        .recordingView(RecordingReference(fileId: 1792377669, path: file.path))
        .title;
    expected.dispose();
    await libraryFile.writeAsString(
      jsonEncode(
        RecordingLibraryStore.encode([
          RecordingAsset(
            path: file.path,
            displayName: '1792377669.wav',
            source: RecordingSource.device,
            recordedAt: DateTime.fromMillisecondsSinceEpoch(1792377669000),
            importedAt: DateTime(2026, 10, 19, 10, 52),
          ),
        ]),
      ),
    );

    final c = controller();
    addTearDown(c.dispose);
    await c.waitForRecordingLibrary();

    expect(
      c
          .recordingView(
            RecordingReference(fileId: 1792377669, path: file.path),
          )
          .title,
      dateTitle,
    );
  });

  test('粗粒度地点去掉街道级细节', () {
    final label = coarsePlaceLabel(
      const Placemark(
        administrativeArea: '上海市',
        locality: '上海市',
        subLocality: '徐汇区',
        street: '某路 1 号',
      ),
    );

    expect(label, '上海市 徐汇区');
    expect(label, isNot(contains('某路')));
  });

  testWidgets('信息页可添加、修改并清除地点', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = _PlaceUiController();
    addTearDown(c.dispose);
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          home: RecordingDetailScreen(
            reference: const RecordingReference(path: _PlaceUiController.path),
          ),
        ),
      ),
    );
    await settle();

    await tester.tap(find.byTooltip('更多操作'));
    await settle();
    await tester.tap(find.text('资料信息'));
    await settle();
    expect(find.text('未知'), findsWidgets);

    await tester.tap(find.text('填写地点'));
    await settle();
    await tester.enterText(
      find.byKey(const ValueKey('place-edit-input')),
      '上海 徐汇',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settle();
    expect(find.text('上海 徐汇，手动填写'), findsOneWidget);

    await tester.tap(find.text('修改地点'));
    await settle();
    await tester.enterText(
      find.byKey(const ValueKey('place-edit-input')),
      '上海 浦东',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settle();
    expect(find.text('上海 浦东，手动填写'), findsOneWidget);

    await tester.tap(find.text('清除地点'));
    await settle();
    expect(find.text('上海 浦东，手动填写'), findsNothing);
    expect(find.text('未知'), findsWidgets);
  });

  testWidgets('地点保存失败保留输入并提示未保存', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const path = '/tmp/place-fail.wav';
    const reference = RecordingReference(fileId: 1, path: path);
    final c = _FailingPlaceController();
    addTearDown(c.dispose);
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: const MaterialApp(
          home: RecordingDetailScreen(reference: reference),
        ),
      ),
    );
    await settle();

    await tester.tap(find.byTooltip('更多操作'));
    await settle();
    await tester.tap(find.text('资料信息'));
    await settle();
    await tester.tap(find.text('填写地点'));
    await settle();
    await tester.enterText(
      find.byKey(const ValueKey('place-edit-input')),
      '未保存的地点',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await settle();

    expect(find.byKey(const ValueKey('place-edit-error')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('place-edit-input')))
          .controller
          ?.text,
      '未保存的地点',
    );
  });
}

final _capturedAt = DateTime(2026, 10, 1, 9, 30);

class _FakePlaceCapture implements PlaceCapture {
  _FakePlaceCapture(this.result);

  final RecordingPlace? result;
  int calls = 0;

  @override
  Future<RecordingPlace?> capture() async {
    calls++;
    return result;
  }
}

class _PlaceUiController extends RecorderController {
  _PlaceUiController() : super(loadPersistedState: false);

  static const path = '/tmp/place-ui.wav';
  RecordingAsset _asset = RecordingAsset(
    path: path,
    displayName: '访谈',
    source: RecordingSource.localImport,
    importedAt: DateTime(2026, 10, 1),
  );

  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      RecordingViewData(
        reference: reference,
        title: '访谈',
        text: '',
        path: path,
        source: RecordingSource.localImport,
      );

  @override
  RecordingAsset? recordingAssetForPath(String path) =>
      path == _PlaceUiController.path ? _asset : null;

  @override
  Future<void> setRecordingPlace(String path, String label) async {
    _asset = _asset.copyWith(
      place: RecordingPlace(
        label: label.trim(),
        source: RecordingPlaceSource.manual,
        capturedAt: DateTime(2026, 10, 1),
      ),
    );
    notifyListeners();
  }

  @override
  Future<void> clearRecordingPlace(String path) async {
    _asset = _asset.copyWith(clearPlace: true);
    notifyListeners();
  }
}

class _FailingPlaceController extends RecorderController {
  _FailingPlaceController() : super(loadPersistedState: false);

  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      RecordingViewData(
        reference: reference,
        title: '保存失败',
        text: '',
        path: reference.path,
      );

  @override
  Future<void> setRecordingPlace(String path, String label) async {
    throw StateError('保存失败');
  }
}
