import '../ai/speech_provider.dart';
import '../ai/stt_types.dart';
import 'recording_library.dart';

/// Navigation identity survives a live recording acquiring its file id/path.
class RecordingReference {
  const RecordingReference({this.sessionId, this.fileId, this.path})
    : assert(sessionId != null || fileId != null || path != null);

  final String? sessionId;
  final int? fileId;
  final String? path;
  String get key => sessionId != null
      ? 'session:$sessionId'
      : fileId != null
      ? 'file:$fileId'
      : 'path:$path';
}

class TranscriptMetadata {
  const TranscriptMetadata({
    this.provider = SttProvider.soniox,
    this.sourceLanguage,
    this.revision = 0,
  });

  final SttProvider provider;
  final String? sourceLanguage;
  final int revision;

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'sourceLanguage': sourceLanguage,
    'revision': revision,
  };

  factory TranscriptMetadata.fromJson(Map json) => TranscriptMetadata(
    provider: SttProvider.parse(json['provider']) ?? SttProvider.soniox,
    sourceLanguage: json['sourceLanguage'] is String
        ? json['sourceLanguage'] as String
        : null,
    revision: json['revision'] is int ? json['revision'] as int : 0,
  );
}

/// One provider-timed transcript segment.
///
/// Times are absolute offsets into the recording, not relative to the previous
/// segment. A missing [end] still allows seeking to [start]; a missing [start]
/// makes the segment unlocatable.
class TranscriptSegment {
  const TranscriptSegment({
    required this.text,
    required this.start,
    this.end,
    this.speaker,
    this.speakerChanged = false,
  });

  final String text;
  final Duration start;
  final Duration? end;

  /// Provider-assigned speaker id, scoped to one recording.
  final String? speaker;

  /// Whether this segment starts a new speaker run and should show the label.
  final bool speakerChanged;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TranscriptSegment &&
          other.text == text &&
          other.start == start &&
          other.end == end &&
          other.speaker == speaker &&
          other.speakerChanged == speakerChanged;

  @override
  int get hashCode => Object.hash(text, start, end, speaker, speakerChanged);

  Map<String, Object?> toJson() => {
    'text': text,
    'startMs': start.inMilliseconds,
    'endMs': end?.inMilliseconds,
    if (speaker != null) 'speaker': speaker,
    if (speakerChanged) 'speakerChanged': true,
  };

  static TranscriptSegment? decode(Object? value) {
    if (value is! Map) return null;
    final text = value['text'];
    final startMs = value['startMs'];
    final endMs = value['endMs'];
    final speaker = value['speaker'];
    if (text is! String || text.trim().isEmpty || startMs is! int) return null;
    if (startMs < 0) return null;
    if (endMs != null && (endMs is! int || endMs < startMs)) return null;
    return TranscriptSegment(
      text: text.trim(),
      start: Duration(milliseconds: startMs),
      end: endMs == null ? null : Duration(milliseconds: endMs as int),
      speaker: speaker is String && speaker.trim().isNotEmpty
          ? speaker.trim()
          : null,
      speakerChanged: value['speakerChanged'] == true,
    );
  }
}

/// A segment label ready for display, including an optional speaker alias.
String transcriptSegmentLabel(
  TranscriptSegment segment, {
  Map<String, String> aliases = const {},
}) {
  final speaker = segment.speaker;
  if (!segment.speakerChanged || speaker == null) return segment.text;
  final alias = aliases[speaker]?.trim();
  final label = alias == null || alias.isEmpty ? '说话人 $speaker' : alias;
  return '$label：${segment.text}';
}

