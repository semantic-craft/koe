import 'dart:convert';
import 'dart:io';
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
/// - Single-cluster multi-speaker collision: if [clusters] <= 1, at least
///   [minMultiSpeakerChunksForCollision] = 10 windows had >= 2 active speakers,
///   and [collisionRate] >= [minCollisionRate] (0.5), [mergeRisk] is 1.0.
class DiarizationQuality {
  const DiarizationQuality({
    required this.chunks,
    required this.clusters,
    required this.cohesion,
    this.multiSpeakerChunks = 0,
    this.collisionRate = 0.0,
  });

  static const double hintThreshold = 0.4;
  static const int minChunksForCheck = 30;
  static const int minMultiSpeakerChunksForCollision = 10;
  static const double minCollisionRate = 0.5;

  final int chunks;
  final int clusters;
  final double cohesion;
  final int multiSpeakerChunks;
  final double collisionRate;

  double get mergeRisk {
    if (chunks < minChunksForCheck) return 0.0;
    if (clusters <= 1 &&
        multiSpeakerChunks >= minMultiSpeakerChunksForCollision &&
        collisionRate >= minCollisionRate) {
      return 1.0;
    }
    return math.max(0.0, 1.0 - cohesion);
  }

  bool get shouldSuggestRediarize => mergeRisk > hintThreshold;

  /// Computes [DiarizationQuality] from per-window speaker embeddings and their
  /// assigned cluster labels.
  factory DiarizationQuality.fromTurnEmbeddings(
    List<({
      int chunkIndex,
      int localSpeaker,
      int clusterSpeaker,
      List<double> embedding,
    })>
    items,
  ) {
    if (items.isEmpty) {
      return const DiarizationQuality(chunks: 0, clusters: 0, cohesion: 1.0);
    }

    final byChunk = <int, List<({int localSpeaker, int clusterSpeaker})>>{};
    for (final item in items) {
      byChunk.putIfAbsent(item.chunkIndex, () => []).add((
        localSpeaker: item.localSpeaker,
        clusterSpeaker: item.clusterSpeaker,
      ));
    }
    var multi = 0;
    var collided = 0;
    for (final group in byChunk.values) {
      final locals = group.map((g) => g.localSpeaker).toSet();
      if (locals.length < 2) continue;
      multi++;
      final assignedClusters = group.map((g) => g.clusterSpeaker).toSet();
      if (assignedClusters.length < locals.length) collided++;
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
      multiSpeakerChunks: multi,
      collisionRate: multi > 0 ? collided / multi : 0.0,
    );
  }

  Map<String, Object?> toJson() => {
    'chunks': chunks,
    'clusters': clusters,
    'cohesion': cohesion,
    'multiSpeakerChunks': multiSpeakerChunks,
    'collisionRate': collisionRate,
  };

