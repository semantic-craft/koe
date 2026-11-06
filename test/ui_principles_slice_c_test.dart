import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/library_screen.dart';
import 'package:koe/ui/screens/new_recording_sheet.dart';
import 'package:koe/ui/screens/projects_screen.dart';
import 'package:koe/ui/screens/today_screen.dart';
import 'package:koe/ui/widgets/connect_onboarding.dart';
import 'package:koe/ui/widgets/scan_sheet.dart';
import 'package:provider/provider.dart';

void main() {
  Future<(RecorderController, Directory)> createController(
    WidgetTester tester,
  ) async {
    final temp =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('koe_slice_c_'),
        ))!;
    final controller = RecorderController(
      loadPersistedState: false,
      libraryDirectory: temp,
      transcriptPersister: ({bool strict = false}) async {},
    );
    return (controller, temp);
  }

  void expectFourScaleAndNoMiddleDots(WidgetTester tester) {
    final texts = tester.widgetList<Text>(find.byType(Text));
    final distinctSizes = <double>{};
    final offScale = <double>{};
    final middleDotTexts = <String>[];
    for (final text in texts) {
      final value = text.data ?? text.textSpan?.toPlainText() ?? '';
      if (value.contains('·')) {
        middleDotTexts.add(value);
      }
      final size = text.style?.fontSize;
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
    expect(
      middleDotTexts,
      isEmpty,
      reason: 'Slice C visible text must not contain middle dot connectors',
    );
    expect(
      distinctSizes.length,
      lessThanOrEqualTo(4),
      reason: 'At most 4 distinct font sizes per screen (Principle 7)',
    );
    expect(
      offScale,
      isEmpty,
      reason: 'Explicit fontSize must stay within AppFontSizes (12/14/16/22)',
    );
  }

  testWidgets(
    'TodayScreen, LibraryScreen, and ProjectsScreen remove redundant subtitles, '
    'avoid middle dots, and stay on the 4-size typography scale',
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

      await tester.pumpWidget(KoeApp(controller: controller));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      expect(find.byType(TodayScreen), findsOneWidget);
      expectFourScaleAndNoMiddleDots(tester);

      await tester.tap(find.byKey(const ValueKey('nav-projects')));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectsScreen), findsOneWidget);
      expect(find.text('把跨天的讨论、目标和承诺放在一起。'), findsNothing);
      expectFourScaleAndNoMiddleDots(tester);

      await tester.tap(find.byKey(const ValueKey('nav-library')));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.text('原声留在手机，标题、时间和文字都能找回同一条资料。'), findsNothing);
      expectFourScaleAndNoMiddleDots(tester);
    },
  );

  testWidgets(
    'NewRecordingSheet, ScanDevicesSheet, and ConnectOnboarding use <= 4 font sizes '
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

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    ElevatedButton(
                      key: const ValueKey('open-new-sheet'),
                      onPressed: () => showNewRecordingSheet(context),
                      child: const Text('New'),
                    ),
                    Expanded(
                      child: ConnectOnboarding(onDone: () {}),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expectFourScaleAndNoMiddleDots(tester);

      await tester.tap(find.byKey(const ValueKey('open-new-sheet')));
      await tester.pumpAndSettle();
      expectFourScaleAndNoMiddleDots(tester);
      Navigator.of(tester.element(find.byType(Scaffold))).pop();
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: ScanDevicesSheet()),
          ),
        ),
      );
      await tester.pump();
      expectFourScaleAndNoMiddleDots(tester);
    },
  );

  testWidgets(
    'Slice C phone screens render across 320/390/430 x 1.0x/2.0x without overflow',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (controller, temp) = await createController(tester);
      addTearDown(() async {
        controller.dispose();
        await tester.runAsync(() => temp.delete(recursive: true));
      });

      for (final width in const [320.0, 390.0, 430.0]) {
        for (final scale in const [1.0, 2.0]) {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1.0;
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: Size(width, 844),
                textScaler: TextScaler.linear(scale),
              ),
              child: KoeApp(controller: controller),
            ),
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(tester.takeException(), isNull);
        }
      }
    },
  );
}
