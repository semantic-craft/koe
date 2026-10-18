import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recorder_controller.dart';
import 'package:koe/state/recording_bookmarks.dart';
import 'package:koe/theme/app_theme.dart';
import 'package:koe/ui/screens/recording_detail_screen.dart';
import 'package:provider/provider.dart';

const _path = '/tmp/100.wav';
const _reference = RecordingReference(fileId: 100, path: _path);
const _otherReference = RecordingReference(fileId: 200, path: '/tmp/200.wav');

TranscriptSegment _segment(String text, int start, int end) =>
    TranscriptSegment(
      text: text,
      start: Duration(seconds: start),
      end: Duration(seconds: end),
    );

final _segments = [
  _segment('第一句', 0, 5),
  _segment('第二句，预算要再确认', 12, 20),
  _segment('第三句', 25, 31),
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

  setUp(() => temp = Directory.systemTemp.createTempSync('koe-bookmarks-'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<_BookmarkController> start(
    WidgetTester tester,
    File file, {
    List<TranscriptSegment>? segments,
  }) async {
    final store = RecordingBookmarkStore(file: file);
    await tester.runAsync(store.load);
    final controller = _BookmarkController(store);
    await tester.runAsync(controller.waitForBookmarks);
    controller.views[_reference.key] = _view(_reference, segments ?? _segments);
    controller.views[_otherReference.key] = _view(_otherReference, _segments);
    return controller;
  }

  Future<void> show(
    WidgetTester tester,
    RecorderController controller,
    RecordingReference reference,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
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
    await tester.pumpAndSettle();
  }

  /// Real file writes finish outside the fake clock; pump until the visible
  /// result exists instead of guessing a delay.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: '等待的保存结果没有出现');
    await tester.pumpAndSettle();
  }

  Future<void> restart(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('播放时为片段加批注，重启后进度标记与列表都回到同一原声', (tester) async {
    final file = File('${temp.path}/bookmarks.json');
    final first = await start(tester, file);
    addTearDown(first.dispose);
    await show(tester, first, _reference);

    first.setPlayback(_path, const Duration(seconds: 14));
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    expect(find.text('00:14'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-note-field')),
      '预算数字要再核对',
    );
    await tester.tap(find.text('保存'));
    await until(tester, () => first.bookmarksFor(_reference).length == 1);
    expect(find.text('已保存书签'), findsOneWidget);

    first.setPlayback(_path, const Duration(seconds: 26));
    await tester.pump();
    await tester.tap(find.byTooltip('为当前片段加书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await until(tester, () => first.bookmarksFor(_reference).length == 2);
    expect(
      find.byKey(const ValueKey('player-marker-1')),
      findsOneWidget,
      reason: '再加一个书签不能覆盖前一个',
    );

    await restart(tester);
    final second = await start(tester, file);
    addTearDown(second.dispose);
    await show(tester, second, _reference);

    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-bookmark-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-marker-1')));
    await tester.pumpAndSettle();
    expect(second.playbackRequests, [
      (_path, const Duration(seconds: 26), 100),
    ]);

    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
    expect(find.text('预算数字要再核对'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bookmark-item-0')));
    await tester.pumpAndSettle();
    expect(second.playbackRequests.last, (
      _path,
      const Duration(seconds: 14),
      100,
    ));

    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑批注').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bookmark-note-field')),
      '预算已和财务确认',
    );
    await tester.tap(find.text('保存'));
    await until(
      tester,
      () => second.bookmarksFor(_reference).first.note == '预算已和财务确认',
    );
    expect(find.text('已更新批注'), findsOneWidget);
    final reloaded = RecordingBookmarkStore(file: file);
    await tester.runAsync(reloaded.load);
    expect(
      reloaded.forRecording(second.recordingKeyFor(_reference)).first.note,
      '预算已和财务确认',
    );
  });

  testWidgets('转写或原音频变化后不跳到别的句子，缺音频时说明原因', (tester) async {
    final file = File('${temp.path}/bookmarks.json');
    final c = await start(tester, file);
    addTearDown(c.dispose);
    await tester.runAsync(
      () => c.addBookmark(
        _reference,
        position: const Duration(seconds: 14),
        segment: _segments[1],
        note: '核对',
      ),
    );

    // Re-transcription inserted a sentence; the bookmarked one keeps its time.
    c.views[_reference.key] = _view(_reference, [
      _segment('第一句', 0, 5),
      _segment('新识别出的一句', 6, 11),
      _segment('第二句，预算要再确认', 12, 20),
      _segment('第三句', 25, 31),
    ]);
    await show(tester, c, _reference);
    expect(find.byKey(const ValueKey('segment-bookmark-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-marker-0')));
    await tester.pumpAndSettle();
    expect(c.playbackRequests, [(_path, const Duration(seconds: 14), 100)]);

    // The sentence itself changed: never land on whatever sits there now.
    c.views[_reference.key] = _view(_reference, [
      _segment('第一句', 0, 5),
      _segment('第二句改成了另一件事', 12, 20),
      _segment('第三句', 25, 31),
    ]);
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-marker-0')), findsNothing);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);
    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
    expect(find.textContaining('转写已更新，原片段已不存在'), findsOneWidget);
    expect(find.text('核对'), findsOneWidget, reason: '个人批注仍可阅读');
    await tester.tap(find.byKey(const ValueKey('bookmark-item-0')));
    await tester.pumpAndSettle();
    expect(c.playbackRequests, hasLength(1));

    c.views[_reference.key] = _view(_reference, _segments);
    c.audioChanged = true;
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('原音频已变化'), findsOneWidget);

    c.audioChanged = false;
    c.views[_reference.key] = _view(
      _reference,
      _segments,
      originalPresent: false,
    );
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('原录音不在本机'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bookmark-item-0')));
    await tester.pumpAndSettle();
    expect(c.playbackRequests, hasLength(1));
  });

  testWidgets('保存失败保留草稿并提示未保存，取消不留下书签', (tester) async {
    final blocker = File('${temp.path}/not-a-directory');
    blocker.writeAsStringSync('x');
    final c = await start(tester, File('${blocker.path}/bookmarks.json'));
    addTearDown(c.dispose);
    await show(tester, c, _reference);

    c.setPlayback(_path, const Duration(seconds: 13));
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
    expect(c.bookmarksFor(_reference), isEmpty);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('已取消，未保存书签'), findsOneWidget);
    expect(find.byKey(const ValueKey('player-marker-0')), findsNothing);
    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookmark-list-empty')), findsOneWidget);
  });

  testWidgets('其他录音不显示本录音书签，关闭标记显示不删除书签', (tester) async {
    final file = File('${temp.path}/bookmarks.json');
    final c = await start(tester, file);
    addTearDown(c.dispose);
    await tester.runAsync(
      () => c.addBookmark(
        _reference,
        position: const Duration(seconds: 12),
        segment: _segments[1],
        note: '只属于访谈',
      ),
    );

    await show(tester, c, _otherReference);
    expect(find.byKey(const ValueKey('player-marker-0')), findsNothing);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);
    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookmark-list-empty')), findsOneWidget);
    expect(find.text('只属于访谈'), findsNothing);

    await show(tester, c, _reference);
    expect(find.byKey(const ValueKey('player-marker-0')), findsOneWidget);
    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookmark-markers-switch')));
    await until(tester, () => !c.showBookmarkMarkers);
    expect(find.text('只属于访谈'), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const ValueKey('bookmark-list'))),
    ).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-marker-0')), findsNothing);
    expect(find.byKey(const ValueKey('segment-bookmark-1')), findsNothing);

    await restart(tester);
    final again = await start(tester, file);
    addTearDown(again.dispose);
    await show(tester, again, _reference);
    expect(find.byKey(const ValueKey('player-marker-0')), findsNothing);
    await tester.tap(find.byTooltip('书签与批注'));
    await tester.pumpAndSettle();
    expect(find.text('只属于访谈'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bookmark-item-0')));
    await tester.pumpAndSettle();
    expect(again.playbackRequests, [(_path, const Duration(seconds: 12), 100)]);
  });
}

class _BookmarkController extends RecorderController {
  _BookmarkController(RecordingBookmarkStore store)
    : super(loadPersistedState: false, bookmarkStore: store);

  final views = <String, RecordingViewData>{};
  final playbackRequests = <(String, Duration, int?)>[];
  bool audioChanged = false;

  @override
  RecordingViewData recordingView(RecordingReference reference) =>
      views[reference.key] ?? super.recordingView(reference);

  @override
  Duration? localDurationForPath(String path) => const Duration(seconds: 40);

  @override
  bool recordingAudioChanged(RecordingReference ref) => audioChanged;

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
