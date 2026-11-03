import 'package:flutter_test/flutter_test.dart';
import 'package:koe/state/live_segments.dart';

void main() {
  test(
    'confirmed connection boundaries discard partials and do not repeat suffixes',
    () {
      final c = LiveSegmentCollector('meeting');
      c.acceptCumulative('one', '第一句');
      c.acceptCumulative('two', '第二句');
      c.acceptCumulative('two', '第二句第三句');
      expect(c.segments.map((s) => s.text).join(), '第一句第二句第三句');
      c.acceptCumulative(
        'two',
        '',
      ); // Empty finish acknowledgements are not revisions.
      expect(c.stale, isFalse);
      c.acceptCumulative('two', '改写第二句');
      expect(c.stale, isTrue);
      expect(c.segments.first.text, '第一句');
    },
  );
  test(
    'final revisions invalidate minutes without accepting a stale session',
    () {
      final c = LiveSegmentCollector('new');
      c.acceptFinal(session: 'old', id: 'mic/1', text: '旧会议');
      expect(c.segments, isEmpty);
      c.acceptFinal(session: 'new', id: 'mic/1', text: '预算一百');
      c.acceptFinal(session: 'new', id: 'mic/1', text: '预算两百');
      expect(c.stale, isTrue);
      expect(c.segments.single.revision, 1);
    },
  );
}
