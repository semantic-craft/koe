import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/transcript_jump.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'meeting_minutes_test.dart' as fixtures;

const sourceText = '讨论发布，请核对发布。';
Map<String, Object?> structuredFixture() => {
  'schemaVersion': 2,
  'title': '发布会议',
  'overview': '核对当前进度',
  'topics': [
    {
      'text': '上线安排',
      'summary': '确认交付窗口',
      'sources': ['S1'],
      'points': [
        {
          'text': '先核对文档',
          'sources': ['S1'],
        },
      ],
      'fishbone': {
        'question': '为何延后',
        'branches': [
          {
            'text': '文档待核',
            'detail': '接口说明需要补全',
            'sources': ['S1'],
          },
          {
            'text': '人手不足',
            'detail': '联调尚需排期',
            'sources': ['S1'],
          },
        ],
      },
    },
  ],
  'decisions': [],
  'actions': [],
  'questions': [],
  'terms': [
    {
      'name': '上线',
      'note': '本场讨论的交付工作',
      'heard': ['发布'],
      'sources': ['S1'],
    },
  ],
};

AnalysisResult resultFor(Map<String, Object?> value) => AnalysisResult(
  text: jsonEncode(value),
  sourceHash: analysisFingerprint(sourceText),
  model: 'fixture',
  instruction: 'test',
  sources: const [sourceText],
  createdAt: DateTime(2026, 11, 3),
);

class FailingReplacementController extends fixtures.Controller {
  FailingReplacementController(super.manager);

  Future<TermReplacementReport> failReplacement() async {
    text = '逐字稿可能已经更新';
    notifyListeners();
    throw StateError('fixture persistence failure');
  }

  @override
  Future<TermReplacementReport> replaceTermInRecording(
    RecordingReference ref,
    String fromTerm,
    String toTerm, {
    bool addToVocabulary = false,
  }) => failReplacement();

  @override
  Future<TermReplacementReport> replaceTermAcrossLibrary(
    String fromTerm,
    String toTerm, {
    bool addToVocabulary = false,
  }) => failReplacement();
}

void main() {
  for (final allRecordings in [false, true]) {
    testWidgets(
      'replacement failure shows recovery guidance (all=$allRecordings)',
      (tester) async {
        final manager = RecordingAnalysis(
          inMemory: true,
          service: fixtures.Service(),
        );
        manager.results['file:1/minutes'] = resultFor(structuredFixture());
        final controller = FailingReplacementController(manager);
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
        await tester.ensureVisible(find.text('查找替换'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('查找替换'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('minutes-replace-from-input')),
          '发布',
        );
        await tester.enterText(
          find.byKey(const ValueKey('minutes-replace-to-input')),
          '交付',
        );
        if (allRecordings) {
          await tester.tap(
            find.byKey(const ValueKey('minutes-replace-scope-all')),
          );
        }
        await tester.tap(find.byKey(const ValueKey('minutes-replace-submit')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text(
            allRecordings ? '替换未完成，部分记录可能已更新，请检查后重试' : '替换未完成，请检查逐字稿与纪要后重试',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('已更新 0 条'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'structured topics, causes and terms remain readable at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final manager = RecordingAnalysis(
          inMemory: true,
          service: fixtures.Service(),
        );
        manager.results['file:1/minutes'] = resultFor(structuredFixture());
        final controller = fixtures.Controller(manager);
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
        expect(find.text('确认交付窗口'), findsOneWidget);
        expect(find.text('先核对文档'), findsOneWidget);
        expect(find.text('为何延后'), findsOneWidget);
        expect(find.text('接口说明需要补全'), findsOneWidget);
        expect(find.text('联调尚需排期'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('本场讨论的交付工作'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('本场讨论的交付工作'), findsOneWidget);
        expect(find.textContaining('发布'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('思维导图'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('层级文本'));
        await tester.pumpAndSettle();
        expect(find.text('确认交付窗口'), findsOneWidget);
        expect(find.text('先核对文档'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'editing only the title preserves all structured fields and previous version',
    (tester) async {
      final original = structuredFixture();
      final manager = RecordingAnalysis(
        inMemory: true,
        service: fixtures.Service(),
      );
      manager.results['file:1/minutes'] = resultFor(original);
      final controller = fixtures.Controller(manager);
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
      await tester.ensureVisible(find.text('编辑纪要'));
      await tester.tap(find.text('编辑纪要'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '已校订标题');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      final saved = jsonDecode(manager.results['file:1/minutes']!.text) as Map;
      expect(saved['title'], '已校订标题');
      for (final field in ['schemaVersion', 'topics', 'terms']) {
        expect(
          saved[field],
          original[field],
          reason: '$field must survive editing',
        );
      }
      expect(
        jsonDecode(manager.versionsFor('file:1/minutes').last.text)['topics'],
        original['topics'],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'nested source opens the original and stale nested source cannot replay',
    (tester) async {
      final manager = RecordingAnalysis(
        inMemory: true,
        service: fixtures.Service(),
      );
      manager.results['file:1/minutes'] = resultFor(structuredFixture());
      final controller = fixtures.Controller(
        manager,
        segments: const [
          TranscriptSegment(
            text: '讨论发布，',
            start: Duration(seconds: 2),
            end: Duration(seconds: 4),
          ),
          TranscriptSegment(
            text: '请核对发布。',
            start: Duration(seconds: 5),
            end: Duration(seconds: 8),
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
      final point = find.ancestor(
        of: find.text('先核对文档'),
        matching: find.byKey(const ValueKey('minutes-topic-point-0')),
      );
      expect(point, findsOneWidget);
      final sourceButton = find.descendant(
        of: point,
        matching: find.text('出处 [S1] 00:02'),
      );
      await tester.ensureVisible(sourceButton);
      await tester.pumpAndSettle();
      await tester.tap(sourceButton);
      await tester.pumpAndSettle();
      expect(jump?.start, const Duration(seconds: 2));
      jump = null;
      controller.text = '已修改的正文';
      controller.notifyListeners();
      await tester.pumpAndSettle();
      final stale = find.descendant(of: point, matching: find.text('出处 [S1]'));
      await tester.ensureVisible(stale);
      await tester.pumpAndSettle();
      await tester.tap(stale);
      await tester.pumpAndSettle();
      expect(jump, isNull);
      expect(find.text('无法可靠定位到原声；以下是模型使用的原文片段。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
