import 'dart:convert';

import 'recording_analysis.dart';
import 'topic_store.dart';

class TopicExcerpt {
  const TopicExcerpt({required this.text, required this.sources, this.page});

  final String text;
  final String? page;
  final List<String> sources;

  Map<String, dynamic> toJson() => {
    'text': text,
    if (page != null && page!.trim().isNotEmpty) 'page': page!.trim(),
    'sources': sources,
  };
}

class TopicComment {
  const TopicComment({required this.text, required this.sources, this.excerpt});

  final String text;
  final String? excerpt;
  final List<String> sources;

  Map<String, dynamic> toJson() => {
    'text': text,
    if (excerpt != null && excerpt!.trim().isNotEmpty)
      'excerpt': excerpt!.trim(),
    'sources': sources,
  };
}

class TopicIdea {
  const TopicIdea({required this.text, required this.sources, this.reason});

  final String text;
  final String? reason;
  final List<String> sources;

  Map<String, dynamic> toJson() => {
    'text': text,
    if (reason != null && reason!.trim().isNotEmpty) 'reason': reason!.trim(),
    'sources': sources,
  };
}

class TopicNoteItem {
  const TopicNoteItem(this.text, this.sources);

  final String text;
  final List<String> sources;

  Map<String, dynamic> toJson() => {'text': text, 'sources': sources};
}

class TopicNote {
  const TopicNote({
    required this.kind,
    required this.topicId,
    required this.overview,
    this.audioSignature,
    this.excerpts = const [],
    this.comments = const [],
    this.ideas = const [],
    this.changes = const [],
    this.questions = const [],
    this.associations = const [],
    this.toCheck = const [],
    this.todos = const [],
    this.conclusion,
  });

  static const slot = 'topic-note';
  static const defaultModel = 'qwen3.8-flash';
  static String slotKey(String recordingKey) => '$recordingKey/$slot';

  TopicNote copyWith({String? overview}) => TopicNote(
    kind: kind,
    topicId: topicId,
    overview: overview ?? this.overview,
    audioSignature: audioSignature,
    excerpts: excerpts,
    comments: comments,
    ideas: ideas,
    changes: changes,
    questions: questions,
    associations: associations,
    toCheck: toCheck,
    todos: todos,
    conclusion: conclusion,
  );

  final TopicKind kind;
  final String topicId;
  final String overview;
  final String? audioSignature;
  final List<TopicExcerpt> excerpts;
  final List<TopicComment> comments;
  final List<TopicIdea> ideas;
  final List<TopicNoteItem> changes;
  final List<TopicNoteItem> questions;
  final List<TopicNoteItem> associations;
  final List<TopicNoteItem> toCheck;
  final List<TopicNoteItem> todos;
  final TopicNoteItem? conclusion;

  static TopicNote? tryParse(
    String text,
    int sourceCount, {
    TopicKind? fallbackKind,
    String? fallbackTopicId,
    bool? hasPriorNotes,
  }) {
    try {
      return TopicNote.parse(
        text,
        sourceCount,
        fallbackKind: fallbackKind,
        fallbackTopicId: fallbackTopicId,
        hasPriorNotes: hasPriorNotes,
      );
    } catch (_) {
      return null;
    }
  }

