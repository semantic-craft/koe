import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:koe/ai/sherpa_diarizer_runner.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

// Real-model regression, intentionally outside scripts/check. Pass an existing
// model/fixture directory, then "responsiveness" or "sample-rate".
Future<void> main(List<String> args) async {
  final dir = args[0];
  await ensureSherpaBindingsInitialized();
  final path = '$dir/0-four-speakers-zh.wav';
  Future<DiarizationResult> run(
    String wav, {
    void Function(double)? progress,
  }) => runSherpaDiarization(
    audioPath: wav,
    segmentationModelPath: '$dir/segmentation-model.onnx',
    embeddingModelPath:
        '$dir/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx',
    expectedSpeakers: 4,
    onProgress: progress,
  );
  if (args[1] == 'responsiveness') {
    var ticks = 0;
    int? first;
    var last = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => ticks++,
    );
    try {
      final result = await run(
        path,
        progress: (_) {
          first ??= ticks;
          last = ticks;
        },
      );
      if (result.turns.isEmpty || first == null || last - first! < 3) {
        throw StateError(
          'UI heartbeat during native inference: ${last - (first ?? 0)}; expected >= 3',
        );
      }
      stdout.writeln(
        'PASS UI heartbeat during native inference: ${last - first!}',
      );
    } finally {
      timer.cancel();
    }
  } else if (args[1] == 'sample-rate') {
    final wave = sherpa.readWave(path);
    if (wave.sampleRate != 16000) throw StateError('fixture must be 16 kHz');
    // Hold each PCM sample for three 48 kHz frames: same physical duration.
    final samples = Float32List(wave.samples.length * 3);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = wave.samples[i ~/ 3];
    }
    final upsampled = '$dir/regression-48k.wav';
    sherpa.writeWave(filename: upsampled, samples: samples, sampleRate: 48000);
    try {
      final reference = await run(path);
      final actual = await run(upsampled);
      if (actual.turns.length != reference.turns.length) {
        throw StateError(
          '48 kHz turns=${actual.turns.length}; 16 kHz turns=${reference.turns.length}',
        );
      }
      var maxDifferenceMs = 0;
      for (var i = 0; i < reference.turns.length; i++) {
        final a = actual.turns[i];
        final b = reference.turns[i];
        final startDifference = (a.start - b.start).inMilliseconds.abs();
        final endDifference = (a.end - b.end).inMilliseconds.abs();
        if (startDifference > maxDifferenceMs) {
          maxDifferenceMs = startDifference;
        }
        if (endDifference > maxDifferenceMs) maxDifferenceMs = endDifference;
        // Filtering changes VAD edges. Bound that change by minDurationOn
        // (200 ms), while a rate interpretation bug stretches the whole clip.
        if (startDifference > 200 || endDifference > 200) {
          throw StateError(
            '48 kHz timeline mismatch at $i: ${a.start}-${a.end}; expected ${b.start}-${b.end} within 200 ms',
          );
        }
      }
      stdout.writeln(
        'PASS 48 kHz / 16 kHz timeline: ${actual.turns.length} turns, max difference $maxDifferenceMs ms, tolerance 200 ms',
      );
    } finally {
      await File(upsampled).delete();
    }
  } else {
    throw ArgumentError('Expected responsiveness or sample-rate');
  }
}
