import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/audio_version.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_bookmarks.dart';
import 'package:koe/ui/screens/minutes_document_screen.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:koe/ui/widgets/material_export_sheet.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

TranscriptSegment _segment(String text, int start, int end, String speaker) =>
    TranscriptSegment(
      text: text,
      start: Duration(seconds: start),
      end: Duration(seconds: end),
      speaker: speaker,
    );

final _segments = [
  _segment('我们先过一下预算。', 0, 4, '1'),
  _segment('预算要再确认一次。', 5, 9, '2'),
  _segment('下周三之前给结论。', 10, 14, '1'),
];

/// One library on one "device": its own folders, nothing shared with
/// another instance except the pack file handed between them.
class _Library {
  _Library(this.root)
    : store = RecordingLibraryStore(
        file: File('${root.path}/recording_library.json'),
      ),
      topics = TopicStore(inMemory: true) {
    controller = RecorderController(
      loadPersistedState: false,
      libraryStore: store,
      libraryDirectory: Directory('${root.path}/imports'),
      topicStore: topics,
      topicsEnabled: false,
      transcriptPersister: ({bool strict = false}) async {},
      minutesStore: MinutesDocumentStore(
        file: File('${root.path}/minutes.json'),
      ),
      bookmarkStore: RecordingBookmarkStore(
        file: File('${root.path}/bookmarks.json'),
      ),
    )..materialPackWorkDirectory = Directory('${root.path}/work');
  }

  final Directory root;
  final RecordingLibraryStore store;
  final TopicStore topics;
  late final RecorderController controller;

  Directory get imports => Directory('${root.path}/imports');

  Future<void> ready() async {
    await controller.waitForRecordingLibrary();
    await controller.waitForTranscripts();
    await controller.waitForBookmarks();
    await controller.waitForMinutesDocuments();
  }

