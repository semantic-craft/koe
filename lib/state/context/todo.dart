import 'context_file.dart';
import 'context_item.dart';

/// Whose commitment a todo is. Only [mine] counts as the user's own todo.
enum TodoKind { mine, wish, others }

enum TodoStatus { open, done, cancelled }

String todoKindLabel(TodoKind kind) => switch (kind) {
  TodoKind.mine => '我的待办',
  TodoKind.wish => '愿望',
  TodoKind.others => '他人承诺',
};

String todoStatusLabel(TodoStatus status) => switch (status) {
  TodoStatus.open => '未完成',
  TodoStatus.done => '已完成',
  TodoStatus.cancelled => '已取消',
};

/// Where a todo is mirrored in a system app (Reminders or Calendar).
///
/// The `synced*` fields are both sides' agreed values at the last successful
/// sync. A side whose current value differs from them changed since; when
/// both sides changed the same field differently that is a [conflict].
class SystemLink {
  const SystemLink({
    required this.externalId,
    required this.syncedTitle,
    this.syncedStart,
    this.syncedEnd,
    this.syncedDone = false,
    this.unsynced = false,
    this.conflict,
  });

  final String externalId;
  final String syncedTitle;

  /// Reminder due time, or calendar event start.
  final DateTime? syncedStart;
  final DateTime? syncedEnd;
  final bool syncedDone;

  /// The last attempt could not reach the system app (no permission, error).
  final bool unsynced;

  /// The external values that clash with Koe's, until the user picks one.
  final SystemSnapshot? conflict;

  SystemLink copyWith({
    String? syncedTitle,
    DateTime? syncedStart,
    bool clearStart = false,
    DateTime? syncedEnd,
    bool clearEnd = false,
    bool? syncedDone,
    bool? unsynced,
    SystemSnapshot? conflict,
    bool clearConflict = false,
  }) => SystemLink(
    externalId: externalId,
    syncedTitle: syncedTitle ?? this.syncedTitle,
    syncedStart: clearStart ? null : (syncedStart ?? this.syncedStart),
    syncedEnd: clearEnd ? null : (syncedEnd ?? this.syncedEnd),
    syncedDone: syncedDone ?? this.syncedDone,
    unsynced: unsynced ?? this.unsynced,
    conflict: clearConflict ? null : (conflict ?? this.conflict),
  );

  Map<String, Object?> toJson() => {
    'externalId': externalId,
    'syncedTitle': syncedTitle,
    if (syncedStart != null) 'syncedStart': syncedStart!.toIso8601String(),
    if (syncedEnd != null) 'syncedEnd': syncedEnd!.toIso8601String(),
    if (syncedDone) 'syncedDone': true,
    if (unsynced) 'unsynced': true,
    if (conflict != null) 'conflict': conflict!.toJson(),
  };

  static SystemLink? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['externalId'];
    final title = value['syncedTitle'];
    if (id is! String || id.isEmpty || title is! String) return null;
    return SystemLink(
      externalId: id,
      syncedTitle: title,
      syncedStart: decodeTime(value['syncedStart']),
      syncedEnd: decodeTime(value['syncedEnd']),
      syncedDone: value['syncedDone'] == true,
      unsynced: value['unsynced'] == true,
      conflict: SystemSnapshot.decode(value['conflict']),
    );
  }
}

/// What a system app currently holds for a linked item.
class SystemSnapshot {
  const SystemSnapshot({
    required this.title,
    this.start,
    this.end,
    this.done = false,
  });

  final String title;
  final DateTime? start;
  final DateTime? end;
  final bool done;

  Map<String, Object?> toJson() => {
    'title': title,
    if (start != null) 'start': start!.toIso8601String(),
    if (end != null) 'end': end!.toIso8601String(),
    if (done) 'done': true,
  };

  static SystemSnapshot? decode(Object? value) {
    if (value is! Map || value['title'] is! String) return null;
    return SystemSnapshot(
      title: value['title'] as String,
      start: decodeTime(value['start']),
      end: decodeTime(value['end']),
      done: value['done'] == true,
    );
  }
}

/// A commitment heard in a recording. [quote] is the sentence it came from
/// and [source] points at that sentence in the original audio.
class Todo {
  const Todo({
    required this.id,
    required this.kind,
    required this.title,
    required this.source,
    required this.quote,
    required this.createdAt,
    required this.updatedAt,
    this.owner,
    this.status = TodoStatus.open,
    this.due,
    this.dueHasTime = false,
    this.projectIds = const [],
    this.reminder,
    this.calendar,
  });

