import 'context_file.dart';

/// What a personal-context item stands for.
enum ContextKind { recording, place, todo, calendar, note, document }

/// Points into an original recording or text material instead of copying
/// its words.
///
/// [recordingKey] is the controller's stable recording identity (`file:<id>`
/// or `path:<path>`); [path] is only a hint for opening the file and may go
/// stale after a rename. [start]/[end] are offsets into the audio.
///
/// A text material (typed note, text-only capture, imported 妙记 text) uses
/// `doc:<id>` and [line], the sentence index in it; it has no audio to replay.
class ContextSource {
  const ContextSource({
    required this.recordingKey,
    this.path,
    this.start = Duration.zero,
    this.end,
    this.line,
  });

  static String documentKey(String documentId) => 'doc:$documentId';

  final String recordingKey;
  final String? path;
  final Duration start;
  final Duration? end;
  final int? line;

  /// The text material this points into, or null for a recording.
  String? get documentId =>
      recordingKey.startsWith('doc:') ? recordingKey.substring(4) : null;

  Map<String, Object?> toJson() => {
    'recordingKey': recordingKey,
    if (path != null) 'path': path,
    'startMs': start.inMilliseconds,
    if (end != null) 'endMs': end!.inMilliseconds,
    if (line != null) 'line': line,
  };

  static ContextSource? decode(Object? value) {
    if (value is! Map) return null;
    final key = value['recordingKey'];
    final startMs = value['startMs'];
    final endMs = value['endMs'];
    final line = value['line'];
    if (key is! String || key.isEmpty) return null;
    return ContextSource(
      recordingKey: key,
      path: value['path'] is String ? value['path'] as String : null,
      start: Duration(
        milliseconds: startMs is int && startMs > 0 ? startMs : 0,
      ),
      end: endMs is int ? Duration(milliseconds: endMs) : null,
      line: line is int && line >= 0 ? line : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContextSource &&
      other.recordingKey == recordingKey &&
      other.path == path &&
      other.start == start &&
      other.end == end &&
      other.line == line;

  @override
  int get hashCode => Object.hash(recordingKey, path, start, end, line);
}

/// One thing that happened in the user's life, as Koe knows it.
///
/// [start] is when it happened. It stays null when that is unknown (an
/// imported file without a recording date); [addedAt] is only when Koe got
/// the material and must never be shown as the time it happened.
///
/// [topicIds] mirror the recording's topic until the user corrects them;
/// after that [userEdited] is true and the correction wins over the topic
/// store. [projectIds] are only ever set by the user.
class ContextItem {
  const ContextItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.addedAt,
    this.start,
    this.end,
    this.source,
    this.location,
    this.topicIds = const [],
    this.projectIds = const [],
    this.userEdited = false,
  });

  final String id;
  final ContextKind kind;
  final String title;
  final DateTime? start;
  final DateTime? end;
  final DateTime addedAt;
  final ContextSource? source;

  /// Coarse place label only; coordinates are never stored.
  final String? location;
  final List<String> topicIds;
  final List<String> projectIds;
  final bool userEdited;

  bool get timeKnown => start != null;

  /// Rebuilt from a recording or text material that currently exists;
  /// hidden while that material is gone.
  bool get derived =>
      kind == ContextKind.recording || kind == ContextKind.document;

  /// The moment used to place the item on a day: when it happened, or, with
  /// an unknown time, when Koe received it.
  DateTime get dayAnchor => start ?? addedAt;

  ContextItem copyWith({
    String? title,
    DateTime? start,
    bool clearStart = false,
    DateTime? end,
    bool clearEnd = false,
    DateTime? addedAt,
    ContextSource? source,
    String? location,
    bool clearLocation = false,
    List<String>? topicIds,
    List<String>? projectIds,
    bool? userEdited,
  }) => ContextItem(
    id: id,
    kind: kind,
    title: title ?? this.title,
    start: clearStart ? null : (start ?? this.start),
    end: clearEnd ? null : (end ?? this.end),
    addedAt: addedAt ?? this.addedAt,
    source: source ?? this.source,
    location: clearLocation ? null : (location ?? this.location),
    topicIds: topicIds ?? this.topicIds,
    projectIds: projectIds ?? this.projectIds,
    userEdited: userEdited ?? this.userEdited,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    if (start != null) 'start': start!.toIso8601String(),
    if (end != null) 'end': end!.toIso8601String(),
    'addedAt': addedAt.toIso8601String(),
    if (source != null) 'source': source!.toJson(),
    if (location != null) 'location': location,
    if (topicIds.isNotEmpty) 'topicIds': topicIds,
    if (projectIds.isNotEmpty) 'projectIds': projectIds,
    if (userEdited) 'userEdited': true,
  };

  static ContextItem? decode(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final title = value['title'];
    final addedAt = decodeTime(value['addedAt']);
    final kind = ContextKind.values
        .where((item) => item.name == value['kind'])
        .firstOrNull;
    if (id is! String || id.isEmpty || title is! String || kind == null) {
      return null;
    }
    if (addedAt == null) return null;
    final location = value['location'];
    return ContextItem(
      id: id,
      kind: kind,
      title: title,
      start: decodeTime(value['start']),
      end: decodeTime(value['end']),
      addedAt: addedAt,
      source: ContextSource.decode(value['source']),
      location: location is String && location.trim().isNotEmpty
          ? location.trim()
          : null,
      topicIds: decodeIds(value['topicIds']),
      projectIds: decodeIds(value['projectIds']),
      userEdited: value['userEdited'] == true,
    );
  }

  /// Same derived content; links and the edit flag are compared separately.
  bool sameDerivedFields(ContextItem other) =>
      other.title == title &&
      other.start == start &&
      other.end == end &&
      other.addedAt == addedAt &&
      other.source == source &&
      other.location == location;
}

bool sameLocalDay(DateTime a, DateTime b) {
  final left = a.toLocal();
  final right = b.toLocal();
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

/// Known times first in time order, then unknown-time items by arrival.
int compareContextItems(ContextItem a, ContextItem b) {
  if (a.start != null && b.start != null) return a.start!.compareTo(b.start!);
  if (a.start != null) return -1;
  if (b.start != null) return 1;
  return a.addedAt.compareTo(b.addedAt);
}

bool sameIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
