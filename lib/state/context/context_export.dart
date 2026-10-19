import 'context_item.dart';
import 'source_pack.dart';
import 'todo.dart';

/// What to hand to an outside AI: one day, one project or one topic.
sealed class ContextExportScope {
  const ContextExportScope();
}

class DayExport extends ContextExportScope {
  const DayExport(this.day);
  final DateTime day;
}

class ProjectExport extends ContextExportScope {
  const ProjectExport(this.projectId);
  final String projectId;
}

class TopicExport extends ContextExportScope {
  const TopicExport(this.topicId);
  final String topicId;
}

/// One timeline entry as exported: its sentences carry the export's labels.
class ExportedItem {
  const ExportedItem({
    required this.item,
    required this.lines,
    required this.topics,
    required this.projects,
  });

  final ContextItem item;
  final List<SourceLine> lines;
  final List<String> topics;
  final List<String> projects;
}

String _two(int value) => value.toString().padLeft(2, '0');

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${_two(local.month)}-${_two(local.day)}';
}

String _clock(DateTime value) {
  final local = value.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

String _offset(Duration value) =>
    '${_two(value.inMinutes)}:${_two(value.inSeconds % 60)}';

/// Markdown for pasting into an outside AI. Every quoted sentence carries a
/// `[S#]` label that the 出处 section resolves to a recording and a time
/// range in it, so answers built on it can be checked against the audio.
String buildContextMarkdown({
  required String title,
  required String scopeLabel,
  required DateTime exportedAt,
  String? goal,
  required List<ExportedItem> items,
  required List<Todo> todos,
  String? diary,
}) {
  final out = StringBuffer()
    ..writeln('# $title')
    ..writeln()
    ..writeln(
      '> 由 Koe 导出（$scopeLabel，${_date(exportedAt)} ${_clock(exportedAt)}）。'
      '内容来自本人录音的转写，[S#] 对应文末「出处」里的录音和时间位置；'
      '地点只到区县。请只依据这些资料回答，没有依据的请说明。',
    );
  if (goal != null && goal.isNotEmpty) {
    out
      ..writeln()
      ..writeln('目标：$goal');
  }
  out
    ..writeln()
    ..writeln('## 时间线');
  if (items.isEmpty) out.writeln('\n（没有资料）');
  for (final entry in items) {
    final item = entry.item;
    final when = item.start == null
        ? '时间未知'
        : '${_date(item.start!)} ${_clock(item.start!)}'
              '${item.end == null ? '' : '–${_clock(item.end!)}'}';
    out
      ..writeln()
      ..writeln('### $when · ${item.title}');
    final meta = [
      if (item.location != null) '地点：${item.location}',
      if (entry.topics.isNotEmpty) '主题：${entry.topics.join('、')}',
      if (entry.projects.isNotEmpty) '项目：${entry.projects.join('、')}',
    ];
    if (meta.isNotEmpty) out.writeln(meta.join('；'));
    if (entry.lines.isEmpty) {
      out.writeln('（这段录音还没有文字）');
      continue;
    }
    out.writeln();
    for (final line in entry.lines) {
      out.writeln(
        '- [${line.label}] ${_offset(line.source.start)} ${line.text}',
      );
    }
  }
  if (todos.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## 待办与承诺');
    for (final todo in todos) {
      final box = todo.status == TodoStatus.done ? '[x]' : '[ ]';
      final due = todo.due == null
          ? '时间未定'
          : todo.dueHasTime
          ? '${_date(todo.due!)} ${_clock(todo.due!)}'
          : _date(todo.due!);
      final who = todo.kind == TodoKind.others && todo.owner != null
          ? '，${todo.owner}'
          : '';
      final status = todo.status == TodoStatus.cancelled ? '，已取消' : '';
      out.writeln(
        '- $box ${todo.title}（${todoKindLabel(todo.kind)}$who，$due$status）'
        '原话：「${todo.quote}」',
      );
    }
  }
  if (diary != null && diary.trim().isNotEmpty) {
    out
      ..writeln()
      ..writeln('## 当天日记')
      ..writeln()
      ..writeln(diary.trim());
  }
  final lines = [for (final entry in items) ...entry.lines];
  if (lines.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## 出处');
    for (final line in lines) {
      final at = line.at == null
          ? ''
          : ' · ${_date(line.at!)} ${_clock(line.at!)}';
      final end = line.source.end == null
          ? ''
          : '–${_offset(line.source.end!)}';
      out.writeln(
        '- [${line.label}] ${line.title}$at · 录音位置 '
        '${_offset(line.source.start)}$end · ${line.source.recordingKey}',
      );
    }
  }
  return out.toString();
}

/// Rewrites a diary's `[S#]` labels to the export's labels for the same
/// sentences; a sentence not in the export keeps no label.
String relabelCitations(
  String text,
  List<SourceLine> from,
  List<SourceLine> to,
) {
  String keyOf(SourceLine line) =>
      '${line.source.recordingKey}@${line.source.start.inMilliseconds}';
  final target = {for (final line in to) keyOf(line): line.label};
  final mapping = {for (final line in from) line.label: target[keyOf(line)]};
  return text.replaceAllMapped(RegExp(r'\[(S\d+)\]'), (match) {
    final label = mapping[match.group(1)];
    return label == null ? '' : '[$label]';
  });
}
