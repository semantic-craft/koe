import '../../platform/system_tasks.dart';
import 'todo_store.dart';

/// Keeps Koe todos in step with the Reminders (#137) and Calendar (#138)
/// items the user explicitly exported them to.
///
/// Each link remembers the values both sides last agreed on; a sync compares
/// both sides against that, takes the side that changed, and records a
/// conflict for the user when both changed differently. A deleted system item
/// only removes the link, never the todo.
class TodoSystemSync {
  TodoSystemSync(this._todos, this._tasks);

  final TodoStore _todos;
  final SystemTasks _tasks;
  final Set<String> _exportsInFlight = {};
  Future<void>? _syncing;

  /// Last system-app problem worth telling the user about.
  String? notice;

  /// Whether this device has [target]'s system app at all.
  bool supports(SystemTaskTarget target) => _tasks.supports(target);

  /// Writes the todo into Reminders after the user confirmed it. A todo that
  /// is already linked is updated in place, never created twice.
  Future<void> exportToReminders(String id) =>
      _export(id, SystemTaskTarget.reminder, null, null);

  /// Writes the todo into Calendar for [start]–[end] after the user
  /// confirmed it. A todo without a due time takes [start] as its due time.
  Future<void> exportToCalendar(
    String id, {
    required DateTime start,
    required DateTime end,
  }) => _export(id, SystemTaskTarget.event, start, end);

  Future<void> _export(
    String id,
    SystemTaskTarget target,
    DateTime? start,
    DateTime? end,
  ) async {
    final guard = '${target.name}:$id';
    if (!_exportsInFlight.add(guard)) return;
    try {
      var todo = _todos.todoById(id);
      if (todo == null) throw StateError('找不到这条待办');
      final existing = target == SystemTaskTarget.reminder
          ? todo.reminder
          : todo.calendar;
      if (existing != null) {
        await _syncLink(id, target);
        return;
      }
      if (!await _tasks.requestAccess(target)) {
        throw SystemTasksUnavailable(
          target == SystemTaskTarget.reminder
              ? '没有访问提醒事项的权限，可在系统设置里允许 Koe 访问；Koe 里的待办不受影响'
              : '没有访问日历的权限，可在系统设置里允许 Koe 访问；Koe 里的待办不受影响',
        );
      }
      // The time picked for the event becomes the todo's time; otherwise
      // the next sync pushes the date-only due back as midnight.
      if (target == SystemTaskTarget.event &&
          (todo.due == null || !todo.dueHasTime)) {
        await _todos.put(todo.copyWith(due: start, dueHasTime: true));
        todo = _todos.todoById(id)!;
      }
      final from = target == SystemTaskTarget.event ? start : todo.due;
      final externalId = await _tasks.save(
        target,
        title: todo.title,
        start: from,
        end: end,
        hasTime: target == SystemTaskTarget.event || todo.dueHasTime,
        done:
            target == SystemTaskTarget.reminder &&
            todo.status == TodoStatus.done,
        notes: '来自 Koe：「${todo.quote}」',
      );
      final link = SystemLink(
        externalId: externalId,
        syncedTitle: todo.title,
        syncedStart: from,
        syncedEnd: end,
        syncedDone: todo.status == TodoStatus.done,
      );
      await _todos.put(
        target == SystemTaskTarget.reminder
            ? todo.copyWith(reminder: link)
            : todo.copyWith(calendar: link),
      );
    } finally {
      _exportsInFlight.remove(guard);
    }
  }

  /// Removes Koe's link; the system item and the Koe todo both stay.
  Future<void> unlink(String id, SystemTaskTarget target) async {
    final todo = _todos.todoById(id);
    if (todo == null) return;
    await _todos.put(
      target == SystemTaskTarget.reminder
          ? todo.copyWith(clearReminder: true)
          : todo.copyWith(clearCalendar: true),
    );
  }

  /// Settles a conflict: [keepKoe] pushes Koe's values, otherwise the
  /// system app's values replace Koe's.
  Future<void> resolveConflict(
    String id,
    SystemTaskTarget target, {
    required bool keepKoe,
  }) async {
    final todo = _todos.todoById(id);
    final link = _linkOf(todo, target);
    final external = link?.conflict;
    if (todo == null || link == null || external == null) return;
    if (keepKoe) {
      await _writeLink(todo, target, link.copyWith(clearConflict: true));
      return;
    }
    final updated = _applyExternal(todo, target, external);
    await _todos.put(
      _withLink(updated, target, _agreed(updated, target, external)),
    );
  }

  /// Reconciles every linked todo with its system item. Runs on demand
  /// (opening Today or a todo, returning to the app); never in a loop.
  Future<void> syncAll() => _syncing ??= () async {
    try {
      await _todos.load();
      for (final todo in _todos.todos) {
        if (todo.reminder != null) {
          await _syncLink(todo.id, SystemTaskTarget.reminder);
        }
        if (todo.calendar != null) {
          await _syncLink(todo.id, SystemTaskTarget.event);
        }
      }
    } finally {
      _syncing = null;
    }
  }();

  /// Pushes a Koe-side change of todo [id] to its linked system items.
  Future<void> pushLinks(String id) async {
    final todo = _todos.todoById(id);
    if (todo?.reminder != null) {
      await _syncLink(id, SystemTaskTarget.reminder);
    }
    if (todo?.calendar != null) await _syncLink(id, SystemTaskTarget.event);
  }

