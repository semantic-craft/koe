import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_bookmarks.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/shell.dart';
import 'package:koe/ui/widgets/material_export_sheet.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

/// Stands in for the macOS open and save panels.
class _Panels extends FileSelectorPlatform {
  String? openPath;
  String? savePath;
  List<XTypeGroup>? openGroups;
  String? suggestedName;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    openGroups = acceptedTypeGroups;
    return openPath == null ? null : XFile(openPath!);
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    suggestedName = options.suggestedName;
    return savePath == null ? null : FileSaveLocation(savePath!);
  }
}

RecorderController _controller(Directory root) => RecorderController(
  loadPersistedState: false,
  libraryStore: RecordingLibraryStore(
    file: File('${root.path}/recording_library.json'),
  ),
  libraryDirectory: Directory('${root.path}/imports'),
  topicStore: TopicStore(inMemory: true),
  topicsEnabled: false,
  transcriptPersister: ({bool strict = false}) async {},
  minutesStore: MinutesDocumentStore(file: File('${root.path}/minutes.json')),
  bookmarkStore: RecordingBookmarkStore(
    file: File('${root.path}/bookmarks.json'),
  ),
)..materialPackWorkDirectory = Directory('${root.path}/work');

void main() {
  late Directory temp;
  late _Panels panels;
  late FileSelectorPlatform originalPanels;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-mac-pack-');
    originalPanels = FileSelectorPlatform.instance;
    panels = _Panels();
    FileSelectorPlatform.instance = panels;
  });
  tearDown(() async {
    FileSelectorPlatform.instance = originalPanels;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<RecorderController> library(String name) async {
    final root = await Directory('${temp.path}/$name').create(recursive: true);
    final c = _controller(root);
    await c.waitForRecordingLibrary();
    await c.waitForTranscripts();
    await c.waitForBookmarks();
    await c.waitForMinutesDocuments();
    return c;
  }

  Future<String> material(RecorderController c) async {
    final audio = File('${temp.path}/周会.wav')
      ..writeAsBytesSync(wavBytes(List<int>.generate(4000, (i) => i % 251)));
    final path = (await c.importLocalAudio(audio.path)).path;
    c.rememberTranscript(path, '我们先过一下预算。');
    return path;
  }

  RecordingReference ref(RecorderController c, String path) =>
      RecordingReference(fileId: c.fileIdFromPath(path), path: path);

  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 300 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('Mac 录音库栏能导入资料包，导入后打开恢复的资料', (tester) async {
    final (a, b, pack) = (await tester.runAsync(() async {
      final a = await library('a');
      final b = await library('b');
      final path = await material(a);
      final file = await a.exportMaterialPack(ref(a, path), includeAudio: true);
      return (a, b, file.path);
    }))!;
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    panels.openPath = pack;

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: b,
        child: MaterialApp(
          theme: AppTheme.light.copyWith(platform: TargetPlatform.macOS),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('desktop-navigation')), findsOneWidget);

    await tester.tap(find.text('导入资料包'));
    await pumpUntil(tester, find.byType(RecordingDetailScreen));

    expect(panels.openGroups?.single.extensions, ['koepack']);
    expect(b.exportedPaths, hasLength(1));
    expect(find.byType(RecordingDetailScreen), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Mac 导出资料包可存到用户选的位置，另一台设备能导入', (tester) async {
    final (a, path) = (await tester.runAsync(() async {
      final a = await library('a');
      return (a, await material(a));
    }))!;
    addTearDown(a.dispose);
    final target = '${temp.path}/存到这里.koepack';
    panels.savePath = target;

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: a,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showMaterialExportSheet(context, ref(a, path)),
                  child: const Text('导出…'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('存储为文件…'));
    await pumpUntil(tester, find.text('已导出资料包（不含原音频）'));

    expect(panels.suggestedName, endsWith('.koepack'));
    expect(File(target).existsSync(), isTrue);
    final restored = (await tester.runAsync(() async {
      final b = await library('b');
      addTearDown(b.dispose);
      return b.importMaterialPack(target);
    }))!;
    expect(restored.minutesId ?? restored.path, isNotNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
