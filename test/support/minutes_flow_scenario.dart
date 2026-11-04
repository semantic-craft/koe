import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/apple_speech.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/platform/credential_store.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/transcript_store.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'wav_fixture.dart';

const dictationLines = [
  '今天先核对资料，因为旧版本的地址可能有误。',
  '比如上次邮件里的门牌号写错了。',
  '原先说周五提交，改为下周一提交。',
  '不采用自动发布，上线日期还没确定。',
  '请不要把暂定计划写成已经完成。',
];
String get dictationInputSha => analysisFingerprint(dictationTranscript);

const dictationTitle = '个人口述：资料核对与提交计划';
const dictationTranscript =
    '今天先核对资料，因为旧版本的地址可能有误。\n'
    '比如上次邮件里的门牌号写错了。\n'
    '原先说周五提交，改为下周一提交。\n'
    '不采用自动发布，上线日期还没确定。\n'
    '请不要把暂定计划写成已经完成。';

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Directory directory;
  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
  @override
  Future<String?> getTemporaryPath() async => directory.path;
}

class _Speech extends AppleSpeechService {
  int calls = 0;
  @override
  Future<AppleSpeechCapabilities> capabilities({
    String? sourceLanguage,
    String? targetLanguage,
  }) async => const AppleSpeechCapabilities(
    supported: true,
    speechStatus: SpeechResourceStatus.ready,
    translationStatus: SpeechResourceStatus.ready,
    suggestedSourceLanguage: 'zh-CN',
  );
  @override
  Future<SttResult> transcribePath(
    String path, {
    required String sourceLanguage,
    SttFileProgressCallback? onProgress,
  }) async {
    calls++;
    return SttResult(
      text: dictationTranscript,
      sourcePath: path,
      language: sourceLanguage,
    );
  }
}

class _Analysis implements AnalysisService {
  int minutesCalls = 0;
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    if (instruction.contains('从句段里找出承诺')) return '{"items":[],"updates":[]}';
    if (!instruction.contains('结构化会议纪要')) return '先核对地址，提交改为下周一，上线日期未定。';
    minutesCalls++;
    for (var i = 0; i < dictationLines.length; i++) {
      expect(source, contains('[S${i + 1}] ${dictationLines[i]}'));
    }
    return jsonEncode({
      'schemaVersion': 2,
      'title': dictationTitle,
      'overview': '先核对可能有误的地址，提交改为下周一。暂定计划尚未完成，上线日期未定。',
      'topics': [
        {
          'text': '核对资料的理由与例子',
          'summary': '旧地址可能有误，上次邮件曾写错门牌号。',
          'sources': ['S1', 'S2'],
          'points': [
            {
              'text': dictationLines[0],
              'sources': ['S1'],
            },
            {
              'text': dictationLines[1],
              'sources': ['S2'],
            },
          ],
        },
        {
          'text': '提交改口与发布边界',
          'summary': '提交从周五改为下周一，不采用自动发布。',
          'sources': ['S3', 'S4', 'S5'],
          'points': [
            {
              'text': dictationLines[2],
              'sources': ['S3'],
            },
            {
              'text': dictationLines[3],
              'sources': ['S4'],
            },
            {
              'text': '暂定计划不能写成已经完成。',
              'sources': ['S5'],
            },
          ],
        },
      ],
      'terms': [],
      'decisions': [],
      'actions': [],
      'questions': [
        {
          'text': '上线日期还没确定',
          'sources': ['S4'],
        },
      ],
      'reviewItems': [],
    });
  }

  @override
  void dispose() {}
}

