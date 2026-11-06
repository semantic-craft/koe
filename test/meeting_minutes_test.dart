import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/transcript_jump.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';

String fixture({String source = 'S1'}) => jsonEncode({
  'title': '项目会议',
  'overview': '讨论发布',
  'topics': [
    {
      'text': '发布安排',
      'sources': [source],
    },
  ],
  'decisions': [],
  'actions': [
    {
      'text': '核对发布',
      'owner': '未提及',
      'due': '未提及',
      'sources': [source],
    },
  ],
  'questions': [],
});

String generatedFixture() => jsonEncode({
  ...jsonDecode(fixture()) as Map<String, dynamic>,
  'schemaVersion': 2,
});

class Service implements AnalysisService {
  String response = generatedFixture();
  int calls = 0;
  Completer<String>? wait;
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    return wait == null ? response : await wait!.future;
  }

  @override
  void dispose() {}
}

class Controller extends RecorderController {
  Controller(
    RecordingAnalysis manager, {
    this.segments = const [],
    this.text = '讨论发布，请核对发布。',
  }) : super(loadPersistedState: false, analysisController: manager);
  final List<TranscriptSegment> segments;
  String text;
  bool audioChanged = false;
  @override
  String get analysisApiKey => 'test-key';
  @override
  String analysisKey(RecordingReference ref) => 'file:1';
  @override
  RecordingViewData recordingView(RecordingReference ref) => RecordingViewData(
    reference: ref,
    title: '短录音',
    text: text,
    path: '/1.wav',
    segments: segments,
  );
  @override
  Duration? localDurationForPath(String path) => const Duration(seconds: 30);
  @override
  bool recordingAudioChanged(RecordingReference ref) => audioChanged;
}

