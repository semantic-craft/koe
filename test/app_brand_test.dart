import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1240, 820)]) {
    testWidgets('settings opens Koe identity at ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      PackageInfo.setMockInitialValues(
        appName: 'legacy platform name',
        packageName: 'legacy.install.identity',
        version: '9.8.7',
        buildNumber: '42',
        buildSignature: '',
      );
      final controller = RecorderController(loadPersistedState: false);
      addTearDown(controller.dispose);
      await tester.pumpWidget(KoeApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      final about = find.text('关于 Koe');
      await tester.scrollUntilVisible(
        about,
        300,
        scrollable: find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(about);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('9.8.7 (42)'), findsOneWidget);
      expect(find.text('适配设备：安克录音豆（soundcore Work / D3200）'), findsOneWidget);
      expect(find.text('连接安克录音豆，管理录音、转写文字、整理纪要。'), findsOneWidget);
      expect(find.text('legacy platform name'), findsNothing);
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Koe');
      if (size.width > 1100) {
        expect(find.text('适配安克录音豆'), findsWidgets);
      }
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('关于 Koe'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
