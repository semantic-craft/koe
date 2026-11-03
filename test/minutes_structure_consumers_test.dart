import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/minutes_export.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Analysis extends RecordingAnalysis {
  _Analysis() : super(inMemory: true);
  bool failSave = false;
  @override
  Future<void> save() async {
    if (failSave) throw const FileSystemException('injected save failure');
    await super.save();
  }
}

Map<String, dynamic> _fixture({List<String> heard = const []}) => {
  'schemaVersion': 2,
  'title': '发布会',
  'overview': '确认交付计划',
  'topics': [
    {
      'text': '排期',
      'summary': '交付风险汇总',
      'sources': ['S1'],
      'points': [
        {
          'text': '检查并行依赖',
          'sources': ['S1'],
        },
      ],
      'fishbone': {
        'question': '为什么延期',
        'branches': [
          {
            'text': '人员',
            'detail': '研发人手不足',
            'sources': ['S1'],
          },
          {
            'text': '流程',
            'detail': '审批耗时',
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
      'name': '江充',
      'note': '本场提到的项目负责人',
      'heard': heard,
      'sources': ['S1'],
    },
  ],
};

AnalysisResult _result(String text, String source) => AnalysisResult(
  text: text,
  sourceHash: analysisFingerprint(source),
  model: 'test-model',
  instruction: 'test prompt',
  sources: [source],
  createdAt: DateTime.utc(2026, 11, 3),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('HTML Word and visible PDF pages retain nested minutes and terms', () {
    final result = _result(jsonEncode(_fixture()), '讨论发布延期与负责人。');
    final minutes = MeetingMinutes.parse(result.text, 1);
    final html = minutes.exportHtml(result);
    final word = utf8.decode(readZipArchive(minutes.exportDocxBytes(result))['word/document.xml']!);
    final pdf = latin1.decode(minutes.exportPdfBytes(result));
    // Decode page text operators rather than the embedded Markdown metadata.
    final pageText = RegExp(r'<([0-9a-fA-F]+)> Tj')
        .allMatches(pdf)
        .map((m) {
          final hex = m.group(1)!;
          return String.fromCharCodes([
            for (var i = 0; i < hex.length; i += 4)
              int.parse(hex.substring(i, i + 4), radix: 16),
          ]);
        })
        .join('\n');
    for (final value in ['交付风险汇总', '检查并行依赖', '为什么延期', '研发人手不足', '本场提到的项目负责人']) {
      expect(html, contains(value), reason: 'HTML lost $value');
      expect(word, contains(value), reason: 'Word lost $value');
      expect(
        pageText,
        contains(value),
        reason: 'PDF visible pages lost $value',
      );
    }
  });

  late Directory temp;
  late RecorderController controller;
  late _Analysis analysis;
  late RecordingReference ref;
  late String slot;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-minutes-consumers-');
    PathProviderPlatform.instance = _Paths(temp.path);
    AppSettingsStore.resetForTesting();
    await AppSettingsStore.load();
    analysis = _Analysis();
    controller = RecorderController(
      loadPersistedState: false,
      phoneRecordingEnabled: false,
      libraryDirectory: temp,
      analysisController: analysis,
      transcriptPersister: ({bool strict = false}) async {},
    );
    final wav = File('${temp.path}/meeting.wav')..writeAsBytesSync([0, 0]);
    await controller.library.upsert(
      RecordingAsset(
        path: wav.path,
        displayName: '例会',
        source: RecordingSource.phone,
        recordedAt: DateTime.utc(2026, 11, 3),
        importedAt: DateTime.utc(2026, 11, 3),
      ),
    );
    controller.rememberTranscript(wav.path, '江松说明了发布延期。');
    ref = RecordingReference(path: wav.path);
    slot = '${controller.analysisKey(ref)}/minutes';
  });
  tearDown(() async {
    controller.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'invalid term evidence is rejected before transcript or vocabulary changes',
    () async {
      final before = controller.recordingView(ref).text;
      final result = _result(jsonEncode(_fixture(heard: ['从未出现的错词'])), before);
      analysis.results[slot] = result;
      await expectLater(
        controller.replaceTermInRecording(
          ref,
          '江松',
          '江充',
          addToVocabulary: true,
        ),
        throwsFormatException,
      );
      expect(controller.recordingView(ref).text, before);
      expect(analysis.results[slot], same(result));
      expect(controller.vocabulary, isNot(contains('江充')));
    },
  );

  test(
    'replacement prunes obsolete heard and keeps nested data in version history',
    () async {
      final before = controller.recordingView(ref).text;
      final original = _result(jsonEncode(_fixture(heard: ['江松'])), before);
      analysis.results[slot] = original;
      final report = await controller.replaceTermInRecording(ref, '江松', '江充');
      expect(report.minutesUpdated, 1);
      final current = analysis.results[slot]!;
      final body = jsonDecode(current.text) as Map;
      expect((body['terms'] as List).single['heard'], isEmpty);
      expect((body['topics'] as List).single['points'], isNotEmpty);
      expect(
        current.sourceHash,
        analysisFingerprint(controller.recordingView(ref).text),
      );
      expect(controller.matchesRecordingSearch(ref, '检查并行依赖'), isTrue);
      expect(controller.matchesRecordingSearch(ref, '江松'), isFalse);
      expect(analysis.versionHistory[slot]!.single.text, original.text);
      expect(analysis.versionHistory[slot]!.single.sources, original.sources);
      await analysis.restoreVersion(slot, 0);
      expect(analysis.results[slot]!.text, original.text);
    },
  );

  test(
    'failed structured save keeps old nested result readable and stale',
    () async {
      final before = controller.recordingView(ref).text;
      final original = _result(jsonEncode(_fixture(heard: ['江松'])), before);
      analysis.results[slot] = original;
      analysis.failSave = true;
      await expectLater(
        controller.replaceTermInRecording(ref, '江松', '江充'),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.recordingView(ref).text, contains('江充'));
      expect(analysis.results[slot], same(original));
      final retained =
          jsonDecode(validateMinutes(original.text, original.sources)) as Map;
      expect((retained['topics'] as List).single['points'], isNotEmpty);
      expect(
        original.sourceHash,
        isNot(analysisFingerprint(controller.recordingView(ref).text)),
      );
      expect(analysis.versionHistory[slot], isNull);
    },
  );
}