Future<void> _until(
  bool Function() predicate, {
  String Function()? detail,
}) async {
  for (var i = 0; i < 600; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('自动纪要未达到持久化完成状态 ${detail?.call() ?? ''}');
}

Future<void> minutesFlowScenario(
  WidgetTester tester, {
  Future<void> Function(String)? screenshot,
}) async {
  final oldPaths = PathProviderPlatform.instance;
  late Directory directory;
  Directory? cleanupDirectory;
  final activeControllers = <RecorderController>[];
  late RecorderController first;
  late RecorderController restored;
  late RecordingReference reference;
  late Map<String, dynamic> saved;
  final speech = _Speech();
  final analysis = _Analysis();
  final qwen = QwenSttService();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(CredentialStore.channel, (call) async {
    if (call.method == 'mode') return 'isolated';
    if (call.method == 'read') return null;
    return null;
  });
  addTearDown(() async {
    for (final controller in activeControllers) {
      await controller.waitForOrganize();
      await controller.organizeStore.idle;
      controller.dispose();
    }
    final folder = cleanupDirectory;
    if (folder != null && await folder.exists()) {
      await folder.delete(recursive: true);
    }
    PathProviderPlatform.instance = oldPaths;
    messenger.setMockMethodCallHandler(CredentialStore.channel, null);
  });
  RecorderController build() => RecorderController(
    loadPersistedState: true,
    phoneRecordingEnabled: false,
    topicsEnabled: false,
    libraryDirectory: Directory('${directory.path}/imports'),
    appleSpeech: speech,
    qwenSpeech: qwen,
    analysisController: RecordingAnalysis(
      service: analysis,
      file: File('${directory.path}/analysis.json'),
    ),
    contextAnalysisService: analysis,
  );
  await tester.runAsync(() async {
    directory = await Directory.systemTemp.createTemp('koe-minutes-flow-');
    cleanupDirectory = directory;
    PathProviderPlatform.instance = _Paths(directory);
    AppSettingsStore.resetForTesting();
    first = build();
    activeControllers.add(first);
    await first.waitForOrganize();
    qwen.apiKeyOverride = 'synthetic-test-key';
    first.speechProvider = SttProvider.apple;
    first.appleSourceLanguage = 'zh-CN';
    await first.refreshAppleCapabilities();
    await first.setAutoOrganize(true);
    final input = File('${directory.path}/dictation.wav');
    await input.writeAsBytes(wavBytes(List.filled(16000, 128)));
    final imported = await first.importLocalAudio(input.path);
    reference = RecordingReference(
      path: imported.path,
      fileId: first.fileIdFromPath(imported.path),
    );
    await _until(
      () => first.organizeStatusFor(imported.path).stage == OrganizeStage.done,
      detail: () =>
          "${first.organizeStatusFor(imported.path).stage} ${first.organizeStatusFor(imported.path).message} ${first.analysis.errors}",
    );
    final result = first.currentMinutesFor(reference)!;
    saved = result.toJson();
    expect(result.sources.map((line) => line.trim()).toList(), dictationLines);
    final minutes = jsonDecode(result.text) as Map<String, dynamic>;
    expect(minutes['topics'], hasLength(2));
    expect(minutes['decisions'], isEmpty);
    expect(minutes['actions'], isEmpty);
    expect(result.text, contains('下周一'));
    expect(result.text, contains('不采用自动发布'));
    expect(result.text, contains('上线日期还没确定'));
    expect(
      await File('${directory.path}/analysis.json').readAsString(),
      contains('下周一'),
    );
    for (var i = 0; i < 600; i++) {
      final transcripts = await TranscriptStore.load();
      if (transcripts.byPath[imported.path] == dictationTranscript) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(
      (await TranscriptStore.load()).byPath[imported.path],
      dictationTranscript,
    );
    await first.organizeStore.idle;
    first.dispose();
    activeControllers.remove(first);
    restored = build();
    activeControllers.add(restored);
    await restored.waitForOrganize();
    await _until(
      () => restored.recordingView(reference).text == dictationTranscript,
    );
    expect(restored.currentMinutesFor(reference)!.toJson(), saved);
    expect(restored.organizeStatusFor(imported.path).stage, OrganizeStage.done);
    expect(speech.calls, 1);
    expect(analysis.minutesCalls, 1);
  });
  Future<void> openFromRecordingDetail() async {
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: restored,
        child: MaterialApp(home: RecordingDetailScreen(reference: reference)),
      ),
    );
    await tester.pumpAndSettle();
    final analysisButton = find.byTooltip('摘要与分析');
    await tester.ensureVisible(analysisButton);
    await tester.tap(analysisButton);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBar), matching: find.text('结构化纪要')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MinutesPanel), findsOneWidget);
  }

  await openFromRecordingDetail();
  expect(find.text(dictationTitle), findsOneWidget);
  Future<void> reveal(String text) async {
    final target = find.text(text);
    final scrollable = find
        .descendant(
          of: find.byType(MinutesPanel),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(target, 200, scrollable: scrollable);
    await tester.pumpAndSettle();
    expect(target, findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  await reveal('核对资料的理由与例子');
  await reveal('提交改口与发布边界');
  await screenshot?.call('minutes-chapters');
  await reveal('上线日期还没确定');
  tester.view.platformDispatcher.textScaleFactorTestValue = 1.35;
  addTearDown(tester.view.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpAndSettle();
  await reveal('上线日期还没确定');
  await screenshot?.call('minutes-large-text');
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
  await openFromRecordingDetail();
  expect(find.text(dictationTitle), findsOneWidget);
  expect(restored.currentMinutesFor(reference)!.toJson(), saved);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox());
}
