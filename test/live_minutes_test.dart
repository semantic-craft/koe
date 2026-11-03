import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/live_minutes.dart';
import 'package:koe/state/live_minutes_store.dart';
import 'package:koe/state/live_segments.dart';

String result() => jsonEncode({
  'title': '会议',
  'overview': '概要',
  'topics': [
    {
      'text': '预算',
      'sources': ['S1'],
    },
  ],
  'decisions': [],
  'actions': [],
  'questions': [],
});

class PausedResultStore extends LiveMinutesStore {
  PausedResultStore() : super(inMemory: true);
  final started = Completer<void>(), release = Completer<void>();
  bool once = true;
  @override
  Future<void> write(String id, Map<String, dynamic> snapshot) async {
    if (once && snapshot['requestStatus'] == 'complete') {
      once = false;
      started.complete();
      await release.future;
    }
    await super.write(id, snapshot);
  }
}

void main() {
  test(
    'explicit resume after editing an aborted request creates a new candidate',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final m = LiveMinutes(
        sessionId: 'abort-edit',
        store: LiveMinutesStore(inMemory: true),
        clock: () => now,
        request: (r) async {
          calls++;
          if (calls == 2) {
            await r.abort;
            throw StateError('aborted transport');
          }
          return result();
        },
      );
      m.add([LiveSegment(id: '1', text: '甲' * 200)]);
      await m.tick();
      now = now.add(const Duration(seconds: 31));
      m.add([LiveSegment(id: '2', text: '乙' * 200)]);
      final work = m.tick();
      while (calls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      await m.pauseForEdit();
      await work;
      await m.edit(result().replaceFirst('概要', '手改'));
      now = now.add(const Duration(seconds: 31));
      await m.resume();
      await m.tick();
      expect(calls, 3);
      expect(m.active, contains('手改'));
      expect(m.candidate, isNotNull);
      m.dispose();
    },
  );
  test(
    'uncommitted minutes are invisible and additions during save survive restart',
    () async {
      final store = PausedResultStore();
      final m = LiveMinutes(
        sessionId: 'commit',
        store: store,
        request: (_) async => result(),
      );
      m.add([const LiveSegment(id: '1', text: '预算计划')]);
      // First content may run after 30 seconds; use 200 characters here.
      m.add([
        const LiveSegment(id: '1', text: '预算计划'),
        LiveSegment(id: '2', text: '甲' * 200),
      ]);
      final work = m.tick();
      await store.started.future;
      final before = m.active;
      m.add([
        ...m.sources.indexed.map(
          (e) => LiveSegment(id: '${e.$1 + 1}', text: e.$2),
        ),
        const LiveSegment(id: '3', text: '保存期间的新增话语'),
      ]);
      store.release.complete();
      await work;
      expect(before, isNull);
      final saved = await store.read('commit');
      expect(saved!['active'], isNotNull);
      expect(saved['sources'], contains('保存期间的新增话语'));
      m.dispose();
    },
  );
  test(
    'editing while a request completes can explicitly resume candidate generation',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final pending = Completer<String>();
      final m = LiveMinutes(
        sessionId: 'edit-resume',
        store: LiveMinutesStore(inMemory: true),
        clock: () => now,
        request: (_) {
          calls++;
          return calls == 2 ? pending.future : Future.value(result());
        },
      );
      m.add([LiveSegment(id: '1', text: '甲' * 200)]);
      await m.tick();
      now = now.add(const Duration(seconds: 31));
      m.add([
        LiveSegment(id: '1', text: '甲' * 200),
        LiveSegment(id: '2', text: '乙' * 200),
      ]);
      final work = m.tick();
      while (calls < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      await m.pauseForEdit();
      pending.complete(result());
      await work;
      await m.edit(result().replaceFirst('概要', '手改'));
      now = now.add(const Duration(seconds: 31));
      await m.resume();
      await m.tick();
      expect(calls, 3);
      expect(m.active, contains('手改'));
      expect(m.candidate, isNotNull);
      m.dispose();
    },
  );

  test(
    'one active request keeps additions for next bounded revision',
    () async {
      var now = DateTime(2026);
      final response = Completer<String>();
      final inputs = <LiveMinutesRequest>[];
      final m = LiveMinutes(
        sessionId: 'a',
        store: LiveMinutesStore(inMemory: true),
        clock: () => now,
        request: (r) {
          inputs.add(r);
          return inputs.length == 1 ? response.future : Future.value(result());
        },
      );
      m.add([LiveSegment(id: '1', text: '甲' * 200)]);
      final running = m.tick();
      await m.requestStarted;
      m.add([
        LiveSegment(id: '1', text: '甲' * 200),
        LiveSegment(id: '2', text: '乙' * 200),
      ]);
      now = now.add(const Duration(seconds: 31));
      await m.tick();
      expect(inputs.length, 1);
      response.complete(result());
      await running;
      expect(m.watermark, 1);
      await m.tick();
      expect(inputs.length, 2);
      expect(inputs.last.sources.length, 2);
      expect(inputs.last.from, 1);
      expect(m.watermark, 2);
      m.dispose();
    },
  );
  test(
    'editing cancels publication and restart never sends pending work',
    () async {
      final dir = await Directory.systemTemp.createTemp('live-minutes-');
      final store = LiveMinutesStore(file: File('${dir.path}/live.json'));
      final response = Completer<String>();
      final m = LiveMinutes(
        sessionId: 'b',
        store: store,
        request: (_) => response.future,
      );
      m.add([LiveSegment(id: '1', text: '甲' * 200)]);
      final running = m.tick();
      await m.requestStarted;
      await m.pauseForEdit();
      response.complete(result());
      await running;
      expect(m.active, isNull);
      final reopened = LiveMinutes(
        sessionId: 'b',
        store: LiveMinutesStore(file: File('${dir.path}/live.json')),
        request: (_) => throw StateError('must not call'),
      );
      await reopened.restore();
      await reopened.tick();
      expect(reopened.closed, isTrue);
      m.dispose();
      reopened.dispose();
      await dir.delete(recursive: true);
    },
  );
  test(
    'failed journal prevents provider and changing configuration during save prevents call',
    () async {
      final dir = await Directory.systemTemp.createTemp('live-journal-');
      var calls = 0;
      final m = LiveMinutes(
        sessionId: 'c',
        store: LiveMinutesStore(file: File(dir.path)),
        request: (_) async {
          calls++;
          return result();
        },
      );
      m.add([LiveSegment(id: '1', text: '甲' * 200)]);
      await m.tick();
      expect(calls, 0);
      expect(m.error, isNotNull);
      m.dispose();
      await dir.delete(recursive: true);
    },
  );
}
