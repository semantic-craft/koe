import 'dart:convert';

import '../ai/stt_types.dart';
import 'topic_store.dart';

/// Maximum characters (runes) of a recording's transcript sent to the model
/// for topic recommendation or drift checking (#52). Never reads full long
/// transcripts or historical recordings.
const int maxTopicExcerptRunes = 600;

String topicTranscriptExcerpt(
  String transcript, {
  int maxRunes = maxTopicExcerptRunes,
}) {
  final normalized = normalizeSttText(transcript);
  final runes = normalized.runes.toList();
  if (runes.length <= maxRunes) return normalized;
  return '${String.fromCharCodes(runes.take(maxRunes))}…';
}

/// Single-speaker vs multi-speaker is passed only as a prompt hint feature
/// (#49/#52), never as a hard gate for topic placement.
String topicSpeakerHint(String transcript) {
  final count = extractTranscriptSpeakers(normalizeSttText(transcript)).length;
  return count <= 1
      ? '说话人特征：单说话人（仅作提示特征，不作归类唯一依据）'
      : '说话人特征：多说话人（共 $count 人，仅作提示特征，不作归类唯一依据）';
}

enum TopicRecommendationKind { existingTopic, newTopic }

class TopicRecommendation {
  const TopicRecommendation.existing({
    required String this.topicId,
    this.sourceHash = '',
  }) : kind = TopicRecommendationKind.existingTopic,
       suggestedKind = TopicKind.general,
       suggestedTitle = '',
       suggestedAuthor = '';

  const TopicRecommendation.newTopic({
    required this.suggestedKind,
    required this.suggestedTitle,
    this.suggestedAuthor = '',
    this.sourceHash = '',
  }) : kind = TopicRecommendationKind.newTopic,
       topicId = null;

  final TopicRecommendationKind kind;
  final String? topicId;
  final TopicKind suggestedKind;
  final String suggestedTitle;
  final String suggestedAuthor;
  final String sourceHash;

  Map<String, Object?> toJson() => switch (kind) {
    TopicRecommendationKind.existingTopic => {
      'kind': 'existing',
      'topicId': topicId,
      if (sourceHash.isNotEmpty) 'sourceHash': sourceHash,
    },
    TopicRecommendationKind.newTopic => {
      'kind': 'new',
      'topicKind': suggestedKind.name,
      'title': suggestedTitle,
      if (suggestedKind == TopicKind.book && suggestedAuthor.isNotEmpty)
        'author': suggestedAuthor,
      if (sourceHash.isNotEmpty) 'sourceHash': sourceHash,
    },
  };

  static TopicRecommendation? decode(
    Object? json, {
    required Topic? Function(String? id) lookupTopic,
  }) {
    if (json is! Map) return null;
    final kind = json['kind'];
    final sourceHash = json['sourceHash'] is String
        ? json['sourceHash'] as String
        : '';
    if (kind == 'existing') {
      final id = json['topicId'];
      if (id is! String || id.isEmpty) return null;
      final topic = lookupTopic(id);
      if (topic == null || topic.closed) return null;
      return TopicRecommendation.existing(topicId: id, sourceHash: sourceHash);
    }
    if (kind == 'new') {
      final title = json['title'];
      if (title is! String || title.trim().isEmpty) return null;
      final trimmed = title.trim();
      final topicKind = TopicKind.values
          .where((k) => k.name == json['topicKind'])
          .firstOrNull;
      if (topicKind == null) return null;
      final author = json['author'];
      return TopicRecommendation.newTopic(
        suggestedKind: topicKind,
        suggestedTitle: trimmed.length > 100
            ? trimmed.substring(0, 100)
            : trimmed,
        suggestedAuthor: topicKind == TopicKind.book && author is String
            ? author.trim()
            : '',
        sourceHash: sourceHash,
      );
    }
    return null;
  }
}

class TopicDriftHint {
  const TopicDriftHint({
    required this.topicId,
    this.suggestedTopicId,
    this.sourceHash = '',
  });

  final String topicId;
  final String? suggestedTopicId;
  final String sourceHash;

  Map<String, Object?> toJson() => {
    'topicId': topicId,
    if (suggestedTopicId != null) 'suggestedTopicId': suggestedTopicId,
    if (sourceHash.isNotEmpty) 'sourceHash': sourceHash,
  };

  static TopicDriftHint? decode(
    Object? json, {
    required Topic? Function(String? id) lookupTopic,
  }) {
    if (json is! Map) return null;
    final id = json['topicId'];
    if (id is! String || id.isEmpty) return null;
    final topic = lookupTopic(id);
    if (topic == null || topic.closed) return null;
    final rawSuggested = json['suggestedTopicId'];
    String? suggestedId;
    if (rawSuggested is String && rawSuggested.isNotEmpty) {
      final suggested = lookupTopic(rawSuggested);
      if (suggested != null && !suggested.closed && suggested.id != id) {
        suggestedId = suggested.id;
      }
    }
    final sourceHash = json['sourceHash'] is String
        ? json['sourceHash'] as String
        : '';
    return TopicDriftHint(
      topicId: id,
      suggestedTopicId: suggestedId,
      sourceHash: sourceHash,
    );
  }
}

