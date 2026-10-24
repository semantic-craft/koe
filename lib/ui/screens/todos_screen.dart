import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/recorder_controller.dart';
import '../../theme/app_theme.dart';
import '../context_source.dart';
import '../widgets/widgets.dart';
import '../widgets/koe_icon_button.dart';

void openTodo(BuildContext context, String id) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: 'todo/$id'),
      builder: (_) => TodoDetailScreen(todoId: id),
    ),
  );
}

void openTodos(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'todos'),
      builder: (_) => const TodosScreen(),
    ),
  );
}

Future<void> _guard(BuildContext context, Future<void> Function() run) async {
  try {
    await run();
  } catch (error) {
    if (!context.mounted) return;
    final message = error is StateError
        ? error.message
        : error is SystemTasksUnavailable
        ? error.message
        : '操作没有完成，请重试';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message.toString())));
  }
}

/// One todo row with a completion control. The title opens the detail.
class TodoRow extends StatelessWidget {
  const TodoRow({super.key, required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    final done = todo.status == TodoStatus.done;
    final details = [
      todoDueLabel(todo),
      if (todo.kind == TodoKind.others && todo.owner != null) todo.owner!,
      if (todo.status == TodoStatus.cancelled) '已取消',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        key: ValueKey('todo-${todo.id}'),
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        onTap: () => openTodo(context, todo.id),
        child: Row(
          children: [
            Checkbox(
              key: ValueKey('todo-check-${todo.id}'),
              value: done,
              semanticLabel: '完成：${todo.title}',
              onChanged: todo.status == TodoStatus.cancelled
                  ? null
                  : (checked) => _guard(
                      context,
                      () => c.setTodoStatus(
                        todo.id,
                        checked == true ? TodoStatus.done : TodoStatus.open,
                      ),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      decoration: todo.open ? null : TextDecoration.lineThrough,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    details.join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (todo.reminder != null || todo.calendar != null)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.event_available_outlined,
                  size: 18,
                  color: AppColors.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// All todos: my own, others' commitments and wishes kept apart, plus the
/// sentences waiting for the user to say which todo they mean.
class TodosScreen extends StatelessWidget {
  const TodosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final all = c.todos.todos;
    List<Todo> of(TodoKind kind) => [
      for (final todo in all)
        if (todo.kind == kind && todo.status != TodoStatus.done) todo,
    ];
    final finished = [
      for (final todo in all)
        if (todo.status == TodoStatus.done) todo,
    ];
    final sections = [
      ('我的待办', of(TodoKind.mine)),
      ('他人承诺', of(TodoKind.others)),
      ('愿望', of(TodoKind.wish)),
      ('已完成', finished),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('待办')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          if (c.todos.clarifications.isNotEmpty) ...[
            const SectionLabel('需要你确认'),
            for (final item in c.todos.clarifications)
              _ClarificationCard(item: item),
            const SizedBox(height: 16),
          ],
          if (all.isEmpty)
            const SurfaceCard(
              padding: EdgeInsets.all(16),
              child: Text(
                '还没有待办。在今日页点「提取待办」，Koe 会从已转写的录音里找出你答应要做的事。',
                style: TextStyle(color: AppColors.textSecondary, height: 1.45),
              ),
            ),
          for (final (label, items) in sections)
            if (items.isNotEmpty) ...[
              SectionLabel(label),
              for (final todo in items) TodoRow(todo: todo),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _ClarificationCard extends StatelessWidget {
  const _ClarificationCard({required this.item});

  final TodoClarification item;

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    final open = [
      for (final todo in c.todos.todos)
        if (todo.open) todo,
    ];
    // The todos the sentence may mean come first, then the rest.
    open.sort(
      (a, b) =>
          (item.candidateIds.contains(a.id) ? 0 : 1) -
          (item.candidateIds.contains(b.id) ? 0 : 1),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        key: ValueKey('clarification-${item.id}'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${item.actionLabel}：哪一条？',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            InkWell(
              onTap: () => openContextSource(context, item.source),
              child: Text(
                '「${item.quote}」 ${sourcePositionLabel(item.source)}',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            Wrap(
              spacing: 4,
              children: [
                for (final todo in open.take(6))
                  TextButton(
                    onPressed: () => _guard(
                      context,
                      () => c.resolveTodoClarification(item.id, todo.id),
                    ),
                    child: Text(todo.title),
                  ),
                TextButton(
                  onPressed: () => _guard(
                    context,
                    () => c.resolveTodoClarification(item.id, null),
                  ),
                  child: const Text('都不是'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Owner, time, status and the sentence a todo came from, with the
/// corrections and the explicit exports to Reminders and Calendar.
class TodoDetailScreen extends StatefulWidget {
  const TodoDetailScreen({super.key, required this.todoId});

  final String todoId;

  @override
  State<TodoDetailScreen> createState() => _TodoDetailScreenState();
}

class _TodoDetailScreenState extends State<TodoDetailScreen> {
  @override
  void initState() {
    super.initState();
    context.read<RecorderController>().syncSystemLinks();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<RecorderController>();
    final todo = c.todos.todoById(widget.todoId);
    if (todo == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('这条待办已不存在')),
      );
    }
    final info = <(String, String)>[
      ('类型', todoKindLabel(todo.kind)),
      if (todo.owner != null) ('承诺人', todo.owner!),
      ('时间', todoDueLabel(todo)),
      ('状态', todoStatusLabel(todo.status)),
      (
        '项目',
        todo.projectIds.isEmpty
            ? '未关联'
            : [
                for (final id in todo.projectIds)
                  ?c.projects.projectById(id)?.title,
              ].join('、'),
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('待办详情'),
        actions: [
          KoeIconButton(
            key: const ValueKey('todo-projects'),
            tooltip: '关联项目',
            onPressed: () => _pickProjects(context, todo),
            icon: const Icon(Icons.folder_open_outlined),
          ),
          KoeIconButton(
            key: const ValueKey('todo-edit'),
            tooltip: '纠正',
            onPressed: () => _edit(context, todo),
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(
            todo.title,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          for (final (label, value) in info)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '$label：$value',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ),
          const SizedBox(height: 12),
          SurfaceCard(
            key: const ValueKey('todo-quote'),
            padding: const EdgeInsets.all(14),
            onTap: () => openContextSource(context, todo.source),
            child: Row(
              children: [
                const Icon(Icons.format_quote_rounded, color: AppColors.accent),
                const SizedBox(width: 10),
                Expanded(child: Text(todo.quote)),
                Text(
                  sourcePositionLabel(todo.source),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (todo.status == TodoStatus.open)
                FilledButton(
                  key: const ValueKey('todo-complete'),
                  onPressed: () => _guard(
                    context,
                    () => c.setTodoStatus(todo.id, TodoStatus.done),
                  ),
                  child: const Text('完成'),
                )
              else
                OutlinedButton(
                  key: const ValueKey('todo-reopen'),
                  onPressed: () => _guard(
                    context,
                    () => c.setTodoStatus(todo.id, TodoStatus.open),
                  ),
                  child: const Text('重新打开'),
                ),
              OutlinedButton(
                key: const ValueKey('todo-reschedule'),
                onPressed: () => _reschedule(context, todo),
                child: const Text('改期'),
              ),
              if (todo.status == TodoStatus.open)
                OutlinedButton(
                  key: const ValueKey('todo-cancel'),
                  onPressed: () => _guard(
                    context,
                    () => c.setTodoStatus(todo.id, TodoStatus.cancelled),
                  ),
                  child: const Text('取消'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          const SectionLabel('系统应用'),
          _LinkCard(todo: todo, target: SystemTaskTarget.reminder),
          const SizedBox(height: 8),
          _LinkCard(todo: todo, target: SystemTaskTarget.event),
          if (c.systemTasksNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                c.systemTasksNotice!,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _reschedule(BuildContext context, Todo todo) async {
    final picked = await pickDateAndOptionalTime(context, todo.due);
    if (picked == null || !context.mounted) return;
    final c = context.read<RecorderController>();
    await _guard(
      context,
      () => c.editTodo(todo.id, due: picked.$1, dueHasTime: picked.$2),
    );
  }

  Future<void> _pickProjects(BuildContext context, Todo todo) async {
    final c = context.read<RecorderController>();
    final chosen = {...todo.projectIds};
    final choices = [
      for (final project in c.projects.projects)
        if (project.status == ProjectStatus.active ||
            chosen.contains(project.id))
          project,
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('关联项目'),
          content: choices.isEmpty
              ? const Text('还没有项目。先在「项目」页新建。')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final project in choices)
                      CheckboxListTile(
                        value: chosen.contains(project.id),
                        title: Text(project.title),
                        onChanged: (checked) => setDialogState(() {
                          if (checked == true) {
                            chosen.add(project.id);
                          } else {
                            chosen.remove(project.id);
                          }
                        }),
                      ),
                  ],
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await _guard(
      context,
      () => c.setTodoProjects(todo.id, [
        for (final project in c.projects.projects)
          if (chosen.contains(project.id)) project.id,
      ]),
    );
  }

  Future<void> _edit(BuildContext context, Todo todo) async {
    final title = TextEditingController(text: todo.title);
    var kind = todo.kind;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('纠正待办'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('todo-edit-title'),
                controller: title,
                decoration: const InputDecoration(labelText: '内容'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<TodoKind>(
                segments: [
                  for (final value in TodoKind.values)
                    ButtonSegment(
                      value: value,
                      label: Text(todoKindLabel(value)),
                    ),
                ],
                selected: {kind},
                onSelectionChanged: (value) =>
                    setDialogState(() => kind = value.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !context.mounted) return;
    final c = context.read<RecorderController>();
    await _guard(
      context,
      () => c.editTodo(todo.id, title: title.text, kind: kind),
    );
  }
}

/// A date, then optionally a time. Returns (moment, hasTime).
Future<(DateTime, bool)?> pickDateAndOptionalTime(
  BuildContext context,
  DateTime? initial,
) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: initial ?? now,
    firstDate: DateTime(now.year - 1),
    lastDate: DateTime(now.year + 5),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: initial == null
        ? TimeOfDay.now()
        : TimeOfDay.fromDateTime(initial),
    helpText: '选择时刻（可跳过）',
    cancelText: '只要日期',
  );
  if (time == null) return (DateTime(date.year, date.month, date.day), false);
  return (
    DateTime(date.year, date.month, date.day, time.hour, time.minute),
    true,
  );
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.todo, required this.target});

  final Todo todo;
  final SystemTaskTarget target;

  bool get _reminder => target == SystemTaskTarget.reminder;

  @override
  Widget build(BuildContext context) {
    final c = context.read<RecorderController>();
    final link = _reminder ? todo.reminder : todo.calendar;
    final name = _reminder ? '提醒事项' : '日历';
    final conflict = link?.conflict;
    final supported = c.systemTaskSupported(target);
    final phase = c.todoExportPhase(todo.id, target);
    final status = phase == SystemExportPhase.authorization
        ? '等待系统授权'
        : phase == SystemExportPhase.writing
        ? '正在写入'
        : link == null
        ? (supported ? '未导出' : '此设备不支持')
        : conflict != null
        ? '有冲突：$name里是「${conflict.title}」'
        : link.unsynced
        ? '未同步'
        : '已关联';
    return SurfaceCard(
      key: ValueKey('link-${target.name}'),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _reminder ? Icons.checklist_rounded : Icons.event_outlined,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('$name · $status')),
              if (link == null && supported)
                TextButton(
                  key: ValueKey('export-${target.name}'),
                  onPressed: phase == null ? () => _export(context) : null,
                  child: Text(phase == null ? '导出' : '处理中'),
                )
              else if (link != null)
                TextButton(
                  key: ValueKey('unlink-${target.name}'),
                  onPressed: () =>
                      _guard(context, () => c.unlinkTodo(todo.id, target)),
                  child: const Text('解除关联'),
                ),
            ],
          ),
          if (conflict != null)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => _guard(
                    context,
                    () =>
                        c.resolveSystemConflict(todo.id, target, keepKoe: true),
                  ),
                  child: Text('保留 Koe：「${todo.title}」'),
                ),
                TextButton(
                  onPressed: () => _guard(
                    context,
                    () => c.resolveSystemConflict(
                      todo.id,
                      target,
                      keepKoe: false,
                    ),
                  ),
                  child: Text('用$name的版本'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context) async {
    final c = context.read<RecorderController>();
    if (_reminder) {
      final ok = await _confirm(
        context,
        '导出到提醒事项',
        '将在提醒事项里新建：\n「${todo.title}」\n期限：${todoDueLabel(todo)}\n\n'
            '之后标题、期限和完成状态会两边同步；在提醒事项里删除只会解除关联。',
      );
      if (ok && context.mounted) {
        await _guard(context, () => c.exportTodoToReminders(todo.id));
      }
      return;
    }
    var start = todo.due != null && todo.dueHasTime ? todo.due : null;
    if (start == null) {
      final picked = await pickDateAndOptionalTime(context, todo.due);
      if (picked == null || !context.mounted) return;
      if (!picked.$2) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('写入日历需要具体时刻，请再选一次')));
        return;
      }
      start = picked.$1;
    }
    final end = start.add(const Duration(hours: 1));
    String two(int value) => value.toString().padLeft(2, '0');
    final local = start.toLocal();
    final ok = await _confirm(
      context,
      '导出到日历',
      '将在日历里新建：\n「${todo.title}」\n'
          '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}，1 小时'
          '（${local.timeZoneName}）\n\n事件结束不会把待办标成完成；在日历里删除只会解除关联。',
    );
    if (ok && context.mounted) {
      await _guard(
        context,
        () => c.exportTodoToCalendar(todo.id, start: start!, end: end),
      );
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-export'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('写入'),
          ),
        ],
      ),
    );
    return ok == true;
  }
}
