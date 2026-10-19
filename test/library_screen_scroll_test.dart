import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/library_screen.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('at a large text size on a short screen the library header '
      'scrolls away and every local recording can be reached', (tester) async {
    // A phone screen after the mini player, Ask button and tab bar.
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final paths = [
      for (var i = 0; i < 12; i++) '/tmp/${1783917051 + i * 60}.wav',
    ];
    final c = RecorderController(loadPersistedState: false)
      ..exportedPaths = [...paths];
    for (final path in paths) {
      c.transcriptsByPath[path] = '这是 $path 的转写';
    }
    addTearDown(c.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pump();

    final list = find.byKey(const ValueKey('local-recordings-refresh'));
    await tester.drag(list, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-search')).hitTestable(),
      findsNothing,
      reason: 'the search field scrolls off with the header',
    );
    expect(tester.getSize(list).height, greaterThan(300));

    final last = find.byKey(ValueKey('recording-row-${paths.last}'));
    await tester.dragUntilVisible(last, list, const Offset(0, -200));
    expect(last.hitTestable(), findsOneWidget);
  });
}
