import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/engine_config.dart';
import 'package:koe/ai/qwen_stt.dart';
import 'package:koe/ai/stt_types.dart';
import 'package:koe/state/file_job_journal.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/topics_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

/// Topic notes foundation (#50): current topic is valid for one local day,
/// retrieval places recordings, one placement per recording, damaged records
/// never cost a recording, and recordings without a topic behave as before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('topics-50-');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<String> recording(int id) async {
    final path = '${dir.path}/$id.wav';
    await File(path).writeAsBytes(wavBytes([1, 2, 3, 4]));
    return path;
  }

  RecorderController controller(
    TopicStore store, {
    _Qwen? qwen,
    RecordingAnalysis? analysis,
  }) {
    final c = RecorderController(
      loadPersistedState: false,
      meetingLocalOnly: false,
      topicsEnabled: true,
      topicStore: store,
      qwenSpeech: qwen ?? _Qwen(),
      fileJobJournal: FileJobJournal(inMemory: true),
      analysisController: analysis,
      retrievedAudioSettleTime: Duration.zero,
    );
    addTearDown(c.dispose);
    return c;
  }

  test('cold start on a later day clears the current topic, so a retrieval '
      'goes to 待归类 instead of yesterday\'s topic', () async {
    final file = File('${dir.path}/topics.json');
    var now = DateTime(2026, 10, 15, 21);
    final yesterday = TopicStore(file: file, now: () => now);
    await yesterday.load();
    final book = await yesterday.createTopic(
      kind: TopicKind.book,
      title: '法学方法论',
      author: '拉伦茨',
    );
    await yesterday.setCurrentTopic(book.id);
    yesterday.dispose();

    now = DateTime(2026, 10, 16, 8);
    final store = TopicStore(file: file, now: () => now);
    final c = controller(store);
    final path = await recording(1760000001);
    await c.processRetrievedRecording(path);

    expect(store.currentTopic, isNull);
    expect(store.isPending('file:1760000001'), isTrue);
    expect(store.recordingsIn(book.id), isEmpty);
    final saved = jsonDecode(await file.readAsString()) as Map;
    expect(saved.containsKey('current'), isFalse);
  });

  test('移出主题后再次取回不会自动归入当前主题', () async {
    final store = TopicStore(inMemory: true);
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '职业规划',
    );
    await store.setCurrentTopic(topic.id);
    final c = controller(store);
    final path = await recording(1760000009);
    const key = 'file:1760000009';

    await c.processRetrievedRecording(path);
    expect(store.placementOf(key), isA<InTopicPlacement>());
    expect(store.recordingsIn(topic.id), contains(key));

    await c.removeRecordingFromTopics(path);
    expect(store.placementOf(key), isA<NoTopicPlacement>());

    await store.placeRetrieved(key);
    expect(store.placementOf(key), isA<NoTopicPlacement>());
    expect(store.recordingsIn(topic.id), isEmpty);
  });

  testWidgets('crossing midnight in the foreground clears the current topic '
      'without any other interaction', (tester) async {
    var now = DateTime(2026, 10, 16, 23, 59, 58);
    final store = TopicStore(inMemory: true, now: () => now);
    final c = RecorderController(
      loadPersistedState: false,
      topicsEnabled: true,
      topicStore: store,
    );
    addTearDown(c.dispose);
    // In-memory store: no file I/O, so the midnight timer is created inside
    // the test's fake clock zone.
    await store.load();
    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '职业规划',
    );
    await store.setCurrentTopic(topic.id);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: c,
        child: MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: TopicsEntry()),
        ),
      ),
    );
    expect(find.text('当前主题：职业规划'), findsOneWidget);

    now = DateTime(2026, 10, 17, 0, 0, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('当前主题：职业规划'), findsNothing);
    expect(find.text('主题 · 今天未设当前主题'), findsOneWidget);
  });

  test('BLE and Wi-Fi retrievals go to the current topic, or to 待归类 when '
      'none is set, independent of the auto-transcribe switch', () async {
    final now = DateTime(2026, 10, 16, 10);
    final store = TopicStore(inMemory: true, now: () => now);
    final c = controller(store)..setAutoTranscribe(false);
    await store.load();

    final pendingPath = await recording(1760000010);
    await c.processRetrievedRecording(pendingPath);
    expect(store.isPending('file:1760000010'), isTrue);

    final topic = await store.createTopic(
      kind: TopicKind.general,
      title: '职业规划',
    );
    await store.setCurrentTopic(topic.id);
    final blePath = await recording(1760000011);
    await c.processRetrievedRecording(blePath);
    final wifiRaw = '${dir.path}/1760000012.wav';
    await File(wifiRaw).writeAsBytes(wavBytes([5, 6, 7, 8]));
    await c.completeWifiTransfer([wifiRaw], decrypted: true);

    expect(
      store.recordingsIn(topic.id),
      unorderedEquals(['file:1760000011', 'file:1760000012']),
    );
    // Setting a current topic later does not sweep 待归类 into it.
    expect(store.isPending('file:1760000010'), isTrue);
  });

  test('a recording belongs to one topic; moves, removal and re-retrieval '
      'keep it there and survive a restart', () async {
    final file = File('${dir.path}/topics.json');
    final now = DateTime(2026, 10, 16, 10);
    final store = TopicStore(file: file, now: () => now);
    final c = controller(store);
    await store.load();
    final a = await store.createTopic(kind: TopicKind.general, title: 'A');
    final b = await store.createTopic(kind: TopicKind.book, title: 'B');
    await store.setCurrentTopic(a.id);
    final path = await recording(1760000020);
    await c.processRetrievedRecording(path);
    const key = 'file:1760000020';
    expect(store.recordingsIn(a.id), [key]);

    await store.moveRecording(key, b.id);
    expect(store.recordingsIn(a.id), isEmpty);
    expect(store.recordingsIn(b.id), [key]);
    // Re-retrieving the same file while A is current does not move it back.
    await c.processRetrievedRecording(path);
    expect(store.topicOf(key)?.id, b.id);

    await store.removeFromTopic(key);
    await c.processRetrievedRecording(path);
    expect(store.topicOf(key), isNull);
    expect(store.isPending(key), isFalse);

    await store.moveRecording(key, a.id);
    final reopened = TopicStore(file: file, now: () => now);
    await reopened.load();
    expect(reopened.recordingsIn(a.id), [key]);
    expect(reopened.recordingsIn(b.id), isEmpty);
    expect(reopened.currentTopic?.id, a.id);
  });

  test('读完/归档 topics leave the default choices and stop being current; '
      'reopening restores them', () async {
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    await store.load();
    final book = await store.createTopic(kind: TopicKind.book, title: '书');
    final note = await store.createTopic(kind: TopicKind.general, title: '想法');
    await store.setCurrentTopic(book.id);

    await store.closeTopic(book.id);
    await store.closeTopic(note.id);
    expect(store.openTopics, isEmpty);
    expect(store.currentTopic, isNull);
    expect(() => store.setCurrentTopic(note.id), throwsStateError);

    await store.reopenTopic(book.id);
    expect(store.openTopics.map((t) => t.id), [book.id]);
  });

  test('a damaged topic record never costs a recording', () async {
    final file = File('${dir.path}/topics.json');
    const garbage = '{"topics": [ {"id": "t1", "kind": "bo';
    await file.writeAsString(garbage);
    final store = TopicStore(file: file, now: () => DateTime(2026, 10, 16, 10));
    final c = controller(store);
    final raw = '${dir.path}/1760000030.wav';
    await File(raw).writeAsBytes(wavBytes([1, 2, 3, 4]));
    await c.completeWifiTransfer([raw], decrypted: true);

    expect(File(raw).existsSync(), isTrue);
    expect(c.exportedPaths, contains(raw));
    expect(store.isPending('file:1760000030'), isTrue);
    expect(store.recoveryNotice, isNotNull);
    final backups = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('topics.json.corrupt-'))
        .toList();
    expect(backups.single.readAsStringSync(), garbage);

    // A damaged entry inside an otherwise readable record: the recording
    // that pointed at it reappears in 待归类 rather than disappearing.
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'topics': [
          {'id': 'ok', 'kind': 'general', 'title': '保留'},
          {'id': 'bad', 'kind': 'unknown'},
        ],
        'placements': {
          'file:1': 'topic:ok',
          'file:2': 'topic:bad',
          'file:3': 42,
        },
      }),
    );
    final partial = TopicStore(file: file);
    await partial.load();
    expect(partial.recordingsIn('ok'), ['file:1']);
    expect(partial.pendingRecordings, unorderedEquals(['file:2', 'file:3']));
  });

  test('a recording without a topic is transcribed exactly as before and '
      'triggers no analysis call', () async {
    final analysisService = _Analysis();
    final analysis = RecordingAnalysis(
      inMemory: true,
      service: analysisService,
    );
    final store = TopicStore(
      inMemory: true,
      now: () => DateTime(2026, 10, 16, 10),
    );
    final qwen = _Qwen();
    final c = controller(store, qwen: qwen, analysis: analysis);
    await c.setQwenConfig(const EngineConfig(apiKey: 'key'));
    c.setSpeechProvider(SttProvider.qwen);
    c.setAutoTranscribe(true);
    final path = await recording(1760000040);
    await c.processRetrievedRecording(path);
    for (var i = 0; i < 100 && c.transcriptForPath(path) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final reference = RecordingReference(fileId: 1760000040, path: path);
    expect(store.isPending('file:1760000040'), isTrue);
    expect(qwen.calls, 1);
    expect(c.transcriptForPath(path), '通义文本');
    expect(c.recordingView(reference).error, isNull);
    expect(c.analysisKey(reference), 'file:1760000040');
    expect(analysisService.calls, 0);
  });

  test('writes started before load finishes wait for the disk read instead of '
      'overwriting existing topics or reviving forgotten placements', () async {
    final file = File('${dir.path}/topics.json');
    final now = DateTime(2026, 10, 16, 10);
    final seeded = TopicStore(file: file, now: () => now);
    await seeded.load();
    final existing = await seeded.createTopic(
      kind: TopicKind.book,
      title: '法学方法论',
    );
    await seeded.placeRetrieved('file:1760000050');
    seeded.dispose();

    final delayedFile = _DelayedReadFile(file);
    final store = TopicStore(file: delayedFile, now: () => now);
    addTearDown(store.dispose);
    final loadFuture = store.load();
    await delayedFile.readingStarted.future;

    final createFuture = store.createTopic(
      kind: TopicKind.general,
      title: '职业规划',
    );
    final forgetFuture = store.forgetRecording('file:1760000050');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    delayedFile.allowRead.complete();
    final created = await createFuture;
    await Future.wait([loadFuture, forgetFuture]);

    expect(
      store.topics.map((t) => t.title),
      unorderedEquals(['法学方法论', '职业规划']),
    );
    expect(store.topics.map((t) => t.id).toSet().length, 2);
    expect(created.id, isNot(existing.id));
    expect(store.placementOf('file:1760000050'), isNull);
    expect(store.pendingRecordings, isEmpty);

    final reopened = TopicStore(file: file, now: () => now);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(
      reopened.topics.map((t) => t.title),
      unorderedEquals(['法学方法论', '职业规划']),
    );
    expect(reopened.topics.map((t) => t.id).toSet().length, 2);
    expect(reopened.topicById(existing.id)?.title, '法学方法论');
    expect(reopened.topicById(created.id)?.title, '职业规划');
    expect(reopened.placementOf('file:1760000050'), isNull);
    expect(reopened.pendingRecordings, isEmpty);
  });
}

class _DelayedReadFile implements File {
  _DelayedReadFile(this._inner);

  final File _inner;
  final Completer<void> readingStarted = Completer<void>();
  final Completer<void> allowRead = Completer<void>();

  @override
  String get path => _inner.path;

  @override
  Directory get parent => _inner.parent;

  @override
  Future<bool> exists() => _inner.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    final content = await _inner.readAsString(encoding: encoding);
    if (!readingStarted.isCompleted) readingStarted.complete();
    await allowRead.future;
    return content;
  }

  @override
  Future<File> rename(String newPath) => _inner.rename(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Qwen extends QwenSttService {
  int calls = 0;

  @override
  Future<SttResult> transcribePath(
    String path, {
    String? apiKey,
    String? baseUrl,
    String? model,
    String? language,
    SttFileProgressCallback? onProgress,
    bool Function()? isCurrent,
  }) async {
    calls++;
    return SttResult(text: '通义文本', sourcePath: path, language: 'zh');
  }
}

class _Analysis implements AnalysisService {
  int calls = 0;
  @override
  Future<String> generate({
    required String model,
    required String apiKey,
    required String source,
    required String instruction,
    required Future<void> abort,
  }) async {
    calls++;
    return '{}';
  }

  @override
  void dispose() {}
}