/// Whether provider times can be used to jump to a specific segment.
///
/// Requires at least two distinct starts: a single whole-file segment or an
/// all-zero timecode list would always jump to the beginning, so the UI must
/// offer whole-file playback instead of pretending it can locate a sentence.
bool transcriptSegmentsLocatable(
  List<TranscriptSegment> segments, {
  Duration? duration,
}) {
  if (segments.length < 2) return false;
  final starts = <int>{};
  const tolerance = Duration(milliseconds: 1000);
  for (final segment in segments) {
    if (segment.start < Duration.zero) return false;
    if (segment.end != null && segment.end! < segment.start) return false;
    if (duration != null && duration > Duration.zero) {
      if (segment.start > duration) return false;
      if (segment.end != null && segment.end! > duration + tolerance) {
        return false;
      }
    }
    starts.add(segment.start.inMilliseconds);
  }
  return starts.length >= 2;
}

/// Detect stale segment data left over from a previous transcript revision.
///
/// Leading speaker labels are presentation only, so they are removed before
/// comparing the concatenated segment text with the stored transcript.
bool transcriptSegmentsMatchText(
  List<TranscriptSegment> segments,
  String transcript, {
  Map<String, String> aliases = const {},
}) {
  if (segments.isEmpty) return false;
  String normalize(String value) {
    var normalized = value.replaceAll(
      RegExp(r'^\s*说话人\s+[^：\r\n]+：', multiLine: true),
      '',
    );
    for (final alias in aliases.values) {
      final label = alias.trim();
      if (label.isEmpty) continue;
      normalized = normalized.replaceAll(
        RegExp('^\\s*${RegExp.escape(label)}：', multiLine: true),
        '',
      );
    }
    return normalized.replaceAll(RegExp(r'\s+'), '').trim();
  }

  final fromSegments = normalize(segments.map((s) => s.text).join());
  return fromSegments.isNotEmpty && fromSegments == normalize(transcript);
}

class RecordingTranslation {
  const RecordingTranslation({
    required this.text,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.provider,
    required this.sourceRevision,
  });

  final String text;
  final String sourceLanguage;
  final String targetLanguage;
  final SttProvider provider;
  final int sourceRevision;

  Map<String, Object?> toJson() => {
    'text': text,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'provider': provider.name,
    'sourceRevision': sourceRevision,
  };

  static RecordingTranslation? decode(Object? value) {
    if (value is! Map ||
        value['text'] is! String ||
        value['sourceLanguage'] is! String ||
        value['targetLanguage'] is! String ||
        value['sourceRevision'] is! int) {
      return null;
    }
    if ((value['text'] as String).trim().isEmpty) return null;
    return RecordingTranslation(
      text: value['text'] as String,
      sourceLanguage: value['sourceLanguage'] as String,
      targetLanguage: value['targetLanguage'] as String,
      provider: SttProvider.parse(value['provider']) ?? SttProvider.apple,
      sourceRevision: value['sourceRevision'] as int,
    );
  }
}

class RecordingViewData {
  const RecordingViewData({
    required this.reference,
    required this.title,
    required this.text,
    this.path,
    this.translation,
    this.sourceLanguage,
    this.mode = SttDisplayMode.transcription,
    this.live = false,
    this.paused = false,
    this.audioLocked = false,
    this.processing = false,
    this.error,
    this.progress,
    this.provider = SttProvider.soniox,
    this.transcriptionEnabled = true,
    this.speechReady = true,
    this.source = RecordingSource.device,
    this.recordedAt,
    this.importedAt,
    this.originalPath,
    this.originalPresent = true,
    this.originalComplete = true,
    this.archived = false,
    this.segments = const [],
  });

  final RecordingReference reference;
  final String? path;
  final String title;
  final String text;
  final RecordingTranslation? translation;
  final String? sourceLanguage;
  final SttDisplayMode mode;
  final bool live;
  final bool paused;
  final bool audioLocked;
  final bool processing;
  final String? error;
  final SttFileProgress? progress;
  final SttProvider provider;
  final bool transcriptionEnabled;
  final bool speechReady;
  final RecordingSource source;
  final DateTime? recordedAt;
  final DateTime? importedAt;
  final String? originalPath;
  final bool originalPresent;
  final bool originalComplete;
  final bool archived;
  final List<TranscriptSegment> segments;
}
