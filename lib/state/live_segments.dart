/// A confirmed recognition unit. IDs are independent of prose and timestamps.
class LiveSegment {
  const LiveSegment({
    required this.id,
    required this.text,
    this.revision = 0,
    this.sourceLanguage = 'zh',
    this.translation,
    this.targetLanguage,
    this.provider = '',
  });
  final String id, text, sourceLanguage, provider;
  final int revision;
  final String? translation, targetLanguage;
  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'revision': revision,
    'sourceLanguage': sourceLanguage,
    'translation': translation,
    'targetLanguage': targetLanguage,
    'provider': provider,
  };
  factory LiveSegment.fromJson(Map<String, dynamic> j) => LiveSegment(
    id: j['id'] as String,
    text: j['text'] as String,
    revision: j['revision'] as int? ?? 0,
    sourceLanguage: j['sourceLanguage'] as String? ?? 'zh',
    translation: j['translation'] as String?,
    targetLanguage: j['targetLanguage'] as String?,
    provider: j['provider'] as String? ?? '',
  );
}

class LiveSegmentCollector {
  LiveSegmentCollector(this.sessionId);
  final String sessionId;
  final _segments = <String, LiveSegment>{};
  final _confirmed = <String, String>{};
  bool stale = false;
  List<LiveSegment> get segments => List.unmodifiable(_segments.values);
  void acceptFinal({
    required String session,
    required String id,
    required String text,
    String sourceLanguage = 'zh',
    String? translation,
    String? targetLanguage,
    String provider = '',
  }) {
    if (session != sessionId || text.trim().isEmpty) return;
    final old = _segments[id];
    if (old != null && old.text != text) stale = true;
    _segments[id] = LiveSegment(
      id: id,
      text: text,
      revision:
          (old?.revision ?? 0) + (old != null && old.text != text ? 1 : 0),
      sourceLanguage: sourceLanguage,
      translation: translation ?? (old?.text == text ? old?.translation : null),
      targetLanguage:
          targetLanguage ?? (old?.text == text ? old?.targetLanguage : null),
      provider: provider,
    );
  }

  void acceptCumulative(
    String connectionId,
    String text, {
    String sourceLanguage = 'zh',
    String? translation,
    String? targetLanguage,
    String provider = '',
  }) {
    final previous = _confirmed[connectionId] ?? '';
    if (!text.startsWith(previous)) {
      stale = true;
      return;
    }
    final added = text.substring(previous.length);
    _confirmed[connectionId] = text;
    if (added.trim().isEmpty) return;
    acceptFinal(
      session: sessionId,
      id: '$connectionId:${previous.length}',
      text: added,
      sourceLanguage: sourceLanguage,
      translation: translation,
      targetLanguage: targetLanguage,
      provider: provider,
    );
  }
}
