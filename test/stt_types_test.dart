import 'package:anker_recorder/ai/stt_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts unique speakers in first-appearance order with aliases', () {
    final speakers = extractTranscriptSpeakers(
      '说话人 2：先说\n说话人 1：后说\n说话人 2：再说',
      aliases: const {'2': '张三'},
    );

    expect(speakers.map((speaker) => speaker.id), ['2', '1']);
    expect(speakers.map((speaker) => speaker.defaultLabel), ['说话人 2', '说话人 1']);
    expect(speakers.map((speaker) => speaker.displayLabel), ['张三', '说话人 1']);
  });

  test('applies aliases only to matching line-start speaker prefixes', () {
    const raw = '说话人 1：你好\n正文里提到说话人 1：但不是标签\n说话人 2：再见\n说话人 1：补充';

    expect(
      applyTranscriptSpeakerAliases(raw, const {'1': '张三'}),
      '张三：你好\n正文里提到说话人 1：但不是标签\n说话人 2：再见\n张三：补充',
    );
  });
}
