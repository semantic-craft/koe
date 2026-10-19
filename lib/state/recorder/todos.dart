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
  List<TranscriptSegment> quotableSegmentsForPath(String path);
  String? transcriptForPath(String path);
  // END DEPS

  late final TodoStore todos;
  late final TodoSystemSync _todoSync;
  final Map<String, Future<int>> _todoExtractionsInFlight = {};

  /// Last system-app problem worth telling the user about.
  String? get systemTasksNotice => _todoSync.notice;

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
    final segments = quotableSegmentsForPath(path);
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
      _todoSync.exportToReminders(id);

  /// Writes the todo into Calendar for [start]–[end] after the user
  /// confirmed it. A todo without a due time takes [start] as its due time.
  Future<void> exportTodoToCalendar(
    String id, {
    required DateTime start,
    required DateTime end,
  }) => _todoSync.exportToCalendar(id, start: start, end: end);

  /// Removes Koe's link; the system item and the Koe todo both stay.
  Future<void> unlinkTodo(String id, SystemTaskTarget target) =>
      _todoSync.unlink(id, target);

  /// Settles a conflict: [keepKoe] pushes Koe's values, otherwise the
  /// system app's values replace Koe's.
  Future<void> resolveSystemConflict(
    String id,
    SystemTaskTarget target, {
    required bool keepKoe,
  }) => _todoSync.resolveConflict(id, target, keepKoe: keepKoe);

  /// Reconciles every linked todo with its system item. Runs on demand
  /// (opening Today or a todo, returning to the app); never in a loop.
  Future<void> syncSystemLinks() => _todoSync.syncAll();

  Future<void> _pushLinks(String id) => _todoSync.pushLinks(id);
}