  factory TopicNote.parse(
    String text,
    int sourceCount, {
    TopicKind? fallbackKind,
    String? fallbackTopicId,
    bool? hasPriorNotes,
    String? forcedTopicId,
    String? forcedAudioSignature,
    bool forceAudioSignature = false,
  }) {
    final cleaned = _stripCodeFence(text);
    final dynamic value = jsonDecode(cleaned);
    if (value is! Map) {
      throw const FormatException('主题笔记必须是 JSON 对象');
    }

    String requiredText(dynamic v) {
      if (v is! String || v.trim().isEmpty) {
        throw const FormatException('主题笔记字段为空');
      }
      return v.trim();
    }

    String? optionalText(dynamic v) {
      if (v is! String) return null;
      final trimmed = v.trim();
      if (trimmed.isEmpty || trimmed == '未提及' || trimmed == '无') {
        return null;
      }
      return trimmed;
    }

    List<String> parseSources(dynamic rawSources) {
      if (rawSources is! List || rawSources.isEmpty) {
        throw const FormatException('缺少原文依据');
      }
      return rawSources
          .map((dynamic id) {
            if (id is! String ||
                !RegExp(r'^S[1-9]\d*$').hasMatch(id) ||
                int.parse(id.substring(1)) > sourceCount) {
              throw const FormatException('无效原文编号');
            }
            return id;
          })
          .toSet()
          .toList();
    }

    List<TopicNoteItem> parseItems(String name, {bool requiredKey = false}) {
      final list = value[name];
      if (list == null && !requiredKey) return const [];
      if (list is! List) throw FormatException('缺少 $name');
      return list.map((dynamic item) {
        if (item is! Map) throw const FormatException('条目格式错误');
        return TopicNoteItem(
          requiredText(item['text']),
          parseSources(item['sources']),
        );
      }).toList();
    }

    final rawKind = value['kind'];
    final TopicKind resolvedKind;
    if (rawKind == 'book') {
      resolvedKind = TopicKind.book;
    } else if (rawKind == 'general') {
      resolvedKind = TopicKind.general;
    } else if (fallbackKind != null) {
      resolvedKind = fallbackKind;
    } else if (value.containsKey('excerpts') ||
        value.containsKey('comments') ||
        value.containsKey('toCheck')) {
      resolvedKind = TopicKind.book;
    } else {
      resolvedKind = TopicKind.general;
    }

    final rawTopicId = value['topicId'];
    final jsonTopicId = rawTopicId is String ? rawTopicId.trim() : '';
    // fallback 只补 JSON 缺省；forced 只在校验模型输出时覆盖。
    final String resolvedTopicId;
    if (forcedTopicId != null) {
      resolvedTopicId = forcedTopicId.trim();
    } else if (jsonTopicId.isNotEmpty) {
      resolvedTopicId = jsonTopicId;
    } else {
      resolvedTopicId = fallbackTopicId?.trim() ?? '';
    }
    final String? resolvedAudioSignature;
    if (forceAudioSignature) {
      final forced = forcedAudioSignature?.trim() ?? '';
      resolvedAudioSignature = forced.isEmpty ? null : forced;
    } else {
      resolvedAudioSignature = optionalText(value['audioSignature']);
    }

    final overview = requiredText(value['overview']);

    if (resolvedKind == TopicKind.book) {
      final rawExcerpts = value['excerpts'];
      if (rawExcerpts != null && rawExcerpts is! List) {
        throw const FormatException('缺少 excerpts');
      }
      final excerpts = (rawExcerpts as List? ?? const []).map((dynamic item) {
        if (item is! Map) throw const FormatException('摘录格式错误');
        return TopicExcerpt(
          text: requiredText(item['text']),
          page: optionalText(item['page']),
          sources: parseSources(item['sources']),
        );
      }).toList();

      final rawComments = value['comments'];
      if (rawComments != null && rawComments is! List) {
        throw const FormatException('缺少 comments');
      }
      final comments = (rawComments as List? ?? const []).map((dynamic item) {
        if (item is! Map) throw const FormatException('评论格式错误');
        return TopicComment(
          text: requiredText(item['text']),
          excerpt: optionalText(item['excerpt']),
          sources: parseSources(item['sources']),
        );
      }).toList();

      return TopicNote(
        kind: TopicKind.book,
        topicId: resolvedTopicId,
        overview: overview,
        audioSignature: resolvedAudioSignature,
        excerpts: excerpts,
        comments: comments,
        questions: parseItems('questions'),
        associations: parseItems('associations'),
        toCheck: parseItems('toCheck'),
      );
    }

    final rawIdeas = value['ideas'];
    if (rawIdeas != null && rawIdeas is! List) {
      throw const FormatException('缺少 ideas');
    }
    final ideas = (rawIdeas as List? ?? const []).map((dynamic item) {
      if (item is! Map) throw const FormatException('想法格式错误');
      return TopicIdea(
        text: requiredText(item['text']),
        reason: optionalText(item['reason']),
        sources: parseSources(item['sources']),
      );
    }).toList();

    final parsedChanges = parseItems('changes');
    final changes = hasPriorNotes == false
        ? const <TopicNoteItem>[]
        : parsedChanges;

    TopicNoteItem? conclusion;
    final rawConclusion = value['conclusion'];
    if (rawConclusion is Map) {
      final textField = optionalText(rawConclusion['text']);
      if (textField != null) {
        conclusion = TopicNoteItem(
          textField,
          parseSources(rawConclusion['sources']),
        );
      }
    } else if (rawConclusion != null &&
        !(rawConclusion is String && optionalText(rawConclusion) == null)) {
      throw const FormatException('结论格式错误');
    }

    return TopicNote(
      kind: TopicKind.general,
      topicId: resolvedTopicId,
      overview: overview,
      audioSignature: resolvedAudioSignature,
      ideas: ideas,
      changes: changes,
      questions: parseItems('questions'),
      associations: parseItems('associations'),
      todos: parseItems('todos'),
      conclusion: conclusion,
    );
  }

