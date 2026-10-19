part of '../recorder_controller.dart';

/// Context export (step 12): a chosen day, project or topic as Markdown with
/// its sources, for the user to paste into an outside AI. Nothing is sent
/// anywhere by Koe; MCP stays closed (#152–#155).
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderContextExport on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  List<ContextItem> allContextItems();
  List<ContextItem> contextItemsForDay(DateTime day);
  List<ContextItem> contextItemsForProject(String projectId);
  List<SourceLine> contextSourceLines(List<ContextItem> items, {int maxChars});
  abstract final DiaryStore diary;
  abstract final ProjectStore projects;
  abstract final TodoStore todos;
  abstract final TopicStore topics;
  // END DEPS

  /// The Markdown and how many items it covers.
  (String markdown, int itemCount) exportContextMarkdown(
    ContextExportScope scope, {
    DateTime? now,
  }) {
    final exportedAt = now ?? DateTime.now();
    final List<ContextItem> items;
    final String title;
    final String scopeLabel;
    String? goal;
    switch (scope) {
      case DayExport(:final day):
        items = contextItemsForDay(day);
        title = 'Koe 资料：${day.year}年${day.month}月${day.day}日';
        scopeLabel = '一天';
      case ProjectExport(:final projectId):
        final project = projects.projectById(projectId);
        items = contextItemsForProject(projectId);
        title = 'Koe 项目：${project?.title ?? '已删除的项目'}';
        scopeLabel = '项目';
        goal = project?.goal;
      case TopicExport(:final topicId):
        items = [
          for (final item in allContextItems())
            if (item.topicIds.contains(topicId)) item,
        ];
        title = 'Koe 主题：${topics.topicById(topicId)?.title ?? '已删除的主题'}';
        scopeLabel = '主题';
    }
    final lines = contextSourceLines(items, maxChars: 400000);
    final byRecording = <String, List<SourceLine>>{};
    for (final line in lines) {
      byRecording.putIfAbsent(line.source.recordingKey, () => []).add(line);
    }
    final keys = {for (final item in items) ?item.source?.recordingKey};
    final relatedTodos = switch (scope) {
      ProjectExport(:final projectId) => todos.todosForProject(projectId),
      _ => [
        for (final todo in todos.todos)
          if (keys.contains(todo.source.recordingKey)) todo,
      ],
    };
    String? diaryText;
    if (scope case DayExport(:final day)) {
      final current = diary.entryFor(DiaryPeriod.day(day).key)?.current;
      if (current != null) {
        diaryText = relabelCitations(current.text, current.sources, lines);
      }
    }
    final markdown = buildContextMarkdown(
      title: title,
      scopeLabel: scopeLabel,
      exportedAt: exportedAt,
      goal: goal,
      items: [
        for (final item in items)
          ExportedItem(
            item: item,
            lines: byRecording[item.source?.recordingKey] ?? const [],
            topics: [
              for (final id in item.topicIds) ?topics.topicById(id)?.title,
            ],
            projects: [
              for (final id in item.projectIds)
                ?projects.projectById(id)?.title,
            ],
          ),
      ],
      todos: relatedTodos,
      diary: diaryText,
    );
    return (markdown, items.length);
  }
}
