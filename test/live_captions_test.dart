import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/live_captions.dart';
import 'package:koe/state/live_minutes_store.dart';
import 'package:koe/state/live_segments.dart';

void main() {
  test('queued revisions are rechecked before translation', () async {
    final first = Completer<String>();
    final calls = <String>[];
    final c = LiveCaptions(
      sessionId: 'queue',
      store: LiveMinutesStore(inMemory: true),
      target: 'en',
      translate: (s, t) {
        calls.add(s.text);
        return calls.length == 1 ? first.future : Future.value('translated');
      },
    );
    final work = c.update([
      const LiveSegment(id: 'a', text: 'first'),
      const LiveSegment(id: 'b', text: 'old'),
    ]);
    await c.requestStarted;
    await c.update([const LiveSegment(id: 'b', text: 'new', revision: 1)]);
    first.complete('first translated');
    await work;
    expect(calls, ['first', 'new']);
    c.dispose();
  });
  test(
    'provider translation is reused; late target translation cannot replace new target',
    () async {
      final pending = Completer<String>();
      var calls = 0;
      final c = LiveCaptions(
        sessionId: 'a',
        store: LiveMinutesStore(inMemory: true),
        target: 'en',
        translate: (s, t) async {
          calls++;
          return pending.future;
        },
      );
      await c.update([
        const LiveSegment(
          id: '1',
          text: '你好',
          translation: 'Hello',
          targetLanguage: 'en',
        ),
      ]);
      expect(c.entries.single.translation, 'Hello');
      expect(calls, 0);
      final run = c.update([
        const LiveSegment(
          id: '1',
          text: '你好',
          translation: 'Hello',
          targetLanguage: 'en',
        ),
        const LiveSegment(id: '2', text: '再见'),
      ]);
      await c.requestStarted;
      c.changeTarget('ja');
      pending.complete('Goodbye');
      await run;
      expect(c.entries.where((e) => e.translation == 'Goodbye'), isEmpty);
      c.dispose();
    },
  );
}
