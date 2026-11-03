import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/mac_interpreting.dart';
import 'package:koe/state/mac_interpreting.dart';
import 'package:koe/state/live_minutes_store.dart';

class FakeBridge extends MacInterpreting {
  final eventsController = StreamController<Map<String, dynamic>>.broadcast(
    sync: true,
  );
  Completer<void>? permission, playing, cancelling;
  Completer<String>? recognition;
  int plays = 0, cancels = 0;
  @override
  Stream<Map<String, dynamic>> get events => eventsController.stream;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    switch (method) {
      case 'begin':
        await permission?.future;
        return null;
      case 'finish':
        return recognition == null ? '你好' : recognition!.future;
      case 'cancel':
        cancels++;
        await cancelling?.future;
        return null;
      case 'disable':
        cancels++;
        return null;
      case 'speak':
        plays++;
        await playing?.future;
        return null;
    }
    return null;
  }
}

class BrokenStore extends LiveMinutesStore {
  BrokenStore() : super(inMemory: true);
  @override
  Future<void> write(String id, Map<String, dynamic> snapshot) async =>
      throw StateError('disk full');
}

void main() {
  test('late error cleanup cannot overwrite disabled state', () async {
    final b = FakeBridge()..cancelling = Completer<void>();
    final m = MacInterpretingState(
      bridge: b,
      store: LiveMinutesStore(inMemory: true),
      configuration: () => 'a',
      translate: (s, a, c) async => throw StateError('translation failed'),
    );
    addTearDown(m.dispose);
    await m.enable(input: 'mic', output: 'hole');
    await m.press();
    final end = m.release();
    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return b.cancels == 0;
    });
    await m.disable();
    b.cancelling!.complete();
    await end;
    expect(m.phase, InterpretingPhase.off);
  });

  test(
    'configuration changed during translation terminates the busy sentence',
    () async {
      final b = FakeBridge();
      final pending = Completer<String>();
      var config = 'a';
      final called = Completer<void>();
      final m = MacInterpretingState(
        bridge: b,
        store: LiveMinutesStore(inMemory: true),
        configuration: () => config,
        translate: (s, a, c) {
          called.complete();
          return pending.future;
        },
      );
      addTearDown(m.dispose);
      await m.enable(input: 'mic', output: 'hole');
      await m.press();
      final end = m.release();
      await called.future;
      config = 'b';
      pending.complete('late');
      await end;
      expect(b.plays, 0);
      expect(m.busy, isFalse);
    },
  );
  test('journal failure prevents both provider and playback', () async {
    final b = FakeBridge();
    var requests = 0;
    final m = MacInterpretingState(
      bridge: b,
      store: BrokenStore(),
      configuration: () => 'a',
      translate: (s, a, c) async {
        requests++;
        return 'Hello';
      },
    );
    addTearDown(m.dispose);
    await m.enable(input: 'mic', output: 'hole');
    await m.press();
    await m.release();
    expect(requests, 0);
    expect(b.plays, 0);
    expect(m.message, contains('disk full'));
  });

  test(
    'release while permission pending cannot start translation or playback',
    () async {
      final b = FakeBridge()..permission = Completer<void>();
      var requests = 0;
      final m = MacInterpretingState(
        bridge: b,
        store: LiveMinutesStore(inMemory: true),
        translate: (s, a, current) async {
          requests++;
          return 'Hello';
        },
        configuration: () => 'fixed',
      );
      addTearDown(m.dispose);
      await m.enable(input: 'mic', output: 'hole');
      final start = m.press();
      expect(m.phase, InterpretingPhase.preparing);
      await m.release();
      b.permission!.complete();
      await start;
      expect(requests, 0);
      expect(b.plays, 0);
      expect(m.phase, InterpretingPhase.ready);
    },
  );
  test(
    'cancelled translation never plays late result; next sentence succeeds',
    () async {
      final b = FakeBridge();
      final pending = Completer<String>();
      var requests = 0;
      final m = MacInterpretingState(
        bridge: b,
        store: LiveMinutesStore(inMemory: true),
        translate: (s, a, current) {
          requests++;
          return requests == 1 ? pending.future : Future.value('Hello');
        },
        configuration: () => 'fixed',
      );
      addTearDown(m.dispose);
      await m.enable(input: 'mic', output: 'hole');
      await m.press();
      final end = m.release();
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return requests == 0;
      });
      await m.cancel();
      pending.complete('late');
      await end;
      expect(b.plays, 0);
      await m.press();
      await m.release();
      expect(b.plays, 1);
    },
  );
  test(
    'persist translated before output and never replay after restart',
    () async {
      final b = FakeBridge()..playing = Completer<void>();
      final store = LiveMinutesStore(inMemory: true);
      final m = MacInterpretingState(
        bridge: b,
        store: store,
        translate: (s, a, current) async => 'Hello',
        configuration: () => 'fixed',
      );
      addTearDown(m.dispose);
      await m.enable(input: 'mic', output: 'hole');
      await m.press();
      final end = m.release();
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return b.plays == 0;
      });
      expect(
        (await store.read('interpreting/latest'))!['translation'],
        'Hello',
      );
      await m.disable();
      b.playing!.complete();
      await end;
      expect(m.phase, InterpretingPhase.off);
      final restored = MacInterpretingState(
        bridge: b,
        store: store,
        translate: (s, a, current) async =>
            throw StateError('must not request'),
        configuration: () => 'fixed',
      );
      addTearDown(restored.dispose);
      await restored.restore();
      expect(restored.translation, 'Hello');
      expect(b.plays, 1);
    },
  );
  test(
    'changed configuration cannot send or play the queued request',
    () async {
      final b = FakeBridge()..recognition = Completer<String>();
      var config = 'a';
      var requests = 0;
      final m = MacInterpretingState(
        bridge: b,
        store: LiveMinutesStore(inMemory: true),
        translate: (s, a, current) async {
          requests++;
          return 'Hello';
        },
        configuration: () => config,
      );
      addTearDown(m.dispose);
      await m.enable(input: 'mic', output: 'hole');
      await m.press();
      final end = m.release();
      config = 'b';
      b.recognition!.complete('hello');
      await end;
      expect(requests, 0);
      expect(b.plays, 0);
    },
  );
}
