import '../ai/stt_types.dart';
import '../state/recording.dart';

/// Splits transcript text into display paragraphs.
///
/// Some services emit an entire recording as one line. Paragraph size is also
/// bounded so a long unpunctuated transcript still lays out lazily.
List<String> splitTranscriptDisplayParagraphs(String text) {
  final paragraphs = <String>[];
  for (final line in text.split(RegExp(r'\n+'))) {
    if (line.trim().isEmpty) continue;
    var runes = line.runes.toList();
    while (runes.length > 1200) {
      var end = 1200;
      for (var index = 1199; index > 800; index--) {
        if (' 。！？.!?'.runes.contains(runes[index])) {
          end = index + 1;
          break;
        }
      }
      paragraphs.add(String.fromCharCodes(runes.take(end)));
      runes = runes.sublist(end);
    }
    if (runes.isNotEmpty) paragraphs.add(String.fromCharCodes(runes));
  }
  return paragraphs;
}

/// A transcript-body search hit and the exact place it points at.
class TranscriptSearchHit {
  const TranscriptSearchHit({
    required this.index,
    required this.snippet,
    this.timecode,
  });

  /// Segment index when [timecode] is available, otherwise paragraph index.
  final int index;
  final String snippet;
  final Duration? timecode;
}

/// Finds the first transcript-body occurrence of [query].
///
/// Provider segments win only when they still match the stored text and have
/// usable, distinct starts. Otherwise the hit falls back to display paragraphs
/// without a timecode, so search never pretends a sentence can be located.
TranscriptSearchHit? findTranscriptSearchHit({
  required String text,
  required List<TranscriptSegment> segments,
  required String query,
  Map<String, String> aliases = const {},
  Duration? duration,
  List<String> extraLines = const [],
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return null;
  final aliasedText = aliases.isEmpty
      ? text
      : applyTranscriptSpeakerAliases(text, aliases);
  final timed =
      transcriptSegmentsMatchText(segments, aliasedText, aliases: aliases) &&
          transcriptSegmentsLocatable(segments, duration: duration)
      ? segments
      : const <TranscriptSegment>[];
  if (timed.isNotEmpty) {
    for (var index = 0; index < timed.length; index++) {
      final segment = timed[index];
      final rendered = transcriptSegmentLabel(segment, aliases: aliases);
      final canonical = segment.speaker == null
          ? segment.text
          : '说话人 ${segment.speaker}：${segment.text}';
      final source = rendered.toLowerCase().contains(needle)
          ? rendered
          : canonical.toLowerCase().contains(needle)
          ? canonical
          : null;
      if (source == null) continue;
      final at = source.toLowerCase().indexOf(needle);
      return TranscriptSearchHit(
        index: index,
        snippet: _snippet(source, at, needle.length),
        timecode: segment.start,
      );
    }
  } else {
    final paragraphs = splitTranscriptDisplayParagraphs(aliasedText);
    for (var index = 0; index < paragraphs.length; index++) {
      final paragraph = paragraphs[index];
      final at = paragraph.toLowerCase().indexOf(needle);
      if (at < 0) continue;
      return TranscriptSearchHit(
        index: index,
        snippet: _snippet(paragraph, at, needle.length),
      );
    }
  }
  for (final extra in extraLines) {
    final trimmed = extra.trim();
    if (trimmed.isEmpty) continue;
    final at = trimmed.toLowerCase().indexOf(needle);
    if (at < 0) continue;
    return TranscriptSearchHit(
      index: -1,
      snippet: _snippet(trimmed, at, needle.length),
    );
  }
  return null;
}

String _snippet(String source, int start, int length) {
  final from = (start - 18).clamp(0, source.length);
  final to = (start + length + 36).clamp(0, source.length);
  final content = source
      .substring(from, to)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return '${from > 0 ? '…' : ''}$content${to < source.length ? '…' : ''}';
}
