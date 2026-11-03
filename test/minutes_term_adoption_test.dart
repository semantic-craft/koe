import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_minutes.dart';
import 'package:koe/state/app_settings_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/widgets/minutes_panel.dart';

import 'meeting_minutes_test.dart' as fixtures;

const source = '江松负责发布，江松明天核对。';
Map<String, dynamic> candidate({bool adopted = false}) => {
  'schemaVersion': 2,
  'title': '项目会议',
  'overview': '核对安排',
  'topics': [],
  'decisions': [],
  'actions': [],
  'questions': [],
  'terms': [
    {
      'name': '江充',
      'note': '本场项目负责人，姓名待确认',
      'heard': ['江松'],
      'sources': ['S1'],
      if (adopted)
        'adoption': {
          'kind': 'vocabulary',
          'at': '2026-11-03T10:00:00.000Z',
          'previousVersion': 'a' * 64,
        },
    },
  ],
};
AnalysisResult result({bool adopted = false}) => AnalysisResult(
  text: jsonEncode(candidate(adopted: adopted)),
  sourceHash: analysisFingerprint(source),
  model: 'test',
  instruction: 'test',
  sources: const [source],
  createdAt: DateTime.utc(2026, 11, 3),
);

class TestPaths extends PathProviderPlatform {
  TestPaths(this.path);
  final String path;
  bool failNext = false;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    if (failNext) {
      failNext = false;
      return '$path/blocked';
    }
    return path;
  }

  @override
  Future<String?> getTemporaryPath() async => path;
}

class AdoptionController extends fixtures.Controller {
  AdoptionController(super.manager) : super(text: source);
  bool failVocabulary = false;
  @override
  Future<void> addVocabularyTermStrict(String term) async {
    if (failVocabulary) {
      throw const FileSystemException('injected vocabulary failure');
    }
    vocabulary = [...vocabulary, term];
  }

  @override
  Future<bool> replaceTermsInTranscript(
    String path,
    Map<String, String> replacements, {
    String? expectedHash,
  }) async {
    final pattern = RegExp(replacements.keys.map(RegExp.escape).join('|'));
    text = text.replaceAllMapped(pattern, (m) => replacements[m[0]]!);
    notifyListeners();
    return true;
  }
}

class _PausedMinutesSave extends RecordingAnalysis {
  _PausedMinutesSave(File file) : super(file: file);
  bool pauseNext = false;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> save() async {
    if (pauseNext) {
      pauseNext = false;
      started.complete();
      await release.future;
    }
    await super.save();
  }
}