  static DiarizationQuality? decode(Object? value) {
    if (value is! Map) return null;
    final chunks = value['chunks'];
    final clusters = value['clusters'];
    final cohesion = value['cohesion'];
    if (chunks is! int || clusters is! int || cohesion is! num) return null;
    final multi = value['multiSpeakerChunks'];
    final collision = value['collisionRate'];
    return DiarizationQuality(
      chunks: chunks,
      clusters: clusters,
      cohesion: cohesion.toDouble(),
      multiSpeakerChunks: multi is int ? multi : 0,
      collisionRate: collision is num ? collision.toDouble() : 0.0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiarizationQuality &&
          other.chunks == chunks &&
          other.clusters == clusters &&
          (other.cohesion - cohesion).abs() < 1e-9 &&
          other.multiSpeakerChunks == multiSpeakerChunks &&
          (other.collisionRate - collisionRate).abs() < 1e-9;

  @override
  int get hashCode => Object.hash(
    chunks,
    clusters,
    cohesion.toStringAsFixed(6),
    multiSpeakerChunks,
    collisionRate.toStringAsFixed(6),
  );
}

class DiarizationResult {
  const DiarizationResult({
    required this.turns,
    this.quality,
  });

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

Future<DiarizationResult> runSherpaDiarization({
  required String audioPath,
  required String segmentationModelPath,
  required String embeddingModelPath,
  int? expectedSpeakers,
  double defaultClusteringThreshold = 0.75,
  int numThreads = 4,
  void Function(double progress)? onProgress,
}) async {
  await ensureSherpaBindingsInitialized();

  final wave = sherpa_onnx.readWave(audioPath);
  if (wave.samples.isEmpty || wave.sampleRate <= 0) {
    throw StateError('无法读取音频样本进行本机发言人区分');
  }

  final numClusters =
      expectedSpeakers != null && expectedSpeakers > 0 ? expectedSpeakers : -1;
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
      threshold: defaultClusteringThreshold,
      computeConfidence: true,
    ),
    minDurationOn: 0.2,
    minDurationOff: 0.5,
  );

  final sd = sherpa_onnx.OfflineSpeakerDiarization(config);
  List<sherpa_onnx.OfflineSpeakerDiarizationSegment> rawSegments;
  try {
    if (onProgress != null) {
      rawSegments = sd.processWithCallback(
        samples: wave.samples,
        callback: (processed, total) {
          if (total > 0) {
            onProgress((processed / total).clamp(0.0, 1.0));
          }
          return 0;
        },
      );
    } else {
      rawSegments = sd.process(samples: wave.samples);
    }
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

  final quality = _computeQualityFromWaveAndTurns(
    wave: wave,
    turns: turns,
    embeddingModelPath: embeddingModelPath,
    numThreads: numThreads,
  );

  return DiarizationResult(turns: turns, quality: quality);
}

DiarizationQuality? _computeQualityFromWaveAndTurns({
  required sherpa_onnx.WaveData wave,
  required List<DiarizationTurn> turns,
  required String embeddingModelPath,
  required int numThreads,
}) {
  if (turns.isEmpty) return null;
  final extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
    config: sherpa_onnx.SpeakerEmbeddingExtractorConfig(
      model: embeddingModelPath,
      numThreads: numThreads,
      debug: false,
    ),
  );
  try {
    final sr = wave.sampleRate;
    final totalSamples = wave.samples.length;
    const windowSec = 2.0;
    final windowSamples = (windowSec * sr).round();
    final observations = <({
      int chunkIndex,
      int localSpeaker,
      int clusterSpeaker,
      List<double> embedding,
    })>[];
    var chunkIdx = 0;

    for (final turn in turns) {
      final startSample = (turn.start.inMicroseconds * sr ~/ 1000000).clamp(
        0,
        totalSamples,
      );
      final endSample = (turn.end.inMicroseconds * sr ~/ 1000000).clamp(
        startSample,
        totalSamples,
      );
      if (endSample - startSample < sr ~/ 5) continue;

      for (
        var pos = startSample;
        pos < endSample;
        pos += windowSamples, chunkIdx++
      ) {
        final sliceEnd = math.min(endSample, pos + windowSamples);
        if (sliceEnd - pos < sr ~/ 5) continue;
        final stream = extractor.createStream();
        try {
          final slice = Float32List.sublistView(wave.samples, pos, sliceEnd);
          stream.acceptWaveform(samples: slice, sampleRate: sr);
          stream.inputFinished();
          if (extractor.isReady(stream)) {
            final emb = extractor.compute(stream);
            if (emb.isNotEmpty) {
              observations.add((
                chunkIndex: chunkIdx,
                localSpeaker: turn.speaker,
                clusterSpeaker: turn.speaker,
                embedding: emb.toList(growable: false),
              ));
            }
          }
        } finally {
          stream.free();
        }
      }
    }

    if (observations.isEmpty) return null;
    return DiarizationQuality.fromTurnEmbeddings(observations);
  } catch (_) {
    return null;
  } finally {
    extractor.free();
  }
}
