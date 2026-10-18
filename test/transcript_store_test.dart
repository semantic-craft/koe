import 'package:koe/state/transcript_store.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/ai/speech_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy transcript data loads with empty speaker aliases', () {
    final data = TranscriptStore.decode({
      'byPath': {'/tmp/123.wav': '说话人 1：你好'},
      'byFileId': {'123': '说话人 1：你好'},
    });

    expect(data.byPath['/tmp/123.wav'], '说话人 1：你好');
    expect(data.byFileId[123], '说话人 1：你好');
    expect(data.aliasesByPath, isEmpty);
    expect(data.aliasesByFileId, isEmpty);
  });

  test('speaker aliases round-trip through transcript JSON data', () {
    final encoded = TranscriptStore.encode(
      byPath: const {'/tmp/123.wav': '说话人 1：你好'},
      byFileId: const {123: '说话人 1：你好'},
      aliasesByPath: const {
        '/tmp/123.wav': {'1': '张三'},
      },
      aliasesByFileId: const {
        123: {'1': '张三'},
      },
    );
    final data = TranscriptStore.decode(encoded);

    expect(data.aliasesByPath['/tmp/123.wav'], {'1': '张三'});
    expect(data.aliasesByFileId[123], {'1': '张三'});
  });

  test(
    'provider and revision-bound translation round-trip with legacy source',
    () {
      final data = TranscriptStore.decode(
        TranscriptStore.encode(
          byPath: const {'/tmp/123.wav': 'Original'},
          byFileId: const {123: 'Original'},
          aliasesByPath: const {},
          aliasesByFileId: const {},
          metadata: const {
            'file:123': TranscriptMetadata(
              provider: SttProvider.apple,
              sourceLanguage: 'en-US',
              revision: 2,
            ),
          },
          translations: const {
            'file:123': RecordingTranslation(
              text: '译文',
              sourceLanguage: 'en-US',
              targetLanguage: 'zh',
              provider: SttProvider.apple,
              sourceRevision: 2,
            ),
          },
        ),
      );
      expect(data.byFileId[123], 'Original');
      expect(data.metadata['file:123']!.provider, SttProvider.apple);
      expect(data.translations['file:123']!.sourceRevision, 2);
      expect(data.translations['file:123']!.text, '译文');
      final malformed = TranscriptStore.decode({
        'translations': {
          'file:123': {'text': 5},
        },
      });
      expect(malformed.translations, isEmpty);
    },
  );

  test('timed segments round-trip while malformed groups are discarded', () {
    const segments = [
      TranscriptSegment(
        text: '第一句',
        start: Duration.zero,
        end: Duration(seconds: 4),
        speaker: '1',
        speakerChanged: true,
      ),
      TranscriptSegment(
        text: '第二句',
        start: Duration(seconds: 4),
        end: Duration(seconds: 9),
        speaker: '2',
        speakerChanged: true,
      ),
    ];
    final encoded = TranscriptStore.encode(
      byPath: const {'/tmp/123.wav': '第一句第二句'},
      byFileId: const {123: '第一句第二句'},
      aliasesByPath: const {},
      aliasesByFileId: const {},
      segments: const {'file:123': segments},
    );
    expect(encoded['version'], 4);

    final data = TranscriptStore.decode(encoded);
    expect(data.segments['file:123'], segments);

    final malformed = TranscriptStore.decode({
      'segments': {
        'file:missing-time': [
          {'text': '没有起点'},
        ],
        'file:bad-end': [
          {'text': '逆序', 'startMs': 900, 'endMs': 400},
          {'text': '正常', 'startMs': 1000, 'endMs': 1400},
        ],
        'file:valid': [
          {'text': '正常', 'startMs': 1000, 'endMs': 1400},
        ],
      },
    });
    expect(malformed.segments.containsKey('file:missing-time'), isFalse);
    expect(malformed.segments.containsKey('file:bad-end'), isFalse);
    expect(malformed.segments['file:valid'], hasLength(1));
  });
}
