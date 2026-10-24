import 'dart:convert';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
// sherpa_onnx 1.13.8's public process() copies the entire input. Use its
// generated C bindings with our owned buffer; dependency upgrades must run
// tool/diarization_regression.dart and the hour-long memory probe.
// ignore: implementation_imports
import 'package:sherpa_onnx/src/sherpa_onnx_bindings.dart';
import 'diarization_pcm.dart';
import 'diarization_refinement.dart';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

/// One speaker-labeled time interval produced by offline speaker diarization.
class DiarizationTurn {
  const DiarizationTurn({
    required this.speaker,
    required this.start,
    required this.end,
    this.confidence = -2.0,
    this.embedding,
  });

  final int speaker;
  final Duration start;
  final Duration end;
  final double confidence;
  final List<double>? embedding;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiarizationTurn &&
          other.speaker == speaker &&
          other.start == start &&
          other.end == end &&
          other.confidence == confidence;

  @override
  int get hashCode => Object.hash(speaker, start, end, confidence);
}

/// Self-check metrics for whether offline diarization may have merged multiple
/// speakers into a single cluster (S24).
///
/// Thresholds and formula follow the approach in Shiyin
/// (`juinwei7/Shiyin` commit `7ffd7d4b43b3f3cf06012cf3abfbe8e2b0e257f9`,
/// `Sources/Shiyin/Transcribe/Diarizer.swift:26-47` & `docs/design.md` §24.5):
/// - [minChunksForCheck] = 30 (~1 minute of speech; shorter clips do not trigger).
/// - [hintThreshold] = 0.4, corresponding to mean intra-cluster cosine similarity
///   [cohesion] < 0.6 (in 15 benchmarked meetings, normal meetings had cohesion
///   0.71–0.87 while under-clustered multi-speaker recordings had 0.48).
/// Only cohesion is available from sherpa's final turns. Those turns do not
/// expose independent pre-clustering local speakers for collision detection.
class DiarizationQuality {
  const DiarizationQuality({
    required this.chunks,
    required this.clusters,
    required this.cohesion,
  });

  static const double hintThreshold = 0.4;
  static const int minChunksForCheck = 30;

  final int chunks;
  final int clusters;
  final double cohesion;

  double get mergeRisk {
    if (chunks < minChunksForCheck) return 0.0;
    return math.max(0.0, 1.0 - cohesion);
  }

  bool get shouldSuggestRediarize => mergeRisk > hintThreshold;

  /// Computes [DiarizationQuality] from per-window speaker embeddings and their
  /// assigned cluster labels.
  factory DiarizationQuality.fromTurnEmbeddings(
    List<({int clusterSpeaker, List<double> embedding})> items,
  ) {
    if (items.isEmpty) {
      return const DiarizationQuality(chunks: 0, clusters: 0, cohesion: 1.0);
    }

    List<double> normalizeVec(List<double> v) {
      var sumSq = 0.0;
      for (final x in v) {
        sumSq += x * x;
      }
      final norm = math.sqrt(sumSq);
      if (norm <= 1e-12) return v;
      return [for (final x in v) x / norm];
    }

    final byCluster = <int, List<List<double>>>{};
    for (final item in items) {
      if (item.embedding.isEmpty) continue;
      byCluster
          .putIfAbsent(item.clusterSpeaker, () => [])
          .add(normalizeVec(item.embedding));
    }

    var totalSimilarity = 0.0;
    var count = 0;
    for (final vectors in byCluster.values) {
      if (vectors.isEmpty) continue;
      final dim = vectors.first.length;
      if (dim == 0) continue;
      final sum = List<double>.filled(dim, 0.0);
      for (final v in vectors) {
        if (v.length != dim) continue;
        for (var i = 0; i < dim; i++) {
          sum[i] += v[i];
        }
      }
      final centroid = normalizeVec(sum);
      for (final v in vectors) {
        if (v.length != dim) continue;
        var dot = 0.0;
        for (var i = 0; i < dim; i++) {
          dot += v[i] * centroid[i];
        }
        totalSimilarity += dot;
        count++;
      }
    }

    return DiarizationQuality(
      chunks: items.length,
      clusters: byCluster.length,
      cohesion: count > 0 ? (totalSimilarity / count).clamp(-1.0, 1.0) : 1.0,
    );
  }

  Map<String, Object?> toJson() => {
    'chunks': chunks,
    'clusters': clusters,
    'cohesion': cohesion,
  };

