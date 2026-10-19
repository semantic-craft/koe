import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../widgets/context_export_sheet.dart';
import '../widgets/context_timeline.dart';
import '../widgets/widgets.dart';
import 'todos_screen.dart';

void openProject(BuildContext context, String id) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: 'project/$id'),
      builder: (_) => ProjectDetailScreen(projectId: id),
    ),
  );
}

String _dayLabel(DateTime day) {
  final local = day.toLocal();
  return '${local.month}月${local.day}日';
}

/// `最新：周会 · 10月18日`, from the newest linked item.
String projectLatestLabel(ProjectProgress progress) {
  final latest = progress.latest;
  if (latest == null) return '还没有关联资料';
  final when = latest.timeKnown ? _dayLabel(latest.start!) : '时间未知';
  return '最新：${latest.title} · $when';
}

String projectNextLabel(ProjectProgress progress) =>
    progress.next == null ? '尚未形成明确下一步' : '下一步：${progress.next!.title}';

Future<void> _report(BuildContext context, Future<void> Function() run) async {
  try {
    await run();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error is StateError ? error.message.toString() : '保存失败，请重试',
        ),
      ),
    );
  }
}

/// Name and goal, for a new project or an edit. Returns (title, goal).
Future<(String, String)?> showProjectDialog(
  BuildContext context, {
  Project? project,
}) async {
  final title = TextEditingController(text: project?.title ?? '');
  final goal = TextEditingController(text: project?.goal ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(project == null ? '新建项目' : '编辑项目'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('project-title'),
            controller: title,
            autofocus: true,
            decoration: const InputDecoration(labelText: '项目名称'),
          ),
          TextField(
            key: const ValueKey('project-goal'),
            controller: goal,
            decoration: const InputDecoration(labelText: '目标（可空）'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('project-save'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (ok != true || title.text.trim().isEmpty) return null;
  return (title.text.trim(), goal.text.trim());
}

/// Status and goal → next steps → what is settled, with sources → the
/// discussions linked across days.
class ProjectDetailScreen extends StatelessWidget {
  const ProjectDetailScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final project = c.projects.projectById(projectId);
    if (project == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('这个项目已删除')),
      );
    }
    final todos = c.todos.todosForProject(projectId);
    final next = [
      for (final todo in todos)
        if (todo.open) todo,
    ];
    final settled = [
      for (final todo in todos)
        if (todo.status == TodoStatus.done) todo,
    ];
    final items = c.contextItemsForProject(projectId).reversed.toList();
    final days = <String, List<ContextItem>>{};
    for (final item in items) {
      final label = item.timeKnown ? _dayLabel(item.start!) : '时间未知';
      days.putIfAbsent(label, () => []).add(item);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(project.title),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('project-menu'),
            onSelected: (value) => _menu(context, project, value),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑名称和目标')),
              const PopupMenuItem(value: 'export', child: Text('导出给外部 AI')),
              for (final status in ProjectStatus.values)
                if (status != project.status)
                  PopupMenuItem(
                    value: status.name,
                    child: Text('标为${projectStatusLabel(status)}'),
                  ),
              const PopupMenuItem(value: 'delete', child: Text('删除项目')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            '${projectStatusLabel(project.status)}'
            '${project.goal.isEmpty ? '' : ' · 目标：${project.goal}'}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          const SectionLabel('下一步'),
          if (next.isEmpty)
            const SurfaceCard(
              padding: EdgeInsets.all(14),
              child: Text(
                '尚未形成明确下一步',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          else
            for (final todo in next) TodoRow(todo: todo),
          if (settled.isNotEmpty) ...[
            const SizedBox(height: 18),
            const SectionLabel('已确定'),
            for (final todo in settled) TodoRow(todo: todo),
          ],
          const SizedBox(height: 18),
          SectionLabel(
            '跨天相关讨论',
            trailing: TextButton(
              key: const ValueKey('project-link-items'),
              onPressed: () => _linkItems(context, project),
              child: const Text('关联资料'),
            ),
          ),
          if (items.isEmpty)
            const SurfaceCard(
              key: ValueKey('project-no-items'),
              padding: EdgeInsets.all(14),
              child: Text(
                '还没有关联资料。点「关联资料」，或在今日时间线的标签按钮里选这个项目。',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          for (final entry in days.entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: Text(
                entry.key,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            for (final item in entry.value) ContextTimelineRow(item: item),
          ],
        ],
      ),
    );
  }

  Future<void> _menu(
    BuildContext context,
    Project project,
    String value,
  ) async {
    final c = context.read<RecorderController>();
    if (value == 'export') {
      await showContextExportSheet(context, ProjectExport(project.id));
      return;
    }
    if (value == 'edit') {
      final edited = await showProjectDialog(context, project: project);
      if (edited == null || !context.mounted) return;
      await _report(
        context,
        () => c.updateProject(
          project.copyWith(title: edited.$1, goal: edited.$2),
        ),
      );
      return;
    }
    if (value == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('删除项目？'),
          content: const Text('只删除项目和它的关联；录音、待办都保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      await _report(context, () => c.deleteProject(project.id));
      if (context.mounted) Navigator.of(context).maybePop();
      return;
    }
    final status = ProjectStatus.values.byName(value);
    await _report(
      context,
      () => c.updateProject(project.copyWith(status: status)),
    );
  }

  Future<void> _linkItems(BuildContext context, Project project) async {
    final c = context.read<RecorderController>();
    final now = DateTime.now();
    final recent = <ContextItem>[
      for (var back = 0; back < 30; back++)
        ...c.contextItemsForDay(now.subtract(Duration(days: back))).reversed,
    ];
    final chosen = {
      for (final item in recent)
        if (item.projectIds.contains(project.id)) item.id,
    };
    final initial = {...chosen};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      sheetAnimationStyle: AppMotion.sheetStyle(context),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '关联到「${project.title}」',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Text(
                  '近 30 天的资料。只记录关系，不复制录音。',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      if (recent.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('近 30 天没有资料'),
                        ),
                      for (final item in recent)
                        CheckboxListTile(
                          key: ValueKey('pick-${item.id}'),
                          value: chosen.contains(item.id),
                          title: Text(item.title),
                          subtitle: Text(
                            '${item.timeKnown ? _dayLabel(item.start!) : '时间未知'} '
                            '${contextTimeLabel(item)}',
                          ),
                          onChanged: (checked) => setSheetState(() {
                            if (checked == true) {
                              chosen.add(item.id);
                            } else {
                              chosen.remove(item.id);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
                FilledButton(
                  key: const ValueKey('project-link-save'),
                  onPressed: () => Navigator.pop(sheetContext, true),
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await _report(context, () async {
      for (final item in recent) {
        final was = initial.contains(item.id);
        final now = chosen.contains(item.id);
        if (was == now) continue;
        await c.setContextItemProjects(item.id, [
          for (final id in item.projectIds)
            if (id != project.id) id,
          if (now) project.id,
        ]);
      }
    });
  }
}