  SystemLink? _linkOf(Todo? todo, SystemTaskTarget target) =>
      target == SystemTaskTarget.reminder ? todo?.reminder : todo?.calendar;

  Todo _withLink(Todo todo, SystemTaskTarget target, SystemLink link) =>
      target == SystemTaskTarget.reminder
      ? todo.copyWith(reminder: link)
      : todo.copyWith(calendar: link);

  static bool _sameTime(DateTime? a, DateTime? b, {required bool hasTime}) {
    if (a == null || b == null) return a == b;
    final x = a.toLocal();
    final y = b.toLocal();
    final day = x.year == y.year && x.month == y.month && x.day == y.day;
    return hasTime ? day && x.hour == y.hour && x.minute == y.minute : day;
  }

  Todo _applyExternal(Todo todo, SystemTaskTarget target, SystemSnapshot ext) {
    var next = todo.copyWith(
      title: ext.title.trim().isEmpty ? null : ext.title,
      updatedAt: DateTime.now(),
    );
    if (ext.start != null) next = next.copyWith(due: ext.start);
    if (target == SystemTaskTarget.reminder) {
      if (ext.done && todo.status != TodoStatus.done) {
        next = next.copyWith(status: TodoStatus.done);
      } else if (!ext.done && todo.status == TodoStatus.done) {
        next = next.copyWith(status: TodoStatus.open);
      }
    }
    return next;
  }

  SystemLink _agreed(Todo todo, SystemTaskTarget target, SystemSnapshot ext) =>
      SystemLink(
        externalId: _linkOf(todo, target)!.externalId,
        syncedTitle: todo.title,
        syncedStart: todo.due,
        syncedEnd: ext.end,
        syncedDone: todo.status == TodoStatus.done,
      );

  Future<void> _syncLink(String id, SystemTaskTarget target) async {
    final todo = _todos.todoById(id);
    final link = _linkOf(todo, target);
    if (todo == null || link == null || link.conflict != null) return;
    final SystemSnapshot? ext;
    try {
      ext = await _tasks.fetch(target, link.externalId);
    } on SystemTasksUnavailable catch (error) {
      notice = error.message;
      await _todos.put(_withLink(todo, target, link.copyWith(unsynced: true)));
      return;
    }
    if (ext == null) {
      // Deleted in the system app: only the link goes away.
      notice = target == SystemTaskTarget.reminder
          ? '提醒事项里的条目已删除，已解除关联；Koe 待办保留'
          : '日历里的事件已删除，已解除关联；Koe 待办保留';
      await _todos.put(
        target == SystemTaskTarget.reminder
            ? todo.copyWith(clearReminder: true)
            : todo.copyWith(clearCalendar: true),
      );
      return;
    }
    final hasTime = target == SystemTaskTarget.event || todo.dueHasTime;
    final koeDone = todo.status == TodoStatus.done;
    final reminder = target == SystemTaskTarget.reminder;
    final titleKoe = todo.title != link.syncedTitle;
    final titleExt = ext.title != link.syncedTitle;
    final startKoe = !_sameTime(todo.due, link.syncedStart, hasTime: hasTime);
    final startExt = !_sameTime(ext.start, link.syncedStart, hasTime: hasTime);
    final doneKoe = reminder && koeDone != link.syncedDone;
    final doneExt = reminder && ext.done != link.syncedDone;
    final clash =
        (titleKoe && titleExt && todo.title != ext.title) ||
        (startKoe &&
            startExt &&
            !_sameTime(todo.due, ext.start, hasTime: hasTime)) ||
        (doneKoe && doneExt && koeDone != ext.done);
    if (clash) {
      await _todos.put(
        _withLink(todo, target, link.copyWith(conflict: ext, unsynced: false)),
      );
      return;
    }
    var next = todo;
    if (titleExt) next = next.copyWith(title: ext.title);
    if (startExt && ext.start != null) next = next.copyWith(due: ext.start);
    if (doneExt) {
      next = next.copyWith(
        status: ext.done ? TodoStatus.done : TodoStatus.open,
      );
    }
    final needsPush = titleKoe || startKoe || doneKoe;
    await _writeLink(
      next,
      target,
      link.copyWith(syncedEnd: ext.end),
      push: needsPush,
    );
  }

  /// Pushes [todo]'s values when asked and records them as agreed.
  Future<void> _writeLink(
    Todo todo,
    SystemTaskTarget target,
    SystemLink link, {
    bool push = true,
  }) async {
    try {
      if (push) {
        await _tasks.save(
          target,
          existingId: link.externalId,
          title: todo.title,
          start: todo.due,
          end: link.syncedEnd,
          hasTime: target == SystemTaskTarget.event || todo.dueHasTime,
          done: todo.status == TodoStatus.done,
        );
      }
    } on SystemTasksUnavailable catch (error) {
      notice = error.message;
      await _todos.put(_withLink(todo, target, link.copyWith(unsynced: true)));
      return;
    }
    await _todos.put(
      _withLink(
        todo,
        target,
        link.copyWith(
          syncedTitle: todo.title,
          syncedStart: todo.due,
          clearStart: todo.due == null,
          syncedDone: todo.status == TodoStatus.done,
          unsynced: false,
          clearConflict: true,
        ),
      ),
    );
  }
}