  static DiarizationQuality? decode(Object? value) {
    if (value is! Map) return null;
    final chunks = value['chunks'];
    final clusters = value['clusters'];
    final cohesion = value['cohesion'];
    if (chunks is! int || clusters is! int || cohesion is! num) return null;
    return DiarizationQuality(
      chunks: chunks,
      clusters: clusters,
      cohesion: cohesion.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiarizationQuality &&
          other.chunks == chunks &&
          other.clusters == clusters &&
          (other.cohesion - cohesion).abs() < 1e-9;

  @override
  int get hashCode =>
      Object.hash(chunks, clusters, cohesion.toStringAsFixed(6));
}

class DiarizationResult {
  const DiarizationResult({required this.turns, this.quality});

  final List<DiarizationTurn> turns;
  final DiarizationQuality? quality;
}

bool _sherpaBindingsInitialized = false;

Future<void> ensureSherpaBindingsInitialized() async {
  if (_sherpaBindingsInitialized) return;
  String? customPath;
  if (Platform.isMacOS) {
    final configFile = File(
      '${Directory.current.path}/.dart_tool/package_config.json',
    );
    if (configFile.existsSync()) {
      try {
        final config =
            jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
        final packages = config['packages'] as List<Object?>;
        for (final entry in packages) {
          final pkg = entry as Map<String, Object?>;
          if (pkg['name'] != 'sherpa_onnx_macos') continue;
          final rootUri = configFile.parent.uri.resolve(
            pkg['rootUri'] as String,
          );
          final candidate = Directory('${rootUri.toFilePath()}/macos');
          if (candidate.existsSync()) {
            customPath = candidate.path;
          }
          break;
        }
      } catch (_) {}
    }
  }
  await sherpa_onnx.initBindingsAsync(customPath);
  _sherpaBindingsInitialized = true;
}

// Frozen using AMI ES2004a 420–840s; the 0–420s holdout is not used to tune.
const defaultDiarizationClusteringThreshold = 1.0;

Future<DiarizationResult> runSherpaDiarization({
  required String audioPath,
  required String segmentationModelPath,
  required String embeddingModelPath,
  int? expectedSpeakers,
  double defaultClusteringThreshold = defaultDiarizationClusteringThreshold,
  int numThreads = 4,
  void Function(double progress)? onProgress,
}) async {
  final progressPort = onProgress == null ? null : ReceivePort();
  final subscription = progressPort?.listen(
    (value) => onProgress!(value as double),
  );
  try {
    return await _dispatchDiarization((
      audioPath: audioPath,
      segmentationModelPath: segmentationModelPath,
      embeddingModelPath: embeddingModelPath,
      expectedSpeakers: expectedSpeakers,
      threshold: defaultClusteringThreshold,
      numThreads: numThreads,
      progress: progressPort?.sendPort,
    ));
  } finally {
    await subscription?.cancel();
    progressPort?.close();
  }
}

// Keep the closure in a separate scope: it captures only transferable values,
// never the UI callback, model store, ReceivePort or native handles.
Future<DiarizationResult> _dispatchDiarization(
  ({
    String audioPath,
    String segmentationModelPath,
    String embeddingModelPath,
    int? expectedSpeakers,
    double threshold,
    int numThreads,
    SendPort? progress,
  })
  request,
) => Isolate.run(
  () => _runSherpaDiarization(
    audioPath: request.audioPath,
    segmentationModelPath: request.segmentationModelPath,
    embeddingModelPath: request.embeddingModelPath,
    expectedSpeakers: request.expectedSpeakers,
    defaultClusteringThreshold: request.threshold,
    numThreads: request.numThreads,
    onProgress: request.progress == null
        ? null
        : (value) => request.progress!.send(value),
  ),
);

Future<DiarizationResult> _runSherpaDiarization({
  required String audioPath,
  required String segmentationModelPath,
  required String embeddingModelPath,
  int? expectedSpeakers,
  double defaultClusteringThreshold = defaultDiarizationClusteringThreshold,
  int numThreads = 4,
  void Function(double progress)? onProgress,
}) async {
  await ensureSherpaBindingsInitialized();

  final pcm = DiarizationPcm.open(audioPath);
  Pointer<Float> owned = nullptr;
  try {
    const rate = DiarizationPcm.sampleRate;
    final count = (pcm.sampleCount * rate / pcm.rate).round();
    if (pcm.rate != rate && pcm.sampleCount > pcm.rate * 300) {
      throw StateError('长录音需要先转为 16 kHz 单声道 WAV；原文已保留');
    }
    owned = calloc<Float>(count);
    final samples = owned.asTypedList(count);
    if (pcm.rate == rate) {
      for (var start = 0; start < count; start += rate) {
        final end = math.min(count, start + rate);
        samples.setRange(start, end, pcm.read(start, end));
      }
    } else {
      samples.setAll(
        0,
        resampleDiarizationMono(pcm.read(0, pcm.sampleCount), pcm.rate, rate),
      );
    }
    return _processDiarizationSamples(
      owned,
      count,
      segmentationModelPath: segmentationModelPath,
      embeddingModelPath: embeddingModelPath,
      expectedSpeakers: expectedSpeakers,
      defaultClusteringThreshold: defaultClusteringThreshold,
      numThreads: numThreads,
      onProgress: onProgress,
    );
  } finally {
    if (owned != nullptr) calloc.free(owned);
    pcm.close();
  }
}

DiarizationResult _processDiarizationSamples(
  Pointer<Float> owned,
  int count, {
  required String segmentationModelPath,
  required String embeddingModelPath,
  required int? expectedSpeakers,
  required double defaultClusteringThreshold,
  required int numThreads,
  required void Function(double)? onProgress,
}) {
  final wave = sherpa_onnx.WaveData(
    samples: owned.asTypedList(count),
    sampleRate: DiarizationPcm.sampleRate,
  );
  List<DiarizationTurn> recognize(int numClusters) {
    final config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
      segmentation: sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
        pyannote: sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
          model: segmentationModelPath,
          windowShiftRatio: 0.1,
        ),
        numThreads: numThreads,
        debug: false,
      ),
      embedding: sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model: embeddingModelPath,
        numThreads: numThreads,
        debug: false,
      ),
      clustering: sherpa_onnx.FastClusteringConfig(
        numClusters: numClusters,
        // Keep the explicit-count configuration independent of auto tuning.
        threshold: numClusters > 0 ? 0.75 : defaultClusteringThreshold,
        computeConfidence: true,
      ),
      minDurationOn: 0.2,
      minDurationOff: 0.5,
    );

    final sd = sherpa_onnx.OfflineSpeakerDiarization(config);
    List<sherpa_onnx.OfflineSpeakerDiarizationSegment> rawSegments;
    try {
      if (sd.sampleRate != wave.sampleRate) throw StateError('发言人模型采样率不匹配');
      rawSegments = _processOwnedBuffer(sd, owned, count, onProgress);
    } finally {
      sd.free();
    }

    final turns = <DiarizationTurn>[
      for (final seg in rawSegments)
        DiarizationTurn(
          speaker: seg.speaker,
          start: Duration(microseconds: (seg.start * 1e6).round()),
          end: Duration(microseconds: (seg.end * 1e6).round()),
          confidence: seg.confidence,
        ),
    ];

    return turns;
  }

  // Count constraints on all native embeddings let tiny mixed clusters occupy
  // slots while real speakers merge. First obtain unconstrained segmentation,
  // then constrain clean representative profiles and reassign mixed fragments.
  final turns = recognize(-1);
  if (turns.isEmpty) return const DiarizationResult(turns: []);
  final evidence = _extractSpeakerEvidence(
    wave: wave,
    turns: turns,
    embeddingModelPath: embeddingModelPath,
    numThreads: numThreads,
  );
  if (evidence.isEmpty && expectedSpeakers == null) {
    return DiarizationResult(turns: turns);
  }
  final labels = refineSpeakerLabels(
    turns.map((t) => t.speaker).toList(),
    evidence,
    expectedSpeakers: expectedSpeakers,
  );
  if (labels == null) {
    // A user can request MORE speakers than the automatic segmentation found.
    // Preserve the native splitting path rather than silently ignoring that.
    final constrained = recognize(expectedSpeakers!);
    final samples = _extractSpeakerEvidence(
      wave: wave,
      turns: constrained,
      embeddingModelPath: embeddingModelPath,
      numThreads: numThreads,
    );
    return DiarizationResult(
      turns: constrained,
      quality: _qualityFromEvidence(
        constrained.map((t) => t.speaker).toList(),
        samples,
      ),
    );
  }
  return DiarizationResult(
    turns: _relabelAndCoalesce(turns, labels),
    quality: _qualityFromEvidence(labels, evidence),
  );
}

