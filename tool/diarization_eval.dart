import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:koe/ai/sherpa_diarizer_runner.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// Standalone evaluation script for offline speaker diarization (#371).
///
/// Not part of `scripts/check`. Run on macOS with:
/// ```bash
/// dart --packages=.dart_tool/package_config.json tool/diarization_eval.dart \
///   --cache-dir /tmp/turing-koe-p2/models-cache
/// ```
Future<void> main(List<String> args) async {
  var cacheDirPath = '/tmp/turing-koe-p2/models-cache';
  var clipSeconds = 420.0;
  var startSeconds = 0.0;
  double? threshold;
  double? maxDer;
  String? audioPath;
  String? referencePath;
  var amiOnly = false;
  var mode = 'both';
  var outputPrefix = 'ES2004a';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--cache-dir' && i + 1 < args.length) {
      cacheDirPath = args[++i];
    } else if (args[i] == '--clip-seconds' && i + 1 < args.length) {
      clipSeconds = double.parse(args[++i]);
    } else if (args[i] == '--start-seconds' && i + 1 < args.length) {
      startSeconds = double.parse(args[++i]);
    } else if (args[i] == '--threshold' && i + 1 < args.length) {
      threshold = double.parse(args[++i]);
    } else if (args[i] == '--max-der' && i + 1 < args.length) {
      maxDer = double.parse(args[++i]);
    } else if (args[i] == '--audio' && i + 1 < args.length) {
      audioPath = args[++i];
    } else if (args[i] == '--reference' && i + 1 < args.length) {
      referencePath = args[++i];
    } else if (args[i] == '--ami-only') {
      amiOnly = true;
    } else if (args[i] == '--mode' && i + 1 < args.length) {
      mode = args[++i];
    } else if (args[i] == '--output-prefix' && i + 1 < args.length) {
      outputPrefix = args[++i];
    } else {
      throw ArgumentError('Unknown or incomplete option: ${args[i]}');
    }
  }

  if ((audioPath == null) != (referencePath == null)) {
    throw ArgumentError('--audio and --reference must be supplied together');
  }
  if (!startSeconds.isFinite ||
      !clipSeconds.isFinite ||
      (threshold != null && (!threshold.isFinite || threshold <= 0)) ||
      (maxDer != null && (!maxDer.isFinite || maxDer < 0)) ||
      startSeconds < 0 ||
      clipSeconds <= 0 ||
      !['auto', '4', 'both'].contains(mode) ||
      !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(outputPrefix)) {
    throw ArgumentError('Invalid evaluation interval, mode or output prefix');
  }
  final modes = mode == 'both'
      ? <int?>[4, null]
      : <int?>[mode == '4' ? 4 : null];
  stdout.writeln(
    'start=$startSeconds duration=$clipSeconds threshold=${threshold ?? "default"} mode=$mode',
  );
  final segModelPath = '$cacheDirPath/segmentation-model.onnx';
  final embModelPath =
      '$cacheDirPath/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx';
  if (!await File(segModelPath).exists() ||
      !await File(embModelPath).exists()) {
    stderr.writeln('Models not found in $cacheDirPath');
    exit(1);
  }
  stdout.writeln('Model files found (verify SHA-256 before evaluation):');
  stdout.writeln('  segmentation: $segModelPath');
  stdout.writeln('  embedding:    $embModelPath');

  // 1. Authorized Chinese 4-speaker test audio from k2-fsa/sherpa-onnx
  final zhWavPath = '$cacheDirPath/0-four-speakers-zh.wav';
  if (!amiOnly && await File(zhWavPath).exists()) {
    await ensureSherpaBindingsInitialized();
    final zhWave = sherpa_onnx.readWave(zhWavPath);
    final zhDurationSec = zhWave.samples.length / zhWave.sampleRate;
    for (final expected in modes) {
      final sw = Stopwatch()..start();
      final result = await runSherpaDiarization(
        audioPath: zhWavPath,
        segmentationModelPath: segModelPath,
        embeddingModelPath: embModelPath,
        expectedSpeakers: expected,
        defaultClusteringThreshold:
            threshold ?? defaultDiarizationClusteringThreshold,
      );
      sw.stop();
      await File(
        '$cacheDirPath/$outputPrefix-zh-${expected ?? "auto"}-prediction.json',
      ).writeAsString(
        jsonEncode([
          for (final turn in result.turns)
            {
              'speaker': turn.speaker,
              'start': turn.start.inMicroseconds / 1e6,
              'end': turn.end.inMicroseconds / 1e6,
            },
        ]),
      );
      final speakers = result.turns.map((t) => t.speaker).toSet().length;
      final elapsedSec = sw.elapsedMilliseconds / 1000.0;
      stdout.writeln(
        '\n[0-four-speakers-zh.wav] duration=${zhDurationSec.toStringAsFixed(2)}s, '
        'expectedSpeakers=${expected ?? "auto"}:\n'
        '  detectedSpeakers=$speakers, turns=${result.turns.length}, '
        'elapsed=${elapsedSec.toStringAsFixed(2)}s '
        '(RTF=${(elapsedSec / zhDurationSec).toStringAsFixed(3)}), '
        'cohesion=${result.quality?.cohesion.toStringAsFixed(3)}, '
        'mergeRisk=${result.quality?.mergeRisk.toStringAsFixed(3)}; '
        'DER=N/A, single-speaker error=N/A (no independent reference annotation)',
      );
    }
  }

  // 2. AMI ES2004a (CC BY 4.0) DER evaluation
  final amiWavPath = audioPath ?? '$cacheDirPath/ES2004a.Mix-Headset.wav';
  final amiRttmPath = referencePath ?? '$cacheDirPath/ES2004a.rttm';
  if (!await File(amiWavPath).exists() || !await File(amiRttmPath).exists()) {
    throw StateError('Audio and independent RTTM reference are required');
  }
  {
    await ensureSherpaBindingsInitialized();
    final amiWave = sherpa_onnx.readWave(amiWavPath);
    final evalSec = math.min(
      clipSeconds,
      amiWave.samples.length / amiWave.sampleRate - startSeconds,
    );
    if (evalSec <= 0) throw ArgumentError('Start is beyond the audio');
    final clipSamples = Float32List.sublistView(
      amiWave.samples,
      (startSeconds * amiWave.sampleRate).round(),
      ((startSeconds + evalSec) * amiWave.sampleRate).round(),
    );
    final clipPath = '$cacheDirPath/${outputPrefix}_clip.wav';
    sherpa_onnx.writeWave(
      filename: clipPath,
      samples: clipSamples,
      sampleRate: amiWave.sampleRate,
    );

    final refTurns = parseDiarizationRttm(
      await File(amiRttmPath).readAsLines(),
      maxTimeSec: evalSec,
      startTimeSec: startSeconds,
    );
    final refSpeakers = refTurns.map((t) => t.speaker).toSet().length;

    for (final expected in modes) {
      final sw = Stopwatch()..start();
      final result = await runSherpaDiarization(
        audioPath: clipPath,
        segmentationModelPath: segModelPath,
        embeddingModelPath: embModelPath,
        expectedSpeakers: expected,
        defaultClusteringThreshold:
            threshold ?? defaultDiarizationClusteringThreshold,
      );
      sw.stop();
      final elapsedSec = sw.elapsedMilliseconds / 1000.0;
      final hypSpeakers = result.turns.map((t) => t.speaker).toSet().length;
      final metrics = evaluateDer(refTurns, result.turns, evalSec);
      await File(
        '$cacheDirPath/$outputPrefix-${expected ?? "auto"}-prediction.json',
      ).writeAsString(
        jsonEncode([
          for (final turn in result.turns)
            {
              'speaker': turn.speaker,
              'start': turn.start.inMicroseconds / 1e6,
              'end': turn.end.inMicroseconds / 1e6,
            },
        ]),
      );
      stdout.writeln(
        '\n[${audioPath ?? 'AMI ES2004a (CC BY 4.0)'} $startSeconds-${(startSeconds + evalSec).toStringAsFixed(0)}s] '
        'expectedSpeakers=${expected ?? "auto"}:\n'
        '  refSpeakers=$refSpeakers, hypSpeakers=$hypSpeakers, turns=${result.turns.length}\n'
        '  single-speaker error (all reference single speech, misses included, no collar) = '
        '${(metrics.speakerErrorRate * 100).toStringAsFixed(2)}% '
        '(accuracy ${(100 - metrics.speakerErrorRate * 100).toStringAsFixed(2)}%, threshold <= 15.0%)\n'
        '  DER (exact 250ms each-side collar, overlap included) = ${(metrics.derCollar250ms * 100).toStringAsFixed(2)}%\n'
        '  single error/reference=${metrics.singleErrorSeconds.toStringAsFixed(6)}/${metrics.singleReferenceSeconds.toStringAsFixed(6)}s; '
        'DER error/reference=${metrics.derErrorSeconds.toStringAsFixed(6)}/${metrics.scoredReferenceSeconds.toStringAsFixed(6)}s\n'
        '  elapsed=${elapsedSec.toStringAsFixed(2)}s '
        '(RTF=${(elapsedSec / evalSec).toStringAsFixed(3)}), '
        'cohesion=${result.quality?.cohesion.toStringAsFixed(3)}',
      );
      if (maxDer != null && metrics.derCollar250ms > maxDer) {
        stderr.writeln('FAIL DER ${metrics.derCollar250ms} exceeds $maxDer');
        exitCode = 1;
      }
    }
    try {
      await File(clipPath).delete();
    } catch (_) {}
  }
}

