import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/recording_navigation.dart';
import 'package:koe/ui/screens/library_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/screens/topics_screen.dart';

void main() {
  late Directory directory;
  late RecorderController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-mobile-nav-');
    controller = RecorderController(
      loadPersistedState: false,
      // iPhone is the first platform where topics are enabled; keep the
      // navigation test on the production path that reaches existing topics.
      topicsEnabled: true,
      libraryDirectory: Directory('${directory.path}/imports'),
    );
    addTearDown(() async {
      controller.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
  }

  Future<String> addAudio(String name) async {
    final file = File('${directory.path}/$name');
    await file.writeAsBytes([1, 2, 3, 4]);
    controller.exportedPaths.add(file.path);
    return file.path;
  }

  testWidgets('phone shell exposes Today Projects Materials and old library', (
    tester,
  ) async {
    final path = (await tester.runAsync(() => addAudio('100.wav')))!;
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );

    expect(find.byKey(const ValueKey('bottom-navigation-bar')), findsOneWidget);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('资料'), findsOneWidget);
    expect(find.text('还没有进行中的项目'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nav-projects')));
    await tester.pumpAndSettle();
    expect(find.text('书籍与主题'), findsOneWidget);
    expect(find.byKey(const ValueKey('projects-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('create-project')), findsOneWidget);
    expect(find.byKey(const ValueKey('projects-topics-entry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('projects-topics-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(TopicsScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('library-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-import')), findsOneWidget);
    expect(find.byKey(ValueKey('recording-row-$path')), findsOneWidget);
  });

  testWidgets('library title search and type filters use real metadata', (
    tester,
  ) async {
    final meeting = (await tester.runAsync(() => addAudio('项目会议.wav')))!;
    final walk = (await tester.runAsync(() => addAudio('散步.wav')))!;
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('recording-row-$meeting')), findsOneWidget);
    expect(find.byKey(ValueKey('recording-row-$walk')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('library-search')), '会议');
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('recording-row-$meeting')), findsOneWidget);
    expect(find.byKey(ValueKey('recording-row-$walk')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('library-filter-text')));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的资料'), findsOneWidget);
    expect(find.byKey(ValueKey('recording-row-$meeting')), findsNothing);
  });

  testWidgets('library searches transcript hits and opens their source', (
    tester,
  ) async {
    final timed = (await tester.runAsync(() => addAudio('访谈.wav')))!;
    final untimed = (await tester.runAsync(() => addAudio('散步.wav')))!;
    controller.rememberTranscript(
      timed,
      '开头第一句。这里谈到产品核心观点A。结尾。',
      segments: const [
        TranscriptSegment(
          text: '开头第一句。',
          start: Duration.zero,
          end: Duration(seconds: 8),
        ),
        TranscriptSegment(
          text: '这里谈到产品核心观点A。',
          start: Duration(seconds: 12),
          end: Duration(seconds: 30),
        ),
        TranscriptSegment(
          text: '结尾。',
          start: Duration(seconds: 35),
          end: Duration(seconds: 40),
        ),
      ],
    );
    controller.rememberTranscript(untimed, '这里也谈到产品核心观点A。');
    controller.notifyListeners();
    await tester.pumpWidget(KoeApp(controller: controller));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('library-search')),
      '核心观点A',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('recording-row-$timed')), findsOneWidget);
    expect(find.byKey(ValueKey('recording-row-$untimed')), findsOneWidget);
    expect(find.byKey(ValueKey('search-hit-$timed')), findsOneWidget);
    expect(find.byKey(ValueKey('search-hit-$untimed')), findsOneWidget);
    expect(find.text('正文命中 · 00:12 可回听'), findsOneWidget);
    expect(find.text('正文命中 · 无可用时码，打开可阅读原文'), findsOneWidget);

    await tester.ensureVisible(find.byKey(ValueKey('recording-row-$untimed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('recording-row-$untimed')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('highlighted-paragraph-0')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('highlighted-segment-0')), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey('recording-row-$timed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('recording-row-$timed')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('highlighted-segment-1')), findsOneWidget);
  });

  testWidgets('renamed speakers keep transcript replay and search hits', (
    tester,
  ) async {
    final path = (await tester.runAsync(() => addAudio('访谈.wav')))!;
    controller.rememberTranscript(
      path,
      '说话人 1：开头第一句。\n说话人 2：这里谈到产品核心观点A。\n说话人 1：结尾。',
      segments: const [
        TranscriptSegment(
          text: '开头第一句。',
          start: Duration.zero,
          end: Duration(seconds: 8),
          speaker: '1',
          speakerChanged: true,
        ),
        TranscriptSegment(
          text: '这里谈到产品核心观点A。',
          start: Duration(seconds: 12),
          end: Duration(seconds: 30),
          speaker: '2',
          speakerChanged: true,
        ),
        TranscriptSegment(
          text: '结尾。',
          start: Duration(seconds: 35),
          end: Duration(seconds: 40),
          speaker: '1',
          speakerChanged: true,
        ),
      ],
    );
    controller.speakerAliasesByPath[path] = {'2': '张三'};
    controller.notifyListeners();
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('library-search')),
      '核心观点',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('recording-row-$path')), findsOneWidget);
    expect(find.text('正文命中 · 00:12 可回听'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('recording-row-$path')));
    await tester.pumpAndSettle();
    expect(find.text('张三：这里谈到产品核心观点A。'), findsOneWidget);
    expect(find.byKey(const ValueKey('highlighted-segment-1')), findsOneWidget);
  });

  testWidgets('wide search target updates the visible recording source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final path = (await tester.runAsync(() => addAudio('访谈.wav')))!;
    controller.rememberTranscript(
      path,
      '开头第一句。这里谈到产品核心观点A。结尾。',
      segments: const [
        TranscriptSegment(
          text: '开头第一句。',
          start: Duration.zero,
          end: Duration(seconds: 8),
        ),
        TranscriptSegment(
          text: '这里谈到产品核心观点A。',
          start: Duration(seconds: 12),
          end: Duration(seconds: 30),
        ),
        TranscriptSegment(
          text: '结尾。',
          start: Duration(seconds: 35),
          end: Duration(seconds: 40),
        ),
      ],
    );
    await pump(tester);
    await tester.tap(find.byKey(ValueKey('recording-row-$path')));
    await tester.pumpAndSettle();

    final navigation = tester.widget<RecordingNavigation>(
      find.byType(RecordingNavigation),
    );
    navigation.onOpen(
      RecordingReference(fileId: controller.fileIdFromPath(path), path: path),
      initialParagraph: 1,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('highlighted-segment-1')), findsOneWidget);
  });

  testWidgets('new recording keeps phone recording honest and import real', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('new-recording')));
    await tester.pumpAndSettle();

    expect(find.text('导入本地音频'), findsOneWidget);
    expect(find.text('取回设备录音'), findsOneWidget);
    expect(find.text('手机录音'), findsOneWidget);
    expect(find.text('尚未开放'), findsOneWidget);
  });

  testWidgets('trash hides a material and restores it from the library', (
    tester,
  ) async {
    final path = (await tester.runAsync(() => addAudio('可删资料.wav')))!;
    controller.rememberTranscript(path, '人工校订正文');
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('recording-row-$path')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除资料…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移到回收站'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('recording-row-$path')), findsNothing);
    expect(await tester.runAsync(() => File(path).exists()), isTrue);

    await tester.tap(find.byKey(const ValueKey('library-trash')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('trash-row-$path')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('trash-restore-$path')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('trash-row-$path')), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('recording-row-$path')), findsOneWidget);
  });

  testWidgets('Ask Koe says it is not open and routes to materials', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('ask-koe')));
    await tester.pumpAndSettle();
    expect(find.text('连续问答尚未开放。现在可以在「资料」里按标题和正文搜索、打开原文并回听原件。'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ask-koe-open-library')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
  });

  testWidgets('settings exposes device and external AI without connecting', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('external-ai-entry')),
      300,
      scrollable: find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byKey(const ValueKey('external-ai-entry')));
    await tester.pumpAndSettle();
    expect(find.text('外部 AI 尚未开放'), findsOneWidget);
    expect(find.textContaining('不会发起连接'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    expect(find.text('今日'), findsOneWidget);
  });

  testWidgets('nav selection is announced to screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester);
    final node = tester.getSemantics(find.byKey(const ValueKey('nav-today')));
    expect(node.label, '今日');
    expect(node.flagsCollection.isSelected.toString(), contains('isTrue'));
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('nav-library')))
          .flagsCollection
          .isSelected
          .toString(),
      contains('isFalse'),
    );
    semantics.dispose();
  });

  for (final size in const [Size(320, 740), Size(390, 844), Size(430, 932)]) {
    for (final scale in const [1.0, 2.0]) {
      testWidgets('phone layout fits ${size.width} at text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pump(tester);
        expect(find.byKey(const ValueKey('new-recording')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('nav-library')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('library-search')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
