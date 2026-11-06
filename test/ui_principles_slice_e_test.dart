import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/ask_koe_screen.dart';
import 'package:koe/ui/screens/communication_screen.dart';
import 'package:koe/ui/screens/diary_screen.dart';
import 'package:koe/ui/screens/library_screen.dart';
import 'package:koe/ui/screens/listening_queue_screen.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/screens/text_capture_sheet.dart';
import 'package:koe/ui/screens/today_screen.dart';
import 'package:koe/ui/screens/todos_screen.dart';
import 'package:koe/ui/screens/topics_screen.dart';
import 'package:koe/ui/screens/trash_screen.dart';
import 'package:koe/ui/shell.dart';
import 'package:provider/provider.dart';

void main() {
  const previewDirectory = String.fromEnvironment('UI_PREVIEW_DIR');
  final previewBoundary = GlobalKey();

  setUpAll(() async {
    if (previewDirectory.isEmpty) return;
    const fontPath = '/System/Library/Fonts/STHeiti Light.ttc';
    if (File(fontPath).existsSync()) {
      for (final family in ['UiPreview', 'Roboto', 'Ahem']) {
        final loader = FontLoader(family);
        loader.addFont(
          File(
            fontPath,
          ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
        );
        await loader.load();
      }
    }
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Future<void> savePreview(WidgetTester tester, String name) async {
    if (previewDirectory.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          previewBoundary.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(previewDirectory).create(recursive: true);
      await File(
        '$previewDirectory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }
  Future<(RecorderController, Directory)> createController(
    WidgetTester tester, {
    bool topicsEnabled = true,
  }) async {
    final temp =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('koe_slice_e_'),
        ))!;
    final controller = RecorderController(
      loadPersistedState: false,
      libraryDirectory: temp,
      topicsEnabled: topicsEnabled,
      transcriptPersister: ({bool strict = false}) async {},
    );
    return (controller, temp);
  }

  void expectSliceEPrinciples(WidgetTester tester, {required String surface}) {
    final distinctSizes = <double>{};
    final offScale = <double>{};
    final middleDotTexts = <String>[];
    void recordText(String value, TextStyle? style) {
      if (value.contains('·')) {
        middleDotTexts.add(value);
      }
      final size = style?.fontSize;
      if (size != null) {
        distinctSizes.add(size);
        if (!const [
          AppFontSizes.xs,
          AppFontSizes.sm,
          AppFontSizes.md,
          AppFontSizes.lg,
        ].contains(size)) {
          offScale.add(size);
        }
      }
    }

    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      recordText(
        text.data ?? text.textSpan?.toPlainText() ?? '',
        text.style,
      );
    }
    for (final selectable in tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    )) {
      recordText(
        selectable.data ?? selectable.textSpan?.toPlainText() ?? '',
        selectable.style,
      );
    }
    expect(
      middleDotTexts,
      isEmpty,
      reason: '$surface must not contain middle dot connectors',
    );
    expect(
      distinctSizes.length,
      lessThanOrEqualTo(4),
      reason: '$surface must use <= 4 distinct font sizes (Principle 7)',
    );
    expect(
      offScale,
      isEmpty,
      reason: '$surface explicit fontSize must stay within AppFontSizes (12/14/16/22)',
    );
  }

  testWidgets(
    'TopicsEntry, TopicsScreen, TrashScreen, and TextCapturePanel use <= 4 font sizes '
    'and zero middle dots',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (controller, temp) = await createController(tester);
      addTearDown(() async {
        controller.dispose();
        await tester.runAsync(() => temp.delete(recursive: true));
      });

      await tester.runAsync(() async {
        await controller.topics.createTopic(
          kind: TopicKind.book,
          title: '正义论',
          author: '罗尔斯',
        );
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: TopicsEntry()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expectSliceEPrinciples(tester, surface: 'TopicsEntry');

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const TopicsScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expectSliceEPrinciples(tester, surface: 'TopicsScreen');

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const TrashScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expectSliceEPrinciples(tester, surface: 'TrashScreen');

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(
              body: TextCapturePanel(startsCapture: false),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expectSliceEPrinciples(tester, surface: 'TextCapturePanel');
    },
  );

  testWidgets(
    'TodosScreen, DiaryScreen, ListeningQueueScreen, AskKoeScreen, and CommunicationScreen '
    'use <= 4 font sizes and zero middle dots across 320x740 at 2.0x text scale',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (controller, temp) = await createController(tester);
      addTearDown(() async {
        controller.dispose();
        await tester.runAsync(() => temp.delete(recursive: true));
      });

      for (final (name, screen) in <(String, Widget)>[
        ('TodosScreen', const TodosScreen()),
        ('DiaryScreen', DiaryScreen(initial: DiaryPeriod.day(DateTime(2026, 10, 18)))),
        ('ListeningQueueScreen', const ListeningQueueScreen()),
        ('AskKoeScreen', const AskKoeScreen()),
        ('CommunicationScreen', const CommunicationScreen()),
      ]) {
        await tester.pumpWidget(
          ChangeNotifierProvider<RecorderController>.value(
            value: controller,
            child: MaterialApp(
              theme: AppTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(2.0),
                ),
                child: child!,
              ),
              home: screen,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: '$name overflow check');
        expectSliceEPrinciples(tester, surface: name);
      }
    },
  );

  testWidgets(
    'Multi-viewport macOS and iOS surfaces render with bamboo-green theme and zero overflow',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (controller, temp) = await createController(tester);
      addTearDown(() async {
        controller.dispose();
        await tester.runAsync(() => temp.delete(recursive: true));
      });

      final audioPath = (await tester.runAsync(() async {
        final file = File('${temp.path}/1760850000_产品评审与发布计划.wav');
        await file.writeAsBytes([1, 2, 3, 4]);
        return file.path;
      }))!;
      controller.exportedPaths.add(audioPath);
      controller.rememberTranscript(
        audioPath,
        '说话人 1：今天确认竹青主色、四级字号和同心圆角规范。\n说话人 2：周五前完成 macOS 与 iOS 双端验收。',
        segments: const [
          TranscriptSegment(
            text: '今天确认竹青主色、四级字号和同心圆角规范。',
            start: Duration(seconds: 4),
            end: Duration(seconds: 18),
            speaker: '1',
            speakerChanged: true,
          ),
          TranscriptSegment(
            text: '周五前完成 macOS 与 iOS 双端验收。',
            start: Duration(seconds: 19),
            end: Duration(seconds: 32),
            speaker: '2',
            speakerChanged: true,
          ),
        ],
      );
      final ref = RecordingReference(fileId: 1760850000, path: audioPath);

      final theme = previewDirectory.isEmpty
          ? AppTheme.light
          : AppTheme.light.copyWith(
              textTheme: AppTheme.light.textTheme.apply(
                fontFamily: 'UiPreview',
              ),
              primaryTextTheme: AppTheme.light.primaryTextTheme.apply(
                fontFamily: 'UiPreview',
              ),
            );

      for (final (name, size, scale, child) in <(String, Size, double, Widget)>[
        ('shell-mac-1280x900', const Size(1280, 900), 1.0, const AppShell()),
        ('today-ios-390x844', const Size(390, 844), 1.0, const Scaffold(body: TodayScreen())),
        ('library-ios-390x844', const Size(390, 844), 1.0, const Scaffold(body: LibraryScreen())),
        ('detail-ios-390x844', const Size(390, 844), 1.0, RecordingDetailScreen(reference: ref)),
        ('detail-ios-320x740-2x', const Size(320, 740), 2.0, RecordingDetailScreen(reference: ref)),
        ('settings-ios-390x844', const Size(390, 844), 1.0, const Scaffold(body: SettingsScreen())),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpWidget(
          RepaintBoundary(
            key: previewBoundary,
            child: ChangeNotifierProvider<RecorderController>.value(
              value: controller,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                builder: (context, widgetChild) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: widgetChild!,
                ),
                home: child,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull, reason: '$name overflow check');
        expectSliceEPrinciples(tester, surface: name);
        await savePreview(tester, name);
      }
    },
  );
}
