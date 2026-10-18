import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/state/transcript_chapters.dart';

void main() {
  test('chapters are not invented when timecodes are unreliable', () {
    expect(
      buildTranscriptChapters(const [
        TranscriptSegment(
          text: '第一段',
          start: Duration.zero,
          end: Duration(seconds: 4),
        ),
        TranscriptSegment(
          text: '第二段',
          start: Duration.zero,
          end: Duration(seconds: 8),
        ),
      ]),
      isEmpty,
    );
    expect(
      buildTranscriptChapters(const [
        TranscriptSegment(
          text: '第一段',
          start: Duration(seconds: 10),
          end: Duration(seconds: 14),
        ),
        TranscriptSegment(
          text: '第二段',
          start: Duration(seconds: 5),
          end: Duration(seconds: 9),
        ),
      ]),
      isEmpty,
    );
    expect(
      buildTranscriptChapters(const [
        TranscriptSegment(
          text: '第一段',
          start: Duration(seconds: 30),
          end: Duration(seconds: 40),
        ),
        TranscriptSegment(
          text: '第二段',
          start: Duration(seconds: 50),
          end: Duration(seconds: 60),
        ),
      ], duration: const Duration(seconds: 45)),
      isEmpty,
    );
  });

  test('chapters split at speaker changes and long pauses', () {
    final chapters = buildTranscriptChapters(const [
      TranscriptSegment(
        text: '开场介绍',
        start: Duration.zero,
        end: Duration(seconds: 30),
        speaker: '1',
        speakerChanged: true,
      ),
      TranscriptSegment(
        text: '补充背景',
        start: Duration(seconds: 40),
        end: Duration(seconds: 60),
        speaker: '1',
      ),
      TranscriptSegment(
        text: '另一位开始回答',
        start: Duration(seconds: 70),
        end: Duration(seconds: 90),
        speaker: '2',
        speakerChanged: true,
      ),
      TranscriptSegment(
        text: '停顿后的结论',
        start: Duration(seconds: 200),
        end: Duration(seconds: 210),
        speaker: '2',
      ),
    ]);

    expect(chapters.map((chapter) => chapter.firstSegmentIndex), [0, 2, 3]);
    expect(chapters.map((chapter) => chapter.start.inSeconds), [0, 70, 200]);
    expect(chapters.first.title, '开场介绍');
  });

  test('chapter cap keeps the rest of the timeline reachable', () {
    final segments = [
      for (var index = 0; index < 20; index++)
        TranscriptSegment(
          text: '第 $index 段',
          start: Duration(seconds: index * 30),
          end: Duration(seconds: index * 30 + 20),
          speaker: '${index % 2}',
          speakerChanged: true,
        ),
    ];

    final chapters = buildTranscriptChapters(segments, maxChapters: 6);

    expect(chapters, hasLength(6));
    expect(chapters.first.start, Duration.zero);
    expect(chapters.last.end, segments.last.end);
    expect(chapters.last.firstSegmentIndex, greaterThan(0));
    expect(
      chapters.map((chapter) => chapter.firstSegmentIndex).toSet(),
      hasLength(6),
    );
  });

  test('analysis sources map back to the segment where they start', () {
    const segments = [
      TranscriptSegment(
        text: '第一句发布安排',
        start: Duration.zero,
        end: Duration(seconds: 5),
      ),
      TranscriptSegment(
        text: '第二句核对发布',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
      ),
    ];
    final matches = matchTranscriptSources(
      sources: const ['第二句核对发布', '不存在的原文'],
      segments: segments,
    );

    expect(matches, hasLength(1));
    expect(matches.single.sourceIndex, 0);
    expect(matches.single.segmentIndex, 1);
    expect(matches.single.start, const Duration(seconds: 10));
  });

  test('ambiguous source prefixes do not seek to the first occurrence', () {
    const segments = [
      TranscriptSegment(
        text: '今天讨论发布安排',
        start: Duration.zero,
        end: Duration(seconds: 5),
      ),
      TranscriptSegment(
        text: '今天讨论预算安排',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
      ),
    ];

    expect(
      matchTranscriptSources(sources: const ['今天讨论'], segments: segments),
      isEmpty,
    );
    final matches = matchTranscriptSources(
      sources: const ['今天讨论预算安排'],
      segments: segments,
    );
    expect(matches, hasLength(1));
    expect(matches.single.segmentIndex, 1);
    expect(matches.single.start, const Duration(seconds: 10));
  });

  test('edited or untimed transcripts produce no source match', () {
    expect(
      matchTranscriptSources(
        sources: const ['第二句核对发布'],
        segments: const [
          TranscriptSegment(
            text: '第二句核对发布',
            start: Duration.zero,
            end: Duration(seconds: 5),
          ),
        ],
      ),
      isEmpty,
    );
    expect(
      matchTranscriptSources(
        sources: const ['校订后的原文'],
        segments: const [
          TranscriptSegment(
            text: '旧的原文',
            start: Duration.zero,
            end: Duration(seconds: 5),
          ),
          TranscriptSegment(
            text: '旧的结尾',
            start: Duration(seconds: 8),
            end: Duration(seconds: 12),
          ),
        ],
      ),
      isEmpty,
    );
  });
}
