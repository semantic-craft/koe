import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_bookmarks.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

TranscriptSegment _segment(String text, int startMs, [int? endMs]) =>
    TranscriptSegment(
      text: text,
      start: Duration(milliseconds: startMs),
      end: endMs == null ? null : Duration(milliseconds: endMs),
    );

final _segments = [
  _segment('第一句', 0, 5000),
  _segment('第二句，预算要再确认', 12000, 20000),
  _segment('第三句', 25000, 31000),
];

RecordingViewData _view(
  RecordingReference reference,
  List<TranscriptSegment> segments, {
  bool originalPresent = true,
}) => RecordingViewData(
  reference: reference,
  title: '访谈录音',
  path: reference.path,
  text: segments.map((segment) => segment.text).join(),
  segments: segments,
  originalPresent: originalPresent,
);

void main() {
  late Directory temp;
  late RecordingReference ref;
  late RecordingReference other;
  late String audio;

  RecordingReference audioRef(int id, {List<int>? bytes}) {
    final file = File('${temp.path}/$id.wav')
      ..writeAsBytesSync(
        bytes ?? List<int>.generate(256, (i) => (i * id) % 251),
      );
    return RecordingReference(fileId: id, path: file.path);
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('koe-bookmarks-');
    ref = audioRef(100);
    other = audioRef(200);
    audio = ref.path!;
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Store and controller are built and loaded in the real zone: their load
  /// and save queues must not be created on the fake test clock.
  Future<_BookmarkController> start(
    WidgetTester tester,
    RecordingBookmarkStore Function() store, {
    List<TranscriptSegment>? segments,
  }) async {
    final controller = (await tester.runAsync(() async {
      final created = store();
      await created.load();
      final controller = _BookmarkController(created);
      await controller.waitForBookmarks();
      return controller;
    }))!;
    addTearDown(controller.dispose);
    controller.views[ref.key] = _view(ref, segments ?? _segments);
    controller.views[other.key] = _view(other, _segments);
    return controller;
  }

  /// Real file reads/writes finish outside the fake clock; pump until the
  /// visible result exists instead of guessing a delay.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: '等待的结果没有出现');
    await tester.pumpAndSettle();
  }

  Future<void> show(
    WidgetTester tester,
    _BookmarkController controller,
    RecordingReference reference,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<RecorderController>.value(
        value: controller,
        child: MaterialApp(
          theme: AppTheme.light,
          home: RecordingDetailScreen(
            key: ValueKey(reference.key),
            reference: reference,
          ),
        ),
      ),
    );
    await tester.pump();
    await until(tester, () => !controller.bookmarkAudioReading);
  }

  Future<void> addAt(
    WidgetTester tester,
    _BookmarkController c,
    Duration at, {
    String? note,
  }) async {
    final before = c.bookmarksFor(c.shown).length;
    c.setPlayback(c.views[c.shown.key]!.path!, at);
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    if (note != null) {
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-note-field')),
        note,
      );
    }
    await tester.tap(find.text('保存'));
    await until(tester, () => c.bookmarksFor(c.shown).length == before + 1);
  }

  Future<void> openList(WidgetTester tester) async {
    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
  }

  Future<void> closeList(WidgetTester tester) async {
    Navigator.of(
      tester.element(find.byKey(const ValueKey('bookmark-list'))),
    ).pop();
    await tester.pumpAndSettle();
  }

  Finder marker(int index) => find.byKey(ValueKey('player-marker-$index'));

  /// Replay re-reads the audio content before playing; wait for that check.
  Future<void> replay(
    WidgetTester tester,
    _BookmarkController c,
    Finder target,
  ) async {
    await tester.tap(target);
    await tester.pump();
    await until(tester, () => !c.bookmarkAudioReading);
  }

  testWidgets('播放时为片段加批注，重启后进度标记与列表都回到同一原声', (tester) async {
    final file = File('${temp.path}/bookmarks.json');
    final first = await start(tester, () => RecordingBookmarkStore(file: file));
    await show(tester, first..shown = ref, ref);

    await addAt(tester, first, const Duration(seconds: 14), note: '预算数字要再核对');
    expect(find.text('已保存书签'), findsOneWidget);
    await addAt(tester, first, const Duration(seconds: 26));
    expect(marker(1), findsOneWidget, reason: '再加一个书签不能覆盖前一个');

    await tester.pumpWidget(const SizedBox());
    final second = await start(
      tester,
      () => RecordingBookmarkStore(file: file),
    );
    await show(tester, second..shown = ref, ref);

    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-bookmark-2')), findsOneWidget);
    await replay(tester, second, marker(1));
    expect(second.playbackRequests, [
      (audio, const Duration(seconds: 26), 100),
    ]);

    await openList(tester);
    expect(find.text('预算数字要再核对'), findsOneWidget);
    await replay(tester, second, find.byKey(const ValueKey('bookmark-item-0')));
    expect(second.playbackRequests.last, (
      audio,
      const Duration(seconds: 14),
      100,
    ));

    await openList(tester);
    await tester.tap(find.byTooltip('编辑批注').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-note-field')),
      '预算已和财务确认',
    );
    await tester.tap(find.text('保存'));
    await until(
      tester,
      () => second.bookmarksFor(ref).first.note == '预算已和财务确认',
    );
    expect(find.text('已更新批注'), findsOneWidget);
    final reloaded = RecordingBookmarkStore(file: file);
    await tester.runAsync(reloaded.load);
    expect(
      reloaded.forRecording(second.recordingKeyFor(ref)).first.note,
      '预算已和财务确认',
    );
  });

  testWidgets('同文短句、无结束时间与句间空隙都回到保存时的真实位置', (tester) async {
    final shortRef = audioRef(300);
    final openRef = audioRef(400);
    final c = await start(
      tester,
      () => RecordingBookmarkStore(file: File('${temp.path}/b.json')),
    );
    c.views[shortRef.key] = _view(shortRef, [
      _segment('嗯', 0, 400),
      _segment('嗯', 600, 900),
      _segment('我们开始吧', 2000, 4000),
    ]);
    c.views[openRef.key] = _view(openRef, [
      _segment('第一句', 0),
      _segment('第二句', 12000),
      _segment('第三句', 25000),
    ]);

    await show(tester, c..shown = shortRef, shortRef);
    await addAt(tester, c, const Duration(milliseconds: 600));
    await replay(tester, c, marker(0));
    expect(c.playbackRequests.last.$2, const Duration(milliseconds: 600));

    await show(tester, c..shown = openRef, openRef);
    await addAt(tester, c, const Duration(seconds: 18));
    await replay(tester, c, marker(0));
    expect(
      c.playbackRequests.last.$2,
      const Duration(seconds: 18),
      reason: '未知结束时间不能当作长度 0',
    );

    await show(tester, c..shown = ref, ref);
    await addAt(tester, c, const Duration(seconds: 10));
    expect(
      find.byKey(const ValueKey('segment-bookmark-0')),
      findsNothing,
      reason: '空隙里的书签不能标到前一句上',
    );
    await replay(tester, c, marker(0));
    expect(
      c.playbackRequests.last.$2,
      const Duration(seconds: 10),
      reason: '句间空隙不属于前一句',
    );
  });

  testWidgets('转写或原音频变化后不跳到别的句子，缺音频时说明原因', (tester) async {
    final c = await start(
      tester,
      () => RecordingBookmarkStore(file: File('${temp.path}/b.json')),
    );
    await show(tester, c..shown = ref, ref);
    await addAt(tester, c, const Duration(seconds: 14), note: '核对');

    // Re-transcription inserted a sentence; the bookmarked one keeps its time.
    c.views[ref.key] = _view(ref, [
      _segment('第一句', 0, 5000),
      _segment('新识别出的一句', 6000, 11000),
      _segment('第二句，预算要再确认', 12000, 20000),
      _segment('第三句', 25000, 31000),
    ]);
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('segment-bookmark-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);
    await replay(tester, c, marker(0));
    expect(c.playbackRequests, [(audio, const Duration(seconds: 14), 100)]);

    // The sentence itself changed: never land on whatever sits there now.
    c.views[ref.key] = _view(ref, [
      _segment('第一句', 0, 5000),
      _segment('第二句改成了另一件事', 12000, 20000),
      _segment('第三句', 25000, 31000),
    ]);
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(marker(0), findsNothing);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);
    await openList(tester);
    expect(find.textContaining('转写已更新，原片段已不存在'), findsOneWidget);
    expect(find.text('核对'), findsOneWidget, reason: '个人批注仍可阅读');
    await replay(tester, c, find.byKey(const ValueKey('bookmark-item-0')));
    expect(c.playbackRequests, hasLength(1));
    await closeList(tester);

    // The original was replaced and re-transcribed to the same text: the
    // controller's audioChanged flag is clear again, the audio is not.
    c.views[ref.key] = _view(ref, _segments);
    await tester.runAsync(
      () => File(audio).writeAsBytes(List<int>.filled(512, 7), flush: true),
    );
    c.notifyListeners();
    await tester.pump();
    await until(tester, () => !c.bookmarkAudioReading);
    expect(marker(0), findsNothing);
    await openList(tester);
    expect(find.textContaining('原音频已变化'), findsOneWidget);
    await replay(tester, c, find.byKey(const ValueKey('bookmark-item-0')));
    expect(c.playbackRequests, hasLength(1));

    c.views[ref.key] = _view(ref, _segments, originalPresent: false);
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('原录音不在本机'), findsOneWidget);
    await replay(tester, c, find.byKey(const ValueKey('bookmark-item-0')));
    expect(c.playbackRequests, hasLength(1));
  });

  testWidgets('保存失败保留草稿并提示未保存，取消不留下书签', (tester) async {
    final blocker = File('${temp.path}/not-a-directory')
      ..writeAsStringSync('x');
    final c = await start(
      tester,
      () => RecordingBookmarkStore(file: File('${blocker.path}/b.json')),
    );
    await show(tester, c..shown = ref, ref);

    c.setPlayback(audio, const Duration(seconds: 13));
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-note-field')),
      '先记下这一句',
    );
    await tester.tap(find.text('保存'));
    await until(
      tester,
      () => find
          .byKey(const ValueKey('bookmark-save-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('未保存'), findsOneWidget);
    expect(find.text('先记下这一句'), findsOneWidget, reason: '草稿不能丢');
    expect(c.bookmarksFor(ref), isEmpty);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('已取消，未保存书签'), findsOneWidget);
    expect(marker(0), findsNothing);
    await openList(tester);
    expect(find.byKey(const ValueKey('bookmark-list-empty')), findsOneWidget);
  });

  testWidgets('保存进行中点遮罩不能关闭，结果与实际写入一致', (tester) async {
    late _GatedStore store;
    final c = await start(
      tester,
      () => store = _GatedStore(File('${temp.path}/b.json')),
    );
    await show(tester, c..shown = ref, ref);
    store.hold();

    c.setPlayback(audio, const Duration(seconds: 13));
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await until(tester, () => store.writing);
    await tester.tapAt(const Offset(195, 40));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookmark-note-field')), findsOneWidget);
    expect(find.text('已取消，未保存书签'), findsNothing);

    store.release();
    await until(tester, () => c.bookmarksFor(ref).length == 1);
    expect(find.text('已保存书签'), findsOneWidget);
    expect(find.text('已取消，未保存书签'), findsNothing);
    expect(find.byKey(const ValueKey('bookmark-note-field')), findsNothing);
  });

  testWidgets('书签文件损坏且无法另存时明确提示，并且不覆盖原文件', (tester) async {
    final file = File('${temp.path}/b.json')..writeAsStringSync('{坏掉的内容');
    final c = await start(tester, () => _NoBackupStore(file));
    await show(tester, c..shown = ref, ref);

    await openList(tester);
    expect(find.textContaining('未能另存原文件'), findsOneWidget);
    expect(find.textContaining('已另存'), findsNothing);
    await closeList(tester);

    c.setPlayback(audio, const Duration(seconds: 13));
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await until(
      tester,
      () => find
          .byKey(const ValueKey('bookmark-save-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(file.readAsStringSync(), '{坏掉的内容');
  });

  String partlyBroken() => jsonEncode({
    'version': 1,
    'showMarkers': true,
    'bookmarks': [
      {
        'id': 'ok',
        'recordingKey': 'file:100',
        'positionMs': 3000,
        'note': '有效批注',
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-01-01T00:00:00.000',
      },
      {
        'id': 'bad',
        'recordingKey': 'file:100',
        'positionMs': '坏',
        'note': '坏条目里的批注',
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-01-01T00:00:00.000',
      },
    ],
  });

  testWidgets('个别书签条目损坏时另存原文件，后续修改不丢坏条目内容', (tester) async {
    final file = File('${temp.path}/b.json')..writeAsStringSync(partlyBroken());
    final c = await start(tester, () => RecordingBookmarkStore(file: file));
    await show(tester, c..shown = ref, ref);

    await openList(tester);
    expect(
      find.byKey(const ValueKey('bookmark-recovery-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('已另存原文件'), findsOneWidget);
    expect(find.textContaining('有效批注'), findsOneWidget);
    await closeList(tester);

    await addAt(tester, c, const Duration(seconds: 13), note: '新批注');

    final backups = temp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('b.json.corrupt-'))
        .toList();
    expect(backups, hasLength(1));
    expect(backups.single.readAsStringSync(), contains('坏条目里的批注'));
    final reloaded = (await tester.runAsync(() async {
      final store = RecordingBookmarkStore(file: file);
      await store.load();
      return store.forRecording('file:100').map((b) => b.note).toList();
    }))!;
    expect(reloaded, unorderedEquals(['有效批注', '新批注']));
  });

  testWidgets('个别书签条目损坏且无法另存时禁止写入，原文件保持不变', (tester) async {
    final original = partlyBroken();
    final file = File('${temp.path}/b.json')..writeAsStringSync(original);
    final c = await start(tester, () => _NoBackupStore(file));
    await show(tester, c..shown = ref, ref);

    await openList(tester);
    expect(find.textContaining('未能另存原文件'), findsOneWidget);
    expect(find.textContaining('有效批注'), findsOneWidget);
    await closeList(tester);

    c.setPlayback(audio, const Duration(seconds: 13));
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await until(
      tester,
      () => find
          .byKey(const ValueKey('bookmark-save-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(file.readAsStringSync(), original);
  });

  testWidgets('其他录音不显示本录音书签，关闭标记显示不删除书签', (tester) async {
    final file = File('${temp.path}/bookmarks.json');
    final c = await start(tester, () => RecordingBookmarkStore(file: file));
    await show(tester, c..shown = ref, ref);
    await addAt(tester, c, const Duration(seconds: 12), note: '只属于访谈');

    await show(tester, c..shown = other, other);
    expect(marker(0), findsNothing);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);
    await openList(tester);
    expect(find.byKey(const ValueKey('bookmark-list-empty')), findsOneWidget);
    expect(find.text('只属于访谈'), findsNothing);
    await closeList(tester);

    await show(tester, c..shown = ref, ref);
    expect(marker(0), findsOneWidget);
    await openList(tester);
    await tester.tap(find.byKey(const ValueKey('bookmark-markers-switch')));
    await until(tester, () => !c.showBookmarkMarkers);
    expect(find.text('只属于访谈'), findsOneWidget);
    await closeList(tester);
    expect(marker(0), findsNothing);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    final again = await start(tester, () => RecordingBookmarkStore(file: file));
    await show(tester, again..shown = ref, ref);
    expect(marker(0), findsNothing);
    await openList(tester);
    expect(find.text('只属于访谈'), findsOneWidget);
    await replay(tester, again, find.byKey(const ValueKey('bookmark-item-0')));
    expect(again.playbackRequests, [(audio, const Duration(seconds: 12), 100)]);
  });

  test('删除资料时等待中的书签写入也一并清除，重启后不复活', () async {
    final file = File('${temp.path}/b.json');
    final store = _GatedStore(file);
    await store.load();
    final c = RecorderController(
      loadPersistedState: false,
      bookmarkStore: store,
    );
    addTearDown(c.dispose);
    await c.waitForBookmarks();
    c.exportedPaths.add(audio);

    store.hold();
    final adding = c.addBookmark(ref, position: const Duration(seconds: 3));
    await store.entered.future;
    final deleting = c.deleteLocalExports([audio]);
    await store.forgetRequested.future;
    store.release();
    await adding;
    final result = await deleting;

    expect(result.deleted, 1);
    expect(c.bookmarksFor(ref), isEmpty);
    final reloaded = RecordingBookmarkStore(file: file);
    await reloaded.load();
    expect(reloaded.forRecording(c.recordingKeyFor(ref)), isEmpty);
  });

  test('算音频指纹期间资料被删除，书签不会在删除后写入', () async {
    final file = File('${temp.path}/b.json');
    final store = RecordingBookmarkStore(file: file);
    await store.load();
    final c = _HashGateController(store);
    addTearDown(c.dispose);
    await c.waitForBookmarks();
    c.exportedPaths.add(audio);

    final adding = c.addBookmark(ref, position: const Duration(seconds: 3));
    await c.hashing.future;
    final result = await c.deleteLocalExports([audio]);
    expect(result.deleted, 1);
    c.gate.complete();
    await expectLater(
      adding,
      throwsA(
        isA<BookmarkSaveException>().having(
          (e) => e.message,
          'message',
          contains('已被删除'),
        ),
      ),
    );

    expect(c.bookmarksFor(ref), isEmpty);
    final reloaded = RecordingBookmarkStore(file: file);
    await reloaded.load();
    expect(reloaded.forRecording(c.recordingKeyFor(ref)), isEmpty);
  });

  testWidgets('无法确认原音频时不保存，旧的无指纹书签不当作来源已确认', (tester) async {
    final file = File('${temp.path}/b.json');
    final c = await start(tester, () => RecordingBookmarkStore(file: file));
    await show(tester, c..shown = ref, ref);
    c.audioUnreadable = true;
    c.setPlayback(audio, const Duration(seconds: 14));
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-note-field')),
      '想记下这句',
    );
    await tester.tap(find.text('保存'));
    await until(
      tester,
      () => find
          .byKey(const ValueKey('bookmark-save-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.textContaining('无法读取原音频'), findsOneWidget);
    expect(find.text('想记下这句'), findsOneWidget);
    expect(c.bookmarksFor(ref), isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    final now = DateTime(2026, 10, 1).toIso8601String();
    file.writeAsStringSync(
      '{"version":1,"showMarkers":true,"bookmarks":[{"id":"old",'
      '"recordingKey":"file:100","positionMs":14000,'
      '"segmentText":"第二句，预算要再确认","segmentStartMs":12000,'
      '"segmentEndMs":20000,"note":"旧书签",'
      '"createdAt":"$now","updatedAt":"$now"}]}',
    );
    final again = await start(tester, () => RecordingBookmarkStore(file: file));
    await show(tester, again..shown = ref, ref);
    expect(marker(0), findsNothing);
    await openList(tester);
    expect(find.text('旧书签'), findsOneWidget);
    expect(find.textContaining('没有记录原音频版本'), findsOneWidget);
    await replay(tester, again, find.byKey(const ValueKey('bookmark-item-0')));
    expect(again.playbackRequests, isEmpty);
  });

  testWidgets('重转写后同文句段变短，越出新范围的书签不跳到下一句', (tester) async {
    final c = await start(
      tester,
      () => RecordingBookmarkStore(file: File('${temp.path}/b.json')),
    );
    await show(tester, c..shown = ref, ref);
    await addAt(tester, c, const Duration(seconds: 19));

    c.views[ref.key] = _view(ref, [
      _segment('第一句', 0, 5000),
      _segment('第二句，预算要再确认', 13000, 18000),
      _segment('紧接着的下一句', 18000, 24000),
      _segment('第三句', 25000, 31000),
    ]);
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(marker(0), findsNothing);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);
    await openList(tester);
    expect(find.textContaining('超出原片段的新范围'), findsOneWidget);
    await replay(tester, c, find.byKey(const ValueKey('bookmark-item-0')));
    expect(c.playbackRequests, isEmpty);
  });

  testWidgets('原音频被同大小同修改时间替换，点击回听时重新核验不放行', (tester) async {
    final c = await start(
      tester,
      () => RecordingBookmarkStore(file: File('${temp.path}/b.json')),
    );
    await show(tester, c..shown = ref, ref);
    await addAt(tester, c, const Duration(seconds: 14));

    final original = File(audio);
    final modified = original.lastModifiedSync();
    final length = original.lengthSync();
    await tester.runAsync(() async {
      await original.writeAsBytes(List<int>.filled(length, 9), flush: true);
      await original.setLastModified(modified);
    });
    expect(original.lengthSync(), length);
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(marker(0), findsOneWidget, reason: '仅凭大小与时间无法看出替换');
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();

    await replay(tester, c, marker(0));
    expect(c.playbackRequests, isEmpty);
    expect(find.textContaining('原音频已变化'), findsOneWidget);
  });
}

class _BookmarkController extends RecorderController {
  _BookmarkController(RecordingBookmarkStore store)
    : super(loadPersistedState: false, bookmarkStore: store);

  final views = <String, RecordingViewData>{};
  final playbackRequests = <(String, Duration, int?)>[];
  late RecordingReference shown;
  bool audioUnreadable = false;

  @override
  Future<String?> readBookmarkAudioVersion(String path) async =>
      audioUnreadable ? null : super.readBookmarkAudioVersion(path);

  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      views[reference.key] ?? super.recordingView(reference);

  @override
  Duration? localDurationForPath(String path) => const Duration(seconds: 40);

  @override
  Future<void> playFrom(String path, Duration start, {int? fileId}) async {
    playbackRequests.add((path, start, fileId));
  }

  @override
  Future<void> refreshFilesOnTabEnter() async {}

  @override
  Future<void> refreshInfoOnDeviceTabEnter() async {}

  void setPlayback(String path, Duration at) {
    playingPath = path;
    position = at;
    notifyListeners();
  }
}

/// Holds a real write open so the save queue can be observed mid-flight.
/// Holds the audio digest read open: the window before the store queue.
class _HashGateController extends RecorderController {
  _HashGateController(RecordingBookmarkStore store)
    : super(loadPersistedState: false, bookmarkStore: store);

  final gate = Completer<void>();
  final hashing = Completer<void>();

  @override
  Future<String?> readBookmarkAudioVersion(String path) async {
    // The digest is read before the delete; only the hand-back is delayed.
    final version = await super.readBookmarkAudioVersion(path);
    if (!hashing.isCompleted) hashing.complete();
    await gate.future;
    return version;
  }
}

class _GatedStore extends RecordingBookmarkStore {
  _GatedStore(File file) : super(file: file);

  Completer<void>? _gate;
  final entered = Completer<void>();
  final forgetRequested = Completer<void>();
  bool writing = false;

  void hold() => _gate = Completer<void>();
  void release() => _gate?.complete();

  @override
  Future<void> writeSnapshot(String json) async {
    writing = true;
    if (!entered.isCompleted) entered.complete();
    await _gate?.future;
    _gate = null;
    await super.writeSnapshot(json);
    writing = false;
  }

  @override
  Future<void> forgetRecording(String recordingKey) {
    if (!forgetRequested.isCompleted) forgetRequested.complete();
    return super.forgetRecording(recordingKey);
  }
}

class _NoBackupStore extends RecordingBookmarkStore {
  _NoBackupStore(File file) : super(file: file);

  @override
  Future<void> backupUnreadable(
    File target, {
    bool keepOriginal = false,
  }) async => throw const FileSystemException('backup refused');
}
