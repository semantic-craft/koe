import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/recording.dart';
import 'package:koe/ui/transcript_layout.dart';

void main() {
  const segments = [
    TranscriptSegment(
      text: '开头第一句。',
      start: Duration.zero,
      end: Duration(seconds: 5),
    ),
    TranscriptSegment(
      text: '这里谈到产品核心观点A。',
      start: Duration(seconds: 12),
      end: Duration(seconds: 30),
      speaker: '2',
      speakerChanged: true,
    ),
    TranscriptSegment(
      text: '结尾。',
      start: Duration(seconds: 35),
      end: Duration(seconds: 40),
    ),
  ];

  test('重复或逆序起点不能开启句段定位', () {
    expect(
      transcriptSegmentsLocatable(const [
        TranscriptSegment(text: '甲', start: Duration.zero),
        TranscriptSegment(text: '乙', start: Duration.zero),
        TranscriptSegment(text: '丙', start: Duration(seconds: 2)),
      ]),
      isFalse,
    );
    expect(
      transcriptSegmentsLocatable(const [
        TranscriptSegment(text: '甲', start: Duration.zero),
        TranscriptSegment(text: '乙', start: Duration(seconds: 2)),
        TranscriptSegment(text: '丙', start: Duration(seconds: 1)),
      ]),
      isFalse,
    );
  });

  test('正文搜索能命中渲染后的说话人名称', () {
    final hit = findTranscriptSearchHit(
      text: '开头第一句。这里谈到产品核心观点A。结尾。',
      segments: segments,
      query: '张三',
      aliases: const {'2': '张三'},
    );

    expect(hit, isNotNull);
    expect(hit!.index, 1);
    expect(hit.timecode, const Duration(seconds: 12));
  });

  test('搜索时码超出音频时长时不宣称可回听', () {
    final hit = findTranscriptSearchHit(
      text: '开头第一句。这里谈到产品核心观点A。结尾。',
      segments: segments,
      query: '核心观点',
      duration: const Duration(seconds: 20),
    );

    expect(hit, isNotNull);
    expect(hit!.timecode, isNull);
  });
}