List<({double start, double end, String speaker})> parseDiarizationRttm(
  List<String> lines, {
  required double maxTimeSec,
  double startTimeSec = 0,
}) {
  final out = <({double start, double end, String speaker})>[];
  for (final line in lines) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 8 || parts[0] != 'SPEAKER') continue;
    final start = double.parse(parts[3]) - startTimeSec;
    final dur = double.parse(parts[4]);
    if (start >= maxTimeSec || start + dur <= 0) continue;
    out.add((
      start: math.max(0, start),
      end: math.min(maxTimeSec, start + dur),
      speaker: parts[7],
    ));
  }
  return out;
}

/// Exact interval scoring over [0, maxTimeSec], including overlapping speech.
/// Reference boundaries exclude 250 ms on EACH side for DER. Speaker mapping
/// maximizes scored reference/hypothesis overlap with a one-to-one assignment.
/// Single-speaker error uses ALL reference single-speaker time, without collar;
/// a missing prediction or an extra speaker counts as incorrect time.
({
  double speakerErrorRate,
  double derCollar250ms,
  double singleReferenceSeconds,
  double singleErrorSeconds,
  double scoredReferenceSeconds,
  double derErrorSeconds,
})
evaluateDer(
  List<({double start, double end, String speaker})> refTurns,
  List<DiarizationTurn> hypTurns,
  double maxTimeSec,
) {
  final boundaries = <double>{0, maxTimeSec};
  final collars = <({double start, double end})>[];
  void boundary(double value) => boundaries.add(value.clamp(0, maxTimeSec));
  for (final r in refTurns) {
    boundary(r.start);
    boundary(r.end);
    for (final edge in [r.start, r.end]) {
      final start = (edge - 0.25).clamp(0.0, maxTimeSec);
      final end = (edge + 0.25).clamp(0.0, maxTimeSec);
      collars.add((start: start, end: end));
      boundary(start);
      boundary(end);
    }
  }
  for (final h in hypTurns) {
    boundary(h.start.inMicroseconds / 1e6);
    boundary(h.end.inMicroseconds / 1e6);
  }
  final edges = boundaries.toList()..sort();
  final intervals =
      <({double seconds, Set<String> refs, Set<int> hyps, bool scored})>[];
  final pairs = <int, Map<String, double>>{};
  for (var i = 1; i < edges.length; i++) {
    final start = edges[i - 1];
    final end = edges[i];
    if (end <= start) continue;
    final mid = (start + end) / 2;
    final refs = {
      for (final r in refTurns)
        if (r.start <= mid && mid < r.end) r.speaker,
    };
    final hyps = {
      for (final h in hypTurns)
        if (h.start.inMicroseconds / 1e6 <= mid &&
            mid < h.end.inMicroseconds / 1e6)
          h.speaker,
    };
    final scored = !collars.any((c) => c.start <= mid && mid < c.end);
    final seconds = end - start;
    intervals.add((seconds: seconds, refs: refs, hyps: hyps, scored: scored));
    if (scored) {
      for (final h in hyps) {
        final overlaps = pairs.putIfAbsent(h, () => {});
        for (final r in refs) {
          overlaps[r] = (overlaps[r] ?? 0) + seconds;
        }
      }
    }
  }
  final hs = hypTurns.map((h) => h.speaker).toSet().toList()..sort();
  final rs = refTurns.map((r) => r.speaker).toSet().toList()..sort();
  // Hungarian assignment on a square matrix with zero-weight dummy speakers.
  // Polynomial time also covers severe over-clustering in automatic mode.
  final n = math.max(hs.length, rs.length);
  final u = List<double>.filled(n + 1, 0);
  final v = List<double>.filled(n + 1, 0);
  final matchedRow = List<int>.filled(n + 1, 0);
  final previous = List<int>.filled(n + 1, 0);
  for (var row = 1; row <= n; row++) {
    matchedRow[0] = row;
    var column = 0;
    final minimum = List<double>.filled(n + 1, double.infinity);
    final used = List<bool>.filled(n + 1, false);
    do {
      used[column] = true;
      final currentRow = matchedRow[column];
      var delta = double.infinity;
      var nextColumn = 0;
      for (var candidate = 1; candidate <= n; candidate++) {
        if (used[candidate]) continue;
        final overlap = currentRow <= hs.length && candidate <= rs.length
            ? (pairs[hs[currentRow - 1]]?[rs[candidate - 1]] ?? 0.0)
            : 0.0;
        final cost = -overlap - u[currentRow] - v[candidate];
        if (cost < minimum[candidate]) {
          minimum[candidate] = cost;
          previous[candidate] = column;
        }
        if (minimum[candidate] < delta) {
          delta = minimum[candidate];
          nextColumn = candidate;
        }
      }
      for (var candidate = 0; candidate <= n; candidate++) {
        if (used[candidate]) {
          u[matchedRow[candidate]] += delta;
          v[candidate] -= delta;
        } else {
          minimum[candidate] -= delta;
        }
      }
      column = nextColumn;
    } while (matchedRow[column] != 0);
    do {
      final parent = previous[column];
      matchedRow[column] = matchedRow[parent];
      column = parent;
    } while (column != 0);
  }
  final best = <int, String>{
    for (var column = 1; column <= rs.length; column++)
      if (matchedRow[column] > 0 && matchedRow[column] <= hs.length)
        hs[matchedRow[column] - 1]: rs[column - 1],
  };
  var singleReference = 0.0;
  var singleError = 0.0;
  var scoredReference = 0.0;
  var derError = 0.0;
  for (final interval in intervals) {
    final correct = interval.hyps
        .where((h) => interval.refs.contains(best[h]))
        .length;
    if (interval.refs.length == 1) {
      singleReference += interval.seconds;
      if (interval.hyps.length != 1 || correct != 1) {
        singleError += interval.seconds;
      }
    }
    if (interval.scored) {
      scoredReference += interval.refs.length * interval.seconds;
      derError +=
          (math.max(interval.refs.length, interval.hyps.length) - correct) *
          interval.seconds;
    }
  }
  return (
    speakerErrorRate: singleReference > 0 ? singleError / singleReference : 0,
    derCollar250ms: scoredReference > 0
        ? derError / scoredReference
        : (derError > 0 ? double.infinity : 0),
    singleReferenceSeconds: singleReference,
    singleErrorSeconds: singleError,
    scoredReferenceSeconds: scoredReference,
    derErrorSeconds: derError,
  );
}
