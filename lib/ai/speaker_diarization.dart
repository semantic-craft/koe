import 'dart:math' as math;

import '../state/recording.dart';
import 'diarization_model_store.dart';
import 'sherpa_diarizer_runner.dart';

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

/// Carries speaker ids over a re-diarization, so names and manual
/// corrections, both keyed by id, stay with the same person (Shiyin R22.2).
///
/// A speaker in [fresh] keeps the id a segment had in [previous] when at
/// least 60% of its time was that old speaker and most of that old
/// speaker's time went to it, counting only segments outside [corrected].
/// Every other speaker takes, in order of first appearance, the smallest
/// free id that no kept speaker and nothing in [reserved] uses.
///
/// The share rule follows Shiyin
/// `Sources/Shiyin/Services/JobRunner.swift:403-436` (`oldToNew`,
/// `inheritNames`, commit `d4deacf`); Shiyin moves the names to the new
/// numbers, Koe keeps the numbers instead.
List<TranscriptSegment> keepSpeakerIds(
  List<TranscriptSegment> previous,
  List<TranscriptSegment> fresh, {
  Set<int> corrected = const {},
  Set<String> reserved = const {},
}) {
  final byNew = <String, Map<String, int>>{};
  final byOld = <String, Map<String, int>>{};
  for (var i = 0; i < fresh.length && i < previous.length; i++) {
    final next = fresh[i].speaker;
    final old = previous[i].speaker;
    if (next == null || old == null || corrected.contains(i)) continue;
    final segment = fresh[i];
    final us = math.max(
      0,
      (segment.end ?? segment.start).inMicroseconds -
          segment.start.inMicroseconds,
    );
    final shares = byNew.putIfAbsent(next, () => {});
    shares[old] = (shares[old] ?? 0) + us;
    final spread = byOld.putIfAbsent(old, () => {});
    spread[next] = (spread[next] ?? 0) + us;
  }

  // Ties go to the earlier entry, which is the earlier speaker to appear.
  String largest(Map<String, int> times) {
    var best = times.entries.first;
    for (final entry in times.entries) {
      if (entry.value > best.value) best = entry;
    }
    return best.key;
  }

  final ids = <String, String>{};
  for (final MapEntry(key: next, value: shares) in byNew.entries) {
    final total = shares.values.fold(0, (sum, us) => sum + us);
    if (total == 0) continue;
    final old = largest(shares);
    if (shares[old]! < 0.6 * total || largest(byOld[old]!) != next) continue;
    ids[next] = old;
  }

  final taken = {...reserved, ...ids.values};
  var candidate = 1;
  return [
    for (final segment in fresh)
      if (segment.speaker case final next?)
        segment.copyWith(
          speaker: ids.putIfAbsent(next, () {
            while (!taken.add('$candidate')) {
              candidate++;
            }
            return '$candidate';
          }),
        )
      else
        segment,
  ];
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
    this.defaultClusteringThreshold = defaultDiarizationClusteringThreshold,
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