Future<void> waitFor(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(done(), isTrue);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final replace in [false, true]) {
    test(
      'source changes during final ${replace ? 'replacement' : 'vocabulary'} save cannot persist adoption',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'koe-adoption-final-race-',
        );
        final file = File('${dir.path}/analysis.json');
        final manager = _PausedMinutesSave(file);
        await manager.load();
        final controller = AdoptionController(manager);
        final original = result();
        manager.results['file:1/minutes'] = original;
        await manager.save();
        manager.pauseNext = true;
        final pending = controller.adoptMinutesTerm(
          const RecordingReference(fileId: 1, path: '/recording.wav'),
          original,
          0,
          replace: replace,
        );
        final outcome = pending.then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        await manager.started.future;
        controller.text = '用户在纪要保存期间写入的新正文';
        manager.release.complete();
        final failure = await outcome;
        final restarted = RecordingAnalysis(file: file);
        await restarted.load();
        try {
          expect(failure, isA<StateError>());
          final restored = MeetingMinutes.parse(
            restarted.results['file:1/minutes']!.text,
            1,
            sourceTexts: restarted.results['file:1/minutes']!.sources,
          );
          expect(restored.terms.single.adoption, isNull);
          expect(controller.text, '用户在纪要保存期间写入的新正文');
        } finally {
          controller.dispose();
          restarted.dispose();
          await dir.delete(recursive: true);
        }
      },
    );
  }

  test(
    'bulk correction includes speaker names and never recursively replaces targets',
    () async {
      final controller = RecorderController(
        loadPersistedState: false,
        phoneRecordingEnabled: false,
        transcriptPersister: ({bool strict = false}) async {},
      );
      addTearDown(controller.dispose);
      controller.transcriptsByPath['/speaker.wav'] = '说话人 1：松负责发布。';
      controller.speakerAliasesByPath['/speaker.wav'] = {'1': '江松'};
      final before = controller.transcriptForPath('/speaker.wav')!;
      await controller.replaceTermsInTranscript('/speaker.wav', {
        '江松': '江松松',
        '松': '江松松',
      }, expectedHash: analysisFingerprint(before));
      expect(controller.transcriptForPath('/speaker.wav'), '江松松：江松松负责发布。');
      expect(controller.speakerAliasesForPath('/speaker.wav')['1'], '江松松');
    },
  );
  test(
    'concurrent strict vocabulary additions survive restart without a failed addition',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'koe-term-vocabulary-',
      );
      final previousPaths = PathProviderPlatform.instance;
      final paths = TestPaths(temp.path);
      PathProviderPlatform.instance = paths;
      AppSettingsStore.resetForTesting();
      await AppSettingsStore.load();
      final controller = RecorderController(
        loadPersistedState: false,
        phoneRecordingEnabled: false,
        libraryDirectory: temp,
      );
      addTearDown(() async {
        controller.dispose();
        PathProviderPlatform.instance = previousPaths;
        await temp.delete(recursive: true);
      });
      await Future.wait([
        controller.addVocabularyTermStrict('江充'),
        controller.addVocabularyTermStrict('张工'),
      ]);
      expect(
        (await AppSettingsStore.load()).vocabulary,
        containsAll(['江充', '张工']),
      );
      final pendingAddition = controller.addVocabularyTermStrict('待取消');
      final pendingRemoval = controller.removeVocabularyTerm('待取消');
      await Future.wait([pendingAddition, pendingRemoval]);
      expect(
        (await AppSettingsStore.load()).vocabulary,
        isNot(contains('待取消')),
      );
      File('${temp.path}/blocked').writeAsStringSync('not a directory');
      paths.failNext = true;
      final failed = controller.addVocabularyTermStrict('不应加入');
      final failedCheck = expectLater(failed, throwsA(isA<Exception>()));
      final succeeding = controller.addVocabularyTermStrict('王工');
      await failedCheck;
      await succeeding;
      final restored = (await AppSettingsStore.load()).vocabulary;
      expect(restored, containsAll(['江充', '张工', '王工']));
      expect(restored, isNot(contains('不应加入')));
    },
  );

  test(
    'failed correction cannot roll back a newer manual transcript',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var calls = 0;
      final controller = RecorderController(
        loadPersistedState: false,
        phoneRecordingEnabled: false,
        transcriptPersister: ({bool strict = false}) async {
          if (++calls == 1) {
            entered.complete();
            await release.future;
            throw const FileSystemException('old save failed');
          }
        },
      );
      addTearDown(controller.dispose);
      controller.transcriptsByPath['/race.wav'] = source;
      final pending = controller.replaceTermInTranscript(
        '/race.wav',
        '江松',
        '江充',
      );
      final failure = expectLater(pending, throwsA(isA<FileSystemException>()));
      await entered.future;
      await controller.saveManualTranscript('/race.wav', '用户刚写的新正文');
      release.complete();
      await failure;
      expect(controller.transcriptForPath('/race.wav'), '用户刚写的新正文');
    },
  );

  testWidgets(
    'confirmed replacement persists acceptance and original evidence after restart',
    (tester) async {
      final temp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('koe-term-adoption-'),
      );
      final file = File('${temp!.path}/analysis.json');
      final manager = (await tester.runAsync(
        () async => RecordingAnalysis(file: file),
      ))!;
      await tester.runAsync(manager.load);
      manager.results['file:1/minutes'] = result();
      await tester.runAsync(manager.save);
      final controller = (await tester.runAsync(
        () async => AdoptionController(manager),
      ))!;
      addTearDown(() async {
        controller.dispose();
        await temp.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MinutesPanel(
            controller: controller,
            reference: const RecordingReference(fileId: 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final vocabularyButton = find.text('仅加入词表');
      await tester.scrollUntilVisible(
        vocabularyButton,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(vocabularyButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认加入词表'));
      await waitFor(
        tester,
        () =>
            jsonDecode(
                  manager.results['file:1/minutes']!.text,
                )['terms'][0]['adoption']?['kind'] ==
                'vocabulary' &&
            !manager.busy('file:1/minutes'),
      );
      final afterVocabulary = RecordingAnalysis(file: file);
      await tester.runAsync(afterVocabulary.load);
      expect(
        jsonDecode(
          afterVocabulary.results['file:1/minutes']!.text,
        )['terms'][0]['adoption']['kind'],
        'vocabulary',
      );
      afterVocabulary.dispose();
      expect(controller.text, source);
      expect(controller.vocabulary, contains('江充'));
      final button = find.text('订正本场原文');
      await tester.scrollUntilVisible(
        button,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认订正'));
      await waitFor(
        tester,
        () =>
            (jsonDecode(
                  manager.results['file:1/minutes']!.text,
                )['terms'][0]['adoption']?['kind']) ==
                'replaced' &&
            !manager.busy('file:1/minutes'),
      );
      expect(controller.text, '江充负责发布，江充明天核对。');
      final restarted = RecordingAnalysis(file: file);
      addTearDown(restarted.dispose);
      await tester.runAsync(restarted.load);
      final restored = jsonDecode(restarted.results['file:1/minutes']!.text);
      expect(restored['terms'][0]['adoption']['kind'], 'replaced');
      expect(restored['terms'][0]['heard'], isEmpty);
      expect(
        restarted.versionsFor('file:1/minutes').first.sources.single,
        source,
      );
      expect(
        controller.searchRecordingHit(
          const RecordingReference(fileId: 1),
          '江松',
        ),
        isNull,
      );
      final evidence = find.text('采纳前原文');
      await tester.ensureVisible(evidence);
      await tester.tap(evidence);
      await tester.pumpAndSettle();
      expect(find.textContaining(source), findsOneWidget);
      expect(find.text('从这里回听'), findsNothing);
    },
  );

  testWidgets('failed vocabulary persistence never marks term accepted', (
    tester,
  ) async {
    final manager = RecordingAnalysis(inMemory: true);
    final original = result();
    manager.results['file:1/minutes'] = original;
    final controller = AdoptionController(manager)..failVocabulary = true;
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
    final button = find.text('仅加入词表');
    await tester.scrollUntilVisible(
      button,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认加入词表'));
    await tester.pumpAndSettle();
    expect(find.textContaining('未完成'), findsOneWidget);
    expect(manager.results['file:1/minutes'], same(original));
    expect(controller.vocabulary, isEmpty);
    expect(controller.text, source);
  });

  test(
    'local adoption survives corrections but generated output cannot claim acceptance',
    () async {
      final raw = candidate(adopted: true);
      final parsed = MeetingMinutes.parse(
        jsonEncode(raw),
        1,
        sourceTexts: [source],
      );
      final body = jsonDecode(
        parsed.replaceTerm('核对', '检查').pruneHeard([source]).encode(),
      );
      expect(body['terms'][0]['adoption'], raw['terms'][0]['adoption']);
      final service = fixtures.Service()..response = jsonEncode(raw);
      final manager = RecordingAnalysis(inMemory: true, service: service);
      addTearDown(manager.dispose);
      await manager.run(
        recording: 'file:1',
        source: source,
        apiKey: 'test',
        custom: true,
        resultSlot: 'minutes',
        instruction: minutesInstruction,
        sourceBlocks: [source],
        validateResult: validateMinutes,
        currentSource: () => source,
      );
      final generated = jsonDecode(manager.results['file:1/minutes']!.text);
      expect(generated['terms'][0].containsKey('adoption'), isFalse);
      final before = result();
      final accepted =
          MeetingMinutes.parse(
            before.text,
            1,
            sourceTexts: before.sources,
          ).adoptTerm(
            0,
            MinuteTermAdoption(
              kind: 'vocabulary',
              at: DateTime.utc(2026),
              previousVersion: minuteVersionFingerprint(before),
            ),
          );
      final current = AnalysisResult(
        text: accepted.encode(),
        sourceHash: before.sourceHash,
        model: 'test',
        instruction: 'test',
        sources: before.sources,
        createdAt: before.createdAt,
      );
      final imported = PackMinutes.decode(
        PackMinutes(current: current, history: [before]).toJson(),
      );
      final importedTerm = MeetingMinutes.parse(
        imported.current.text,
        1,
        sourceTexts: imported.current.sources,
      ).terms.single;
      expect(
        minuteVersionFingerprint(imported.history.single),
        importedTerm.adoption!.previousVersion,
      );
    },
  );

  test(
    'correct name locates current mishearing and labels the association',
    () {
      final manager = RecordingAnalysis(inMemory: true);
      manager.results['file:1/minutes'] = result();
      final controller = fixtures.Controller(
        manager,
        text: source,
        segments: const [
          TranscriptSegment(
            text: '江松负责发布，',
            start: Duration(seconds: 4),
            end: Duration(seconds: 8),
          ),
          TranscriptSegment(
            text: '江松明天核对。',
            start: Duration(seconds: 8),
            end: Duration(seconds: 10),
          ),
        ],
      );
      addTearDown(controller.dispose);
      final hit = controller.searchRecordingHit(
        const RecordingReference(fileId: 1),
        '江充',
      );
      expect(hit?.index, 0);
      expect(hit?.snippet, contains('术语关联'));
      expect(hit?.snippet, contains('江松负责发布'));
      expect(hit?.timecode, const Duration(seconds: 4));
      controller.audioChanged = true;
      expect(
        controller
            .searchRecordingHit(const RecordingReference(fileId: 1), '江充')
            ?.timecode,
        isNull,
      );
      controller.audioChanged = false;
      controller.text = '已删除该人的全部发言。';
      final stale = controller.searchRecordingHit(
        const RecordingReference(fileId: 1),
        '江充',
      );
      expect(stale?.snippet, isNot(contains('术语关联')));
      expect(
        controller.searchRecordingHit(
          const RecordingReference(fileId: 1),
          '江松',
        ),
        isNull,
      );
    },
  );

  testWidgets('term adoption asks before changing this recording', (
    tester,
  ) async {
    final manager = RecordingAnalysis(inMemory: true);
    manager.results['file:1/minutes'] = result();
    final controller = fixtures.Controller(manager, text: source);
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
    final button = find.text('订正本场原文');
    await tester.scrollUntilVisible(
      button,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('仅影响本场'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('2 处'), findsOneWidget);
    expect(controller.text, source);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(manager.results['file:1/minutes']!.text, result().text);
  });
}
