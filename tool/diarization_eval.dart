import 'dart:io';
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
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--cache-dir' && i + 1 < args.length) {
      cacheDirPath = args[++i];
    } else if (args[i] == '--clip-seconds' && i + 1 < args.length) {
      clipSeconds = double.parse(args[++i]);
    }
  }

  final segModelPath = '$cacheDirPath/segmentation-model.onnx';
  final embModelPath =
      '$cacheDirPath/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx';
  if (!await File(segModelPath).exists() ||
      !await File(embModelPath).exists()) {
    stderr.writeln('Models not found in $cacheDirPath');
    exit(1);
  }
  stdout.writeln('Models verified ready:');
  stdout.writeln('  segmentation: $segModelPath');
  stdout.writeln('  embedding:    $embModelPath');

  // 1. Authorized Chinese 4-speaker test audio from k2-fsa/sherpa-onnx
  final zhWavPath = '$cacheDirPath/0-four-speakers-zh.wav';
  if (await File(zhWavPath).exists()) {
    await ensureSherpaBindingsInitialized();
    final zhWave = sherpa_onnx.readWave(zhWavPath);
    final zhDurationSec = zhWave.samples.length / zhWave.sampleRate;
    for (final expected in <int?>[null, 4]) {
      final sw = Stopwatch()..start();
      final result = await runSherpaDiarization(
        audioPath: zhWavPath,
        segmentationModelPath: segModelPath,
        embeddingModelPath: embModelPath,
        expectedSpeakers: expected,
      );
      sw.stop();
      final speakers = result.turns.map((t) => t.speaker).toSet().length;
      final elapsedSec = sw.elapsedMilliseconds / 1000.0;
      stdout.writeln(
        '\n[0-four-speakers-zh.wav] duration=${zhDurationSec.toStringAsFixed(2)}s, '
        'expectedSpeakers=${expected ?? "auto"}:\n'
        '  detectedSpeakers=$speakers, turns=${result.turns.length}, '
        'elapsed=${elapsedSec.toStringAsFixed(2)}s '
        '(RTF=${(elapsedSec / zhDurationSec).toStringAsFixed(3)}), '
        'cohesion=${result.quality?.cohesion.toStringAsFixed(3)}, '
        'mergeRisk=${result.quality?.mergeRisk.toStringAsFixed(3)}',
      );
    }
  }

  // 2. AMI ES2004a (CC BY 4.0) DER evaluation
  final amiWavPath = '$cacheDirPath/ES2004a.Mix-Headset.wav';
  final amiRttmPath = '$cacheDirPath/ES2004a.rttm';
  if (await File(amiWavPath).exists() && await File(amiRttmPath).exists()) {
    await ensureSherpaBindingsInitialized();
    final amiWave = sherpa_onnx.readWave(amiWavPath);
    final evalSec = math.min(
      clipSeconds,
      amiWave.samples.length / amiWave.sampleRate,
    );
    final clipSamples = Float32List.sublistView(
      amiWave.samples,
      0,
      (evalSec * amiWave.sampleRate).round(),
    );
    final clipPath = '$cacheDirPath/ES2004a_clip_${evalSec.round()}s.wav';
    sherpa_onnx.writeWave(
      filename: clipPath,
      samples: clipSamples,
      sampleRate: amiWave.sampleRate,
    );

    final refTurns = _parseRttm(
      await File(amiRttmPath).readAsLines(),
      maxTimeSec: evalSec,
    );
    final refSpeakers = refTurns.map((t) => t.speaker).toSet().length;

    for (final expected in <int?>[4, null]) {
      final sw = Stopwatch()..start();
      final result = await runSherpaDiarization(
        audioPath: clipPath,
        segmentationModelPath: segModelPath,
        embeddingModelPath: embModelPath,
        expectedSpeakers: expected,
      );
      sw.stop();
      final elapsedSec = sw.elapsedMilliseconds / 1000.0;
      final hypSpeakers = result.turns.map((t) => t.speaker).toSet().length;
      final metrics = _evaluateDer(refTurns, result.turns, evalSec);
      stdout.writeln(
        '\n[AMI ES2004a 0-${evalSec.toStringAsFixed(0)}s (CC BY 4.0)] '
        'expectedSpeakers=${expected ?? "auto"}:\n'
        '  refSpeakers=$refSpeakers, hypSpeakers=$hypSpeakers, turns=${result.turns.length}\n'
        '  speakerErrorRate (T-A3 single-speaker voiced time) = '
        '${(metrics.speakerErrorRate * 100).toStringAsFixed(2)}% '
        '(accuracy ${(100 - metrics.speakerErrorRate * 100).toStringAsFixed(2)}%, threshold <= 15.0%)\n'
        '  NIST DER (250ms collar) = ${(metrics.derCollar250ms * 100).toStringAsFixed(2)}%\n'
        '  elapsed=${elapsedSec.toStringAsFixed(2)}s '
        '(RTF=${(elapsedSec / evalSec).toStringAsFixed(3)}), '
        'cohesion=${result.quality?.cohesion.toStringAsFixed(3)}',
      );
    }
    try {
      await File(clipPath).delete();
    } catch (_) {}
  }
}

