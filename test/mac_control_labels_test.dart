import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/protocol/models.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:provider/provider.dart';

// #307: the Mac accessibility bridge exposes a Flutter tooltip as AXHelp, not
// as the control's name, so VoiceOver and scripts/mac-ax saw unnamed buttons.
// A control is named on the Mac only by its semantics label.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RecorderController newController() {
    final controller = RecorderController(loadPersistedState: false);
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> pump(
    WidgetTester tester,
    RecorderController controller,
    Widget home,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(home: home),
      ),
    );
    await tester.pump();
  }

  testWidgets('recording detail icon buttons carry their name as a label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final c = newController()
      ..files = [OfflineFileEntry(fileId: 102, sizeBytes: 160)];
    await pump(
      tester,
      c,
      const RecordingDetailScreen(reference: RecordingReference(fileId: 102)),
    );
    for (final name in ['分享录音', '更多操作']) {
      expect(
        tester.getSemantics(find.byTooltip(name)).label,
        contains(name),
        reason: name,
      );
    }
    handle.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the Mac receive switch is named by its title', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, newController(), const SettingsScreen());
    final toggle = find.byKey(const ValueKey('mac-receive-switch'));
    await tester.scrollUntilVisible(
      toggle,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.getSemantics(toggle).label, contains('这台 Mac 接收原件'));
    handle.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
