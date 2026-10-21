import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/widgets/analysis_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service implements AnalysisService {
  int calls = 0;
  String? lastInstruction;
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    lastInstruction = instruction;
    return '已完成的摘要 [S1]';
  }

  @override
  void dispose() {}
}

class _Controller extends RecorderController {
  _Controller(RecordingAnalysis manager)
    : super(loadPersistedState: false, analysisController: manager);
  @override
  String get analysisApiKey => 'test-key';
  bool changed = false;
  @override
  bool recordingAudioChanged(RecordingReference ref) => changed;
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
  testWidgets(
    'changed audio marks old analysis stale and prevents paid generation',
    (tester) async {
      final manager = RecordingAnalysis(inMemory: true, service: _Service());
      final c = _Controller(manager);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AnalysisPanel(
            controller: c,
            reference: const RecordingReference(fileId: 123),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('generate-analysis')));
      await tester.pumpAndSettle();
      c.changed = true;
      c.notifyListeners();
      await tester.pump();
      expect(find.textContaining('音频内容已变化'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('generate-analysis')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('已过期'), findsOneWidget);
      expect(manager.results.values.single.text, '已完成的摘要 [S1]');
    },
  );
  testWidgets(
    'creating a template, running it, and editing it marks the old result stale '
    'without auto re-running',
    (tester) async {
      final service = _Service();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      final c = _Controller(manager);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AnalysisPanel(
            controller: c,
            reference: const RecordingReference(fileId: 123),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('默认摘要'), findsOneWidget);
      expect(find.text('读书笔记'), findsOneWidget);
      expect(find.text('思考笔记'), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-template')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('create-template')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('template-name-input')),
        '问题清单',
      );
      await tester.enterText(
        find.byKey(const ValueKey('template-prompt-input')),
        '只列出未决问题',
      );
      await tester.tap(find.byKey(const ValueKey('save-template')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('generate-analysis')));
      await tester.pumpAndSettle();
      expect(service.calls, 1);
      expect(service.lastInstruction, '只列出未决问题');
      expect(find.text('已完成的摘要 [S1]'), findsOneWidget);
      expect(find.textContaining('已过期'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('edit-template')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('template-prompt-input')),
        '只列出未决问题与负责人',
      );
      await tester.tap(find.byKey(const ValueKey('save-template')));
      await tester.pumpAndSettle();

      expect(service.calls, 1);
      expect(find.text('已完成的摘要 [S1]'), findsOneWidget);
      expect(find.textContaining('已过期'), findsOneWidget);
    },
  );
  testWidgets('Android exports the analysis through the share sheet', (
    tester,
  ) async {
    final shared = <Map<Object?, Object?>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/share'),
      (call) async {
        shared.add(call.arguments as Map<Object?, Object?>);
        return 'dev.fluttercommunity.plus/share/unavailable';
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/share'),
        null,
      ),
    );
    final manager = RecordingAnalysis(inMemory: true, service: _Service());
    final c = _Controller(manager);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisPanel(
          controller: c,
          reference: const RecordingReference(fileId: 123),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('generate-analysis')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(shared.single['text'], contains('已完成的摘要'));
    expect(find.text('导出失败，请重试'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