  Map<String, dynamic> toJson() {
    if (kind == TopicKind.book) {
      return {
        'kind': kind.name,
        if (topicId.isNotEmpty) 'topicId': topicId,
        if (audioSignature != null && audioSignature!.isNotEmpty)
          'audioSignature': audioSignature,
        'overview': overview,
        'excerpts': excerpts.map((e) => e.toJson()).toList(),
        'comments': comments.map((e) => e.toJson()).toList(),
        'questions': questions.map((e) => e.toJson()).toList(),
        'associations': associations.map((e) => e.toJson()).toList(),
        'toCheck': toCheck.map((e) => e.toJson()).toList(),
      };
    }
    return {
      'kind': kind.name,
      if (topicId.isNotEmpty) 'topicId': topicId,
      if (audioSignature != null && audioSignature!.isNotEmpty)
        'audioSignature': audioSignature,
      'overview': overview,
      'ideas': ideas.map((e) => e.toJson()).toList(),
      'changes': changes.map((e) => e.toJson()).toList(),
      'questions': questions.map((e) => e.toJson()).toList(),
      'associations': associations.map((e) => e.toJson()).toList(),
      'todos': todos.map((e) => e.toJson()).toList(),
      if (conclusion != null) 'conclusion': conclusion!.toJson(),
    };
  }

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  String compactPriorContext() {
    final parts = <String>[overview];
    if (kind == TopicKind.general) {
      for (final idea in ideas.take(3)) {
        parts.add(
          idea.reason == null ? idea.text : '${idea.text}（${idea.reason}）',
        );
      }
      if (conclusion != null) {
        parts.add('结论：${conclusion!.text}');
      }
    } else {
      for (final excerpt in excerpts.take(2)) {
        parts.add(excerpt.text);
      }
    }
    final summary = parts.join('；');
    if (summary.runes.length <= 160) return summary;
    return '${String.fromCharCodes(summary.runes.take(160))}…';
  }

