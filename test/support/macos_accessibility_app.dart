// ignore_for_file: avoid_print

// Native AXTree regression fixture. Never loads saved recordings or credentials.
// Run through scripts/check-macos-accessibility.py with VoiceOver already on.
// For manual inspection: flutter run -d macos -t
// test/support/macos_accessibility_app.dart --dart-define=AX_SMOKE_AUTORUN=false
import 'dart:async';
import 'dart:io';
import 'package:koe/ui/recording_navigation.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('AX_SMOKE_AUTORUN', defaultValue: true)) {
    unawaited(
      _exercise()
          .then((_) {
            print('AX_SMOKE_COMPLETED');
            exit(0);
          })
          .catchError((Object error, StackTrace stack) {
            print('AX_SMOKE_FAILED: $error');
            exit(1);
          }),
    );
  }
  runApp(
    ChangeNotifierProvider<RecorderController>(
      create: (_) => PreviewController(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const Banner(
          message: 'UI PREVIEW',
          location: BannerLocation.topEnd,
          child: AppShell(),
        ),
      ),
    ),
  );
}

class PreviewController extends RecorderController {
  PreviewController() : super(loadPersistedState: false) {
    exportedPaths = [
      '/tmp/ui-preview-100.wav',
      '/tmp/ui-preview-101.wav',
      '/tmp/ui-preview-102.wav',
    ];
  }
  @override
  Future<void> refreshFilesOnTabEnter() async {}
  @override
  Future<void> refreshInfoOnDeviceTabEnter() async {}
  @override
  Future<void> startScan() async {}
  @override
  RecordingViewData recordingView(
    RecordingReference reference,
  ) => RecordingViewData(
    reference: reference,
    path: reference.path,
    title: reference.path?.contains('101') == true
        ? '访谈记录'
        : reference.path?.contains('102') == true
        ? '本周计划'
        : '产品讨论',
    text:
        '这是一段用于检查界面的示例文字，没有读取真实录音。\n\n打开录音库，可以在左侧浏览记录，在右侧阅读文字。声音和文字留在同一个地方，便于回顾。\n\n阅读较长内容时，界面保留清楚的文字层级和适当的行间距。原文、译文与播放控制都在手边。\n\n接下来会继续用实际的录音、下载与转写流程验证体验。这次只确认界面呈现。',
  );
}

Element _find(bool Function(Widget) predicate) {
  Element? match;
  void visit(Element element) {
    if (match != null) return;
    if (predicate(element.widget)) {
      match = element;
      return;
    }
    element.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return match ?? (throw StateError('Missing fixture target'));
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 700));
}

Future<void> _exercise() async {
  await Future<void>.delayed(const Duration(seconds: 2));
  for (final id in [100, 101, 102, 100, 102]) {
    final navigation =
        _find((w) => w is RecordingNavigation).widget as RecordingNavigation;
    navigation.onOpen(RecordingReference(path: '/tmp/ui-preview-$id.wav'));
    await _settle();
    final detail =
        _find((w) => w is RecordingDetailScreen).widget
            as RecordingDetailScreen;
    if (detail.reference.path != '/tmp/ui-preview-$id.wav') {
      throw StateError('Detail did not change to $id');
    }
    print('AX_SMOKE_STEP: recording $id');
  }
  for (final tab in ['settings', 'device', 'home']) {
    final button =
        _find((w) => w.key == ValueKey('nav-$tab')).widget as TextButton;
    button.onPressed!();
    await _settle();
    print('AX_SMOKE_STEP: $tab');
  }
  // Pop and re-enter the same nested navigator as a compact window's Back does.
  final detail = _find((w) => w is RecordingDetailScreen);
  Navigator.of(detail).pop();
  await _settle();
  final navigation =
      _find((w) => w is RecordingNavigation).widget as RecordingNavigation;
  navigation.onOpen(const RecordingReference(path: '/tmp/ui-preview-101.wav'));
  await _settle();
  print('AX_SMOKE_STEP: pop and reopen');
}
