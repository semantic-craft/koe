import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/screens/todos_screen.dart';
import 'package:provider/provider.dart';

/// Android phones get the iPhone's phone features; capabilities only Apple
/// platforms have are reported unsupported instead of offered (#337).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final android = TargetPlatformVariant.only(TargetPlatform.android);

  Future<void> pumpPhone(
    WidgetTester tester,
    RecorderController controller,
    Widget home,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Android gets phone recording and topics like iPhone', (
    tester,
  ) async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);

    expect(c.phoneRecordingEnabled, isTrue);
    expect(c.topicsEnabled, isTrue);
  }, variant: android);

  testWidgets('Android settings list neither the Apple engine nor Mac '
      'archiving', (tester) async {
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    await pumpPhone(tester, c, const SettingsScreen());

    expect(
      find.byKey(const ValueKey('speech-provider-option-qwen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('speech-provider-option-apple')),
      findsNothing,
    );
    expect(find.text(SttProvider.apple.label), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('external-ai-entry')),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Mac 原件归档'), findsNothing);
    expect(find.byKey(const ValueKey('mac-archive-section')), findsNothing);
  }, variant: android);

  testWidgets('Android todo detail says Reminders is not on this device', (
    tester,
  ) async {
    final store = TodoStore(inMemory: true);
    final c = RecorderController(loadPersistedState: false, todoStore: store);
    addTearDown(c.dispose);
    final now = DateTime(2026, 10, 21, 9);
    await tester.runAsync(
      () => store.put(
        Todo(
          id: 't1',
          kind: TodoKind.mine,
          title: '买牛奶',
          source: const ContextSource(recordingKey: 'file:1'),
          quote: '我回去买牛奶。',
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    await pumpPhone(tester, c, const TodoDetailScreen(todoId: 't1'));

    expect(find.text('提醒事项 · 此设备不支持'), findsOneWidget);
    expect(find.byKey(const ValueKey('export-reminder')), findsNothing);
  }, variant: android);
}
