import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/device_screen.dart';
import 'package:koe/ui/screens/files_screen.dart';
import 'package:koe/ui/screens/minutes_document_screen.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:provider/provider.dart';

void main() {
  Future<(RecorderController, Directory)> createController(
    WidgetTester tester,
  ) async {
    final temp =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('koe_slice_d_'),
        ))!;
    final controller = RecorderController(
      loadPersistedState: false,
      libraryDirectory: temp,
      transcriptPersister: ({bool strict = false}) async {},
    );
    return (controller, temp);
  }

  void expectSliceDPrinciples(WidgetTester tester, {required String surface}) {
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
    for (final button in tester.widgetList<FilledButton>(
      find.byType(FilledButton),
    )) {
      final bg = button.style?.backgroundColor?.resolve(const <WidgetState>{});
      expect(
        bg,
        isNot(equals(AppColors.coral)),
        reason: '$surface must not use full-red FilledButton (Principle 5)',
      );
    }
  }

  testWidgets(
    'FilesBody, RecordingDetailScreen, and MinutesPanel use <= 4 font sizes '
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

      final audioPath = (await tester.runAsync(() async {
        final file = File('${temp.path}/meeting.wav');
        await file.writeAsBytes([1, 2, 3, 4]);
        return file.path;
      }))!;
      controller.exportedPaths.add(audioPath);
      controller.rememberTranscript(
        audioPath,
        '说话人 1：这里谈到产品核心观点A。',
        segments: const [
          TranscriptSegment(
            text: '这里谈到产品核心观点A。',
            start: Duration(seconds: 12),
            end: Duration(seconds: 30),
            speaker: '1',
            speakerChanged: true,
          ),
        ],
      );
      final ref = RecordingReference(path: audioPath);
      final minutesKey = '${controller.analysisKey(ref)}/minutes';
      controller.analysis.results[minutesKey] = AnalysisResult(
        model: 'qwen-plus',
        instruction: 'minutes',
        sourceHash: 'hash-1',
        createdAt: DateTime(2026, 10, 18, 10, 0),
        sources: const ['说话人 1：这里谈到产品核心观点A。'],
        text: '## 会议摘要\n- 确认核心观点A [1]\n## 行动项\n- 跟进压测 | 负责人：张工 | 期限：周五 [1]',
      );
      controller.notifyListeners();

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: FilesBody(query: '核心观点A')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectSliceDPrinciples(tester, surface: 'FilesBody');

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: RecordingDetailScreen(reference: ref),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expectSliceDPrinciples(tester, surface: 'RecordingDetailScreen');

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: MinutesPanel(controller: controller, reference: ref),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expectSliceDPrinciples(tester, surface: 'MinutesPanel');
    },
  );

  testWidgets(
    'MinutesDocumentScreen, DeviceScreen, and SettingsScreen use <= 4 font sizes '
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

      final imported =
          (await tester.runAsync(
            () => controller.importMinutesText(
              '周会.txt',
              '[00:05] 张工：第一句讨论发布节奏。',
            ),
          ))!;

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: MinutesDocumentScreen(
              documentId: imported.document.id,
              focusLine: 0,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expectSliceDPrinciples(tester, surface: 'MinutesDocumentScreen');

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: DeviceScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expectSliceDPrinciples(tester, surface: 'DeviceScreen');

      await tester.pumpWidget(
        ChangeNotifierProvider<RecorderController>.value(
          value: controller,
          child: MaterialApp(
            theme: AppTheme.light,
            home: const Scaffold(body: SettingsScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expectSliceDPrinciples(tester, surface: 'SettingsScreen');
    },
  );

  testWidgets(
    'RecordingDetailScreen, DeviceScreen, and SettingsScreen fit 320x740 at 2.0x text scale without overflow',
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

      final audioPath = (await tester.runAsync(() async {
        final file = File(
          '${temp.path}/A long recording title that wraps onto two lines on narrow phones.wav',
        );
        await file.writeAsBytes([1, 2, 3, 4]);
        return file.path;
      }))!;
      controller.exportedPaths.add(audioPath);
      controller.rememberTranscript(audioPath, '第一段转写文本\n第二段转写文本');
      final ref = RecordingReference(path: audioPath);

      for (final screen in <Widget>[
        RecordingDetailScreen(reference: ref),
        const Scaffold(body: DeviceScreen()),
        const Scaffold(body: SettingsScreen()),
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
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      }
    },
  );
}