  RecordingReference ref(String path) =>
      RecordingReference(fileId: controller.fileIdFromPath(path), path: path);
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-pack-');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<_Library> library(String name) async {
    final created = _Library(
      await Directory('${temp.path}/$name').create(recursive: true),
    );
    await created.ready();
    return created;
  }

  /// A fully worked material: corrected text, named and re-assigned
  /// speakers, a bookmark with a note, a place and a topic.
  Future<String> workedMaterial(_Library source) async {
    final audio = File('${temp.path}/周会.wav')
      ..writeAsBytesSync(wavBytes(List<int>.generate(4000, (i) => i % 251)));
    final c = source.controller;
    final imported = await c.importLocalAudio(
      audio.path,
      recordedAt: DateTime(2026, 10, 12, 9, 30),
    );
    final path = imported.path;
    c.rememberTranscript(
      path,
      _segments.map((s) => s.text).join(),
      segments: _segments,
    );
    await c.renameTranscriptSpeaker(path, '1', '王老师');
    await c.setSegmentSpeaker(path, 2, '2');
    await c.addBookmark(
      source.ref(path),
      position: const Duration(seconds: 6),
      segment: _segments[1],
      note: '预算待确认',
    );
    await c.setRecordingPlace(path, '杭州市西湖区');
    final topic = await source.topics.createTopic(
      kind: TopicKind.general,
      title: '年度预算',
    );
    await source.topics.moveRecording(
      c.recordingKeyFor(source.ref(path)),
      topic.id,
    );
    await c.saveManualTranscript(path, '我们先过一下预算。预算要再确认一次（已核对）。下周三之前给结论。');
    return path;
  }

  test('含原音频的资料包导入另一台干净资料库后，校订、发言人、书签、地点和主题都恢复，'
      '重复导入不产生第二份', () async {
    final a = await library('a');
    addTearDown(a.controller.dispose);
    final path = await workedMaterial(a);
    final file = await a.controller.exportMaterialPack(
      a.ref(path),
      includeAudio: true,
    );

    // Nothing in the pack names this device's files or keys.
    final bytes = await file.readAsBytes();
    final manifest = utf8.decode(bytes, allowMalformed: true);
    expect(manifest.startsWith('KOEPACK1\n'), isTrue);
    expect(manifest, isNot(contains(temp.path)));
    expect(manifest, isNot(contains('recordingKey')));
    expect(manifest, isNot(contains('originalPath')));

    final b = await library('b');
    addTearDown(b.controller.dispose);
    final outcome = await b.controller.importMaterialPack(file.path);
    final restored = outcome.path!;
    expect(outcome.duplicate, isFalse);
    expect(restored.startsWith(b.imports.path), isTrue);

    final view = b.controller.recordingView(b.ref(restored));
    expect(view.title, '周会');
    expect(view.recordedAt, DateTime(2026, 10, 12, 9, 30));
    expect(view.originalPresent, isTrue);
    expect(view.manuallyEdited, isTrue);
    expect(view.text, contains('预算要再确认一次（已核对）'));
    // Timecodes and the corrected speaker of the third sentence survive.
    final segments = b.controller.transcriptSegmentsForPath(restored);
    expect(segments.map((s) => s.start.inSeconds), [0, 5, 10]);
    expect(segments.map((s) => s.speaker), ['1', '2', '2']);
    expect(b.controller.speakerAliasesForPath(restored), {'1': '王老师'});
    final bookmarks = b.controller.bookmarksFor(b.ref(restored));
    expect(bookmarks.single.note, '预算待确认');
    // The bookmark still resolves to the same sentence in the restored audio.
    final target = resolveBookmark(
      bookmarks.single,
      audioAvailable: true,
      audioChanged: false,
      segments: segments,
      currentAudioVersion: await audioVersion(restored),
    );
    expect(target.seekTo, const Duration(seconds: 6));
    expect(b.store.assetForPath(restored)?.place?.label, '杭州市西湖区');
    final key = b.controller.recordingKeyFor(b.ref(restored));
    expect(b.topics.topicOf(key)?.title, '年度预算');

    final again = await b.controller.importMaterialPack(file.path);
    expect(again.duplicate, isTrue);
    expect(again.path, restored);
    expect(b.store.assets, hasLength(1));
    expect(b.controller.bookmarksFor(b.ref(restored)), hasLength(1));
    expect(b.topics.topics, hasLength(1));
    expect(
      b.imports.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.json'),
      ),
      hasLength(1),
    );
  });

  test('同一资料在本机已有另一份手改正文时，导入不覆盖，两份并列待比较', () async {
    final a = await library('a');
    addTearDown(a.controller.dispose);
    final path = await workedMaterial(a);
    final file = await a.controller.exportMaterialPack(
      a.ref(path),
      includeAudio: false,
    );

    // The same audio, edited differently on this device.
    await a.controller.saveManualTranscript(path, '本机这边改成了另一种说法。');
    final outcome = await a.controller.importMaterialPack(file.path);

    expect(outcome.conflict, isTrue);
    expect(a.controller.canonicalTranscriptForPath(path), '本机这边改成了另一种说法。');
    expect(
      a.controller.incomingTranscriptForPath(path),
      contains('预算要再确认一次（已核对）'),
    );
    expect(a.controller.bookmarksFor(a.ref(path)), hasLength(1));
    expect(a.store.assets, hasLength(1));
  });

  test('损坏或被截断的资料包如实报错，现有资料一点不变', () async {
    final a = await library('a');
    addTearDown(a.controller.dispose);
    final path = await workedMaterial(a);
    final file = await a.controller.exportMaterialPack(
      a.ref(path),
      includeAudio: true,
    );
    final bytes = await file.readAsBytes();

    final b = await library('b');
    addTearDown(b.controller.dispose);
    final kept = File('${temp.path}/已有.wav')
      ..writeAsBytesSync(wavBytes(List<int>.generate(800, (i) => i % 7)));
    final existing = await b.controller.importLocalAudio(kept.path);
    final before = await b.store.file!.readAsString();

    final truncated = File('${temp.path}/truncated.koepack')
      ..writeAsBytesSync(bytes.sublist(0, bytes.length - 100));
    final flipped = Uint8List.fromList(bytes);
    flipped[flipped.length - 10] ^= 0xff;
    final corrupt = File('${temp.path}/corrupt.koepack')
      ..writeAsBytesSync(flipped);

    for (final (pack, message) in [
      (truncated, '资料包不完整：原音频被截断'),
      (corrupt, '资料包已损坏：原音频校验不一致'),
    ]) {
      await expectLater(
        b.controller.importMaterialPack(pack.path),
        throwsA(
          isA<MaterialPackException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
    }
    expect(await b.store.file!.readAsString(), before);
    expect(b.store.assets.single.path, existing.path);
    expect(b.controller.minutesDocuments, isEmpty);
    expect(
      b.imports.listSync().whereType<File>().where(
        (f) => !f.path.endsWith('.json'),
      ),
      hasLength(1),
    );
  });

  test('不含原音频的资料包导入干净资料库时明确缺音频，补配同一原音频后完整恢复', () async {
    final a = await library('a');
    addTearDown(a.controller.dispose);
    final path = await workedMaterial(a);
    final file = await a.controller.exportMaterialPack(
      a.ref(path),
      includeAudio: false,
    );
    expect(await file.length(), lessThan(await File(path).length()));

    final b = await library('b');
    addTearDown(b.controller.dispose);
    final outcome = await b.controller.importMaterialPack(file.path);
    expect(outcome.path, isNull);
    final document = b.controller.minutesDocumentById(outcome.minutesId!)!;
    expect(document.textOnly, isTrue);
    expect(document.warning, contains('没有包含原音频'));
    expect(document.bodyText, contains('预算要再确认一次（已核对）'));
    expect(b.store.assets, isEmpty);

    final again = await b.controller.importMaterialPack(file.path);
    expect(again.duplicate, isTrue);
    expect(b.controller.minutesDocuments, hasLength(1));

    // A different audio is refused; the same original completes the pack.
    final wrong = File('${temp.path}/别的.wav')
      ..writeAsBytesSync(wavBytes(List<int>.generate(4000, (i) => i % 13)));
    final refused = await b.controller.attachMinutesAudio(
      document.id,
      wrong.path,
    );
    expect(refused.ok, isFalse);
    final paired = await b.controller.attachMinutesAudio(document.id, path);
    expect(paired.ok, isTrue);
    final restored = paired.restoredPath!;
    expect(b.controller.minutesDocuments, isEmpty);
    expect(b.controller.recordingView(b.ref(restored)).title, '周会');
    expect(b.controller.bookmarksFor(b.ref(restored)).single.note, '预算待确认');
    expect(b.controller.speakerAliasesForPath(restored), {'1': '王老师'});
  });

  testWidgets('资料详情 → 更多 → 导出资料包（含原音频），另一台设备导入后详情页显示校订和书签', (tester) async {
    final (a, b, path) = (await tester.runAsync(() async {
      final a = await library('a');
      final b = await library('b');
      return (a, b, await workedMaterial(a));
    }))!;
    addTearDown(a.controller.dispose);
    addTearDown(b.controller.dispose);

    File? shared;
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: a.controller,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showMaterialExportSheet(
                    context,
                    a.ref(path),
                    share: (context, file, title) async {
                      shared = File('${temp.path}/shared.koepack');
                      await file.copy(shared!.path);
                      return true;
                    },
                  ),
                  child: const Text('导出…'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('导出…'));
    await tester.pumpAndSettle();

    final contents = find.byKey(const ValueKey('material-export-contents'));
    expect(
      find.descendant(of: contents, matching: find.text('含你的校订')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: contents, matching: find.text('1 个')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: contents,
        matching: find.text('不包含；导入后需补配同一份原音频才能回听'),
      ),
      findsOneWidget,
    );
    // Audio goes in only when the user turns it on.
    await tester.tap(find.byKey(const ValueKey('material-export-audio')));
    await tester.pump();
    expect(
      find.descendant(of: contents, matching: find.textContaining('包含（')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('material-export-share')));
    // Real file writes finish outside the fake clock; pump until the sheet
    // reports the result instead of guessing a delay.
    final done = find.text('已导出资料包（含原音频）');
    for (var i = 0; i < 300 && done.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(shared, isNotNull);
    expect(find.text('已导出资料包（含原音频）'), findsOneWidget);

    final restored = (await tester.runAsync(
      () => b.controller.importMaterialPack(shared!.path),
    ))!.path!;
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: b.controller,
        child: MaterialApp(
          home: RecordingDetailScreen(reference: b.ref(restored)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('周会'), findsWidgets);
    expect(find.textContaining('预算要再确认一次（已核对）'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('bookmark-list-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bookmark-list')),
        matching: find.textContaining('预算待确认'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('不含原音频导入的资料，在文字资料页说明缺音频', (tester) async {
    final (b, id) = (await tester.runAsync(() async {
      final a = await library('a');
      final path = await workedMaterial(a);
      final file = await a.controller.exportMaterialPack(
        a.ref(path),
        includeAudio: false,
      );
      a.controller.dispose();
      final b = await library('b');
      return (b, (await b.controller.importMaterialPack(file.path)).minutesId!);
    }))!;
    addTearDown(b.controller.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: b.controller,
        child: MaterialApp(home: MinutesDocumentScreen(documentId: id)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('资料包没有包含原音频'), findsOneWidget);
    expect(find.textContaining('1 个书签的回听'), findsOneWidget);
  });
}
