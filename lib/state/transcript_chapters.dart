import 'recording.dart';

/// A chapter derived from provider-timed transcript segments.
///
/// Chapters only exist when the segment times are reliable; a text-only or
/// all-zero transcript produces no chapter so the UI never invents a
/// playable start time.
class TranscriptChapter {
  const TranscriptChapter({
    required this.title,
    required this.summary,
    required this.start,
    required this.end,
    required this.firstSegmentIndex,
  });

  final String title;
  final String summary;
  final Duration start;
  final Duration end;
  final int firstSegmentIndex;
}

/// A citation source that still maps to a timed transcript segment.
class TranscriptSourceMatch {
  const TranscriptSourceMatch({
    required this.sourceIndex,
    required this.segmentIndex,
    required this.start,
    required this.snippet,
  });

  final int sourceIndex;
  final int segmentIndex;
  final Duration start;
  final String snippet;
}

/// Groups consecutive sentences at speaker changes or long pauses.
List<TranscriptChapter> buildTranscriptChapters(
  List<TranscriptSegment> segments, {
  Duration? duration,
  Duration minGap = const Duration(seconds: 90),
  int maxChapters = 12,
}) {
  if (!transcriptSegmentsLocatable(segments, duration: duration)) {
    return const [];
  }
  final groups = <List<(int, TranscriptSegment)>>[];
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final last = groups.isEmpty ? null : groups.last.last.$2;
    final startsNew =
        last == null ||
        segment.start - (last.end ?? last.start) >= minGap ||
        (segment.speakerChanged &&
            segment.speaker != null &&
            segment.speaker != last.speaker);
    if (startsNew) {
      groups.add([(index, segment)]);
    } else {
      groups.last.add((index, segment));
    }
  }
  final chapters = <TranscriptChapter>[];
  for (final group in groups) {
    if (chapters.length >= maxChapters) break;
    final first = group.first.$2;
    final last = group.last.$2;
    chapters.add(
      TranscriptChapter(
        title: _clip(first.text, 24),
        summary: _clip(group.take(2).map((item) => item.$2.text).join(' '), 72),
        start: first.start,
        end: last.end ?? last.start,
        firstSegmentIndex: group.first.$1,
      ),
    );
  }
  return chapters;
}

/// Maps analysis source blocks back to the segment where each block starts.
///
/// Provider times are used only while the stored segments still match the
/// current transcript. Sources edited past recognition return no match so the
/// UI can show the text without pretending it can seek to it.
List<TranscriptSourceMatch> matchTranscriptSources({
  required List<String> sources,
  required List<TranscriptSegment> segments,
  Map<String, String> aliases = const {},
  Duration? duration,
}) {
  if (!transcriptSegmentsLocatable(segments, duration: duration)) {
    return const [];
  }
  final normalized = <String>[];
  final offsets = <int>[];
  var offset = 0;
  for (final segment in segments) {
    final text = _normalizeForMatch(segment.text);
    offsets.add(offset);
    normalized.add(text);
    offset += text.length;
  }
  final haystack = normalized.join();
  final matches = <TranscriptSourceMatch>[];
  for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {
    final source = sources[sourceIndex];
    final text = _normalizeForMatch(source, labels: aliases.values);
    if (text.isEmpty) continue;
    var at = _locate(haystack, text);
    if (at == null) continue;
    var segmentIndex = 0;
    for (var index = 0; index < offsets.length; index++) {
      if (offsets[index] <= at) {
        segmentIndex = index;
      } else {
        break;
      }
    }
    matches.add(
      TranscriptSourceMatch(
        sourceIndex: sourceIndex,
        segmentIndex: segmentIndex,
        start: segments[segmentIndex].start,
        snippet: _clip(source, 48),
      ),
    );
  }
  return matches;
}

int? _locate(String haystack, String source) {
  for (final length in [40, 24, 12, 8, 4]) {
    if (source.runes.length < length) continue;
    final needle = String.fromCharCodes(source.runes.take(length));
    final at = haystack.indexOf(needle);
    if (at >= 0) return at;
  }
  return null;
}

String _normalizeForMatch(String value, {Iterable<String> labels = const []}) {
  var text = value.replaceAll(
    RegExp(r'^\s*说话人\s+[^：\r\n]{1,40}：', multiLine: true),
    '',
  );
  for (final label in labels) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) continue;
    text = text.replaceAll(
      RegExp('^\\s*${RegExp.escape(trimmed)}：', multiLine: true),
      '',
    );
  }
  return text.replaceAll(RegExp(r'\s+'), '');
}

String _clip(String value, int length) {
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = text.runes.toList();
  if (runes.length <= length) return text;
  return '${String.fromCharCodes(runes.take(length))}…';
}
