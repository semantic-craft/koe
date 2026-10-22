import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/projects_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/screens/today_screen.dart';
import 'package:provider/provider.dart';

/// Phone pages whose scrolled content ran under fixed chrome (#384): the
/// 2026-10-22 Pixel smoke run caught Today's 「下一步行动」 over the clock
/// and the settings back arrow over 「语音服务」; the library had the same
/// fault in #260.
void main() {
  // An iPhone with a Dynamic Island: the status bar covers the top 62pt.
  const statusBar = 62.0;

  Future<Finder> pumpScrolled(
    WidgetTester tester,
    RecorderController c,
    Widget screen,
  ) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: statusBar);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pump();
    final list = find.byType(ListView).first;
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    return list;
  }

  testWidgets('scrolled Today content stops below the status bar', (
    tester,
  ) async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    final list = await pumpScrolled(tester, c, const TodayScreen());

    expect(
      find.byKey(const ValueKey('new-recording')).hitTestable(),
      findsNothing,
      reason: 'the header scrolls away with the page',
    );
    expect(tester.getRect(list).top, greaterThanOrEqualTo(statusBar));
  });

  testWidgets('scrolled Projects content stops below the status bar', (
    tester,
  ) async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    for (var i = 1; i <= 6; i++) {
      await c.createProject('项目 $i', goal: '跨天推进的第 $i 件事');
    }
    final list = await pumpScrolled(tester, c, const ProjectsScreen());

    expect(
      find.byKey(const ValueKey('new-recording')).hitTestable(),
      findsNothing,
      reason: 'the header scrolls away with the page',
    );
    expect(tester.getRect(list).top, greaterThanOrEqualTo(statusBar));
  });

  testWidgets('scrolled settings stop below the back button instead of '
      'running behind it', (tester) async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    final list = await pumpScrolled(
      tester,
      c,
      const SettingsScreen(showBack: true),
    );

    expect(
      find.text('处理与偏好').hitTestable(),
      findsNothing,
      reason: 'the title scrolls away with the page',
    );
    final back = tester.getRect(find.byKey(const ValueKey('settings-back')));
    expect(back.top, greaterThanOrEqualTo(statusBar));
    expect(tester.getRect(list).top, greaterThanOrEqualTo(back.bottom));
  });
}