Future<void> generate(RecordingAnalysis manager) => manager.run(
  recording: 'file:1',
  source: '讨论发布，请核对发布。',
  apiKey: 'test-key',
  custom: true,
  resultSlot: 'minutes',
  instruction: minutesInstruction,
  validateResult: validateMinutes,
  currentSource: () => '讨论发布，请核对发布。',
);
void main() {
  test(
    'structured schema rejects malformed fields and invented source IDs',
    () {
      expect(
        () => MeetingMinutes.parse(fixture(source: 'S2'), 1),
        throwsFormatException,
      );
      expect(() => MeetingMinutes.parse('{}', 1), throwsFormatException);
      final valid = MeetingMinutes.parse(fixture(), 1);
      expect(valid.actions.single.owner, '未提及');
      expect(valid.decisions, isEmpty);
    },
  );
  test(
    'invalid response retains previous result and retry makes a fresh request',
    () async {
      final service = Service();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      await generate(manager);
      final original = manager.results['file:1/minutes']!;
      service.response = '{}';
      await generate(manager);
      expect(manager.results['file:1/minutes'], same(original));
      expect(manager.errors, isNotEmpty);
      service.response = generatedFixture();
      await generate(manager);
      expect(service.calls, 3);
      expect(manager.errors, isEmpty);
    },
  );
  test(
    'edited result survives restart, keeps provenance and exports readable minutes',
    () async {
      final dir = await Directory.systemTemp.createTemp('minutes-test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/analysis.json');
      final manager = RecordingAnalysis(file: file, service: Service());
      addTearDown(manager.dispose);
      await generate(manager);
      final original = manager.results['file:1/minutes']!;
      await manager.editResult(
        'file:1/minutes',
        original,
        fixture().replaceAll('项目会议', '已编辑会议'),
      );
      final loaded = RecordingAnalysis(file: file, service: Service());
      addTearDown(loaded.dispose);
      await loaded.load();
      final result = loaded.results['file:1/minutes']!;
      expect(result.editedAt, isNotNull);
      expect(result.sourceHash, original.sourceHash);
      expect(
        MeetingMinutes.parse(result.text, 1).export(result),
        contains('# 已编辑会议'),
      );
      expect(await file.readAsString(), isNot(contains('test-key')));
    },
  );
  test(
    'cancelled late structured response cannot replace edited result',
    () async {
      final service = Service();
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      await generate(manager);
      final original = manager.results['file:1/minutes']!;
      service.wait = Completer<String>();
      final pending = generate(manager);
      await Future<void>.delayed(Duration.zero);
      manager.cancel('file:1/minutes');
      await manager.editResult('file:1/minutes', original, original.text);
      final edited = manager.results['file:1/minutes'];
      service.wait!.complete(generatedFixture());
      await pending;
      expect(manager.results['file:1/minutes'], same(edited));
    },
  );
  for (final width in [390.0, 1100.0]) {
    testWidgets('complete minutes interface at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final manager = RecordingAnalysis(inMemory: true, service: Service());
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
      await tester.pumpAndSettle();
      expect(find.text('项目会议'), findsOneWidget);
      expect(find.text('负责人：未提及，期限：未提及'), findsOneWidget);
      await tester.tap(find.text('编辑纪要'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '已编辑会议');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(find.text('已编辑会议'), findsOneWidget);
      await tester.tap(find.text('重新生成纪要'));
      await tester.pumpAndSettle();
      expect(find.textContaining('包括手动修改'), findsOneWidget);
      await tester.tap(find.text('保留'));
      await tester.pumpAndSettle();
      expect(find.text('已编辑会议'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('source links reopen the timed transcript at their segment', (
    tester,
  ) async {
    final manager = RecordingAnalysis(inMemory: true, service: Service());
    final controller = Controller(
      manager,
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
    TranscriptJump? jump;
    await tester.pumpWidget(
      MaterialApp(
        home: MinutesPanel(
          controller: controller,
          reference: const RecordingReference(fileId: 1),
          onOpenSource: (value) => jump = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成纪要'));
    await tester.pumpAndSettle();

    expect(find.text('出处 [S1] 00:00'), findsWidgets);
    await tester.tap(find.text('出处 [S1] 00:00').first);
    await tester.pumpAndSettle();
    expect(jump, isNotNull);
    expect(jump!.segmentIndex, 0);
    expect(jump!.start, Duration.zero);
    expect(find.text('项目会议'), findsOneWidget);
  });

  testWidgets('unlocatable sources show text without inventing playback', (
    tester,
  ) async {
    final manager = RecordingAnalysis(inMemory: true, service: Service());
    final controller = Controller(manager);
    addTearDown(controller.dispose);
    TranscriptJump? jump;
    await tester.pumpWidget(
      MaterialApp(
        home: MinutesPanel(
          controller: controller,
          reference: const RecordingReference(fileId: 1),
          onOpenSource: (value) => jump = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成纪要'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('出处 [S1]').first);
    await tester.pumpAndSettle();
    expect(jump, isNull);
    expect(find.text('无法可靠定位到原声；以下是模型使用的原文片段。'), findsOneWidget);
    expect(find.text('讨论发布，请核对发布。'), findsWidgets);
  });

  testWidgets('stale minutes never expose playable source links', (
    tester,
  ) async {
    final manager = RecordingAnalysis(inMemory: true, service: Service());
    final controller = Controller(
      manager,
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
    TranscriptJump? jump;
    await tester.pumpWidget(
      MaterialApp(
        home: MinutesPanel(
          controller: controller,
          reference: const RecordingReference(fileId: 1),
          onOpenSource: (value) => jump = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成纪要'));
    await tester.pumpAndSettle();

    controller.text = '讨论发布，请核对发布日期。';
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('原文已更新，这份纪要已过期，请重新生成。'), findsOneWidget);
    await tester.tap(find.text('出处 [S1]').first);
    await tester.pumpAndSettle();

    expect(jump, isNull);
    expect(find.text('无法可靠定位到原声；以下是模型使用的原文片段。'), findsOneWidget);
  });

  testWidgets('音频内容变化后旧时码不再作为出处跳转', (tester) async {
    final manager = RecordingAnalysis(inMemory: true, service: Service());
    final controller = Controller(
      manager,
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
    TranscriptJump? jump;
    await tester.pumpWidget(
      MaterialApp(
        home: MinutesPanel(
          controller: controller,
          reference: const RecordingReference(fileId: 1),
          onOpenSource: (value) => jump = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成纪要'));
    await tester.pumpAndSettle();
    expect(find.text('出处 [S1] 00:00'), findsWidgets);

    controller.audioChanged = true;
    controller.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('出处 [S1]').first);
    await tester.pumpAndSettle();

    expect(jump, isNull);
    expect(find.text('无法可靠定位到原声；以下是模型使用的原文片段。'), findsOneWidget);
  });

  testWidgets('regeneration keeps the previous minutes for comparison', (
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
    await tester.tap(find.text('生成纪要'));
    await tester.pumpAndSettle();

    service.response = generatedFixture().replaceAll('项目会议', '新稿会议');
    await tester.tap(find.text('重新生成纪要'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();

    expect(find.text('新稿会议'), findsOneWidget);
    expect(manager.previousResults['file:1/minutes'], isNotNull);
    await tester.tap(find.text('对比上一版'));
    await tester.pumpAndSettle();
    expect(find.text('与上一版对比'), findsOneWidget);
    expect(find.textContaining('项目会议'), findsWidgets);
    expect(find.textContaining('新稿会议'), findsWidgets);
  });

  test(
    'previous minutes survive a restart without reviving paid requests',
    () async {
      final dir = await Directory.systemTemp.createTemp('minutes-history');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/analysis.json');
      final service = Service();
      final manager = RecordingAnalysis(file: file, service: service);
      addTearDown(manager.dispose);
      await generate(manager);
      service.response = generatedFixture().replaceAll('项目会议', '新稿会议');
      await generate(manager);
      expect(manager.previousResults['file:1/minutes'], isNotNull);

      final loaded = RecordingAnalysis(file: file, service: Service());
      addTearDown(loaded.dispose);
      await loaded.load();
      expect(
        MeetingMinutes.parse(
          loaded.previousResults['file:1/minutes']!.text,
          1,
        ).title,
        '项目会议',
      );
      expect(loaded.results['file:1/minutes'], isNotNull);
    },
  );

  testWidgets('Android exports minutes through the share sheet', (
    tester,
  ) async {
    final shared = <Map<Object?, Object?>>[];
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      shared.add(call.arguments as Map<Object?, Object?>);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final manager = RecordingAnalysis(inMemory: true, service: Service());
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
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('导出纪要'));
    await tester.tap(find.text('导出纪要'));
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(shared.single['title'], '会议纪要');
    expect(find.text('导出失败，请重试'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