DiarizationQuality? _qualityFromEvidence(
  List<int> labels,
  List<SpeakerEvidence> evidence,
) {
  if (evidence.isEmpty) return null;
  return DiarizationQuality.fromTurnEmbeddings([
    for (final item in evidence)
      (clusterSpeaker: labels[item.turn], embedding: item.embedding),
  ]);
}

List<DiarizationTurn> _relabelAndCoalesce(
  List<DiarizationTurn> turns,
  List<int> labels,
) {
  final grouped = <int, List<DiarizationTurn>>{};
  for (var i = 0; i < turns.length; i++) {
    final t = turns[i];
    grouped
        .putIfAbsent(labels[i], () => [])
        .add(
          DiarizationTurn(
            speaker: labels[i],
            start: t.start,
            end: t.end,
            // Native silhouette describes the original clustering, not this result.
          ),
        );
  }
  final result = <DiarizationTurn>[];
  for (final entries in grouped.values) {
    entries.sort((a, b) => a.start.compareTo(b.start));
    var current = entries.first;
    for (final next in entries.skip(1)) {
      if (next.start <= current.end) {
        current = DiarizationTurn(
          speaker: current.speaker,
          start: current.start,
          end: next.end > current.end ? next.end : current.end,
        );
      } else {
        result.add(current);
        current = next;
      }
    }
    result.add(current);
  }
  result.sort((a, b) => a.start.compareTo(b.start));
  return result;
}

