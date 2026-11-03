import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/screens/settings_screen.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:provider/provider.dart';

void main() {
  test(
    'built-in meeting templates (one-on-one, interview, lecture, brainstorm) '
    'build localized prompts (zh/en/ja) and validate custom sections with [S#] citations',
    () {
      expect(
        builtInMeetingTemplates.map((t) => t.id).toList(),
        equals([
          minutesTemplateId,
          minutesOneOnOneTemplateId,
          minutesInterviewTemplateId,
          minutesLectureTemplateId,
          minutesBrainstormTemplateId,
        ]),
      );

      final oneOnOneZh = buildMeetingMinutesPrompt(
        templateId: minutesOneOnOneTemplateId,
        language: 'zh',
      );
      expect(oneOnOneZh, contains('一对一'));
      expect(oneOnOneZh, contains('近况与进展'));
      expect(oneOnOneZh, contains('反馈'));
      expect(oneOnOneZh, contains('需要的支持'));

      final interviewEn = buildMeetingMinutesPrompt(
        templateId: minutesInterviewTemplateId,
        language: 'en',
      );
      expect(interviewEn, contains('Background'));
      expect(interviewEn, contains('Key quotes'));
      expect(interviewEn, contains('Insights & opportunities'));

      final lectureJa = buildMeetingMinutesPrompt(
        templateId: minutesLectureTemplateId,
        language: 'ja',
      );
      expect(lectureJa, contains('重要概念'));
      expect(lectureJa, contains('質疑応答'));

      final brainstormZh = buildMeetingMinutesPrompt(
        templateId: minutesBrainstormTemplateId,
        language: 'zh',
      );
      expect(brainstormZh, contains('点子清单'));
      expect(brainstormZh, contains('评估与取舍'));

      final fencedJson = '''```json
{
  "title": "1:1 复盘",
  "overview": "讨论本季度进展与下阶段支持。",
  "topics": [{"text": "季度目标进展", "sources": ["S1"]}],
  "decisions": [{"text": "下周调整优先级", "sources": ["S1"]}],
  "actions": [{"text": "整理排期表", "owner": "张三", "due": "周五", "sources": ["S1"]}],
  "questions": [],
  "custom": [
    {
      "title": "近况与进展",
      "items": [{"text": "核心模块已完成联调", "sources": ["S1"]}]
    },
    {
      "title": "需要的支持",
      "items": [{"text": "需要增加一台测试机", "sources": ["S1"]}]
    }
  ]
}
```''';

      final validated = validateMinutes(fencedJson, const ['[S1] 原始转写片段']);
      final parsed = MeetingMinutes.parse(validated, 1);
      expect(parsed.title, '1:1 复盘');
      expect(parsed.custom, hasLength(2));
      expect(parsed.custom.first.title, '近况与进展');
      expect(parsed.custom.first.items.single.text, '核心模块已完成联调');
      expect(parsed.custom.first.items.single.sources, ['S1']);
      expect(
        parsed.sections.map((s) => s.$1),
        containsAll(['议题', '近况与进展', '需要的支持', '决策', '待办', '未决问题']),
      );

      final invalidCustomCitation = jsonEncode({
        'title': '访谈',
        'overview': '概览',
        'topics': [],
        'decisions': [],
        'actions': [],
        'questions': [],
        'custom': [
          {
            'title': '重点引述',
            'items': [
              {
                'text': '虚构引用',
                'sources': ['S2'],
              },
            ],
          },
        ],
      });
      expect(
        () => validateMinutes(invalidCustomCitation, const ['only one source']),
        throwsFormatException,
      );
    },
  );

  test(
    'OpenAI-compatible / Ollama service normalizes URLs, works keyless on '
    'localhost, extracts JSON from markdown fences, and sends only text',
    () async {
      expect(
        normalizeOpenAiCompatibleBaseUrl(
          'http://localhost:11434/v1/chat/completions/',
        ),
        'http://localhost:11434/v1',
      );
      expect(
        normalizeOpenAiCompatibleBaseUrl('openrouter.ai/api/v1/'),
        'https://openrouter.ai/api/v1',
      );

      http.Request? capturedRequest;
      final service = OpenAiCompatibleAnalysisService(
        baseUrl: () => 'http://localhost:11434/v1/chat/completions/',
        client: MockClient((request) async {
          capturedRequest = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'content':
                        'Here is the JSON:\n```json\n{"title":"本地整理","overview":"完成","topics":[],"decisions":[],"actions":[],"questions":[]}\n```',
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(service.dispose);

      final output = await service.generate(
        model: 'qwen2.5:7b',
        apiKey: '',
        source: '[S1] 发言人 1：今天确认本地 Ollama 整理纪要。',
        instruction: buildMeetingMinutesPrompt(
          templateId: minutesTemplateId,
          language: 'zh',
        ),
        abort: Completer<void>().future,
      );

      expect(capturedRequest, isNotNull);
      expect(
        capturedRequest!.url.toString(),
        'http://localhost:11434/v1/chat/completions',
      );
      expect(capturedRequest!.headers.containsKey('Authorization'), isFalse);
      final bodyText = utf8.decode(capturedRequest!.bodyBytes);
      expect(bodyText, contains('今天确认本地 Ollama 整理纪要'));
      expect(bodyText, isNot(contains('RIFF')));
      expect(bodyText, isNot(contains('.wav')));

      final parsed = MeetingMinutes.parse(
        validateMinutes(output, const ['s1']),
        1,
      );
      expect(parsed.title, '本地整理');
    },
  );

  test(
    'analysisBackend none makes zero HTTP requests and skips LLM calls cleanly',
    () async {
      var httpCalls = 0;
      final wire = MockClient((request) async {
        httpCalls++;
        return http.Response('{}', 500);
      });
      final controller = RecorderController(loadPersistedState: false);
      addTearDown(controller.dispose);
      await controller.setQwenConfig(const EngineConfig(apiKey: 'qwen-key'));
      await controller.setAnalysisBackend(AnalysisBackendKind.none);

      expect(controller.analysisBackend, AnalysisBackendKind.none);
      expect(controller.analysisConfigured, isFalse);
      expect(controller.analysisApiKey, isEmpty);

      final manager = RecordingAnalysis(
        inMemory: true,
        service: QwenAnalysisService(client: wire),
      );
      addTearDown(manager.dispose);
      await manager.run(
        recording: 'file:1',
        source: '测试转写文本',
        apiKey: controller.analysisApiKey,
        templateId: summaryTemplateId,
        currentSource: () => '测试转写文本',
      );
      expect(httpCalls, 0);
      expect(manager.results, isEmpty);
    },
  );

  testWidgets(
    'SettingsScreen switches analysis backend between Qwen, OpenAI-compatible presets, and None',
    (tester) async {
      AppSettingsStore.resetForTesting();
      final controller = RecorderController(loadPersistedState: false);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: controller,
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final noneChip = find.byKey(const ValueKey('analysis-backend-none'));
      await tester.scrollUntilVisible(
        noneChip,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(noneChip);
      await tester.pumpAndSettle();
      expect(controller.analysisBackend, AnalysisBackendKind.none);

      final openAiChip = find.byKey(
        const ValueKey('analysis-backend-openaiCompatible'),
      );
      await tester.tap(openAiChip);
      await tester.pumpAndSettle();
      expect(controller.analysisBackend, AnalysisBackendKind.openaiCompatible);

      await tester.ensureVisible(
        find.byKey(const ValueKey('analysis-preset-ollama')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('analysis-preset-ollama')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('analysis-openai-model')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('analysis-openai-model')),
        'qwen2.5:7b',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('analysis-openai-save')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('analysis-openai-save')));
      await tester.pumpAndSettle();

      expect(
        controller.analysisOpenAiConfig.baseUrl,
        'http://localhost:11434/v1',
      );
      expect(controller.analysisOpenAiConfig.model, 'qwen2.5:7b');
      expect(controller.analysisConfigured, isTrue);
      expect(controller.analysisApiKey, isNotEmpty);
    },
  );

  testWidgets(
    'MinutesPanel selects meeting template and language, generates custom sections, and edits them',
    (tester) async {
      String? capturedInstruction;
      final service = _MinutesTestService((instruction) {
        capturedInstruction = instruction;
        return jsonEncode({
          'schemaVersion': 2,
          'title': '1:1 沟通纪要',
          'overview': '回顾本周工作与支持需求',
          'topics': [
            {
              'text': '版本进度同步',
              'sources': ['S1'],
            },
          ],
          'decisions': [],
          'actions': [],
          'questions': [],
          'custom': [
            {
              'title': '近况与进展',
              'items': [
                {
                  'text': 'Mac 端验收完成',
                  'sources': ['S1'],
                },
              ],
            },
          ],
        });
      });
      final manager = RecordingAnalysis(inMemory: true, service: service);
      final controller = _MinutesTestController(manager);
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

      await tester.tap(
        find.byKey(const ValueKey('minutes-template-minutes-one-on-one')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('minutes-language-en')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('生成纪要'));
      await tester.pumpAndSettle();

      expect(capturedInstruction, isNotNull);
      expect(capturedInstruction, contains('One-on-one'));
      await tester.scrollUntilVisible(
        find.text('Mac 端验收完成'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('近况与进展'), findsOneWidget);
      expect(find.text('Mac 端验收完成'), findsOneWidget);
    },
  );
}

class _MinutesTestService implements AnalysisService {
  _MinutesTestService(this._onGenerate);
  final String Function(String instruction) _onGenerate;

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async => _onGenerate(instruction);

  @override
  void dispose() {}
}

class _MinutesTestController extends RecorderController {
  _MinutesTestController(RecordingAnalysis manager)
    : super(loadPersistedState: false, analysisController: manager);

  @override
  String get analysisApiKey => 'test-key';

  @override
  String analysisKey(RecordingReference ref) => 'file:1';

  @override
  RecordingViewData recordingView(RecordingReference ref) => RecordingViewData(
    reference: ref,
    title: '1:1 录音',
    text: '今天聊一下 Mac 端验收完成情况和后续支持。',
    path: '/1.wav',
  );
}