String _formatOpenTopicLine(Topic topic) {
  final kind = topic.kind == TopicKind.book ? 'book（书籍）' : 'general（普通）';
  final author = topic.kind == TopicKind.book && topic.author.isNotEmpty
      ? ' 作者="${topic.author}"'
      : '';
  return '- id="${topic.id}" 类型=$kind 名称="${topic.title}"$author';
}

String buildTopicRecommendationInstruction({
  required List<Topic> openTopics,
  required String transcript,
}) {
  final unarchived = [
    for (final t in openTopics)
      if (!t.closed) t,
  ];
  final topicSection = unarchived.isEmpty
      ? '当前进行中的主题：（暂无）'
      : [
          '当前进行中的主题（仅限以下未读完/未归档主题）：',
          for (final t in unarchived) _formatOpenTopicLine(t),
        ].join('\n');
  return [
    '根据这条待归类录音的转写摘要片段，给出一条归类推荐。',
    topicSpeakerHint(transcript),
    topicSection,
    '仅输出 JSON 对象，不要 Markdown 代码围栏：',
    '- 若适合归入上述某个进行中主题：{"action":"existing","topicId":"<进行中主题id>"}',
    '- 若建议新建主题：{"action":"new","kind":"book"或"general","title":"<建议名称>","author":"<书籍作者，可选>"}',
  ].join('\n');
}

String buildTopicDriftInstruction({
  required Topic currentTopic,
  required List<Topic> openTopics,
  required String transcript,
}) {
  final others = [
    for (final t in openTopics)
      if (!t.closed && t.id != currentTopic.id) t,
  ];
  final otherSection = others.isEmpty
      ? '其他进行中的主题：（无）'
      : [
          '其他进行中的主题：',
          for (final t in others) _formatOpenTopicLine(t),
        ].join('\n');
  return [
    '判断这条录音的转写摘要片段是否明显偏离当前主题《${currentTopic.title}》。',
    '当前主题：${_formatOpenTopicLine(currentTopic)}',
    topicSpeakerHint(transcript),
    otherSection,
    '仅在内容明显不属于《${currentTopic.title}》时判为偏离；仅输出 JSON 对象，不要 Markdown 代码围栏：',
    '- 未明显偏离：{"drift":false}',
    '- 明显偏离：{"drift":true,"suggestedTopicId":"<可选：更匹配的进行中主题id>"}',
  ].join('\n');
}

Map<String, Object?>? _decodeJsonObject(String raw) {
  var text = raw.trim();
  if (text.startsWith('```')) {
    text = text
        .replaceFirst(RegExp(r'^```[a-zA-Z0-9_-]*\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map) return null;
  return Map<String, Object?>.from(decoded);
}

TopicRecommendation? parseTopicRecommendation(
  String raw,
  List<Topic> openTopics, {
  String sourceHash = '',
}) {
  final map = _decodeJsonObject(raw);
  if (map == null) return null;
  final action = map['action'];
  if (action == 'existing' || (action == null && map['topicId'] is String)) {
    final topicId = (map['topicId'] as String?)?.trim();
    if (topicId == null || topicId.isEmpty) return null;
    final topic = openTopics
        .where((t) => t.id == topicId && !t.closed)
        .firstOrNull;
    if (topic == null) return null;
    return TopicRecommendation.existing(
      topicId: topic.id,
      sourceHash: sourceHash,
    );
  }
  if (action == 'new' ||
      (action == null &&
          (map['title'] is String || map['suggestedTitle'] is String))) {
    final rawTitle = (map['title'] ?? map['suggestedTitle']) as String?;
    if (rawTitle == null || rawTitle.trim().isEmpty) return null;
    final title = rawTitle.trim();
    final kindRaw = map['kind'] ?? map['topicKind'] ?? map['suggestedKind'];
    final kind = kindRaw == 'book' ? TopicKind.book : TopicKind.general;
    final rawAuthor = map['author'];
    final author = kind == TopicKind.book && rawAuthor is String
        ? rawAuthor.trim()
        : '';
    return TopicRecommendation.newTopic(
      suggestedKind: kind,
      suggestedTitle: title.length > 100 ? title.substring(0, 100) : title,
      suggestedAuthor: author.length > 100 ? author.substring(0, 100) : author,
      sourceHash: sourceHash,
    );
  }
  return null;
}

TopicDriftHint? parseTopicDriftHint(
  String raw, {
  required Topic currentTopic,
  required List<Topic> openTopics,
  String sourceHash = '',
}) {
  if (currentTopic.closed) return null;
  final map = _decodeJsonObject(raw);
  if (map == null) return null;
  final drifted = map['drift'] == true || map['drifted'] == true;
  if (!drifted) return null;
  final rawSuggested = (map['suggestedTopicId'] ?? map['topicId']) as String?;
  String? suggestedId;
  if (rawSuggested != null && rawSuggested.trim().isNotEmpty) {
    final target = openTopics
        .where((t) => t.id == rawSuggested.trim() && !t.closed)
        .firstOrNull;
    if (target != null && target.id != currentTopic.id) {
      suggestedId = target.id;
    }
  }
  return TopicDriftHint(
    topicId: currentTopic.id,
    suggestedTopicId: suggestedId,
    sourceHash: sourceHash,
  );
}