/// Windowed-sinc conversion of mono PCM to the model rate. The low-pass cutoff
/// follows the lower Nyquist frequency, so downsampling does not simply discard
/// high-rate samples. Duration is preserved to one target sample; model seconds
/// therefore remain recording seconds (no post-hoc time scaling).
Float32List resampleDiarizationMono(
  Float32List input,
  int sourceRate,
  int targetRate,
) {
  if (sourceRate <= 0 || targetRate <= 0) {
    throw ArgumentError('Invalid sample rate');
  }
  if (sourceRate == targetRate || input.isEmpty) return input;
  final ratio = sourceRate / targetRate;
  final cutoff = math.min(1.0, 1.0 / ratio);
  final radius = (16 / cutoff).ceil();
  final output = Float32List((input.length / ratio).round());
  // Cache kernels by fractional phase (48 -> 16 kHz has one phase).
  final kernels = <int, List<double>>{};
  for (var i = 0; i < output.length; i++) {
    final position = i * ratio;
    final center = position.floor();
    final fraction = position - center;
    final phase = (fraction * 1000000).round();
    final kernel = kernels.putIfAbsent(
      phase,
      () => [
        for (var offset = -radius; offset <= radius; offset++)
          _resamplingWeight(offset - fraction, cutoff, radius),
      ],
    );
    var sum = 0.0;
    var weight = 0.0;
    for (var offset = -radius; offset <= radius; offset++) {
      final index = center + offset;
      if (index < 0 || index >= input.length) continue;
      final w = kernel[offset + radius];
      sum += input[index] * w;
      weight += w;
    }
    output[i] = weight.abs() > 1e-12 ? sum / weight : 0;
  }
  return output;
}

double _resamplingWeight(double offset, double cutoff, int radius) {
  if (offset.abs() > radius) return 0;
  final x = math.pi * cutoff * offset;
  final sinc = x.abs() < 1e-12 ? 1.0 : math.sin(x) / x;
  return cutoff * sinc * (0.5 + 0.5 * math.cos(math.pi * offset / radius));
}