  final String id;
  final TodoKind kind;
  final String title;

  /// Who promised it, for [TodoKind.others].
  final String? owner;
  final TodoStatus status;

  /// Only set when the words gave a date; [dueHasTime] says whether they
  /// also gave a time of day. Koe never guesses a time.
  final DateTime? due;
  final bool dueHasTime;
  final ContextSource source;
  final String quote;
  final List<String> projectIds;
  final DateTime createdAt;
  final DateTime updatedAt;
  final SystemLink? reminder;
  final SystemLink? calendar;

  bool get open => status == TodoStatus.open;

  Todo copyWith({
    TodoKind? kind,
    String? title,
    String? owner,
    TodoStatus? status,
    DateTime? due,
    bool clearDue = false,
    bool? dueHasTime,
    List<String>? projectIds,
    DateTime? updatedAt,
    SystemLink? reminder,
    bool clearReminder = false,
    SystemLink? calendar,
    bool clearCalendar = false,
  }) => Todo(
    id: id,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    owner: owner ?? this.owner,
    status: status ?? this.status,
    due: clearDue ? null : (due ?? this.due),
    dueHasTime: clearDue ? false : (dueHasTime ?? this.dueHasTime),
    source: source,
    quote: quote,
    projectIds: projectIds ?? this.projectIds,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    reminder: clearReminder ? null : (reminder ?? this.reminder),
    calendar: clearCalendar ? null : (calendar ?? this.calendar),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    if (owner != null) 'owner': owner,
    'status': status.name,
    if (due != null) 'due': due!.toIso8601String(),
    if (dueHasTime) 'dueHasTime': true,
    'source': source.toJson(),
    'quote': quote,
    if (projectIds.isNotEmpty) 'projectIds': projectIds,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (reminder != null) 'reminder': reminder!.toJson(),
    if (calendar != null) 'calendar': calendar!.toJson(),
  };

  static Todo? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final title = value['title'];
    final quote = value['quote'];
    final source = ContextSource.decode(value['source']);
    final createdAt = decodeTime(value['createdAt']);
    final kind = TodoKind.values
        .where((item) => item.name == value['kind'])
        .firstOrNull;
    final status = TodoStatus.values
        .where((item) => item.name == value['status'])
        .firstOrNull;
    if (id is! String ||
        title is! String ||
        quote is! String ||
        source == null ||
        createdAt == null ||
        kind == null) {
      return null;
    }
    final owner = value['owner'];
    return Todo(
      id: id,
      kind: kind,
      title: title,
      owner: owner is String && owner.isNotEmpty ? owner : null,
      status: status ?? TodoStatus.open,
      due: decodeTime(value['due']),
      dueHasTime: value['dueHasTime'] == true,
      source: source,
      quote: quote,
      projectIds: decodeIds(value['projectIds']),
      createdAt: createdAt,
      updatedAt: decodeTime(value['updatedAt']) ?? createdAt,
      reminder: SystemLink.decode(value['reminder']),
      calendar: SystemLink.decode(value['calendar']),
    );
  }
}

/// A later sentence that may change an existing todo, but Koe cannot tell
/// which one. The user picks the todo (or dismisses it); nothing changes
/// until then.
class TodoClarification {
  const TodoClarification({
    required this.id,
    required this.action,
    required this.quote,
    required this.source,
    this.due,
    this.dueHasTime = false,
  });

  final String id;

  /// `done`, `reschedule` or `cancel`.
  final String action;
  final String quote;
  final ContextSource source;
  final DateTime? due;
  final bool dueHasTime;

  String get actionLabel => switch (action) {
    'done' => '可能已完成',
    'cancel' => '可能已取消',
    _ => '可能改期',
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'action': action,
    'quote': quote,
    'source': source.toJson(),
    if (due != null) 'due': due!.toIso8601String(),
    if (dueHasTime) 'dueHasTime': true,
  };

  static TodoClarification? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final action = value['action'];
    final quote = value['quote'];
    final source = ContextSource.decode(value['source']);
    if (id is! String ||
        action is! String ||
        quote is! String ||
        source == null) {
      return null;
    }
    return TodoClarification(
      id: id,
      action: action,
      quote: quote,
      source: source,
      due: decodeTime(value['due']),
      dueHasTime: value['dueHasTime'] == true,
    );
  }
}
