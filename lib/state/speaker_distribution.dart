import 'recording.dart';

/// One time range, start inclusive and end exclusive.
typedef SpeakerSpan = ({Duration start, Duration end});

/// How long one speaker talked and where, from the timed segments only.
class SpeakerShare {
  const SpeakerShare({
    required this.speakerId,
    required this.talk,
    required this.spans,
    required this.segmentIndices,
  });

  /// Provider speaker id; null groups the segments with no speaker label.
  final String? speakerId;

  /// Union of this speaker's timed segments, so a speaker's own overlapping
  /// segments are not counted twice.
  final Duration talk;

  /// Merged ranges in order, for the timeline.
  final List<SpeakerSpan> spans;

  /// Indices into the segment list, including segments without an end time.
  final List<int> segmentIndices;
}

/// Speaker distribution of one recording, with every denominator explicit.
///
/// Shares use [voiced] — time anyone is speaking — as the denominator.
/// [overlap] is the time two or more speakers (the unlabeled group counts as
/// one) talk at once; it is counted in each speaker's [SpeakerShare.talk], so
/// shares can add up to more than 100%. Nothing is rounded to make them fit.
class SpeakerDistribution {
  const SpeakerDistribution({
    required this.speakers,
    required this.unlabeled,
    required this.voiced,
    required this.overlap,
    required this.overlapSpans,
    required this.total,
    required this.untimedSegments,
  });

  /// Labeled speakers in order of first appearance.
  final List<SpeakerShare> speakers;

  /// Segments the transcript gives no speaker for; never assigned to anyone.
  final SpeakerShare? unlabeled;
  final Duration voiced;
  final Duration overlap;
  final List<SpeakerSpan> overlapSpans;

  /// Length of the recording, when the audio could be measured.
  final Duration? total;

  /// Segments with no end time: they can be located but add no duration.
  final int untimedSegments;

  /// Time no one is speaking; unknown without the recording length.
  Duration? get silence {
    final length = total;
    if (length == null) return null;
    final rest = length - voiced;
    return rest.isNegative ? Duration.zero : rest;
  }

  bool get hasLabels => speakers.isNotEmpty;

  /// [talk] as a share of [voiced], or null when nothing was timed.
  double? shareOfVoiced(Duration talk) => voiced > Duration.zero
      ? talk.inMicroseconds / voiced.inMicroseconds
      : null;
}

/// Builds the distribution from the segments the reader shows, after the
/// user's speaker corrections. [total] clips segments that run past the end.
SpeakerDistribution buildSpeakerDistribution(
  List<TranscriptSegment> segments, {
  Duration? total,
}) {
  final order = <String?>[];
  final indices = <String?, List<int>>{};
  final ranges = <String?, List<SpeakerSpan>>{};
  var untimed = 0;
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    final id = segment.speaker == null || segment.speaker!.isEmpty
        ? null
        : segment.speaker;
    if (!indices.containsKey(id)) order.add(id);
    indices.putIfAbsent(id, () => []).add(index);
    var end = segment.end;
    if (end == null) {
      untimed++;
      continue;
    }
    if (total != null && total > Duration.zero && end > total) end = total;
    if (end <= segment.start) continue;
    ranges.putIfAbsent(id, () => []).add((start: segment.start, end: end));
  }

  final merged = {for (final id in order) id: _merge(ranges[id] ?? const [])};
  SpeakerShare share(String? id) => SpeakerShare(
    speakerId: id,
    talk: _length(merged[id]!),
    spans: merged[id]!,
    segmentIndices: List.unmodifiable(indices[id]!),
  );

  // Sweep the per-speaker unions: covered by one speaker is voiced, by two
  // or more is overlap.
  final events = <(Duration, int)>[
    for (final spans in merged.values)
      for (final span in spans) ...[(span.start, 1), (span.end, -1)],
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2 - b.$2);
  var active = 0;
  var voiced = Duration.zero;
  final overlapSpans = <SpeakerSpan>[];
  Duration? previous;
  for (final (at, step) in events) {
    if (previous != null && at > previous) {
      if (active >= 1) voiced += at - previous;
      if (active >= 2) overlapSpans.add((start: previous, end: at));
    }
    active += step;
    previous = at;
  }
  final overlap = _merge(overlapSpans);

  return SpeakerDistribution(
    speakers: [
      for (final id in order)
        if (id != null) share(id),
    ],
    unlabeled: indices.containsKey(null) ? share(null) : null,
    voiced: voiced,
    overlap: _length(overlap),
    overlapSpans: overlap,
    total: total != null && total > Duration.zero ? total : null,
    untimedSegments: untimed,
  );
}

List<SpeakerSpan> _merge(List<SpeakerSpan> spans) {
  if (spans.isEmpty) return const [];
  final sorted = [...spans]..sort((a, b) => a.start.compareTo(b.start));
  final output = <SpeakerSpan>[sorted.first];
  for (final span in sorted.skip(1)) {
    final last = output.last;
    if (span.start <= last.end) {
      if (span.end > last.end) {
        output[output.length - 1] = (start: last.start, end: span.end);
      }
    } else {
      output.add(span);
    }
  }
  return List.unmodifiable(output);
}

Duration _length(List<SpeakerSpan> spans) =>
    spans.fold(Duration.zero, (sum, span) => sum + (span.end - span.start));
