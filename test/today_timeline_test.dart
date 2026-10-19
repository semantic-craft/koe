import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/main.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 5),
);

void main() {
  testWidgets('Today lists the day in time order and fixes a topic link '
      'without moving the recording', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('koe-today-'),
    ))!;
    final topics = TopicStore(inMemory: true);
    late RecorderController controller;
    addTearDown(() async {
      controller.dispose();
      topics.dispose();
      await directory.delete(recursive: true);
    });
    final now = DateTime.now();
    int at(int hour) =>
        DateTime(now.year, now.month, now.day, hour).millisecondsSinceEpoch ~/
        1000;
    final morning = at(9);
    final afternoon = at(14);
    late Topic renovation;
    late Topic budget;
    await tester.runAsync(() async {
      controller = RecorderController(
        loadPersistedState: false,
        topicsEnabled: true,
        topicStore: topics,
        analysisController: RecordingAnalysis(inMemory: true),
        libraryDirectory: Directory('${directory.path}/imports'),
      );
      for (final id in [afternoon, morning]) {
        final path = '${directory.path}/$id.wav';
        await File(path).writeAsBytes([1, 2, 3, 4]);
        controller.exportedPaths.add(path);
      }
      renovation = await topics.createTopic(
        kind: TopicKind.general,
        title: '装修',
      );
      budget = await topics.createTopic(kind: TopicKind.general, title: '预算');
      await topics.moveRecording('file:$morning', renovation.id);
      await controller.contextItems.load();
    });

    // Tall phone so the whole day fits above the bottom navigation.
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(KoeApp(controller: controller));
    await settle(tester);
    final first = find.byKey(ValueKey('timeline-item-recording:file:$morning'));
    final second = find.byKey(
      ValueKey('timeline-item-recording:file:$afternoon'),
    );
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
    expect(find.text('# 装修'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey('timeline-links-recording:file:$morning')),
    );
    await settle(tester);
    await tester.tap(find.byKey(ValueKey('link-topic-${budget.id}')));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('save-context-links')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester);

    expect(find.text('# 预算'), findsOneWidget);
    expect(
      controller.contextItems.itemById('recording:file:$morning')?.topicIds,
      [renovation.id, budget.id],
    );
    expect(topics.topicOf('file:$morning')?.id, renovation.id);
  });
}
