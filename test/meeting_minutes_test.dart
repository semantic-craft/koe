import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recorder_controller.dart';
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

class Service implements AnalysisService {
  String response = fixture();
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
  Controller(RecordingAnalysis manager)
    : super(loadPersistedState: false, analysisController: manager);
  @override
  String get analysisApiKey => 'test-key';
  @override
  String analysisKey(RecordingReference ref) => 'file:1';
  @override
  RecordingViewData recordingView(RecordingReference ref) => RecordingViewData(
    reference: ref,
    title: '短录音',
    text: '讨论发布，请核对发布。',
    path: '/1.wav',
  );
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
      service.response = fixture();
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
      service.wait!.complete(fixture());
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
      expect(find.text('负责人：未提及 · 期限：未提及'), findsOneWidget);
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
}