List<({double start, double end, String speaker})> _parseRttm(
  List<String> lines, {
  required double maxTimeSec,
}) {
  final out = <({double start, double end, String speaker})>[];
  for (final line in lines) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 8 || parts[0] != 'SPEAKER') continue;
    final start = double.parse(parts[3]);
    final dur = double.parse(parts[4]);
    if (start >= maxTimeSec) continue;
    out.add((
      start: start,
      end: math.min(maxTimeSec, start + dur),
      speaker: parts[7],
    ));
  }
  return out;
}

({double speakerErrorRate, double derCollar250ms}) _evaluateDer(
  List<({double start, double end, String speaker})> refTurns,
  List<DiarizationTurn> hypTurns,
  double maxTimeSec,
) {
  const step = 0.1;
  final cells = (maxTimeSec / step).ceil() + 1;
  final refGrid = List<Set<String>>.generate(cells, (_) => <String>{});
  final collarCells = (0.25 / step).ceil();
  final boundaryMask = List<bool>.filled(cells, false);

  for (final r in refTurns) {
    final s = (r.start / step).floor().clamp(0, cells);
    final e = (r.end / step).floor().clamp(0, cells);
    for (var i = s; i < e; i++) {
      refGrid[i].add(r.speaker);
    }
    for (
      var i = math.max(0, s - collarCells);
      i < math.min(cells, s + collarCells + 1);
      i++
    ) {
      boundaryMask[i] = true;
    }
    for (
      var i = math.max(0, e - collarCells);
      i < math.min(cells, e + collarCells + 1);
      i++
    ) {
      boundaryMask[i] = true;
    }
  }

  final hypGrid = List<Set<int>>.generate(cells, (_) => <int>{});
  for (final h in hypTurns) {
    final startSec = h.start.inMicroseconds / 1e6;
    final endSec = h.end.inMicroseconds / 1e6;
    final s = (startSec / step).floor().clamp(0, cells);
    final e = (endSec / step).floor().clamp(0, cells);
    for (var i = s; i < math.max(s, e); i++) {
      hypGrid[i].add(h.speaker);
    }
  }

  final pairs = <int, Map<String, int>>{};
  var scoredSingle = 0;
  for (var i = 0; i < cells; i++) {
    if (refGrid[i].length != 1 || hypGrid[i].isEmpty) continue;
    final h = hypGrid[i].first;
    scoredSingle++;
    final r = refGrid[i].first;
    final m = pairs.putIfAbsent(h, () => <String, int>{});
    m[r] = (m[r] ?? 0) + 1;
  }

  final hs = pairs.keys.toList()..sort();
  final rs = pairs.values.expand((m) => m.keys).toSet().toList()..sort();
  int scoreMap(Map<int, String> map) {
    var total = 0;
    map.forEach((h, r) => total += pairs[h]?[r] ?? 0);
    return total;
  }

  var best = <int, String>{};
  void search(int idx, Set<String> used, Map<int, String> cur) {
    if (idx == hs.length) {
      if (scoreMap(cur) > scoreMap(best)) best = Map<int, String>.of(cur);
      return;
    }
    search(idx + 1, used, cur);
    for (final r in rs) {
      if (used.contains(r)) continue;
      cur[hs[idx]] = r;
      search(idx + 1, {...used, r}, cur);
      cur.remove(hs[idx]);
    }
  }

  if (hs.length <= 7 && rs.length <= 7) {
    search(0, <String>{}, <int, String>{});
  } else {
    final used = <String>{};
    final triples = <({int h, String r, int c})>[
      for (final h in hs)
        for (final e in pairs[h]!.entries) (h: h, r: e.key, c: e.value),
    ]..sort((a, b) => b.c.compareTo(a.c));
    for (final t in triples) {
      if (!best.containsKey(t.h) && !used.contains(t.r)) {
        best[t.h] = t.r;
        used.add(t.r);
      }
    }
  }

  final correctSingle = scoreMap(best);
  final speakerErrorRate = 1.0 - (correctSingle / math.max(scoredSingle, 1));

  var totalRefCollar = 0;
  var totalErrCollar = 0;
  for (var i = 0; i < cells; i++) {
    if (boundaryMask[i]) continue;
    final rSet = refGrid[i];
    final hMapped = hypGrid[i].map((h) => best[h] ?? 'unmapped_$h').toSet();
    final nRef = rSet.length;
    final nHyp = hMapped.length;
    totalRefCollar += nRef;
    final nCorrect = rSet.intersection(hMapped).length;
    totalErrCollar += math.max(nRef, nHyp) - nCorrect;
  }
  final derCollar250ms = totalErrCollar / math.max(totalRefCollar, 1);

  return (speakerErrorRate: speakerErrorRate, derCollar250ms: derCollar250ms);
}
