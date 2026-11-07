import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/files_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:provider/provider.dart';

/// Black-box UI entry regression for Koe #148.
///
/// Deliberately imports only classes that already existed before the archive
/// implementation, so this file can be copied onto the baseline commit and
/// fails there for the real user-visible reason: there is no Mac archive entry
/// and no Mac status on a recording row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-archive-entry-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  RecorderController newController() {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pumpSettings(
    WidgetTester tester,
    RecorderController controller,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
  }

  Future<void> scrollToArchive(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('mac-archive-section')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('iOS settings expose the direct Mac archive entry', (
    tester,
  ) async {
    final controller = newController();
    await pumpSettings(tester, controller);
    await scrollToArchive(tester);

    expect(find.byKey(const ValueKey('mac-archive-section')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-archive-pair')), findsOneWidget);
    expect(find.text('配对 Mac'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a local recording row shows a separate Mac archive status', (
    tester,
  ) async {
    final controller = newController();
    final audio = File('${directory.path}/100.wav');
    await tester.runAsync(() => audio.writeAsBytes(<int>[1, 2, 3, 4]));
    controller.exportedPaths = <String>[audio.path];

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: const MaterialApp(home: Scaffold(body: FilesBody())),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(ValueKey('recording-mac-archive-${audio.path}')),
      findsOneWidget,
    );
    expect(find.textContaining('Mac：未配对'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('macOS settings expose the receiving switch', (tester) async {
    final controller = newController();
    await pumpSettings(tester, controller);
    await scrollToArchive(tester);

    expect(find.byKey(const ValueKey('mac-archive-section')), findsOneWidget);
    expect(find.byKey(const ValueKey('mac-receive-switch')), findsOneWidget);
    expect(find.text('这台 Mac 接收原件'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('macOS local recording row does not show phone-only Mac pairing status', (
    tester,
  ) async {
    final controller = newController();
    final audio = File('${directory.path}/100.wav');
    await tester.runAsync(() => audio.writeAsBytes(<int>[1, 2, 3, 4]));
    controller.exportedPaths = <String>[audio.path];

    tester.view.physicalSize = const Size(1240, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: const MaterialApp(home: Scaffold(body: FilesBody())),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(ValueKey('recording-mac-archive-${audio.path}')),
      findsNothing,
    );
    expect(find.textContaining('Mac：未配对'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
