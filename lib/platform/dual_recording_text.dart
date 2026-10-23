/// A recognition request can revise its text; its lane and start offset form
/// its stable key. Only near-time matches across lanes count as loudspeaker echo.
class DualRecordingText {
  final _parts = <String, ({String lane, double offset, String text})>{};
  void update(String lane, double offset, String text) {
    _parts['$lane:$offset'] = (lane: lane, offset: offset, text: text);
  }

  void clear() => _parts.clear();
  String get text {
    final parts = _parts.values.toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));
    String normalized(String text) => text.toLowerCase().replaceAll(
      RegExp(r'[\s\p{P}\p{S}]', unicode: true),
      '',
    );
    return parts
        .where((part) {
          if (part.text.trim().isEmpty) return false;
          if (part.lane != 'microphone') return true;
          final voice = normalized(part.text);
          // Short acknowledgements are real turns too; only suppress a substantive
          // matching phrase, never every 'yes' or 'OK' near the system lane.
          return !parts.any(
            (other) =>
                other.lane == 'system' &&
                (other.offset - part.offset).abs() <= 5 &&
                voice.length >= 6 &&
                _similar(normalized(other.text), voice),
          );
        })
        .map((part) => '${part.lane == 'system' ? '系统声音' : '麦克风'}：${part.text}')
        .join('\n');
  }
}

// Bigram Dice similarity tolerates small ASR differences without treating
// a repeated short acknowledgement as a loudspeaker copy.
bool _similar(String a, String b) {
  if (a == b) return true;
  if (a.length < 6 || b.length < 6) return false;
  Set<String> grams(String s) => {
    for (var i = 0; i < s.length - 1; i++) s.substring(i, i + 2),
  };
  final x = grams(a), y = grams(b);
  return 2 * x.intersection(y).length / (x.length + y.length) >= .8;
}