  String export(AnalysisResult result, {Topic? topic}) {
    final title = topic?.title.trim().isNotEmpty == true
        ? topic!.title
        : '主题笔记';
    final lines = <String>['# $title', overview];
    String fmtSources(List<String> s) => s.map((id) => '[$id]').join(' ');

    if (kind == TopicKind.book) {
      lines.add('## 原文摘录');
      if (excerpts.isEmpty) {
        lines.add('未提及');
      } else {
        for (final item in excerpts) {
          final pagePrefix = item.page == null ? '' : '（${item.page}）';
          lines.add('- $pagePrefix${item.text} ${fmtSources(item.sources)}');
        }
      }
      lines.add('## 我的评论');
      if (comments.isEmpty) {
        lines.add('未提及');
      } else {
        for (final item in comments) {
          final paired = item.excerpt == null ? '' : '\n  对应摘录：${item.excerpt}';
          lines.add('- ${item.text}$paired ${fmtSources(item.sources)}');
        }
      }
      for (final section in [
        ('疑问', questions),
        ('联想', associations),
        ('待查', toCheck),
      ]) {
        lines.add('## ${section.$1}');
        if (section.$2.isEmpty) {
          lines.add('未提及');
        } else {
          for (final item in section.$2) {
            lines.add('- ${item.text} ${fmtSources(item.sources)}');
          }
        }
      }
    } else {
      lines.add('## 主要想法');
      if (ideas.isEmpty) {
        lines.add('未提及');
      } else {
        for (final item in ideas) {
          final reason = item.reason == null ? '' : '\n  理由：${item.reason}';
          lines.add('- ${item.text}$reason ${fmtSources(item.sources)}');
        }
      }
      if (changes.isNotEmpty) {
        lines.add('## 与此前笔记的变化');
        for (final item in changes) {
          lines.add('- ${item.text} ${fmtSources(item.sources)}');
        }
      }
      for (final section in [
        ('疑问', questions),
        ('联想', associations),
        ('待办/待查', todos),
      ]) {
        lines.add('## ${section.$1}');
        if (section.$2.isEmpty) {
          lines.add('未提及');
        } else {
          for (final item in section.$2) {
            lines.add('- ${item.text} ${fmtSources(item.sources)}');
          }
        }
      }
      if (conclusion != null) {
        lines.add('## 倾向的结论');
        lines.add('- ${conclusion!.text} ${fmtSources(conclusion!.sources)}');
      }
    }

    lines.add('模型：${result.model} · 模板：topic-${kind.name}-v1');
    lines.add('生成时间：${result.createdAt.toIso8601String()}');
    if (result.editedAt != null) {
      lines.add('编辑时间：${result.editedAt!.toIso8601String()}');
    }
    lines.add('## 原文依据');
    for (final source in result.sources.indexed) {
      lines.add('[S${source.$1 + 1}] ${source.$2}');
    }
    return lines.join('\n\n');
  }
}

String _stripCodeFence(String raw) {
  final trimmed = raw.trim();
  if (trimmed.startsWith('```')) {
    final firstNewline = trimmed.indexOf('\n');
    final lastFence = trimmed.lastIndexOf('```');
    if (firstNewline != -1 && lastFence > firstNewline) {
      return trimmed.substring(firstNewline + 1, lastFence).trim();
    }
  }
  return trimmed;
}

String topicNoteInstruction(
  Topic topic, {
  List<TopicNote> priorNotes = const [],
}) {
  final authorPart = topic.author.trim().isEmpty
      ? ''
      : '（作者：${topic.author.trim()}）';
  if (topic.kind == TopicKind.book) {
    return '''生成一本书的当次读书笔记（主题ID:${topic.id}，书名：${topic.title}$authorPart），仅输出 JSON，不要 Markdown 代码围栏。字段严格如下：
{"overview":"本次概要","excerpts":[{"text":"录音里复述的书中内容","page":"第24页","sources":["S1"]}],"comments":[{"text":"我的评论","excerpt":"配对的摘录原文","sources":["S1"]}],"questions":[{"text":"疑问","sources":["S1"]}],"associations":[{"text":"联想","sources":["S1"]}],"toCheck":[{"text":"待查","sources":["S1"]}]}
规则：只整理用户亲口说出的内容，不替用户补观点，不编造页码或引用。口述了页码或章节才填 page，未口述省略 page。评论若针对某条摘录则在 excerpt 填对应摘录文字，独立评论省略 excerpt。没有某类条目用空数组。每项 sources 必须引用实际原文编号 [S1..Sn]。合并分段笔记时保持相同 JSON 结构。''';
  }

  final priorSummary = <String>[];
  var usedRunes = 0;
  for (final note in priorNotes) {
    final item = note.compactPriorContext();
    if (item.isEmpty) continue;
    if (usedRunes + item.runes.length > 600) break;
    priorSummary.add('- $item');
    usedRunes += item.runes.length;
  }
  final priorBlock = priorSummary.isEmpty
      ? '这是该主题下的第一条笔记，changes 必须为空数组 []。'
      : '同主题此前笔记摘要（仅供对比本次变化，勿当作本次原文事实）：\n${priorSummary.join('\n')}';

  return '''生成一般主题的当次思考笔记（主题ID:${topic.id}，主题：${topic.title}），仅输出 JSON，不要 Markdown 代码围栏。字段严格如下：
{"overview":"本次概要","ideas":[{"text":"主要观点","reason":"理由","sources":["S1"]}],"changes":[{"text":"与该主题此前笔记相比的变化","sources":["S1"]}],"questions":[{"text":"疑问","sources":["S1"]}],"associations":[{"text":"联想","sources":["S1"]}],"todos":[{"text":"待办或待查","sources":["S1"]}],"conclusion":{"text":"明确表达的倾向结论","sources":["S1"]}}
$priorBlock
规则：只整理用户亲口说出的内容，不替用户补观点或下结论。仅在录音明确表达倾向结论时填 conclusion，否则省略 conclusion。没有某类条目用空数组。每项 sources 必须引用实际原文编号 [S1..Sn]。合并分段笔记时保持相同 JSON 结构。''';
}

