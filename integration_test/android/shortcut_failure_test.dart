// Android scenario: 开始录音 on the Koe icon that cannot start says why on
// screen. On a fresh install all-day listening is off and no recorder is
// bound, so the shortcut has nothing to start, and the real app shows the
// reason at the bottom of the screen. `scripts/android-check` goes to the
// home screen and fires the shortcut the way the launcher does. On a phone
// locked with a PIN the scenario is skipped.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/main.dart' as app;
import 'package:koe/platform/recording_shortcut_service.dart';

import 'background_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('开始录音 that cannot start says why on screen', (tester) async {
    if (await skipIfLocked('shortcut_failure_test.dart')) return;
    await app.main();
    final navigation = find.byKey(const ValueKey('bottom-navigation-bar'));
    await pumpUntil(tester, () => navigation.evaluate().isNotEmpty);
    expect(navigation, findsOneWidget);

    // ignore: avoid_print
    print('KOE_ADB: home');
    await waitUntil(
      () => tester.binding.lifecycleState == AppLifecycleState.paused,
    );
    expect(
      tester.binding.lifecycleState,
      AppLifecycleState.paused,
      reason: 'scripts/android-check did not take Koe off screen',
    );

    // ignore: avoid_print
    print(
      'KOE_ADB: launch-shortcut '
      '${RecordingShortcutService.startRecordingShortcut.type}',
    );
    await waitUntil(
      () => tester.binding.lifecycleState == AppLifecycleState.resumed,
    );
    expect(
      tester.binding.lifecycleState,
      AppLifecycleState.resumed,
      reason: 'the shortcut did not reach Koe; see the android-check line',
    );
    final reason = find.text('快捷录音未开始：未找到已绑定的录音豆，请先在应用中连接设备');
    await pumpUntil(tester, () => reason.evaluate().isNotEmpty);
    expect(reason, findsOneWidget);
  });
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
