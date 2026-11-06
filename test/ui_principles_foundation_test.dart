import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/widgets/widgets.dart';

void main() {
  test(
    'AppColors uses Chinese traditional bamboo green accent, warm paper grays, and flat inline cards',
    () {
      expect(AppColors.accent, const Color(0xFF2E5E4E));
      expect(KoeTokens.light.accent, const Color(0xFF2E5E4E));

      for (final c in [
        AppColors.surface0,
        AppColors.surface1,
        AppColors.bgPanel,
        AppColors.bgSubtle,
        AppColors.bgMuted,
        AppColors.border,
        AppColors.textPrimary,
        AppColors.textSecondary,
        AppColors.textMuted,
      ]) {
        final r = (c.r * 255).round();
        final g = (c.g * 255).round();
        final b = (c.b * 255).round();
        expect(r >= g && g >= b, isTrue, reason: 'Expected warm gray for $c');
      }

      expect(AppColors.cardShadow, isEmpty);
      expect(AppColors.floatingShadow, isNotEmpty);
      expect(AppRadii.concentric(12, 4), 8);
      expect(AppRadii.concentric(8, 6), 4);
    },
  );

  test('AppTheme textTheme uses at most 4 font sizes (12, 14, 16, 22)', () {
    final tt = AppTheme.light.textTheme;
    final sizes = {
      tt.displayLarge?.fontSize,
      tt.displayMedium?.fontSize,
      tt.displaySmall?.fontSize,
      tt.headlineLarge?.fontSize,
      tt.headlineMedium?.fontSize,
      tt.headlineSmall?.fontSize,
      tt.titleLarge?.fontSize,
      tt.titleMedium?.fontSize,
      tt.titleSmall?.fontSize,
      tt.bodyLarge?.fontSize,
      tt.bodyMedium?.fontSize,
      tt.bodySmall?.fontSize,
      tt.labelLarge?.fontSize,
      tt.labelMedium?.fontSize,
      tt.labelSmall?.fontSize,
    }.whereType<double>().toSet();
    expect(sizes.length, lessThanOrEqualTo(4));
    expect(sizes.difference(const {12, 14, 16, 22}), isEmpty);
  });

  testWidgets('SectionLabel preserves natural casing without uppercasing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: SectionLabel('Next steps')),
      ),
    );
    expect(find.text('Next steps'), findsOneWidget);
    expect(find.text('NEXT STEPS'), findsNothing);
  });

  testWidgets(
    'Disconnected HomeScreen shows unified 连接录音豆 button instead of radar scan prose',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('koe-ui-foundation-'),
      ))!;
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: Directory('${dir.path}/imports'),
      );
      addTearDown(() async {
        controller.dispose();
        await tester.runAsync(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
      });

      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(KoeApp(controller: controller));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );

      expect(find.text('点「扫描」查找安克录音豆'), findsNothing);
      expect(find.text('连接录音豆'), findsWidgets);
    },
  );
}
