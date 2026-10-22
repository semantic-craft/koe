import 'package:flutter_test/flutter_test.dart';
import 'package:koe/audio/input_level_watch.dart';

/// Hints about the microphone while recording (#401), by Shiyin's rules.
void main() {
  /// Feeds [seconds] of a conversation: each second six readings at [speech]
  /// and four at [background], so those are the 90th and 10th percentiles.
  /// Returns the hints shown along the way.
  Set<InputLevelHint> talk(
    InputLevelWatch watch,
    int seconds, {
    required double speech,
    required double background,
  }) {
    final shown = <InputLevelHint>{};
    for (var i = 0; i < seconds * 10; i++) {
      watch.add(i % 10 < 6 ? speech : background);
      if (watch.hint case final hint?) shown.add(hint);
    }
    return shown;
  }

  /// Feeds [seconds] of digital silence, as from a muted microphone.
  Set<InputLevelHint> silence(InputLevelWatch watch, int seconds) =>
      talk(watch, seconds, speech: -160, background: -160);

  test('only zeros for over ten seconds say the microphone hears nothing', () {
    final watch = InputLevelWatch();
    talk(watch, 5, speech: -25, background: -60);
    expect(silence(watch, 10), isEmpty);
    expect(silence(watch, 1), {InputLevelHint.silent});
    talk(watch, 1, speech: -25, background: -60);
    expect(watch.hint, isNull);
  });

  test('quiet speech for a minute of full windows says to move closer', () {
    final watch = InputLevelWatch();
    expect(talk(watch, 88, speech: -55, background: -65), isEmpty);
    expect(talk(watch, 1, speech: -55, background: -65), {
      InputLevelHint.quiet,
    });
  });

  test('a loud background for 45 seconds says it is noisy, except where '
      'levels are peaks', () {
    final watch = InputLevelWatch();
    expect(talk(watch, 73, speech: -15, background: -30), isEmpty);
    expect(talk(watch, 1, speech: -15, background: -30), {
      InputLevelHint.noisy,
    });

    final peaks = InputLevelWatch(loudness: false);
    expect(talk(peaks, 120, speech: -15, background: -30), isEmpty);
    expect(talk(peaks, 120, speech: -55, background: -65), isEmpty);
    expect(silence(peaks, 11), {InputLevelHint.silent});
  });

  test('ordinary speech and long pauses in a quiet room never warn', () {
    final watch = InputLevelWatch();
    for (var round = 0; round < 3; round++) {
      expect(talk(watch, 40, speech: -28, background: -58), isEmpty);
      // Room noise only: flat, so not mistaken for quiet speech.
      expect(talk(watch, 90, speech: -62, background: -65), isEmpty);
    }
  });

  test('a dismissed hint stays away for the take, and a pause starts the '
      'counts over', () {
    final watch = InputLevelWatch();
    expect(silence(watch, 11), {InputLevelHint.silent});
    watch.dismiss();
    expect(watch.hint, isNull);
    expect(silence(watch, 30), isEmpty);
    watch.restart();
    expect(silence(watch, 30), isEmpty);

    final paused = InputLevelWatch();
    expect(talk(paused, 80, speech: -55, background: -65), isEmpty);
    paused.restart();
    expect(talk(paused, 80, speech: -55, background: -65), isEmpty);
    expect(talk(paused, 10, speech: -55, background: -65), {
      InputLevelHint.quiet,
    });
  });
}
