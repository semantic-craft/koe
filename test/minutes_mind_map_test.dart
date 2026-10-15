import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anker_recorder/state/meeting_minutes.dart';
import 'package:anker_recorder/state/recording_analysis.dart';
import 'package:anker_recorder/state/recorder_controller.dart';
import 'package:anker_recorder/ui/widgets/minutes_mind_map.dart';
import 'meeting_minutes_test.dart' as fixtures;

void main() {
  testWidgets('layout retains all items and paints a complete image', (
    tester,
  ) async {
    final minutes = MeetingMinutes.parse(fixtures.fixture(), 1);
    final nodes = minuteMapNodes(minutes);
    final layout = MinuteMapLayout(nodes, '测试录音', '版本 1');
    expect(nodes.map((n) => n.id).toSet().length, nodes.length);
    for (final rect in layout.rects.values) {
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(90));
      expect(rect.right, lessThan(layout.size.width));
      expect(rect.bottom, lessThan(layout.size.height));
    }
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        expect(
          layout.rects[nodes[i].id]!.overlaps(layout.rects[nodes[j].id]!),
          isFalse,
        );
      }
    }
    await tester.runAsync(() async {
      final data = Uint8List.fromList(await layout.png());
      final image = await ui.instantiateImageCodec(data);
      final frame = await image.getNextFrame();
      expect(frame.image.width, greaterThan(layout.size.width));
      expect(frame.image.height, greaterThan(layout.size.height));
      frame.image.dispose();
      image.dispose();
    });
  });
  testWidgets('long Chinese items retain full text and do not overlap', (
    tester,
  ) async {
    final minutes = MeetingMinutes(
      title: '长中文会议',
      overview: '概览',
      topics: List.generate(
        80,
        (i) => MinuteItem('议题 $i ${List.filled(8, '完整内容需保留').join()}', ['S1']),
      ),
      decisions: [],
      actions: [],
      questions: [],
    );
    final nodes = minuteMapNodes(minutes);
    final layout = MinuteMapLayout(nodes, '标题', '来源版本');
    expect(nodes.where((n) => n.item != null).length, 80);
    expect(layout.rects.length, nodes.length);
    final items = nodes.where((n) => n.item != null).toList();
    for (var i = 1; i < items.length; i++) {
      expect(
        layout.rects[items[i - 1].id]!.overlaps(layout.rects[items[i].id]!),
        isFalse,
      );
    }
  });
  for (final width in [390.0, 1100.0]) {
    testWidgets('map collapse, source view, version refresh at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = fixtures.Service();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      await fixtures.generate(manager);
      final controller = fixtures.Controller(manager);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MinutesMindMap(
            controller: controller,
            reference: const RecordingReference(fileId: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(service.calls, 1);
      final before =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) => w is CustomPaint && w.painter is MinuteMapPainter,
                    ),
                  )
                  .painter
              as MinuteMapPainter;
      expect(before.layout.nodes.any((n) => n.text == '发布安排'), isTrue);
      await tester.tap(find.byKey(const ValueKey('map-node-section:0')));
      await tester.pumpAndSettle();
      final folded =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (w) => w is CustomPaint && w.painter is MinuteMapPainter,
                    ),
                  )
                  .painter
              as MinuteMapPainter;
      expect(folded.layout.nodes.any((n) => n.text == '发布安排'), isFalse);
      await tester.tap(find.text('展开全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('层级文本'));
      await tester.pumpAndSettle();
      expect(find.text('发布安排'), findsOneWidget);
      await tester.tap(find.text('发布安排'));
      await tester.pumpAndSettle();
      expect(find.text('讨论发布，请核对发布。'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      final original = manager.results['file:1/minutes']!;
      await manager.editResult(
        'file:1/minutes',
        original,
        fixtures.fixture().replaceAll('发布安排', '调整后的议题'),
      );
      await tester.pumpAndSettle();
      expect(find.text('调整后的议题'), findsOneWidget);
      expect(service.calls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
