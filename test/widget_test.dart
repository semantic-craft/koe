import 'package:anker_recorder/main.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/theme/app_theme.dart';
import 'package:anker_recorder/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('app boots to home shell', (tester) async {
    await tester.pumpWidget(const SoundcoreManagerApp());
    // Primary tab is Home with recording history while idle.
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    final nav = tester.widget<Container>(
      find.byKey(const ValueKey('bottom-navigation-bar')),
    );
    final decoration = nav.decoration! as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect(decoration.borderRadius, isNull);

    final activeIndicator = find.byKey(const ValueKey('active-tab-indicator'));
    expect(activeIndicator, findsOneWidget);
    expect(
      tester.getCenter(activeIndicator).dy,
      greaterThan(tester.getCenter(find.text('首页')).dy),
    );
  });

  test('light and dark themes register distinct KoeTokens extensions', () {
    final lightTokens = AppTheme.light.extension<KoeTokens>();
    final darkTokens = AppTheme.dark.extension<KoeTokens>();
    expect(lightTokens, isNotNull);
    expect(darkTokens, isNotNull);
    expect(lightTokens!.bg, isNot(equals(darkTokens!.bg)));
    expect(lightTokens.textPrimary, isNot(equals(darkTokens.textPrimary)));
  });

  testWidgets('settings renders data-driven selectable cards for all SttProvider values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const SettingsScreen(),
        ),
      ),
    );

    for (final provider in SttProvider.values) {
      expect(
        find.byKey(ValueKey('speech-provider-option-${provider.name}')),
        findsOneWidget,
      );
      expect(find.text(provider.label), findsOneWidget);
    }

    await tester.tap(
      find.byKey(ValueKey('speech-provider-option-${SttProvider.moss.name}')),
    );
    await tester.pump();
    expect(controller.speechProvider, SttProvider.moss);
  });
}
