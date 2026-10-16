import 'dart:convert';
import 'recording_analysis.dart';

// Template adapted from Meetily and Ownscribe; see THIRD_PARTY_NOTICES.md.
const minutesInstruction = defaultMinutesPrompt;

class MinuteItem {
  const MinuteItem(this.text, this.sources, {this.owner, this.due});
  final String text;
  final List<String> sources;
  final String? owner, due;
  Map<String, dynamic> toJson() => {
    'text': text,
    'sources': sources,
    if (owner != null) 'owner': owner,
    if (due != null) 'due': due,
  };
}

class MeetingMinutes {
  const MeetingMinutes({
    required this.title,
    required this.overview,
    required this.topics,
    required this.decisions,
    required this.actions,
    required this.questions,
  });
  final String title, overview;
  final List<MinuteItem> topics, decisions, actions, questions;
  List<(String, List<MinuteItem>)> get sections => [
    ('议题', topics),
    ('决策', decisions),
    ('待办', actions),
    ('未决问题', questions),
  ];

  factory MeetingMinutes.parse(String text, int sourceCount) {
    final dynamic value = jsonDecode(text);
    if (value is! Map) throw const FormatException('纪要必须是 JSON 对象');
    String requiredText(dynamic v) {
      if (v is! String || v.trim().isEmpty) {
        throw const FormatException('纪要字段为空');
      }
      return v.trim();
    }

    List<MinuteItem> items(String name) {
      final list = value[name];
      if (list is! List) throw FormatException('缺少 $name');
      return list.map((dynamic item) {
        if (item is! Map ||
            item['sources'] is! List ||
            (item['sources'] as List).isEmpty) {
          throw const FormatException('缺少原文依据');
        }
        final ids = (item['sources'] as List)
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
        return MinuteItem(
          requiredText(item['text']),
          ids,
          owner: name == 'actions' ? requiredText(item['owner']) : null,
          due: name == 'actions' ? requiredText(item['due']) : null,
        );
      }).toList();
    }

    return MeetingMinutes(
      title: requiredText(value['title']),
      overview: requiredText(value['overview']),
      topics: items('topics'),
      decisions: items('decisions'),
      actions: items('actions'),
      questions: items('questions'),
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'overview': overview,
    'topics': topics.map((e) => e.toJson()).toList(),
    'decisions': decisions.map((e) => e.toJson()).toList(),
    'actions': actions.map((e) => e.toJson()).toList(),
    'questions': questions.map((e) => e.toJson()).toList(),
  };
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());
  String export(AnalysisResult result) => [
    '# $title',
    overview,
    for (final section in sections) ...[
      '## ${section.$1}',
      if (section.$2.isEmpty) '未提及',
      for (final item in section.$2)
        '- ${item.text}${item.owner == null ? '' : '\n  负责人：${item.owner}；期限：${item.due}'} ${item.sources.map((s) => '[$s]').join(' ')}',
    ],
    '模型：${result.model} · 模板：meeting-v1',
    '生成时间：${result.createdAt.toIso8601String()}',
    if (result.editedAt != null) '编辑时间：${result.editedAt!.toIso8601String()}',
    '## 原文依据',
    for (final source in result.sources.indexed)
      '[S${source.$1 + 1}] ${source.$2}',
  ].join('\n\n');
}

String validateMinutes(String text, List<String> sources) =>
    MeetingMinutes.parse(text, sources.length).encode();
