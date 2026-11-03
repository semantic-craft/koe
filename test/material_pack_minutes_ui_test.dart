import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/minutes_document_screen.dart';
import 'package:koe/ui/widgets/material_export_sheet.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _snapshot(String title) => AnalysisResult(
  text: jsonEncode({
    'schemaVersion': 2,
    'title': title,
    'overview': '会议概览',
    'topics': [
      {
        'text': '接口延期',
        'summary': '接口没有联调',
        'sources': ['S1'],
        'points': [
          {
            'text': '先完成联调',
            'sources': ['S1'],
          },
        ],
        'fishbone': {
          'question': '延期原因',
          'branches': [
            {
              'text': '技术原因',
              'detail': '缺少联调环境',
              'sources': ['S1'],
            },
          ],
        },
      },
    ],
    'terms': [
      {
        'name': '联调',
        'adoption': {
          'kind': 'vocabulary',
          'at': '2026-11-03T00:00:00.000',
          'previousVersion': 'b' * 64,
        },
        'note': '本场指接口联合调试',
        'heard': [],
        'sources': ['S1'],
      },
    ],
    'decisions': [],
    'actions': [],
    'questions': [],
  }),
  sourceHash: analysisFingerprint('接口没有联调环境'),
  sources: ['接口没有联调环境'],
  model: 'test',
  instruction: 'test',
  createdAt: DateTime(2026, 11, 3),
).toJson()..['isDraft'] = false;

class _ColdMinutes extends RecordingAnalysis {
  _ColdMinutes() : super(inMemory: true);
  late String slot;
  final ready = Completer<void>();
  @override
  Future<void> load() async {
    await ready.future;
    results[slot] = AnalysisResult.fromJson(_snapshot('尚未打开过的纪要'));
  }
}

void main() {
  testWidgets('导出前先读入已有纪要，预览不漏掉冷启动时的纪要', (tester) async {
    final analysis = _ColdMinutes();
    final c = RecorderController(
      loadPersistedState: false,
      analysisController: analysis,
      phoneRecordingEnabled: false,
      topicsEnabled: false,
    );
    addTearDown(c.dispose);
    const ref = RecordingReference(path: '/unavailable/meeting.wav');
    analysis.slot = '${c.analysisKey(ref)}/minutes';
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: c,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showMaterialExportSheet(context, ref),
                child: const Text('导出测试'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导出测试'));
    await tester.pumpAndSettle();
    final openedBeforeLoaded = find.text('导出资料').evaluate().isNotEmpty;
    analysis.ready.complete();
    await tester.pumpAndSettle();
    expect(openedBeforeLoaded, isFalse);
    expect(find.text('当前纪要及 0 版历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无音频资料包可阅读当前纪要、嵌套内容和历史快照，不提供回听', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MinutesDocumentStore(inMemory: true);
    await store.upsert(
      MinutesDocument(
        id: 'pack-example',
        title: '导入会议',
        sourceName: 'meeting.koepack',
        importedAt: DateTime(2026, 11, 3),
        timingReliable: false,
        segments: const [
          MinutesSegment(text: '接口没有联调环境', start: Duration.zero),
        ],
        restore: {
          'format': 'koe-material-pack',
          'version': 2,
          'exportedAt': '2026-11-03T00:00:00.000',
          'material': {
            'contentHash': 'a' * 64,
            'title': '导入会议',
            'source': 'localImport',
          },
          'transcript': {'text': '接口没有联调环境'},
          'audio': {'included': false},
          'minutes': {
            'current': _snapshot('当前纪要'),
            'history': [_snapshot('之前的纪要')],
          },
        },
      ),
    );
    final controller = RecorderController(
      loadPersistedState: false,
      minutesStore: store,
      phoneRecordingEnabled: false,
      topicsEnabled: false,
    );
    addTearDown(controller.dispose);
    await controller.waitForMinutesDocuments();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(
          home: MinutesDocumentScreen(documentId: 'pack-example'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('包内纪要'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('包内纪要'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前纪要'), findsWidgets);
    expect(find.textContaining('先完成联调'), findsOneWidget);
    expect(find.textContaining('缺少联调环境'), findsOneWidget);
    expect(find.textContaining('本场指接口联合调试'), findsOneWidget);
    expect(find.textContaining('联调：已加入词表'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('查看纪要历史（1）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('查看纪要历史（1）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('之前的纪要'), findsWidgets);
    expect(find.textContaining('接口没有联调环境'), findsWidgets);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
