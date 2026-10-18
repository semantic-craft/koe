import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/minutes_document.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/ui/screens/library_screen.dart';
import 'package:koe/ui/screens/minutes_document_screen.dart';
import 'package:provider/provider.dart';

import 'support/wav_fixture.dart';

void main() {
  late Directory temp;
  late File minutesFile;
  late File libraryFile;
  late Directory imports;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('koe-minutes-');
    minutesFile = File('${temp.path}/minutes_documents.json');
    libraryFile = File('${temp.path}/recording_library.json');
    imports = Directory('${temp.path}/imports');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  RecorderController controller() => RecorderController(
    loadPersistedState: false,
    libraryStore: RecordingLibraryStore(file: libraryFile),
    libraryDirectory: imports,
    minutesStore: MinutesDocumentStore(file: minutesFile),
  );

  const json = '''
{
  "title": "产品讨论",
  "recordedAt": "2026-10-17T09:30:00+08:00",
  "segments": [
    {"speaker": "林舟", "start": "00:00", "text": "先做手机上的录音与回听。"},
    {"speaker": "我", "start": "00:12", "text": "保留原音频，再点字定位。"},
    {"speaker": "林舟", "start": "00:26", "text": "外部 AI 放到后面。"}
  ]
}
''';

  Future<File> audio(String name, Duration duration) async {
    final file = File('${temp.path}/$name.wav');
    final samples = (16000 * duration.inMilliseconds / 1000).round();
    await file.writeAsBytes(wavBytes(List<int>.filled(samples * 2, 0)));
    return file;
  }

  test('妙记 JSON 保留发言人与真实发生时间，重复导入不新增资料', () async {
    final c = controller();
    addTearDown(c.dispose);
    final first = await c.importMinutesText('讨论.json', json);

    expect(first.duplicate, isFalse);
    expect(first.document.title, '产品讨论');
    expect(
      first.document.capturedAt,
      DateTime.parse('2026-10-17T09:30:00+08:00'),
    );
    expect(
      first.document.importedAt.difference(first.document.capturedAt!).inHours,
      greaterThan(1),
    );
    expect(first.document.segments[1].speaker, '我');
    expect(first.document.segments[1].start, const Duration(seconds: 12));
    expect(first.document.timingReliable, isTrue);
    expect(first.document.textOnly, isTrue);

    final second = await c.importMinutesText('讨论.json', json);
    expect(second.duplicate, isTrue);
    expect(second.document.id, first.document.id);
    expect(c.minutesDocuments, hasLength(1));
  });

  test('全零或缺失时码只保留阅读，不显示可定位', () async {
    final zero = parseMinutesDocument(
      'zero.json',
      '{"title":"只有文字","segments":[{"start":0,"text":"第一句"},{"start":0,"text":"第二句"}]}',
    );
    expect(zero.document.timingReliable, isFalse);
    expect(zero.document.textOnly, isTrue);
    expect(zero.document.warning, isNotNull);

    final text = parseMinutesDocument('plain.txt', '第一行没有时间\n第二行也没有');
    expect(text.document.timingReliable, isFalse);
    expect(text.document.segments.single.text, contains('第二行'));

    final speakers = parseMinutesDocument('speakers.txt', '林舟：第一句\n我：第二句');
    expect(speakers.document.segments, hasLength(2));
    expect(speakers.document.segments[0].speaker, '林舟');
    expect(speakers.document.segments[1].speaker, '我');

    expect(
      () => parseMinutesDocument('empty.json', '{"title":"空记录","segments":[]}'),
      throwsFormatException,
    );
  });

  test('补配音频覆盖最后时码才建立配对，过短音频被拒绝且不留下资料', () async {
    final c = controller();
    addTearDown(c.dispose);
    final imported = await c.importMinutesText('讨论.json', json);
    final short = await audio('short', const Duration(seconds: 3));

    final rejected = await c.attachMinutesAudio(
      imported.document.id,
      short.path,
    );
    expect(rejected.ok, isFalse);
    expect(rejected.message, contains('比文字时码短'));
    expect(c.minutesDocuments.single.audioPath, isNull);
    expect(c.exportedPaths, isEmpty);

    final long = await audio('long', const Duration(seconds: 40));
    final accepted = await c.attachMinutesAudio(
      imported.document.id,
      long.path,
    );
    expect(accepted.ok, isTrue);
    expect(accepted.document!.audioPath, isNotNull);
    expect(accepted.document!.unaligned, isFalse);
    expect(c.exportedPaths, contains(accepted.document!.audioPath));
  });

  test('重启恢复导入文字与原音频配对', () async {
    final first = controller();
    final imported = await first.importMinutesText('讨论.json', json);
    final long = await audio('long', const Duration(seconds: 40));
    final attached = await first.attachMinutesAudio(
      imported.document.id,
      long.path,
    );
    expect(attached.ok, isTrue);
    final audioPath = attached.document!.audioPath;
    first.dispose();

    final restarted = controller();
    addTearDown(restarted.dispose);
    await restarted.waitForMinutesDocuments();
    await restarted.waitForRecordingLibrary();

    final restored = restarted.minutesDocuments.single;
    expect(restored.title, '产品讨论');
    expect(restored.audioPath, audioPath);
    expect(restored.timingReliable, isTrue);
    expect(File(audioPath!).existsSync(), isTrue);
  });

  testWidgets('只有文字的资料不显示假播放器，配好音频后点句回听', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late _PlaybackProbeController c;
    late MinutesImportOutcome imported;
    await tester.runAsync(() async {
      c = _PlaybackProbeController(
        libraryFile: libraryFile,
        imports: imports,
        minutesFile: minutesFile,
      );
      imported = await c.importMinutesText('讨论.json', json);
    });
    addTearDown(c.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(ValueKey('minutes-row-${imported.document.id}')),
      findsOneWidget,
    );
    expect(find.textContaining('只有文字'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey('minutes-row-${imported.document.id}')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MinutesDocumentScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('minutes-text-only')), findsOneWidget);
    expect(find.byKey(const ValueKey('minutes-play-all')), findsNothing);

    await tester.runAsync(() async {
      final long = await audio('long', const Duration(seconds: 40));
      await c.attachMinutesAudio(imported.document.id, long.path);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('minutes-play-all')), findsOneWidget);

    await tester.tap(find.text('先做手机上的录音与回听。'));
    await tester.pump();
    expect(c.requests, hasLength(1));
    expect(c.requests.single.$2, Duration.zero);
    expect(c.requests.single.$1, c.minutesDocuments.single.audioPath);

    await tester.runAsync(
      () => File(c.minutesDocuments.single.audioPath!).delete(),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: c,
        child: MaterialApp(
          home: MinutesDocumentScreen(documentId: imported.document.id),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已配对，但原件不可用'), findsOneWidget);
    final play = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('minutes-play-all')),
    );
    expect(play.onPressed, isNull);
  });

  test('保存失败会回滚内存文档，重试不会误报重复', () async {
    final blocker = File('${temp.path}/blocked');
    await blocker.writeAsString('not a directory');
    final store = MinutesDocumentStore(
      file: File('${blocker.path}/minutes.json'),
    );
    final document = parseMinutesDocument('a.txt', '一段文字').document;

    await expectLater(
      store.upsert(document),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.documents, isEmpty);
  });

  test('改名或删除音频后同步补配引用', () async {
    final c = controller();
    addTearDown(c.dispose);
    final imported = await c.importMinutesText('讨论.json', json);
    final long = await audio('long', const Duration(seconds: 40));
    final attached = await c.attachMinutesAudio(
      imported.document.id,
      long.path,
    );
    final oldPath = attached.document!.audioPath!;

    final renamed = await c.renameLocalExport(oldPath, '改名后的录音');
    expect(c.minutesDocuments.single.audioPath, renamed);
    expect(File(renamed).existsSync(), isTrue);

    final removed = await c.deleteLocalExports([renamed]);
    expect(removed.deleted, 1);
    expect(c.minutesDocuments.single.audioPath, isNull);
  });
}

class _PlaybackProbeController extends RecorderController {
  _PlaybackProbeController({
    required File libraryFile,
    required Directory imports,
    required File minutesFile,
  }) : super(
         loadPersistedState: false,
         libraryStore: RecordingLibraryStore(file: libraryFile),
         libraryDirectory: imports,
         minutesStore: MinutesDocumentStore(file: minutesFile),
       );

  final requests = <(String, Duration, int?)>[];

  @override
  Future<void> playFrom(String path, Duration start, {int? fileId}) async {
    requests.add((path, start, fileId));
  }
}
