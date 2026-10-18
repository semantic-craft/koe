/// A user request to show and, when available, play a timed transcript place.
class TranscriptJump {
  const TranscriptJump({
    required this.segmentIndex,
    required this.start,
    this.snippet = '',
  });

  final int segmentIndex;
  final Duration start;
  final String snippet;
}
