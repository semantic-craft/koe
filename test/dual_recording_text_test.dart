import 'package:flutter_test/flutter_test.dart';
import 'package:koe/platform/dual_recording_text.dart';

void main() {
  test('late system recognition replaces microphone loudspeaker echo', () {
    final text = DualRecordingText();
    text.update('microphone', 2, '今天讨论录音功能。');
    text.update('system', 0, '今天讨论录音功能');
    expect(text.text, '系统声音：今天讨论录音功能');
  });
  test('small recognition differences in a substantive phrase are echoes', () {
    final text = DualRecordingText();
    text.update('system', 0, '今天我们讨论录音功能的开发计划');
    text.update('microphone', 1, '今天我们讨论录音功能的开发计画');
    expect(text.text.split('\n'), hasLength(1));
    text.update('microphone', 3, '我有不同的意见，需要保留原件');
    expect(text.text.split('\n'), hasLength(2));
  });
  test(
    'same words later in the meeting remain and partials replace themselves',
    () {
      final text = DualRecordingText();
      text.update('system', 0, '好的我们开始讨论');
      text.update('microphone', 60, '好的我们');
      text.update('microphone', 60, '好的我们开始讨论');
      expect(text.text.split('\n'), hasLength(2));
    },
  );
}
