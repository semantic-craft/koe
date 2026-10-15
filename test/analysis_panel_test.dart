import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/widgets/analysis_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service implements AnalysisService {
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => '已完成的摘要 [S1]';
  @override
  void dispose() {}
}

class _Controller extends RecorderController {
  _Controller(RecordingAnalysis manager)
    : super(loadPersistedState: false, analysisController: manager);
  @override
  String get analysisApiKey => 'test-key';
  @override
  String analysisKey(RecordingReference ref) => 'file:123';
  @override
  RecordingViewData recordingView(RecordingReference ref) => RecordingViewData(
    reference: ref,
    title: '短录音',
    text: '会议决定周五发布，负责人小王。',
    path: '/123.wav',
  );
}

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('summary and analysis readable at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = RecordingAnalysis(inMemory: true, service: _Service());
      final controller = _Controller(manager);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AnalysisPanel(
            controller: controller,
            reference: const RecordingReference(fileId: 123),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Qwen3.8-Flash'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('generate-analysis')));
      await tester.pumpAndSettle();
      expect(find.text('已完成的摘要 [S1]'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('导出'), findsOneWidget);
      await tester.tap(find.text('自定义分析'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('analysis-instruction')),
        '提取待办',
      );
      await tester.tap(find.byKey(const ValueKey('generate-analysis')));
      await tester.pumpAndSettle();
      expect(manager.results.length, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
