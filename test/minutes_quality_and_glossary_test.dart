import 'dart:convert';
import 'dart:io';

import 'package:koe/ai/engine_config.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

class _FakeAnalysisService implements AnalysisService {
  _FakeAnalysisService(this.handler);
  final Future<String> Function({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
  })
  handler;

  final List<(String source, String instruction)> calls = [];

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) {
    calls.add((source, instruction));
    return handler(
      model: model,
      apiKey: apiKey,
      source: source,
      instruction: instruction,
    );
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('koe_491_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    AppSettingsStore.resetForTesting();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'vocabulary suggestions extract invitees, speaker aliases, manual edits, and meeting title, and inject into analysisNotesFor',
    () async {
      final wav = File('${tempDir.path}/take_vocab.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);

      await controller.library.upsert(
        RecordingAsset(
          path: wav.path,
          displayName: 'Koe 架构评审 10-24 14:00',
          source: RecordingSource.phone,
          recordedAt: DateTime(2026, 10, 24, 14),
          importedAt: DateTime(2026, 10, 24, 14, 30),
          meeting: const RecordingMeeting(
            title: 'Sherpa 离线管线对齐',
            participants: ['李四', '王五'],
          ),
        ),
      );
      controller.rememberTranscript(
        wav.path,
        '说话人 1：今天先讨论声网模型的准确率。\n说话人 2：好的。',
      );
      await controller.renameTranscriptSpeaker(wav.path, '1', '赵六');
      await controller.saveManualTranscript(
        wav.path,
        '说话人 1：今天先讨论声纹模型的准确率。\n说话人 2：好的。',
      );

      final ref = RecordingReference(path: wav.path);
      final suggestions = controller.suggestVocabularyFor(ref);
      expect(
        suggestions,
        containsAll(<String>['李四', '王五', '赵六', 'Sherpa', '声纹模型']),
      );

      await controller.addVocabularyTerm('声纹模型');
      await controller.addVocabularyTerm('Sherpa');
      expect(controller.vocabulary, ['声纹模型', 'Sherpa']);
      expect(
        controller.suggestVocabularyFor(ref),
        isNot(contains('声纹模型')),
      );

      final notes = controller.analysisNotesFor(ref);
      expect(notes, contains('个人词汇表（专有名词、人名、术语，优先采用正确写法）：声纹模型、Sherpa'));
    },
  );

  test(
    'draft minutes auto-upgrade to formal minutes on transcription completion, preserve user edits, and support version history restore',
    () async {
      final wav1 = File('${tempDir.path}/draft_auto.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final wav2 = File('${tempDir.path}/draft_edited.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));

      final fakeService = _FakeAnalysisService(({
        required model,
        required apiKey,
        required source,
        required instruction,
      }) async {
        final isDraftInput = source.contains('实时识别草稿');
        return jsonEncode({
          'title': isDraftInput ? '草稿会议主题' : '正式会议主题',
          'overview': isDraftInput ? '来自实时草稿的概览' : '来自正式转写的概览',
          'topics': [
            {
              'text': isDraftInput ? '草稿要点' : '正式要点',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': <Object>[],
          'questions': <Object>[],
        });
      });

      final analysis = RecordingAnalysis(service: fakeService, inMemory: true);
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        analysisController: analysis,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);

      await controller.setQwenConfig(
        const EngineConfig(apiKey: 'sk-test-qwen'),
      );
      await controller.library.upsert(
        RecordingAsset(
          path: wav1.path,
          displayName: '自动替换测试',
          source: RecordingSource.phone,
          recordedAt: DateTime(2026, 10, 24, 10),
          importedAt: DateTime(2026, 10, 24, 10, 10),
        ),
      );
      await controller.library.upsert(
        RecordingAsset(
          path: wav2.path,
          displayName: '手改保护测试',
          source: RecordingSource.phone,
          recordedAt: DateTime(2026, 10, 24, 11),
          importedAt: DateTime(2026, 10, 24, 11, 10),
        ),
      );

      // Case 1: unedited draft is automatically replaced by formal minutes.
      final ref1 = RecordingReference(path: wav1.path);
      final slot1 = '${controller.analysisKey(ref1)}/minutes';
      await controller.generateDraftMinutes(
        ref1,
        liveText: '说话人 1：这是实时识别草稿内容。',
      );
      expect(analysis.results[slot1]?.isDraft, isTrue);
      expect(
        MeetingMinutes.parse(analysis.results[slot1]!.text, 1).title,
        '草稿会议主题',
      );

      controller.rememberTranscript(
        wav1.path,
        '说话人 1：这是正式转写完成后的完整内容。',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(analysis.results[slot1]?.isDraft, isFalse);
      expect(
        MeetingMinutes.parse(analysis.results[slot1]!.text, 1).title,
        '正式会议主题',
      );
      expect(analysis.versionsFor(slot1), hasLength(1));
      expect(analysis.versionsFor(slot1).first.isDraft, isTrue);

      // Restore the draft version from history.
      await analysis.restoreVersion(slot1, 0);
      expect(analysis.results[slot1]?.isDraft, isTrue);
      expect(
        MeetingMinutes.parse(analysis.results[slot1]!.text, 1).title,
        '草稿会议主题',
      );

      // Case 2: user-edited draft is NOT overwritten when formal transcription finishes;
      // the formal version goes into versionHistory instead.
      final ref2 = RecordingReference(path: wav2.path);
      final slot2 = '${controller.analysisKey(ref2)}/minutes';
      await controller.generateDraftMinutes(
        ref2,
        liveText: '说话人 1：第二段实时识别草稿。',
      );
      final initialDraft = analysis.results[slot2]!;
      final userEditedJson = validateMinutes(
        const MeetingMinutes(
          title: '用户手动定稿标题',
          overview: '用户手改概览',
          topics: [
            MinuteItem('用户手改要点', ['S1']),
          ],
          decisions: [],
          actions: [],
          questions: [],
        ).encode(),
        initialDraft.sources,
      );
      await analysis.editResult(slot2, initialDraft, userEditedJson);
      expect(analysis.results[slot2]!.editedAt, isNotNull);

      controller.rememberTranscript(
        wav2.path,
        '说话人 1：第二段正式转写完成后的完整内容。',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // User edit stays active!
      expect(
        MeetingMinutes.parse(analysis.results[slot2]!.text, 1).title,
        '用户手动定稿标题',
      );
      // Both original draft and newly generated formal minutes are in versionHistory.
      final versions2 = analysis.versionsFor(slot2);
      expect(versions2, hasLength(2));
      expect(
        MeetingMinutes.parse(versions2.last.text, 1).title,
        '正式会议主题',
      );
    },
  );

  test(
    'reviewItems are capped at 8, revised with user answers, and keep valid [S#] citations',
    () async {
      final wav = File('${tempDir.path}/review_items.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));

      final fakeService = _FakeAnalysisService(({
        required model,
        required apiKey,
        required source,
        required instruction,
      }) async {
        if (instruction.contains('用户确认回答')) {
          expect(instruction, contains('负责人确认是陈工'));
          return jsonEncode({
            'title': '架构升级纪要',
            'overview': '已根据确认回答更新负责人',
            'topics': [
              {
                'text': '讨论 Sherpa 离线推理性能',
                'sources': ['S1'],
              },
            ],
            'decisions': <Object>[],
            'actions': [
              {
                'text': '压测 Sherpa 内存占用',
                'owner': '陈工',
                'due': '周五',
                'sources': ['S1'],
              },
            ],
            'questions': <Object>[],
            'reviewItems': ['上线窗口是本周日还是下周一？'],
          });
        }
        return jsonEncode({
          'title': '架构升级纪要',
          'overview': '初版纪要',
          'topics': [
            {
              'text': '讨论离线推理性能',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': [
            {
              'text': '压测内存占用',
              'owner': '未提及',
              'due': '周五',
              'sources': ['S1'],
            },
          ],
          'questions': <Object>[],
          'reviewItems': [
            '压测内存占用的具体负责人是谁？',
            '上线窗口是本周日还是下周一？',
            for (var i = 3; i <= 10; i++) '额外问题 $i',
          ],
        });
      });

      final analysis = RecordingAnalysis(service: fakeService, inMemory: true);
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        analysisController: analysis,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);

      await controller.setQwenConfig(
        const EngineConfig(apiKey: 'sk-test-qwen'),
      );
      controller.rememberTranscript(
        wav.path,
        '说话人 1：周五前把离线推理内存占用压测完。',
      );
      final ref = RecordingReference(path: wav.path);
      final slot = '${controller.analysisKey(ref)}/minutes';

      await analysis.run(
        recording: controller.analysisKey(ref),
        source: controller.recordingView(ref).text,
        apiKey: controller.analysisApiKey,
        custom: true,
        templateId: minutesTemplateId,
        resultSlot: 'minutes',
        instruction: buildMeetingMinutesPrompt(),
        validateResult: validateMinutes,
        currentSource: () => controller.recordingView(ref).text,
      );

      final initial = MeetingMinutes.parse(analysis.results[slot]!.text, 1);
      expect(initial.reviewItems, hasLength(8));
      expect(initial.reviewItems.first, '压测内存占用的具体负责人是谁？');

      await controller.reviseMinutesWithReviewAnswers(ref, {
        '压测内存占用的具体负责人是谁？': '负责人确认是陈工',
      });

      final revised = MeetingMinutes.parse(analysis.results[slot]!.text, 1);
      expect(revised.actions.single.owner, '陈工');
      expect(revised.actions.single.sources, ['S1']);
      expect(revised.reviewItems, ['上线窗口是本周日还是下周一？']);
      expect(analysis.versionsFor(slot), hasLength(1));
    },
  );

  test(
    'AI speaker naming and transcript correction validate, apply to transcript + minutes, add to vocabulary, and revert',
    () async {
      final wav = File('${tempDir.path}/speaker_and_correction.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));

      final fakeService = _FakeAnalysisService(({
        required model,
        required apiKey,
        required source,
        required instruction,
      }) async {
        if (instruction.contains('推测以下未命名说话人的真实姓名')) {
          return jsonEncode({
            'suggestions': [
              {
                'speakerId': '1',
                'suggestedName': '林总',
                'confidence': 'high',
                'reason': '在开场自称林总并分配任务',
                'evidenceQuote': '我是林总，我们开始吧',
              },
              {
                'speakerId': '99',
                'suggestedName': '不存在的人',
                'confidence': 'low',
                'reason': '无效编号应被过滤',
              },
            ],
          });
        }
        if (instruction.contains('疑似语音识别听错的同音词')) {
          return jsonEncode({
            'corrections': [
              {
                'wrong': '千问三点八',
                'right': 'Qwen3.8',
                'reason': '模型标准名称为 Qwen3.8',
                'contextQuote': '先用千问三点八跑一次',
              },
              {
                'wrong': '原文不存在的词',
                'right': '某词',
                'reason': '应被过滤',
              },
            ],
          });
        }
        return jsonEncode({
          'title': '纪要标题',
          'overview': '说话人 1 安排了测试任务',
          'topics': [
            {
              'text': '说话人 1 提出先用千问三点八跑一次',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': [
            {
              'text': '验证接口响应',
              'owner': '说话人 1',
              'due': '明天',
              'sources': ['S1'],
            },
          ],
          'questions': <Object>[],
        });
      });

      final analysis = RecordingAnalysis(service: fakeService, inMemory: true);
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        analysisController: analysis,
        contextAnalysisService: fakeService,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);

      await controller.setQwenConfig(
        const EngineConfig(apiKey: 'sk-test-qwen'),
      );
      controller.rememberTranscript(
        wav.path,
        '说话人 1：我是林总，我们开始吧，先用千问三点八跑一次。\n说话人 2：收到。',
        segments: const [
          TranscriptSegment(
            text: '我是林总，我们开始吧，先用千问三点八跑一次。',
            start: Duration.zero,
            end: Duration(seconds: 4),
            speaker: '1',
            speakerChanged: true,
          ),
          TranscriptSegment(
            text: '收到。',
            start: Duration(seconds: 4),
            end: Duration(seconds: 6),
            speaker: '2',
            speakerChanged: true,
          ),
        ],
      );
      final ref = RecordingReference(path: wav.path);
      final slot = '${controller.analysisKey(ref)}/minutes';

      await analysis.run(
        recording: controller.analysisKey(ref),
        source: controller.recordingView(ref).text,
        apiKey: controller.analysisApiKey,
        custom: true,
        templateId: minutesTemplateId,
        resultSlot: 'minutes',
        instruction: buildMeetingMinutesPrompt(),
        validateResult: validateMinutes,
        currentSource: () => controller.recordingView(ref).text,
      );

      // 1. AI speaker naming suggestion & apply.
      final speakerSuggestions = await controller.suggestSpeakerNames(ref);
      expect(speakerSuggestions, hasLength(1));
      expect(speakerSuggestions.single.speakerId, '1');
      expect(speakerSuggestions.single.suggestedName, '林总');

      await controller.applySpeakerNameSuggestion(
        ref,
        speakerSuggestions.single,
      );
      expect(controller.speakerAliasesForPath(wav.path)['1'], '林总');
      expect(controller.transcriptForPath(wav.path), contains('林总：'));
      final updatedMinutes = MeetingMinutes.parse(
        analysis.results[slot]!.text,
        1,
      );
      expect(updatedMinutes.overview, '林总 安排了测试任务');
      expect(updatedMinutes.actions.single.owner, '林总');

      // 2. AI transcript correction suggestion, accept + add to vocabulary, and revert.
      final corrections = await controller.suggestTranscriptCorrections(ref);
      expect(corrections, hasLength(1));
      expect(corrections.single.wrong, '千问三点八');
      expect(corrections.single.right, 'Qwen3.8');

      await controller.acceptTranscriptCorrection(
        ref,
        corrections.single,
        addToVocabulary: true,
      );
      expect(controller.transcriptForPath(wav.path), contains('Qwen3.8'));
      expect(controller.vocabulary, contains('Qwen3.8'));
      expect(controller.canRevertTranscriptCorrection(ref), isTrue);

      await controller.revertTranscriptCorrection(ref);
      expect(controller.transcriptForPath(wav.path), contains('千问三点八'));
      expect(controller.canRevertTranscriptCorrection(ref), isFalse);
    },
  );

  testWidgets(
    'MinutesPanel renders review items, version history restore, speaker naming, and transcript corrections',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fakeService = _FakeAnalysisService(({
        required model,
        required apiKey,
        required source,
        required instruction,
      }) async {
        if (instruction.contains('用户确认回答')) {
          return jsonEncode({
            'title': '产品周会（已修订）',
            'overview': '已确认发布负责人为张工',
            'topics': [
              {
                'text': '确认周五上线',
                'sources': ['S1'],
              },
            ],
            'decisions': <Object>[],
            'actions': [
              {
                'text': '执行上线发布',
                'owner': '张工',
                'due': '周五',
                'sources': ['S1'],
              },
            ],
            'questions': <Object>[],
            'reviewItems': <Object>[],
          });
        }
        return jsonEncode({
          'title': '产品周会（初稿）',
          'overview': '讨论周五上线安排',
          'topics': [
            {
              'text': '讨论周五上线',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': [
            {
              'text': '执行上线发布',
              'owner': '未提及',
              'due': '周五',
              'sources': ['S1'],
            },
          ],
          'questions': <Object>[],
          'reviewItems': ['谁负责执行周五上线发布？'],
        });
      });

      final analysis = RecordingAnalysis(service: fakeService, inMemory: true);
      final controller = _Panel5BTestController(
        analysisController: analysis,
        contextAnalysisService: fakeService,
      );
      addTearDown(controller.dispose);

      const ref = RecordingReference(path: '/panel_5b.wav');

      await tester.pumpWidget(
        MaterialApp(
          home: MinutesPanel(controller: controller, reference: ref),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('生成纪要'));
      await tester.pumpAndSettle();

      expect(find.text('产品周会（初稿）'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('minutes-review-items-card')),
        findsOneWidget,
      );
      expect(find.text('• 谁负责执行周五上线发布？'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('minutes-review-items-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('minutes-review-items-button')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('minutes-review-answer-0')),
        '张工负责',
      );
      await tester.tap(find.byKey(const ValueKey('minutes-review-submit')));
      await tester.pumpAndSettle();

      expect(find.text('产品周会（已修订）'), findsOneWidget);
      expect(find.text('负责人：张工 · 期限：周五'), findsOneWidget);

      // Open version history and restore the initial version.
      await tester.ensureVisible(
        find.byKey(const ValueKey('minutes-version-history-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('minutes-version-history-button')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('minutes-restore-version-0')),
      );
      await tester.pumpAndSettle();

      expect(find.text('产品周会（初稿）'), findsOneWidget);
    },
  );
}

class _Panel5BTestController extends RecorderController {
  _Panel5BTestController({
    required super.analysisController,
    required super.contextAnalysisService,
  }) : super(loadPersistedState: false);

  @override
  String get analysisApiKey => 'sk-test-qwen';

  @override
  String analysisKey(RecordingReference ref) => 'path:/panel_5b.wav';

  @override
  RecordingViewData recordingView(RecordingReference ref) => RecordingViewData(
    reference: ref,
    title: '产品周会录音',
    text: '说话人 1：周五执行上线发布。',
    path: '/panel_5b.wav',
  );
}
