import 'dart:convert';
import 'dart:io';

import 'topic_note.dart';
import 'topic_store.dart';
import 'topic_summary.dart';

/// The material exported for one recording. No audio, transcript, or storage
/// identifier is needed to render it.
class TopicExportNote {
  const TopicExportNote({
    required this.title,
    required this.recordedAt,
    required this.note,
    this.page,
  });

  final String title;
  final DateTime recordedAt;
  final TopicNote note;
  final int? page;
}

// Leave room for ".md" and a collision suffix within a 255-byte component.
const _maxStemBytes = 230;

String _displayName(Topic topic) =>
    topic.kind == TopicKind.book && topic.author.trim().isNotEmpty
    ? '${topic.title} - ${topic.author}'
    : topic.title;

String _fileStem(Topic topic) {
  // Keep the name portable to Files, Obsidian, Notion, and desktop filesystems.
  var stem = _displayName(topic)
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '')
      .trim();
  if (stem.isEmpty) stem = '主题';
  stem = _truncateUtf8(stem, _maxStemBytes);
  stem = stem.replaceAll(RegExp(r'[. ]+$'), '');
  if (stem.isEmpty) stem = '主题';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
    caseSensitive: false,
  ).hasMatch(stem)) {
    stem = '_$stem';
  }
  return stem;
}

String _truncateUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) return value;
  final buffer = StringBuffer();
  var bytes = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final length = utf8.encode(char).length;
    if (bytes + length > maxBytes) break;
    buffer.write(char);
    bytes += length;
  }
  return buffer.toString();
}

/// Stable, human-readable collision handling, including names that collide
/// only after invalid characters are cleaned or because one ends in " (2)".
String topicExportFileName(Topic topic, Iterable<Topic> allTopics) {
  final used = <String>{};
  for (final candidate in allTopics) {
    final stem = _fileStem(candidate);
    var name = '$stem.md';
    var suffix = 2;
    while (used.contains(name.toLowerCase())) {
      name = '$stem ($suffix).md';
      suffix++;
    }
    used.add(name.toLowerCase());
    if (candidate.id == topic.id) return name;
  }
  return '${_fileStem(topic)}.md';
}

/// Writes one export to an isolated temp directory and always removes it after
/// the share callback returns, throws, or declines to present the share sheet.
Future<void> shareTopicMarkdownFile({
  required String markdown,
  required String filename,
  required Future<void> Function(File file) share,
}) async {
  final directory = await Directory.systemTemp.createTemp('koe-topic-');
  try {
    final file = File('${directory.path}/$filename');
    await file.writeAsString(markdown, encoding: utf8, flush: true);
    await share(file);
  } finally {
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  }
}

String _oneLine(String value) => value
    .replaceAll(RegExp(r'\[(?:N|S)[1-9]\d*\]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

String _date(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

void _items(
  List<String> lines,
  String label,
  Iterable<String> items, {
  int headingLevel = 4,
}) {
  lines.add('${''.padLeft(headingLevel, '#')} $label');
  final values = items.map(_oneLine).where((text) => text.isNotEmpty).toList();
  if (values.isEmpty) {
    lines.add('未提及');
  } else {
    for (final value in values) {
      lines.add('- $value');
    }
  }
  lines.add('');
}

/// Markdown intentionally excludes storage IDs, source block IDs, source
/// transcripts, model details, and audio. It is safe to copy or share as text.
String buildTopicMarkdown({
  required Topic topic,
  required int recordingCount,
  required DateTime exportedAt,
  required List<TopicExportNote> notes,
  TopicSummary? summary,
  bool summaryStale = false,
  int unavailableNoteCount = 0,
}) {
  final orderedNotes = [...notes]
    ..sort((a, b) {
      if (topic.kind == TopicKind.book) {
        if (a.page != null && b.page != null && a.page != b.page) {
          return a.page!.compareTo(b.page!);
        }
        if (a.page != null && b.page == null) return -1;
        if (a.page == null && b.page != null) return 1;
      }
      final byTime = a.recordedAt.compareTo(b.recordedAt);
      return byTime != 0 ? byTime : a.title.compareTo(b.title);
    });
  final lines = <String>[
    '# ${_oneLine(topic.title)}',
    '',
    '- 类型：${topic.kind == TopicKind.book ? '书籍' : '普通主题'}',
    if (topic.kind == TopicKind.book)
      '- 作者：${topic.author.trim().isEmpty ? '未填写' : _oneLine(topic.author)}',
    '- 状态：${topic.closed ? topic.closedLabel : '进行中'}',
    '- 录音数：$recordingCount',
    '- 导出时间：${_date(exportedAt)}',
    '',
    '## 汇总',
    '',
  ];
  if (summary == null ||
      summary.kind != topic.kind ||
      summary.topicId != topic.id) {
    lines.add('尚无汇总。');
    lines.add('');
  } else {
    if (summaryStale) {
      lines.add('> 此汇总已过期，可能未包含最新笔记。');
      lines.add('');
    }
    for (final key in TopicSummary.sectionKeys(topic.kind)) {
      _items(
        lines,
        TopicSummary.sectionLabel(key),
        (summary.sections[key] ?? const <TopicSummaryItem>[]).map(
          (item) => item.text,
        ),
        headingLevel: 3,
      );
    }
  }

  lines.add('## 笔记');
  lines.add('');
  if (orderedNotes.isEmpty) {
    lines.add('尚无笔记。');
    lines.add('');
  }
  if (unavailableNoteCount > 0) {
    lines.add('有 $unavailableNoteCount 条笔记不可读取，未包含在本次导出中。');
    lines.add('');
  }
  for (final entry in orderedNotes.indexed) {
    final item = entry.$2;
    final note = item.note;
    lines.add('### ${entry.$1 + 1}. ${_oneLine(item.title)}');
    lines.add('');
    lines.add('- 录音日期：${_date(item.recordedAt)}');
    if (item.page != null) lines.add('- 口述页码：${item.page}');
    lines.add('');
    lines.add(_oneLine(note.overview));
    lines.add('');
    if (note.kind == TopicKind.book) {
      _items(
        lines,
        '原文摘录',
        note.excerpts.map(
          (e) => e.page == null ? e.text : '（${_oneLine(e.page!)}）${e.text}',
        ),
      );
      _items(
        lines,
        '我的评论',
        note.comments.map(
          (e) => e.excerpt == null ? e.text : '${e.text}（对应摘录：${e.excerpt}）',
        ),
      );
      _items(lines, '疑问', note.questions.map((e) => e.text));
      _items(lines, '联想', note.associations.map((e) => e.text));
      _items(lines, '待查', note.toCheck.map((e) => e.text));
    } else {
      _items(
        lines,
        '主要想法',
        note.ideas.map(
          (e) => e.reason == null ? e.text : '${e.text}（理由：${e.reason}）',
        ),
      );
      if (note.changes.isNotEmpty) {
        _items(lines, '变化', note.changes.map((e) => e.text));
      }
      _items(lines, '疑问', note.questions.map((e) => e.text));
      _items(lines, '联想', note.associations.map((e) => e.text));
      _items(lines, '待办/待查', note.todos.map((e) => e.text));
      if (note.conclusion != null) {
        _items(lines, '倾向的结论', [note.conclusion!.text]);
      }
    }
  }
  return '${lines.join('\n').trimRight()}\n';
}
