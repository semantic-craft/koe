import 'dart:async';
import 'dart:math' as math;

import 'package:koe/state/recorder_controller.dart';

/// Answers the n-th call with the n-th list of [answers], repeating the last
/// one, and holds every answer while [gate] is open.
class ScriptedSpeakerDiarizer implements SpeakerDiarizer {
  ScriptedSpeakerDiarizer(this.answers, {this.quality});

  final List<List<DiarizationTurn>> answers;
  final DiarizationQuality? quality;
  final audioPaths = <String>[];
  int calls = 0;
  int? lastExpectedSpeakers;
  Completer<void>? gate;

  @override
  Future<DiarizationResult> diarize(
    String audioPath, {
    int? expectedSpeakers,
    void Function(double progress)? onProgress,
  }) async {
    final turns = answers[math.min(calls, answers.length - 1)];
    calls++;
    audioPaths.add(audioPath);
    lastExpectedSpeakers = expectedSpeakers;
    if (gate case final open?) await open.future;
    return DiarizationResult(turns: turns, quality: quality);
  }
}

/// Polls until [done] holds, for state written after asynchronous work.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
