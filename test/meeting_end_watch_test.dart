import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_end_watch.dart';

void main() {
  test(
    'unavailable and stale observations never stop; cancellation needs new activity',
    () {
      var now = DateTime(2026);
      final stopped = <String>[];
      final w = MeetingEndWatch(clock: () => now, onStop: stopped.add);
      void sample(
        List<String> users, {
        bool available = true,
        String device = 'mic',
      }) => w.observe(
        MicrophoneSnapshot(available: available, users: users, device: device),
      );
      sample(['us.zoom.xos']);
      expect(w.bind('take'), isTrue);
      for (var i = 0; i < 32; i++) {
        now = now.add(const Duration(seconds: 1));
        sample([]);
        w.tick();
      }
      expect(w.remainingSeconds, isNotNull);
      sample([], available: false);
      now = now.add(const Duration(minutes: 2));
      w.tick();
      expect(stopped, isEmpty);
      sample(['us.zoom.xos']);
      for (var i = 0; i < 32; i++) {
        now = now.add(const Duration(seconds: 1));
        sample([]);
        w.tick();
      }
      w.cancelCountdown();
      for (var i = 0; i < 100; i++) {
        now = now.add(const Duration(seconds: 1));
        sample([]);
        w.tick();
      }
      expect(stopped, isEmpty);
      sample(['us.zoom.xos']);
      for (var i = 0; i < 92; i++) {
        now = now.add(const Duration(seconds: 1));
        sample([]);
        w.tick();
      }
      expect(stopped, ['take']);
      w.dispose();
    },
  );
  test('multiple apps and changed devices reset the ending observation', () {
    var now = DateTime(2026);
    final w = MeetingEndWatch(
      clock: () => now,
      onStop: (_) => fail('must not stop'),
    );
    w.observe(
      const MicrophoneSnapshot(
        available: true,
        users: ['us.zoom.xos', 'com.tencent.meeting'],
        device: 'one',
      ),
    );
    expect(w.bind('take'), isFalse);
    w.observe(
      const MicrophoneSnapshot(
        available: true,
        users: ['us.zoom.xos'],
        device: 'one',
      ),
    );
    expect(w.bind('take'), isTrue);
    w.observe(
      const MicrophoneSnapshot(available: true, users: [], device: 'one'),
    );
    now = now.add(const Duration(seconds: 31));
    w.observe(
      const MicrophoneSnapshot(available: true, users: [], device: 'two'),
    );
    w.tick();
    expect(w.remainingSeconds, isNull);
    now = now.add(const Duration(seconds: 90));
    w.tick();
    expect(w.remainingSeconds, isNull);
    w.dispose();
  });
}
