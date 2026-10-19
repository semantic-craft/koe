part of '../recorder_controller.dart';

/// Thrown when an earlier paid extraction for the same recording never
/// reported back. The user decides whether to send it again.
class TodoExtractionUnknown implements Exception {
  const TodoExtractionUnknown();

  @override
  String toString() => '上次提取结果未知，确认后再重新提取';
}

/// Koe todos (#136): extraction from transcripts with Qwen, status changes,
/// and the explicit Reminders (#137) / Calendar (#138) exports that stay in
/// step with them.
///
/// Mixed into [RecorderController]; members the rest of the controller owns
/// are declared abstract at the top so this part compiles on its own terms.
mixin _RecorderTodos on ChangeNotifier {
  // --- Provided by RecorderController and its other parts. ---
  // ignore: unused_element_parameter
  String _recordingKey({int? fileId, String? path});
  AnalysisService _contextService(String systemPrompt);
  String get analysisApiKey;
  abstract final RecordingAnalysis analysis;
  RecordingViewData recordingView(RecordingReference ref);
  List<TranscriptSegment> transcriptSegmentsForPath(String path);
  String? transcriptForPath(String path);
  // END DEPS

  late final TodoStore todos;
  late final SystemTasks _systemTasks;
  final Map<String, Future<int>> _todoExtractionsInFlight = {};
  final Set<String> _todoExportsInFlight = {};
  Future<void>? _systemSync;

  /// Last system-app problem worth telling the user about.
  String? systemTasksNotice;

  String get _contextModel => analysis.model ?? 'qwen3.8-flash';

  /// Whether a previous extraction for [ref] never reported its result.
  bool todoExtractionUnknown(RecordingReference ref) {
    final path = ref.path;
    if (path == null) return false;
    final record = todos.extractionFor(_recordingKey(path: path));
    return record != null && !record.done;
  }

  /// Extracts commitments from one recording's transcript and returns how
  /// many todos it added. Running it again on the same text adds nothing and
  /// sends no request; an unknown earlier result needs [confirmRetry].
  Future<int> extractTodos(
    RecordingReference ref, {
    bool confirmRetry = false,
  }) {
    final path = recordingView(ref).path ?? ref.path;
    if (path == null) throw StateError('找不到这条录音');
    final key = _recordingKey(path: path);
    return _todoExtractionsInFlight[key] ??=
        _extractTodos(key, path, confirmRetry).whenComplete(() {
          _todoExtractionsInFlight.remove(key);
        });
  }

  Future<int> _extractTodos(String key, String path, bool confirmRetry) async {
    await todos.load();
    final text = transcriptForPath(path)?.trim() ?? '';
    if (text.isEmpty) throw StateError('这条录音还没有文字，转写后再提取待办');
    final apiKey = analysisApiKey;
    if (apiKey.isEmpty) throw StateError('先在设置里配置通义千问，再提取待办');
    final timed = transcriptSegmentsForPath(path);
    final segments = timed.isNotEmpty
        ? timed
        : [TranscriptSegment(text: text, start: Duration.zero)];
    final fingerprint = analysisFingerprint(text);
    final previous = todos.extractionFor(key);
    if (previous != null &&
        previous.done &&
        previous.fingerprint == fingerprint) {
      return 0;
    }
    if (previous != null && !previous.done && !confirmRetry) {
      throw const TodoExtractionUnknown();
    }
    final open = [
      for (final todo in todos.todos)
        if (todo.open) todo,
    ];
    final view = recordingView(RecordingReference(path: path));
    final instruction = commitmentInstruction(
      view.recordedAt ?? view.importedAt ?? DateTime.now(),
    );
    await todos.markExtraction(
      key,
      TodoExtraction(fingerprint: fingerprint, done: false),
    );
    final String raw;
    try {
      raw = await _contextService(commitmentSystemPrompt).generate(
        model: _contextModel,
        apiKey: apiKey,
        source: commitmentSource(segments, open),
        instruction: instruction,
        abort: Completer<void>().future,
      );
    } on TimeoutException {
      // The provider may have run it; keep the marker so a retry is a choice.
      rethrow;
    } catch (_) {
      await todos.markExtraction(key, previous);
      rethrow;
    }
    final CommitmentChanges changes;
    try {
      changes = parseCommitments(
        raw,
        segments: segments,
        openTodos: open,
        recordingKey: key,
        path: path,
        now: DateTime.now(),
      );
    } catch (_) {
      await todos.markExtraction(key, previous);
      rethrow;
    }
    String norm(String value) => value.replaceAll(RegExp(r'\s+'), '');
    final known = {
      for (final todo in todos.todosFromRecording(key))
        '${todo.kind.name}:${norm(todo.title)}',
    };
    final added = [
      for (final todo in changes.added)
        if (known.add('${todo.kind.name}:${norm(todo.title)}')) todo,
    ];
    await todos.applyExtraction(
      recordingKey: key,
      fingerprint: fingerprint,
      added: added,
      updated: changes.updated,
      clarifications: changes.clarifications,
    );
    for (final todo in changes.updated) {
      unawaited(_pushLinks(todo.id));
    }
    return added.length;
  }

  Future<void> setTodoStatus(String id, TodoStatus status) =>
      _changeTodo(id, (todo) => todo.copyWith(status: status));

  /// The user's correction of a todo's title, kind or due date.
  Future<void> editTodo(
    String id, {
    String? title,
    TodoKind? kind,
    DateTime? due,
    bool? dueHasTime,
    bool clearDue = false,
  }) => _changeTodo(
    id,
    (todo) => todo.copyWith(
      title: title?.trim().isEmpty == true ? null : title?.trim(),
      kind: kind,
      due: due,
      dueHasTime: dueHasTime,
      clearDue: clearDue,
    ),
  );

  Future<void> setTodoProjects(String id, List<String> projectIds) =>
      _changeTodo(id, (todo) => todo.copyWith(projectIds: projectIds));

  Future<void> _changeTodo(String id, Todo Function(Todo todo) change) async {
    final todo = todos.todoById(id);
    if (todo == null) throw StateError('找不到这条待办');
    await todos.put(change(todo).copyWith(updatedAt: DateTime.now()));
    unawaited(_pushLinks(id));
  }

  /// Applies an unclear later sentence to the todo the user picked, or just
  /// dismisses it when [todoId] is null.
  Future<void> resolveTodoClarification(String id, String? todoId) async {
    final item = todos.clarifications.where((c) => c.id == id).firstOrNull;
    if (item == null) return;
    final target = todoId == null ? null : todos.todoById(todoId);
    if (target != null) {
      await todos.put(
        applyTodoAction(
          target,
          item.action,
          item.due,
          item.dueHasTime,
          DateTime.now(),
        ),
      );
      unawaited(_pushLinks(target.id));
    }
    await todos.resolveClarification(id);
  }

  // ---- System apps (#137 / #138) ---------------------------------------

  /// Writes the todo into Reminders after the user confirmed it. A todo that
  /// is already linked is updated in place, never created twice.
  Future<void> exportTodoToReminders(String id) =>
      _export(id, SystemTaskTarget.reminder, null, null);

  /// Writes the todo into Calendar for [start]–[end] after the user
  /// confirmed it. A todo without a due date takes [start] as its due time.
  Future<void> exportTodoToCalendar(
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
    if (!_todoExportsInFlight.add(guard)) return;
    try {
      var todo = todos.todoById(id);
      if (todo == null) throw StateError('找不到这条待办');
      final existing = target == SystemTaskTarget.reminder
          ? todo.reminder
          : todo.calendar;
      if (existing != null) {
        await _syncLink(id, target);
        return;
      }
      if (!await _systemTasks.requestAccess(target)) {
        throw SystemTasksUnavailable(
          target == SystemTaskTarget.reminder
              ? '没有访问提醒事项的权限；Koe 里的待办不受影响'
              : '没有访问日历的权限；Koe 里的待办不受影响',
        );
      }
      if (target == SystemTaskTarget.event && todo.due == null) {
        await todos.put(todo.copyWith(due: start, dueHasTime: true));
        todo = todos.todoById(id)!;
      }
      final from = target == SystemTaskTarget.event ? start : todo.due;
      final externalId = await _systemTasks.save(
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
      await todos.put(
        target == SystemTaskTarget.reminder
            ? todo.copyWith(reminder: link)
            : todo.copyWith(calendar: link),
      );
    } finally {
      _todoExportsInFlight.remove(guard);
    }
  }

  /// Removes Koe's link; the system item and the Koe todo both stay.
  Future<void> unlinkTodo(String id, SystemTaskTarget target) async {
    final todo = todos.todoById(id);
    if (todo == null) return;
    await todos.put(
      target == SystemTaskTarget.reminder
          ? todo.copyWith(clearReminder: true)
          : todo.copyWith(clearCalendar: true),
    );
  }

  /// Settles a conflict: [keepKoe] pushes Koe's values, otherwise the
  /// system app's values replace Koe's.
  Future<void> resolveSystemConflict(
    String id,
    SystemTaskTarget target, {
    required bool keepKoe,
  }) async {
    final todo = todos.todoById(id);
    final link = _linkOf(todo, target);
    final external = link?.conflict;
    if (todo == null || link == null || external == null) return;
    if (keepKoe) {
      await _writeLink(todo, target, link.copyWith(clearConflict: true));
      return;
    }
    final updated = _applyExternal(todo, target, external);
    await todos.put(
      _withLink(updated, target, _agreed(updated, target, external)),
    );
  }

  /// Reconciles every linked todo with its system item. Runs on demand
  /// (opening Today or a todo, returning to the app); never in a loop.
  Future<void> syncSystemLinks() => _systemSync ??= () async {
    try {
      await todos.load();
      for (final todo in todos.todos) {
        if (todo.reminder != null) {
          await _syncLink(todo.id, SystemTaskTarget.reminder);
        }
        if (todo.calendar != null) {
          await _syncLink(todo.id, SystemTaskTarget.event);
        }
      }
    } finally {
      _systemSync = null;
    }
  }();

  Future<void> _pushLinks(String id) async {
    final todo = todos.todoById(id);
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
    final todo = todos.todoById(id);
    final link = _linkOf(todo, target);
    if (todo == null || link == null || link.conflict != null) return;
    final SystemSnapshot? ext;
    try {
      ext = await _systemTasks.fetch(target, link.externalId);
    } on SystemTasksUnavailable catch (error) {
      systemTasksNotice = error.message;
      await todos.put(_withLink(todo, target, link.copyWith(unsynced: true)));
      return;
    }
    if (ext == null) {
      // Deleted in the system app: only the link goes away.
      systemTasksNotice = target == SystemTaskTarget.reminder
          ? '提醒事项里的条目已删除，已解除关联；Koe 待办保留'
          : '日历里的事件已删除，已解除关联；Koe 待办保留';
      await todos.put(
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
      await todos.put(
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
        await _systemTasks.save(
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
      systemTasksNotice = error.message;
      await todos.put(_withLink(todo, target, link.copyWith(unsynced: true)));
      return;
    }
    await todos.put(
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
