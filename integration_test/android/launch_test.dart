// Android smoke scenario: the real app starts on the Pixel and reaches the
// phone navigation, drawn edge to edge. Run with `scripts/android-check`,
// which grants the runtime permissions first so no dialog blocks the run.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:koe/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('launches to the phone navigation, edge to edge', (tester) async {
    await app.main();
    final navigation = find.byKey(const ValueKey('bottom-navigation-bar'));
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (navigation.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(navigation, findsOneWidget);
    for (final tab in ['nav-today', 'nav-projects', 'nav-library']) {
      expect(find.byKey(ValueKey(tab)), findsOneWidget);
    }

    // Edge to edge: the app is laid out under the status bar and gesture
    // bar, and keeps the navigation clear of the gesture bar itself.
    final view = tester.view;
    final ratio = view.devicePixelRatio;
    final top = view.viewPadding.top / ratio;
    final bottom = view.viewPadding.bottom / ratio;
    final height = view.physicalSize.height / ratio;
    expect(top, greaterThan(0));
    expect(bottom, greaterThan(0));
    final today = tester.getRect(find.byKey(const ValueKey('nav-today')));
    expect(today.bottom, lessThanOrEqualTo(height - bottom));
  });
}
