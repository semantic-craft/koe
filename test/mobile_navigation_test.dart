import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
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

  testWidgets('Ask Koe says it is not open and routes to materials', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('ask-koe')));
    await tester.pumpAndSettle();
    expect(find.text('连续问答尚未开放。现在可以在「资料」里按标题搜索、打开原文并回听原件。'), findsOneWidget);
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
