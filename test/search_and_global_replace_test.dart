import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'support/settings_completion.dart';

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

  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) => handler(
    model: model,
    apiKey: apiKey,
    source: source,
    instruction: instruction,
  );

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('koe_493_test_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    AppSettingsStore.resetForTesting();
    await AppSettingsStore.load();
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'full-text search matches corrected transcript text, renamed speakers, structured minutes, and user notes without matching overwritten raw words (#493 / S33 / #235)',
    () async {
      final wav = File('${tempDir.path}/search_take.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        transcriptPersister: ({bool strict = false}) async {},
        analysisController: RecordingAnalysis(inMemory: true),
      );
      addTearDown(controller.dispose);

      await controller.library.upsert(
        RecordingAsset(
          path: wav.path,
          displayName: '架构对齐会',
          source: RecordingSource.phone,
          recordedAt: DateTime(2026, 10, 24, 14),
          importedAt: DateTime(2026, 10, 24, 14, 10),
          meeting: const RecordingMeeting(
            title: '鸿蒙与桌面端评审',
            participants: ['陈工'],
          ),
        ),
      );

      // Initial provider transcript has typo "声网模型".
      controller.rememberTranscript(
        wav.path,
        '说话人 1：我们先看声网模型的延迟。\n说话人 2：同意。',
        segments: const [
          TranscriptSegment(
            start: Duration(seconds: 2),
            end: Duration(seconds: 6),
            text: '我们先看声网模型的延迟。',
            speaker: '1',
          ),
          TranscriptSegment(
            start: Duration(seconds: 7),
            end: Duration(seconds: 10),
            text: '同意。',
            speaker: '2',
          ),
        ],
      );
      await controller.renameTranscriptSpeaker(wav.path, '1', '林工');
      // User manually edits transcript: "声网模型" -> "声纹模型".
      await controller.saveManualTranscript(
        wav.path,
        '说话人 1：我们先看声纹模型的延迟。\n说话人 2：同意。',
      );

      final ref = RecordingReference(path: wav.path);
      final recKey = controller.analysisKey(ref);
      controller.analysis.results['$recKey/minutes'] = AnalysisResult(
        text: jsonEncode({
          'title': '声纹延迟专项纪要',
          'overview': '讨论端侧推理吞吐指标。',
          'topics': [
            {
              'text': '端侧吞吐目标为 3x 实时率',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': [
            {
              'text': '提交基准测试报告',
              'owner': '林工',
              'due': '下周二',
              'sources': ['S1'],
            },
          ],
          'questions': <Object>[],
          'reviewItems': ['确认是否包含量化模型 [S1]'],
        }),
        sourceHash: analysisFingerprint(controller.recordingView(ref).text),
        model: 'qwen-plus',
        instruction: 'prompt',
        sources: const ['林工：我们先看声纹模型的延迟。'],
        createdAt: DateTime.utc(2026, 10, 24, 14, 20),
      );

      await controller.addBookmark(
        ref,
        position: const Duration(seconds: 3),
        note: '重点核查内存峰值 180MB',
      );

      // 1. Overwritten typo "声网模型" must NOT match (#235).
      expect(controller.matchesRecordingSearch(ref, '声网模型'), isFalse);
      expect(controller.searchRecordingHit(ref, '声网模型'), isNull);

      // 2. Corrected word "声纹模型" MUST match.
      final correctedHit = controller.searchRecordingHit(ref, '声纹模型');
      expect(correctedHit, isNotNull);
      expect(correctedHit!.snippet, contains('声纹模型'));

      // 3. Renamed speaker "林工" MUST still match even after manual edit.
      final speakerHit = controller.searchRecordingHit(ref, '林工');
      expect(speakerHit, isNotNull);
      expect(speakerHit!.snippet, contains('林工'));

      // 4. Structured minutes content ("吞吐目标", "基准测试报告", "量化模型") MUST match.
      final minutesHit = controller.searchRecordingHit(ref, '基准测试报告');
      expect(minutesHit, isNotNull);
      expect(minutesHit!.snippet, contains('基准测试报告'));
      expect(controller.matchesRecordingSearch(ref, '量化模型'), isTrue);

      // 5. User bookmark note ("内存峰值 180MB") and calendar meeting ("陈工") MUST match.
      final noteHit = controller.searchRecordingHit(ref, '内存峰值 180MB');
      expect(noteHit, isNotNull);
      expect(noteHit!.snippet, contains('内存峰值 180MB'));
      expect(controller.matchesRecordingSearch(ref, '陈工'), isTrue);
    },
  );

  test(
    'global term replacement updates transcript segments, structured minutes JSON (preserving [S#]), imported documents, and optionally adds to vocabulary (#493 / S34)',
    () async {
      final wav1 = File('${tempDir.path}/replace_1.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final wav2 = File('${tempDir.path}/replace_2.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        transcriptPersister: ({bool strict = false}) async {},
        analysisController: RecordingAnalysis(inMemory: true),
      );
      addTearDown(controller.dispose);

      for (final (wav, text) in [
        (wav1, '说话人 1：科音支持导出文档。\n说话人 2：科音还可以记待办。'),
        (wav2, '说话人 1：第二场会议也提到科音。'),
      ]) {
        await controller.library.upsert(
          RecordingAsset(
            path: wav.path,
            displayName: wav.uri.pathSegments.last,
            source: RecordingSource.phone,
            recordedAt: DateTime(2026, 10, 24, 15),
            importedAt: DateTime(2026, 10, 24, 15, 5),
          ),
        );
        controller.rememberTranscript(
          wav.path,
          text,
          segments: [
            TranscriptSegment(
              start: const Duration(seconds: 1),
              end: const Duration(seconds: 4),
              text: text.split('\n').first.replaceFirst('说话人 1：', ''),
              speaker: '1',
            ),
          ],
        );
      }

      final ref1 = RecordingReference(path: wav1.path);
      final key1 = controller.analysisKey(ref1);
      controller.analysis.results['$key1/minutes'] = AnalysisResult(
        text: jsonEncode({
          'title': '科音产品周会',
          'overview': '围绕科音桌面端体验展开。',
          'topics': [
            {
              'text': '科音导出 Word 与 PDF',
              'sources': ['S1'],
            },
          ],
          'decisions': [
            {
              'text': '科音默认使用千问模型',
              'sources': ['S1'],
            },
          ],
          'actions': [
            {
              'text': '完善科音说明书',
              'owner': '科音小组',
              'due': '周五',
              'sources': ['S1'],
            },
          ],
          'questions': <Object>[],
          'reviewItems': ['确认科音版本号 [S1]'],
        }),
        sourceHash: analysisFingerprint(controller.recordingView(ref1).text),
        model: 'qwen-plus',
        instruction: 'prompt',
        sources: const ['说话人 1：科音支持导出文档。'],
        createdAt: DateTime.utc(2026, 10, 24, 15, 10),
      );

      await controller.importMinutesText(
        '外部字幕.srt',
        '1\n00:00:01,000 --> 00:00:03,000\n林工：科音字幕导入测试\n',
      );

      // Execute global replacement across library: "科音" -> "Koe", with addToVocabulary: true.
      final report = await controller.replaceTermAcrossLibrary(
        '科音',
        'Koe',
        addToVocabulary: true,
      );

      expect(report.recordingsUpdated, 2);
      expect(report.minutesUpdated, 1);
      expect(report.documentsUpdated, 1);
      expect(report.addedToVocabulary, isTrue);
      expect(controller.vocabulary, contains('Koe'));

      // Verify transcript & segments in both recordings are updated and keep timestamps.
      expect(controller.transcriptForPath(wav1.path), contains('Koe支持导出文档'));
      expect(controller.transcriptForPath(wav1.path), isNot(contains('科音')));
      expect(
        controller.transcriptSegmentsForPath(wav1.path).first.text,
        'Koe支持导出文档。',
      );
      expect(
        controller.transcriptSegmentsForPath(wav1.path).first.start,
        const Duration(seconds: 1),
      );
      expect(controller.transcriptForPath(wav2.path), contains('第二场会议也提到Koe'));

      // Verify structured minutes JSON and [S#] citations are preserved and sourceHash stays fresh.
      final updatedResult = controller.analysis.results['$key1/minutes']!;
      final parsedMinutes = MeetingMinutes.parse(
        updatedResult.text,
        updatedResult.sources.length,
      );
      expect(parsedMinutes.title, 'Koe产品周会');
      expect(parsedMinutes.overview, '围绕Koe桌面端体验展开。');
      expect(parsedMinutes.topics.single.text, 'Koe导出 Word 与 PDF');
      expect(parsedMinutes.topics.single.sources, ['S1']);
      expect(parsedMinutes.actions.single.text, '完善Koe说明书');
      expect(parsedMinutes.actions.single.owner, 'Koe小组');
      expect(parsedMinutes.actions.single.sources, ['S1']);
      expect(parsedMinutes.reviewItems.single, '确认Koe版本号 [S1]');
      expect(updatedResult.sources.single, '说话人 1：Koe支持导出文档。');
      expect(
        updatedResult.sourceHash,
        analysisFingerprint(controller.recordingView(ref1).text),
      );

      // Verify imported document is also updated.
      expect(
        controller.minutesDocuments.single.segments.single.text,
        'Koe字幕导入测试',
      );

      // Verify that if minutes were already outdated (sourceHash mismatch) before
      // replacement, replacing a term preserves the outdated sourceHash rather
      // than falsely marking the minutes up-to-date.
      await controller.saveManualTranscript(
        wav1.path,
        '说话人 1：Koe支持导出文档，并补充了新的段落。',
      );
      final staleHashBefore = controller.analysis.results['$key1/minutes']!.sourceHash;
      expect(
        staleHashBefore,
        isNot(analysisFingerprint(controller.recordingView(ref1).text)),
      );
      await controller.replaceTermInRecording(ref1, '导出文档', '多格式导出');
      expect(
        controller.analysis.results['$key1/minutes']!.sourceHash,
        staleHashBefore,
      );

      // Verify that replacing transcript text invalidates any prior speaker-undo
      // snapshot so undoSpeakerEdit cannot erase the word replacement.
      controller.rememberTranscript(
        wav2.path,
        '说话人 1：第一句测试词。\n说话人 2：第二句测试词。',
        segments: const [
          TranscriptSegment(
            start: Duration.zero,
            end: Duration(seconds: 2),
            text: '第一句测试词。',
            speaker: '1',
          ),
          TranscriptSegment(
            start: Duration(seconds: 2),
            end: Duration(seconds: 4),
            text: '第二句测试词。',
            speaker: '2',
          ),
        ],
      );
      await controller.mergeTranscriptSpeakers(
        wav2.path,
        fromSpeakerId: '2',
        intoSpeakerId: '1',
      );
      expect(controller.speakerUndoLabel(wav2.path), isNotNull);
      await controller.replaceTermInTranscript(wav2.path, '测试词', '正式词');
      expect(controller.speakerUndoLabel(wav2.path), isNull);
      expect(await controller.undoSpeakerEdit(wav2.path), isFalse);
      expect(controller.transcriptForPath(wav2.path), contains('正式词'));
    },
  );

  test(
    'background minutes generation completion and failure update task status notice (#493 / S34)',
    () async {
      var shouldFail = false;
      final service = _FakeAnalysisService(({
        required model,
        required apiKey,
        required source,
        required instruction,
      }) async {
        if (shouldFail) throw const HttpException('network down');
        return jsonEncode({
          'title': '通知测试纪要',
          'overview': '整理成功。',
          'topics': [
            {
              'text': '完成提醒',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': <Object>[],
          'questions': <Object>[],
        });
      });

      final wav = File('${tempDir.path}/notice_take.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        transcriptPersister: ({bool strict = false}) async {},
        analysisController: RecordingAnalysis(service: service, inMemory: true),
      );
      addTearDown(controller.dispose);
      controller.analysis.model = 'qwen-plus';

      controller.rememberTranscript(wav.path, '说话人 1：测试后台整理完成通知。');
      final ref = RecordingReference(path: wav.path);
      final recKey = controller.analysisKey(ref);

      await controller.analysis.run(
        recording: recKey,
        custom: true,
        apiKey: 'sk-test',
        source: controller.recordingView(ref).text,
        currentSource: () => controller.recordingView(ref).text,
        instruction: defaultMinutesPrompt,
        templateId: minutesTemplateId,
        resultSlot: 'minutes',
        validateResult: validateMinutes,
      );

      expect(controller.lastTaskNotice, isNotNull);
      expect(controller.lastTaskNotice!.kind, 'minutes');
      expect(controller.lastTaskNotice!.succeeded, isTrue);
      expect(controller.lastTaskNotice!.message, contains('通知测试纪要'));

      // Now trigger a failure and verify failure notice.
      shouldFail = true;
      await controller.analysis.run(
        recording: recKey,
        custom: true,
        apiKey: 'sk-test',
        source: '说话人 1：新内容触发重新生成失败。',
        currentSource: () => '说话人 1：新内容触发重新生成失败。',
        instruction: defaultMinutesPrompt,
        templateId: minutesTemplateId,
        resultSlot: 'minutes',
        validateResult: validateMinutes,
        confirmedRestart: true,
      );

      expect(controller.lastTaskNotice, isNotNull);
      expect(controller.lastTaskNotice!.kind, 'minutes');
      expect(controller.lastTaskNotice!.succeeded, isFalse);
    },
  );

  testWidgets(
    'MinutesPanel global replace dialog replaces term and adds to vocabulary',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final wav = File('${tempDir.path}/panel_replace.wav')
        ..writeAsBytesSync(List<int>.filled(16000, 0));
      final controller = RecorderController(
        loadPersistedState: false,
        libraryDirectory: tempDir,
        transcriptPersister: ({bool strict = false}) async {},
        analysisController: RecordingAnalysis(inMemory: true),
      );
      addTearDown(controller.dispose);

      await controller.library.upsert(
        RecordingAsset(
          path: wav.path,
          displayName: '替换弹窗测试',
          source: RecordingSource.phone,
          recordedAt: DateTime(2026, 10, 24, 16),
          importedAt: DateTime(2026, 10, 24, 16, 5),
        ),
      );
      controller.rememberTranscript(wav.path, '说话人 1：讨论拾音器的降噪表现。');
      final ref = RecordingReference(path: wav.path);
      final recKey = controller.analysisKey(ref);
      controller.analysis.results['$recKey/minutes'] = AnalysisResult(
        text: jsonEncode({
          'title': '拾音器评测',
          'overview': '测试拾音器固件。',
          'topics': [
            {
              'text': '拾音器续航',
              'sources': ['S1'],
            },
          ],
          'decisions': <Object>[],
          'actions': <Object>[],
          'questions': <Object>[],
        }),
        sourceHash: analysisFingerprint(controller.recordingView(ref).text),
        model: 'qwen-plus',
        instruction: 'prompt',
        sources: const ['说话人 1：讨论拾音器的降噪表现。'],
        createdAt: DateTime.utc(2026, 10, 24, 16, 10),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 820,
              child: MinutesPanel(controller: controller, reference: ref),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final replaceBtn = find.byKey(const Key('minutes-replace-term-button'));
      expect(replaceBtn, findsOneWidget);
      await tester.ensureVisible(replaceBtn);
      await tester.tap(replaceBtn);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('minutes-replace-from-input')),
        '拾音器',
      );
      await tester.enterText(
        find.byKey(const Key('minutes-replace-to-input')),
        '录音豆',
      );
      await tester.tap(find.byKey(const Key('minutes-replace-submit')));
      await tester.pumpAndSettle();
      await waitForSettings(tester, controller);
      await tester.pumpAndSettle();

      expect(controller.transcriptForPath(wav.path), contains('录音豆'));
      expect(controller.vocabulary, contains('录音豆'));
      expect(find.text('录音豆评测'), findsOneWidget);
    },
  );
}
