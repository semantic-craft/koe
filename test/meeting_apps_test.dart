import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/meeting_apps.dart';

/// Which calls of meeting apps Koe asks about on the Mac (#406). The Mac
/// reports the processes using the microphone whenever they change.
void main() {
  late List<String> asked;

  MeetingAppWatch watch({Set<String> muted = const {}}) {
    asked = [];
    return MeetingAppWatch(
      ask: (ask, app) => asked.add('${ask.name} $app'),
      muted: muted.contains,
    );
  }

  testWidgets(
    'a listed app or its helper using the microphone for 5 seconds asks '
    'once per call to start; other apps, muted ones and a call Koe was '
    'recording at 5 seconds ask nothing',
    (tester) async {
      final calls = watch(muted: {'com.hnc.Discord'});
      calls.microphoneUsers([
        'com.google.Chrome.helper',
        'com.example.Dictation',
        'com.hnc.Discord',
      ]);
      await tester.pump(const Duration(seconds: 4));
      expect(asked, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(asked, ['start com.google.Chrome']);

      // Letting go of the microphone for less than 10 seconds is the same
      // call.
      calls.microphoneUsers([]);
      await tester.pump(const Duration(seconds: 9));
      calls.microphoneUsers(['com.google.Chrome.helper']);
      await tester.pump(const Duration(seconds: 10));
      expect(asked, hasLength(1));

      // Recording at 5 seconds, so not asked, even once the take stops and
      // the Mac reports again.
      calls.recording = true;
      calls.microphoneUsers(['com.google.Chrome.helper', 'us.zoom.xos']);
      await tester.pump(const Duration(seconds: 5));
      calls.recording = false;
      calls.microphoneUsers([
        'com.google.Chrome.helper',
        'us.zoom.xos',
        'com.example.Dictation',
      ]);
      await tester.pump(const Duration(seconds: 5));
      expect(asked, hasLength(1));

      // A call over for 10 seconds that starts again is a new call.
      calls.microphoneUsers([]);
      await tester.pump(const Duration(seconds: 10));
      calls.microphoneUsers(['com.google.Chrome.helper']);
      await tester.pump(const Duration(seconds: 5));
      expect(asked, ['start com.google.Chrome', 'start com.google.Chrome']);
      calls.reset();
    },
  );

  testWidgets(
    'once every app used during the take has let go of the microphone for '
    '10 seconds, asks once to stop',
    (tester) async {
      final calls = watch();
      calls.microphoneUsers(['us.zoom.xos', 'com.tencent.meeting']);
      calls.recording = true;
      await tester.pump(const Duration(seconds: 5));
      calls.microphoneUsers(['com.tencent.meeting']);
      await tester.pump(const Duration(seconds: 10));
      // Tencent Meeting is still in its call.
      expect(asked, isEmpty);

      calls.microphoneUsers([]);
      await tester.pump(const Duration(seconds: 9));
      expect(asked, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(asked, ['stop com.tencent.meeting']);

      // Once per take.
      calls.microphoneUsers(['com.tencent.meeting']);
      await tester.pump(const Duration(seconds: 5));
      calls.microphoneUsers([]);
      await tester.pump(const Duration(seconds: 10));
      expect(asked, hasLength(1));

      // A take started once a call let go of the microphone is not that
      // meeting's.
      calls.recording = false;
      calls.microphoneUsers(['us.zoom.xos']);
      await tester.pump(const Duration(seconds: 5));
      calls.microphoneUsers([]);
      calls.recording = true;
      await tester.pump(const Duration(seconds: 10));
      expect(asked, ['stop com.tencent.meeting', 'start us.zoom.xos']);
      calls.reset();
    },
  );
}
