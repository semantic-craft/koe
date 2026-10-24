import 'dart:math' as math;

/// Evidence extracted from a single turn. Only non-overlapping speech trains
/// speaker profiles; short speech is kept distinct unless it matches a profile.
class SpeakerEvidence {
  const SpeakerEvidence({
    required this.turn,
    required this.embedding,
    required this.seconds,
    required this.clean,
  });
  final int turn;
  final List<double> embedding;
  final double seconds;
  final bool clean;
}

/// Null means the requested count cannot be supported by clean profiles; the
/// caller must retain its native count-constrained path in that case.
List<int>? refineSpeakerLabels(
  List<int> speakers,
  List<SpeakerEvidence> evidence, {
  int? expectedSpeakers,
}) {
  final clean = <int, _Profile>{};
  final byTurn = <int, _Profile>{};
  final shortSoloTurns = <int>{};
  int? dimension;
  for (final item in evidence) {
    if (item.turn < 0 ||
        item.turn >= speakers.length ||
        !item.seconds.isFinite ||
        item.seconds <= 0) {
      continue;
    }
    final vector = _normalized(item.embedding);
    if (vector == null) continue;
    dimension ??= vector.length;
    if (vector.length != dimension) continue;
    byTurn
        .putIfAbsent(item.turn, () => _Profile(dimension!))
        .add(vector, item.seconds);
    if (item.clean && item.seconds < 0.8) shortSoloTurns.add(item.turn);
    if (item.clean && item.seconds >= 0.8) {
      clean
          .putIfAbsent(speakers[item.turn], () => _Profile(dimension!))
          .add(vector, item.seconds);
    }
  }
  final target = expectedSpeakers != null && expectedSpeakers > 0
      ? expectedSpeakers
      : null;
  if (target != null && clean.length < target) return null;
  if (clean.isEmpty) return List.of(speakers);
  final labels = {for (final speaker in clean.keys) speaker: speaker};
  // Like pyannote's stable-cluster/reassignment stage, use representative
  // profiles rather than making mixed fragments consume the requested count.
  // This is an independently implemented final-turn refinement, not VBx.
  // Sources: pyannote-audio 3.3.2 pipelines/clustering.py:345-457;
  // sherpa-onnx v1.13.8 fast-clustering.cc:62-71 uses complete-link cutree_k.
  while (clean.length > (target ?? 1)) {
    final keys = clean.keys.toList()..sort();
    var best = -double.infinity;
    var a = keys.first, b = keys.last;
    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        final similarity = _dot(
          clean[keys[i]]!.centroid,
          clean[keys[j]]!.centroid,
        );
        if (similarity > best) {
          best = similarity;
          a = keys[i];
          b = keys[j];
        }
      }
    }
    // Conservative same-voice merge; freeze before independent holdouts.
    if (best < 0.7) {
      // A requested count is not evidence that two distinct voices match.
      // Let native constrained clustering handle a genuinely different count.
      if (target != null) return null;
      break;
    }
    clean[a]!.merge(clean.remove(b)!);
    for (final entry in labels.entries.toList()) {
      if (entry.value == b) labels[entry.key] = a;
    }
  }
  final result = <int>[];
  for (var i = 0; i < speakers.length; i++) {
    final mapped = labels[speakers[i]];
    if (mapped != null) {
      result.add(mapped);
      continue;
    }
    final profile = byTurn[i];
    if (profile == null) {
      result.add(speakers[i]);
      continue;
    }
    final nearest = _nearest(profile.centroid, clean);
    // A brief exclusive answer can belong to a new speaker. Unlike fully
    // overlapping speech, it must not be forced into an existing profile.
    final preserve =
        target == null &&
        shortSoloTurns.contains(i) &&
        _dot(profile.centroid, clean[nearest]!.centroid) < 0.7;
    result.add(preserve ? speakers[i] : nearest);
  }
  if (target != null && result.toSet().length != target) return null;
  return result;
}

int _nearest(List<double> vector, Map<int, _Profile> profiles) {
  var chosen = profiles.keys.first, best = -double.infinity;
  for (final entry in profiles.entries) {
    final similarity = _dot(vector, entry.value.centroid);
    if (similarity > best) {
      best = similarity;
      chosen = entry.key;
    }
  }
  return chosen;
}

double _dot(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}

List<double>? _normalized(List<double> vector) {
  if (vector.isEmpty || vector.any((x) => !x.isFinite)) return null;
  final norm = math.sqrt(_dot(vector, vector));
  if (!norm.isFinite || norm < 1e-12) return null;
  return [for (final x in vector) x / norm];
}

class _Profile {
  _Profile(int dimension) : sum = List.filled(dimension, 0);
  final List<double> sum;
  List<double>? _centroid;
  List<double> get centroid =>
      _centroid ??= _normalized(sum) ?? List.filled(sum.length, 0);
  void add(List<double> vector, double weight) {
    for (var i = 0; i < sum.length; i++) {
      sum[i] += vector[i] * weight;
    }
    _centroid = null;
  }

  void merge(_Profile other) => add(other.sum, 1);
}
