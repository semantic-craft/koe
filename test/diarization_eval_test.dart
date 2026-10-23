import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/sherpa_diarizer_runner.dart';
import '../tool/diarization_eval.dart';

void main() {
  test('RTTM interval excludes holdout and rebases crossing turns', () {
    final reference = parseDiarizationRttm(
      [
        'SPEAKER test 1 0 5 <NA> <NA> holdout <NA> <NA>',
        'SPEAKER test 1 419 2 <NA> <NA> A <NA> <NA>',
        'SPEAKER test 1 420 2 <NA> <NA> B <NA> <NA>',
        'SPEAKER test 1 839 2 <NA> <NA> A <NA> <NA>',
        'SPEAKER test 1 840 1 <NA> <NA> outside <NA> <NA>',
      ],
      startTimeSec: 420,
      maxTimeSec: 420,
    );
    expect(reference, [
      (start: 0.0, end: 1.0, speaker: 'A'),
      (start: 0.0, end: 2.0, speaker: 'B'),
      (start: 419.0, end: 420.0, speaker: 'A'),
    ]);
  });

  test(
    'exact speaker mapping scores over-clustering beyond seven predictions',
    () {
      final result = evaluateDer(
        [(start: 0.0, end: 10.0, speaker: 'A')],
        [
          const DiarizationTurn(
            speaker: 0,
            start: Duration.zero,
            end: Duration(seconds: 3),
          ),
          for (var i = 1; i <= 7; i++)
            DiarizationTurn(
              speaker: i,
              start: Duration(seconds: i + 2),
              end: Duration(milliseconds: (i + 2) * 1000 + 250),
            ),
        ],
        10,
      );
      expect(result.speakerErrorRate, closeTo(0.7, 1e-9));
      expect(result.derCollar250ms, closeTo(6.75 / 9.5, 1e-9));
    },
  );
  test(
    '250 ms collar is exact on both sides; missing single speech counts',
    () {
      final result = evaluateDer(
        [(start: 0.013, end: 1.013, speaker: 'A')],
        [
          const DiarizationTurn(
            speaker: 0,
            start: Duration(milliseconds: 13),
            end: Duration(milliseconds: 413),
          ),
        ],
        1.1,
      );
      // Single reference speech = 1 s; missing speech = 0.6 s.
      expect(result.speakerErrorRate, closeTo(0.6, 1e-9));
      // Scored reference after collar = [0.263, 0.763], 0.5 s.
      // Missing speech on [0.413, 0.763] = 0.35 s.
      expect(result.derCollar250ms, closeTo(0.7, 1e-9));
    },
  );
}
