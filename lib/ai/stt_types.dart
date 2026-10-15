import 'dart:async';
import 'dart:typed_data';

enum SttDisplayMode { transcription, translation, conversation }

enum SttFileStage { preparing, uploading, queued, processing, fetching }

class SttFileProgress {
  const SttFileProgress(this.stage, {this.uploadedBytes, this.totalBytes});

  final SttFileStage stage;
  final int? uploadedBytes;
  final int? totalBytes;

  double? get fraction {
    final uploaded = uploadedBytes;
    final total = totalBytes;
    if (uploaded == null || total == null || total <= 0) return null;
    return (uploaded / total).clamp(0.0, 1.0);
  }
}

typedef SttFileProgressCallback = void Function(SttFileProgress progress);

/// One diarized speaker found in a completed transcript.
class TranscriptSpeaker {
  const TranscriptSpeaker({
    required this.id,
    required this.defaultLabel,
    required this.displayLabel,
  });

  /// Provider-assigned identifier, scoped to one recording.
  final String id;
  final String defaultLabel;
  final String displayLabel;
}

final RegExp _transcriptSpeakerPrefix = RegExp(
  r'^说话人\s+([^：\r\n]+)：',
  multiLine: true,
);

/// Extract diarized speakers in first-appearance order.
List<TranscriptSpeaker> extractTranscriptSpeakers(
  String transcript, {
  Map<String, String> aliases = const {},
}) {
  final seen = <String>{};
  final speakers = <TranscriptSpeaker>[];
  for (final match in _transcriptSpeakerPrefix.allMatches(transcript)) {
    final id = match.group(1)!.trim();
    if (id.isEmpty || !seen.add(id)) continue;
    final defaultLabel = '说话人 $id';
    final alias = aliases[id]?.trim();
    speakers.add(
      TranscriptSpeaker(
        id: id,
        defaultLabel: defaultLabel,
        displayLabel: alias == null || alias.isEmpty ? defaultLabel : alias,
      ),
    );
  }
  return speakers;
}

/// Apply recording-specific aliases only to canonical line-start prefixes.
String applyTranscriptSpeakerAliases(
  String transcript,
  Map<String, String> aliases,
) {
  if (transcript.isEmpty || aliases.isEmpty) return transcript;
  return transcript.replaceAllMapped(_transcriptSpeakerPrefix, (match) {
    final id = match.group(1)!.trim();
    final alias = aliases[id]?.trim();
    return alias == null || alias.isEmpty ? match.group(0)! : '$alias：';
  });
}

/// Normalize provider-specific markers in transcript text.
///
/// Soniox endpoint detection emits `<end>` tokens; convert those to newlines
/// and tidy surrounding whitespace.
String normalizeSttText(String raw) {
  var t = raw;
  // Soniox endpoint marker → paragraph break.
  t = t.replaceAll(RegExp(r'\s*<end>\s*', caseSensitive: false), '\n');
  // Collapse spaces/tabs within a line (keep newlines).
  t = t.replaceAll(RegExp(r'[^\S\n]+'), ' ');
  // Trim spaces at line edges; collapse 3+ blank lines to one blank line.
  t = t
      .split('\n')
      .map((line) => line.trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return t;
}

class SttTranslationTurn {
  const SttTranslationTurn({
    required this.targetLanguage,
    required this.sourceLanguage,
    required this.text,
    required this.isFinal,
    this.sourceText = '',
  });

  final String targetLanguage;
  final String sourceLanguage;
  final String text;
  final bool isFinal;
  final String sourceText;
}

class SttSourceChunk {
  const SttSourceChunk({required this.language, required this.text});

  final String language;
  final String text;
}

/// Batch / file transcription result.
class SttResult {
  const SttResult({
    required this.text,
    this.durationSec,
    this.language,
    this.sourcePath,
  });

  final String text;
  final double? durationSec;
  final String? language;
  final String? sourcePath;
}

/// Live transcript event from a streaming STT session.
class SttStreamEvent {
  const SttStreamEvent({
    required this.type,
    this.text = '',
    this.isFinal = false,
    this.speechFinal = false,
    this.durationSec,
    this.error,
    this.translationTurns = const [],
    this.pendingTranslationSource,
  });

  /// `created` | `partial` | `done` | `error` | `closed`
  final String type;
  final String text;
  final bool isFinal;
  final bool speechFinal;
  final double? durationSec;
  final String? error;
  final List<SttTranslationTurn> translationTurns;
  final SttSourceChunk? pendingTranslationSource;
}

/// Common interface for PCM16 LE streaming STT.
abstract class SttStreamSession {
  Stream<SttStreamEvent> get events;
  bool get isOpen;
  bool get isServerReady;

  Future<void> start({Duration timeout = const Duration(seconds: 15)});
  void sendPcm(Uint8List pcm16le);
  void finalizeUtterance();
  Future<SttStreamEvent?> finish({
    Duration timeout = const Duration(seconds: 20),
  });
  Future<void> close();
  Future<void> dispose();
}
