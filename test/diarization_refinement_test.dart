import 'package:flutter_test/flutter_test.dart';
import 'package:koe/ai/diarization_refinement.dart';

SpeakerEvidence e(
  int turn,
  List<double> v, {
  bool clean = true,
  double seconds = 3,
}) => SpeakerEvidence(turn: turn, embedding: v, seconds: seconds, clean: clean);

void main() {
  test(
    'unsupported fixed count falls back instead of merging distinct voices',
    () {
      expect(
        refineSpeakerLabels(
          [0, 1, 2],
          [
            e(0, [1, 0, 0]),
            e(1, [0, 1, 0]),
            e(2, [0, 0, 1]),
          ],
          expectedSpeakers: 2,
        ),
        isNull,
      );
    },
  );
  test('missing evidence cannot escape the requested count', () {
    expect(
      refineSpeakerLabels(
        [0, 1, 2],
        [
          e(0, [1, 0]),
          e(1, [0, 1]),
        ],
        expectedSpeakers: 2,
      ),
      isNull,
    );
  });

  final speakers = [0, 1, 2, 3, 4, 5, 6];
  final evidence = [
    e(0, [1, 0, 0, 0]), e(1, [0, 1, 0, 0]),
    e(2, [0, 0, 1, 0]), e(3, [0, 0, 0, 1]),
    // Another clean turn of speaker 2 was split into a new native label.
    e(4, [0, 0.1, 0.99, 0]),
    // Overlapping fragments must not consume two of the requested speakers.
    e(5, [0.1, 0.9, 0, 0], clean: false, seconds: 0.3),
    e(6, [0, 0, 0.1, 0.9], clean: false, seconds: 0.4),
  ];

  test(
    'auto rejoins split voices and assigns mixed fragments without new people',
    () {
      final labels = refineSpeakerLabels(speakers, evidence)!;
      expect(labels.toSet(), hasLength(4));
      expect(labels[4], labels[2]);
      expect(labels[5], labels[1]);
      expect(labels[6], labels[3]);
      expect(labels.take(4).toSet(), hasLength(4));
    },
  );

  test(
    'four-person constraint preserves four clean voices despite mixed fragments',
    () {
      final labels = refineSpeakerLabels(
        speakers,
        evidence,
        expectedSpeakers: 4,
      )!;
      expect(labels.take(4).toSet(), hasLength(4));
      expect(labels.toSet(), hasLength(4));
      expect(labels[5], labels[1]);
      expect(labels[6], labels[3]);
    },
  );

  test('a brief but clean distinct speaker is retained', () {
    final labels = refineSpeakerLabels(
      [0, 1],
      [
        e(0, [1, 0], seconds: 100),
        e(1, [0, 1], seconds: 0.5),
      ],
    )!;
    expect(labels[0], isNot(labels[1]));
  });

  test('mixed or invalid embeddings do not invent clean speaker profiles', () {
    expect(
      refineSpeakerLabels(
        [0, 1],
        [
          e(0, [1, 0], clean: false),
          e(1, [double.nan, 1]),
        ],
      ),
      [0, 1],
    );
    expect(
      refineSpeakerLabels(
        [0, 1],
        [
          e(0, [1, 0]),
        ],
        expectedSpeakers: 3,
      ),
      isNull,
    );
  });
}
