import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_analysis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('koe-context-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  test('a corrected topic link survives topic moves and a restart '
      'without changing the recording topic', () async {
    final topics = TopicStore(inMemory: true);
    addTearDown(topics.dispose);
    final a = await topics.createTopic(kind: TopicKind.general, title: '装修');
    final b = await topics.createTopic(kind: TopicKind.general, title: '预算');
    final c = await topics.createTopic(kind: TopicKind.general, title: '家人');
    final storeFile = File('${directory.path}/context_items.json');
    const fileId = 1760850000;
    final recordedAt = DateTime.fromMillisecondsSinceEpoch(fileId * 1000);
    final path = '${directory.path}/$fileId.wav';
    await File(path).writeAsBytes([1, 2, 3, 4]);

    RecorderController open() {
      final controller = RecorderController(
        loadPersistedState: false,
        topicsEnabled: true,
        topicStore: topics,
        analysisController: RecordingAnalysis(inMemory: true),
        contextStore: ContextStore(file: storeFile),
        libraryDirectory: Directory('${directory.path}/imports'),
      );
      controller.exportedPaths.add(path);
      return controller;
    }

    final first = open();
    final key = first.recordingKeyFor(
      RecordingReference(fileId: fileId, path: path),
    );
    await topics.moveRecording(key, a.id);
    await first.setRecordingPlace(path, '杭州 西湖区');
    await first.contextItems.load();

    final item = first.contextItemsForDay(recordedAt).single;
    expect(item.start, recordedAt);
    expect(item.location, '杭州 西湖区');
    expect(item.topicIds, [a.id]);
    expect(item.source?.recordingKey, key);

    await first.setContextItemTopics(item.id, [b.id, c.id]);
    expect(topics.topicOf(key)?.id, a.id);
    await topics.moveRecording(key, c.id);
    expect(first.contextItemsForDay(recordedAt).single.topicIds, [b.id, c.id]);
    await first.contextItems.idle;
    first.dispose();

    final second = open();
    addTearDown(second.dispose);
    await second.contextItems.load();
    final restored = second.contextItemsForDay(recordedAt).single;
    expect(restored.topicIds, [b.id, c.id]);
    expect(restored.userEdited, isTrue);
    await second.contextItems.idle;
  });

  test(
    'project links span days and come back with a restored recording',
    () async {
      final store = ContextStore(inMemory: true);
      addTearDown(store.dispose);
      await store.load();
      ContextItem recording(String key, {DateTime? start, DateTime? added}) =>
          ContextItem(
            id: 'recording:$key',
            kind: ContextKind.recording,
            title: key,
            start: start,
            addedAt: added ?? start!,
            source: ContextSource(recordingKey: key),
          );
      final monday = recording('file:1', start: DateTime(2026, 10, 18, 9));
      final tuesday = recording('file:2', start: DateTime(2026, 10, 19, 10));
      final undated = recording('path:x', added: DateTime(2026, 10, 19, 8));
      store.sync([monday, tuesday, undated]);
      await store.setProjects(monday.id, ['p1']);
      await store.setProjects(tuesday.id, ['p1']);

      expect(store.itemsForProject('p1').map((item) => item.id), [
        monday.id,
        tuesday.id,
      ]);
      final day = store.itemsForDay(DateTime(2026, 10, 19));
      expect(day.map((item) => item.id), [tuesday.id, undated.id]);
      expect(day.last.timeKnown, isFalse);

      store.sync([monday, undated]);
      expect(store.itemsForProject('p1').map((item) => item.id), [monday.id]);
      store.sync([monday, tuesday, undated]);
      expect(store.itemsForProject('p1').map((item) => item.id), [
        monday.id,
        tuesday.id,
      ]);
    },
  );
}
