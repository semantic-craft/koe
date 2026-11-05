import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'meeting_minutes_test.dart' show Controller, Service;

void main() {
  testWidgets('trim-only transcript changes keep generated minutes current', (
    tester,
  ) async {
    final service = Service();
    final manager = RecordingAnalysis(inMemory: true, service: service);
    final controller = Controller(
      manager,
      text: '\n  讨论发布，请核对发布。  \n',
      segments: const [
        TranscriptSegment(
          text: '讨论发布，',
          start: Duration.zero,
          end: Duration(seconds: 4),
        ),
        TranscriptSegment(
          text: '请核对发布。',
          start: Duration(seconds: 8),
          end: Duration(seconds: 12),
        ),
      ],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MinutesPanel(
          controller: controller,
          reference: const RecordingReference(fileId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成纪要'));
    await tester.pumpAndSettle();

    expect(service.calls, 1);
    expect(find.text('项目会议'), findsOneWidget);
    expect(find.text('原文已更新，这份纪要已过期，请重新生成。'), findsNothing);
    expect(find.text('出处 [S1] 00:00'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'first minutes interrupted by a source edit can explicitly restart',
    (tester) async {
      final service = Service()..wait = Completer<String>();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      final controller = Controller(manager);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MinutesPanel(
            controller: controller,
            reference: const RecordingReference(fileId: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成纪要'));
      await tester.pump();
      expect(service.calls, 1);
      controller.text = '改为明天核对发布。';
      service.wait!.complete(service.response);
      await tester.pumpAndSettle();
      expect(manager.results['file:1/minutes'], isNull);
      expect(manager.hasUnconfirmedNode('file:1/minutes'), isFalse);
      service.wait = null;
      await tester.tap(find.text('生成纪要'));
      await tester.pumpAndSettle();
      expect(find.text('继续生成'), findsOneWidget);
      await tester.tap(find.text('继续生成'));
      await tester.pumpAndSettle();
      expect(service.calls, 2);
      expect(
        manager.results['file:1/minutes']!.sourceHash,
        analysisFingerprint(controller.text),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('timed-out first retry asks before risking duplicate charges', (
    tester,
  ) async {
    final service = Service();
    final manager = RecordingAnalysis(inMemory: true, service: service);
    final controller = Controller(manager);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MinutesPanel(
          controller: controller,
          reference: const RecordingReference(fileId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    service.wait = Completer<String>();
    await tester.tap(find.text('生成纪要'));
    await tester.pump();
    service.wait!.completeError(TimeoutException('request timed out'));
    await tester.pump();

    expect(service.calls, 1);
    expect(manager.hasUnconfirmedNode('file:1/minutes'), isTrue);
    service.wait = null;

    await tester.tap(find.text('生成纪要'));
    await tester.pump();
    expect(find.text('可能重复收费？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.calls, 1);

    await tester.tap(find.text('生成纪要'));
    await tester.pump();
    expect(find.text('可能重复收费？'), findsOneWidget);
    await tester.tap(find.text('继续生成'));
    await tester.pumpAndSettle();

    expect(service.calls, 2);
    expect(manager.hasUnconfirmedNode('file:1/minutes'), isFalse);
    expect(find.text('项目会议'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