List<SpeakerEvidence> _extractSpeakerEvidence({
  required sherpa_onnx.WaveData wave,
  required List<DiarizationTurn> turns,
  required String embeddingModelPath,
  required int numThreads,
}) {
  if (turns.isEmpty) return [];
  final sherpa_onnx.SpeakerEmbeddingExtractor extractor;
  try {
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
      config: sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model: embeddingModelPath,
        numThreads: numThreads,
        debug: false,
      ),
    );
  } catch (_) {
    return [];
  }
  final observations = <SpeakerEvidence>[];
  try {
    final sr = wave.sampleRate;
    List<double>? extract(int start, int end) {
      final stream = extractor.createStream();
      try {
        stream.acceptWaveform(
          samples: Float32List.sublistView(wave.samples, start, end),
          sampleRate: sr,
        );
        stream.inputFinished();
        if (!extractor.isReady(stream)) return null;
        final vector = extractor.compute(stream).toList(growable: false);
        return vector.isEmpty || vector.any((x) => !x.isFinite) ? null : vector;
      } finally {
        stream.free();
      }
    }

    for (var index = 0; index < turns.length; index++) {
      final turn = turns[index];
      final start = (turn.start.inMicroseconds * sr ~/ 1000000).clamp(
        0,
        wave.samples.length,
      );
      final end = (turn.end.inMicroseconds * sr ~/ 1000000).clamp(
        start,
        wave.samples.length,
      );
      var spans = <(int, int)>[(start, end)];
      // Native output is time ordered. Exclude other speakers before profile
      // extraction: a mixed waveform must never train a single-speaker center.
      for (final other in turns) {
        if (other.start >= turn.end) break;
        if (other.speaker == turn.speaker || other.end <= turn.start) continue;
        final a = other.start.inMicroseconds * sr ~/ 1000000;
        final b = other.end.inMicroseconds * sr ~/ 1000000;
        final next = <(int, int)>[];
        for (final span in spans) {
          if (b <= span.$1 || a >= span.$2) {
            next.add(span);
            continue;
          }
          if (a > span.$1) next.add((span.$1, a));
          if (b < span.$2) next.add((b, span.$2));
        }
        spans = next;
      }
      var hasClean = false;
      for (final span in spans) {
        for (var pos = span.$1; pos < span.$2; pos += sr * 3) {
          final stop = math.min(span.$2, pos + sr * 3);
          if (stop - pos < sr * 0.8) continue;
          final embedding = extract(pos, stop);
          if (embedding == null) continue;
          observations.add(
            SpeakerEvidence(
              turn: index,
              embedding: embedding,
              seconds: (stop - pos) / sr,
              clean: true,
            ),
          );
          hasClean = true;
        }
      }
      if (!hasClean && end - start >= sr ~/ 5) {
        // Mixed/short fragments can match existing profiles, never create one.
        // Bound this input too: a long all-overlap turn need not be copied whole.
        final stop = math.min(end, start + sr * 3);
        final embedding = extract(start, stop);
        if (embedding != null) {
          observations.add(
            SpeakerEvidence(
              turn: index,
              embedding: embedding,
              seconds: (stop - start) / sr,
              clean: false,
            ),
          );
        }
      }
    }
    return observations;
  } catch (_) {
    // Refinement is optional; preserve native turns if extra extraction fails.
    return [];
  } finally {
    extractor.free();
  }
}

// Mirrors the ownership contract in sherpa_onnx 1.13.8
// lib/src/offline_speaker_diarization.dart:115–205, without its input copy.
List<sherpa_onnx.OfflineSpeakerDiarizationSegment> _processOwnedBuffer(
  sherpa_onnx.OfflineSpeakerDiarization sd,
  Pointer<Float> samples,
  int count,
  void Function(double)? onProgress,
) {
  final process = SherpaOnnxBindings
      .sherpaOnnxOfflineSpeakerDiarizationProcessWithCallbackNoArg;
  final destroy =
      SherpaOnnxBindings.sherpaOnnxOfflineSpeakerDiarizationDestroyResult;
  final length = SherpaOnnxBindings
      .sherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments;
  final sorted = SherpaOnnxBindings
      .sherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime;
  final freeSegments =
      SherpaOnnxBindings.sherpaOnnxOfflineSpeakerDiarizationDestroySegment;
  if (process == null ||
      destroy == null ||
      length == null ||
      sorted == null ||
      freeSegments == null) {
    throw StateError('发言人模型运行库不完整');
  }
  final callback =
      NativeCallable<
        SherpaOnnxOfflineSpeakerDiarizationProgressCallbackNoArgNative
      >.isolateLocal((int done, int total) {
        if (total > 0) {
          onProgress?.call((done / total).clamp(0.0, 1.0));
        }
        return 0;
      }, exceptionalReturn: 0);
  try {
    final result = process(sd.ptr, samples, count, callback.nativeFunction);
    if (result == nullptr) throw StateError('发言人区分未返回结果；原文已保留');
    try {
      final n = length(result);
      if (n == 0) return [];
      final segments = sorted(result);
      if (segments == nullptr) throw StateError('发言人区分结果无法读取');
      try {
        return [
          for (var i = 0; i < n; i++)
            sherpa_onnx.OfflineSpeakerDiarizationSegment(
              start: segments[i].start,
              end: segments[i].end,
              speaker: segments[i].speaker,
              confidence: segments[i].confidence,
            ),
        ];
      } finally {
        freeSegments(segments);
      }
    } finally {
      destroy(result);
    }
  } finally {
    callback.close();
  }
}
