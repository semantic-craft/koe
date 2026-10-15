import 'package:koe/state/recorder_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Native calls and file IO need real async time; pump their continuations
/// under the widget test clock until the actual save finishes.
Future<void> waitForSettings(WidgetTester tester, RecorderController c) async {
  var complete = false;
  c.settingsSaved.then(
    (_) => complete = true,
    onError: (Object _) => complete = true,
  );
  for (var i = 0; i < 100 && !complete; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(complete, true, reason: 'settings operation should complete');
  await tester.pump();
}
