import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/localization.dart';
import 'package:koe/ui/screens/todos_screen.dart';
import 'package:koe/ui/screens/trash_screen.dart';
import 'package:koe/ui/widgets/inline_player.dart';
import 'package:provider/provider.dart';

/// Controls VoiceOver must name and announce with the right role (#237).
void main() {
  Widget wrap(RecorderController c, Widget home) =>
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          locale: koeLocale,
          supportedLocales: const [koeLocale],
          localizationsDelegates: koeLocalizationsDelegates,
          home: home,
        ),
      );

  SemanticsNode node(WidgetTester tester, Pattern label) =>
      tester.getSemantics(find.bySemanticsLabel(label));

  testWidgets('settings switches are named by the text beside them', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(wrap(c, const SettingsScreen()));
    for (final title in ['自动转写', '自动整理新录音']) {
      final label = RegExp('^$title\n');
      await tester.ensureVisible(find.bySemanticsLabel(label));
      expect(
        node(tester, label),
        isSemantics(hasToggledState: true, hasTapAction: true),
      );
    }
    semantics.dispose();
  });

  testWidgets('the detail player names its slider and buttons', (tester) async {
    final semantics = tester.ensureSemantics();
    const path = '/tmp/178.wav';
    final c = RecorderController(loadPersistedState: false)
      ..playingPath = path
      ..duration = const Duration(seconds: 120);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      wrap(
        c,
        Scaffold(
          body: InlinePlayer(path: path, onAddBookmark: () {}),
        ),
      ),
    );
    expect(node(tester, '播放进度'), isSemantics(isSlider: true, value: '00:00'));
    expect(
      node(tester, '播放录音'),
      isSemantics(isButton: true, hasTapAction: true),
    );
    // VoiceOver reads a button's tooltip as its name.
    for (final tooltip in ['后退 15 秒', '前进 15 秒', '为当前片段加书签']) {
      expect(
        tester.getSemantics(find.byTooltip(tooltip)),
        isSemantics(isButton: true, tooltip: tooltip),
        reason: tooltip,
      );
    }
    semantics.dispose();
  });

  testWidgets('a todo checkbox is named by the todo', (tester) async {
    final semantics = tester.ensureSemantics();
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    final now = DateTime(2026, 10, 19);
    final todo = Todo(
      id: 't1',
      kind: TodoKind.mine,
      title: '周五量房',
      source: const ContextSource(recordingKey: 'file:1'),
      quote: '周五量房',
      createdAt: now,
      updatedAt: now,
    );
    await tester.pumpWidget(wrap(c, Scaffold(body: TodoRow(todo: todo))));
    expect(
      node(tester, '完成：周五量房'),
      isSemantics(hasCheckedState: true, isChecked: false),
    );
    semantics.dispose();
  });

  testWidgets('engine cards are buttons, and Material\'s own controls speak '
      'Chinese', (tester) async {
    final semantics = tester.ensureSemantics();
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(wrap(c, const SettingsScreen()));
    for (final provider in SttProvider.available) {
      final card = find.byKey(
        ValueKey('speech-provider-option-${provider.name}'),
      );
      await tester.ensureVisible(card);
      final node = tester.getSemantics(card);
      expect(
        node,
        isSemantics(isButton: true, hasTapAction: true),
        reason: provider.name,
      );
      expect(node.label, startsWith(provider.label));
    }

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => Scaffold(appBar: AppBar())),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回'), findsOneWidget);

    showDatePicker(
      context: navigator.context,
      firstDate: DateTime(2026),
      lastDate: DateTime(2027),
    );
    await tester.pumpAndSettle();
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('Cancel'), findsNothing);
    semantics.dispose();
  });

  testWidgets('navigation buttons can be activated by VoiceOver and Voice '
      'Control, on the phone and on the Mac sidebar', (tester) async {
    final semantics = tester.ensureSemantics();
    final c = RecorderController(loadPersistedState: false);
    addTearDown(c.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    tester.view.physicalSize = const Size(1280, 900);
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    tester.semantics.tap(find.semantics.byLabel('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    tester.semantics.tap(find.semantics.byLabel('回收站'));
    await tester.pumpAndSettle();
    expect(find.byType(TrashScreen), findsOneWidget);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(KoeApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nav-library')), findsOneWidget);
    final libraryTab = find.semantics.byPredicate(
      (node) => node.label == '资料' && node.flagsCollection.isButton,
    );
    tester.semantics.tap(libraryTab);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(const ValueKey('nav-library'))),
      isSemantics(isSelected: true),
    );
    semantics.dispose();
  });
}
