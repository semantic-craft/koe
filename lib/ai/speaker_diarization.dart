import 'dart:math' as math;

import '../state/recording.dart';
import 'diarization_model_store.dart';
import 'sherpa_diarizer_runner.dart';
import 'stt_types.dart';

export 'sherpa_diarizer_runner.dart';

/// Assigns speaker IDs to timed transcript [segments] by temporal overlap with
/// diarization [turns], falling back to the nearest turn midpoint when a
/// segment falls in a gap, and renumbering speakers (`'1'`, `'2'`, ...) in
/// order of their first appearance in the transcript.
///
/// Adapted in Dart from the overlap + midpoint + first-appearance numbering
/// idea in Shiyin `Sources/Shiyin/Transcribe/Diarizer.swift:140-165`
/// (`assignNumbering`, commit `7ffd7d4b43b3f3cf06012cf3abfbe8e2b0e257f9`).
({List<TranscriptSegment> segments, Map<int, String> speakerNumbering})
assignSpeakersToSegments(
  List<DiarizationTurn> turns,
  List<TranscriptSegment> segments,
) {
  if (turns.isEmpty || segments.isEmpty) {
    return (
      segments: [
        for (final s in segments)
          s.copyWith(clearSpeaker: true, speakerChanged: false),
      ],
      speakerNumbering: const {},
    );
  }

  final rawSpeakers = <int?>[];
  for (final segment in segments) {
    final segStartUs = segment.start.inMicroseconds;
    final segEndUs = (segment.end ?? segment.start).inMicroseconds;
    final overlapBySpeaker = <int, int>{};

    for (final turn in turns) {
      final turnStartUs = turn.start.inMicroseconds;
      final turnEndUs = turn.end.inMicroseconds;
      if (turnEndUs > segStartUs && turnStartUs < segEndUs) {
        final overlap =
            math.min<int>(turnEndUs, segEndUs) -
            math.max<int>(turnStartUs, segStartUs);
        if (overlap > 0) {
          overlapBySpeaker[turn.speaker] =
              (overlapBySpeaker[turn.speaker] ?? 0) + overlap;
        }
      }
    }

    if (overlapBySpeaker.isNotEmpty) {
      int? bestSpeaker;
      var bestOverlap = -1;
      for (final entry in overlapBySpeaker.entries) {
        if (entry.value > bestOverlap) {
          bestOverlap = entry.value;
          bestSpeaker = entry.key;
        }
      }
      rawSpeakers.add(bestSpeaker);
      continue;
    }

    // Segment falls in a gap (or has zero duration): pick the turn whose
    // midpoint is closest to the segment's midpoint.
    final segMidUs = (segStartUs + segEndUs) / 2.0;
    DiarizationTurn? nearest;
    var bestDistance = double.infinity;
    for (final turn in turns) {
      final turnMidUs =
          (turn.start.inMicroseconds + turn.end.inMicroseconds) / 2.0;
      final distance = (turnMidUs - segMidUs).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = turn;
      }
    }
    rawSpeakers.add(nearest?.speaker);
  }

  final numbering = <int, String>{};
  final assigned = <TranscriptSegment>[];
  String? previousSpeaker;
  for (var i = 0; i < segments.length; i++) {
    final raw = rawSpeakers[i];
    String? speakerId;
    if (raw != null) {
      speakerId = numbering.putIfAbsent(raw, () => '${numbering.length + 1}');
    }
    final changed = speakerId != null && speakerId != previousSpeaker;
    assigned.add(
      segments[i].copyWith(
        speaker: speakerId,
        clearSpeaker: speakerId == null,
        speakerChanged: changed,
      ),
    );
    previousSpeaker = speakerId;
  }

  return (
    segments: List<TranscriptSegment>.unmodifiable(assigned),
    speakerNumbering: Map<int, String>.unmodifiable(numbering),
  );
}

/// Synthesizes timed [SttSegment]s by splitting [text] into sentences and
/// distributing their times proportionally across [turns] when an on-device
/// engine returns plain text without sentence timestamps.
List<SttSegment> synthesizeSegmentsFromTextAndTurns(
  String text,
  List<DiarizationTurn> turns,
) {
  final normalized = normalizeSttText(text);
  if (normalized.isEmpty || turns.isEmpty) return const [];
  final rawPieces = normalized
      .split(RegExp(r'(?<=[。！？!?；;\n])\s*'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final pieces = rawPieces.isEmpty ? [normalized] : rawPieces;
  final minStartMs = turns.map((t) => t.start.inMilliseconds).reduce(math.min);
  final maxEndMs = math.max(
    minStartMs + pieces.length * 100,
    turns.map((t) => t.end.inMilliseconds).reduce(math.max),
  );
  final totalSpanMs = math.max(maxEndMs - minStartMs, pieces.length * 10);
  final totalRunes = math.max(
    1,
    pieces.fold<int>(0, (sum, s) => sum + s.runes.length),
  );

  final out = <SttSegment>[];
  var cursorRunes = 0;
  var prevStartMs = -1;
  for (var i = 0; i < pieces.length; i++) {
    final piece = pieces[i];
    final nextRunes = cursorRunes + piece.runes.length;
    var startMs = minStartMs + (totalSpanMs * cursorRunes) ~/ totalRunes;
    if (startMs <= prevStartMs) startMs = prevStartMs + 1;
    var endMs = i == pieces.length - 1
        ? maxEndMs
        : minStartMs + (totalSpanMs * nextRunes) ~/ totalRunes;
    if (endMs < startMs) endMs = startMs;
    out.add(SttSegment(text: piece, startMs: startMs, endMs: endMs));
    prevStartMs = startMs;
    cursorRunes = nextRunes;
  }
  return out;
}

abstract interface class SpeakerDiarizer {
  Future<DiarizationResult> diarize(
    String audioPath, {
    int? expectedSpeakers,
    void Function(double progress)? onProgress,
  });
}

/// Offline speaker diarizer powered by `sherpa_onnx` (`pyannote/segmentation-3.0`
/// + `3D-Speaker CAM++` embedding + hierarchical complete-linkage clustering).
class SherpaSpeakerDiarizer implements SpeakerDiarizer {
  SherpaSpeakerDiarizer({
    required this.modelStore,
    this.defaultClusteringThreshold = 0.75,
    this.numThreads = 4,
  });

  final DiarizationModelStore modelStore;
  final double defaultClusteringThreshold;
  final int numThreads;

  @override
  Future<DiarizationResult> diarize(
    String audioPath, {
    int? expectedSpeakers,
    void Function(double progress)? onProgress,
  }) async {
    final paths = await modelStore.ensureReady();
    return runSherpaDiarization(
      audioPath: audioPath,
      segmentationModelPath: paths.segmentationModelPath,
      embeddingModelPath: paths.embeddingModelPath,
      expectedSpeakers: expectedSpeakers,
      defaultClusteringThreshold: defaultClusteringThreshold,
      numThreads: numThreads,
      onProgress: onProgress,
    );
  }
}