String Function(String text, List<String> sources) validateTopicNote(
  Topic topic, {
  bool hasPriorNotes = false,
  String? audioSignature,
}) =>
    (text, sources) => TopicNote.parse(
      text,
      sources.length,
      fallbackKind: topic.kind,
      forcedTopicId: topic.id,
      forcedAudioSignature: audioSignature,
      forceAudioSignature: true,
      hasPriorNotes: hasPriorNotes,
    ).encode();

List<String> splitTranscriptParagraphs(String text) {
  final out = <String>[];
  for (final raw in text.split(RegExp(r'\n+'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final runes = line.runes.toList();
    for (var i = 0; i < runes.length; i += 1200) {
      final end = i + 1200 < runes.length ? i + 1200 : runes.length;
      out.add(String.fromCharCodes(runes.sublist(i, end)));
    }
  }
  return out;
}

int? locateTranscriptParagraph(
  String transcript,
  List<String> sources, {
  String? itemText,
  List<String>? sourceBlocks,
}) {
  final paragraphs = splitTranscriptParagraphs(transcript);
  if (paragraphs.isEmpty) return null;

  final blocks = sourceBlocks ?? analysisSourceBlocks(transcript);
  final candidateIndices = <int>[];
  for (final id in sources) {
    final match = RegExp(r'^S([1-9]\d*)$').firstMatch(id);
    if (match == null) continue;
    final blockIndex = int.parse(match.group(1)!) - 1;
    if (blockIndex < 0 || blockIndex >= blocks.length) continue;
    final block = blocks[blockIndex];
    for (var i = 0; i < paragraphs.length; i++) {
      if (block.contains(paragraphs[i]) && !candidateIndices.contains(i)) {
        candidateIndices.add(i);
      }
    }
  }
  final searchPool = candidateIndices.isNotEmpty
      ? candidateIndices
      : List<int>.generate(paragraphs.length, (i) => i);
  if (searchPool.isEmpty) return null;

  final needle = _normalizeForMatch(itemText ?? '');
  if (needle.isEmpty) return null;
  var bestIndex = searchPool.first;
  var bestScore = -1;
  for (final idx in searchPool) {
    final hay = _normalizeForMatch(paragraphs[idx]);
    final score = _matchScore(hay, needle);
    if (score > bestScore) {
      bestScore = score;
      bestIndex = idx;
    }
  }
  if (bestScore > 0) return bestIndex;
  return null;
}

String _normalizeForMatch(String input) =>
    input.replaceAll(RegExp(r'[\s\p{P}\p{S}]+', unicode: true), '');

int _matchScore(String hay, String needle) {
  if (hay.isEmpty || needle.isEmpty) return 0;
  if (hay.contains(needle)) return needle.runes.length * 4;
  if (needle.contains(hay)) return hay.runes.length * 3;
  final needleRunes = needle.runes.toList();
  if (needleRunes.length < 2) {
    return hay.contains(needle) ? 1 : 0;
  }
  var score = 0;
  for (var i = 0; i < needleRunes.length - 1; i++) {
    final bigram = String.fromCharCodes(needleRunes.sublist(i, i + 2));
    if (hay.contains(bigram)) score++;
  }
  return score;
}
